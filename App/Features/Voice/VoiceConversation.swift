import Foundation
import Combine
#if os(iOS)
import UIKit
#endif
import OpenWebUIKit

/// Hands-free voice conversation: **listen → think → speak → listen**, looping
/// until stopped. It glues together the existing STT (`VoiceInputManager`) and
/// TTS (`SpeechManager`) engines with a streamed LLM reply.
///
/// This is the seed of app #2 (the voice-first companion); it lives in the app
/// layer because it depends on Speech/AVFoundation, while the model talk stays in
/// `OpenWebUIKit`.
@MainActor
final class VoiceConversation: ObservableObject {
    enum Phase: Equatable { case idle, listening, thinking, speaking }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var active = false
    @Published var turns: [Turn] = []
    @Published var liveText = ""        // partial user transcription while listening
    @Published var reply = ""           // streaming assistant reply
    @Published var error: String?
    @Published var model: String?
    /// Per-conversation server TTS voice ("" = global default). Persisted per chat.
    @Published var ttsVoice: String = ""

    struct Turn: Identifiable, Equatable { var id: String = UUID().uuidString; let role: String; var text: String; var at = Date() }

    let models: [OWModel]
    private let client: OpenWebUIClient
    private let completions: ChatCompletionsClient
    private let voice = VoiceInputManager()
    private let tts = SpeechManager.shared
    private let bargeMonitor = BargeInMonitor()
    private var persistTask: Task<Void, Never>?

    /// Server chat this voice session is being saved to (created on first reply).
    private var chatID: String?

    private var cancellables = Set<AnyCancellable>()
    private var silenceTimer: Timer?
    private var lastPartial = ""
    private var lastChange = Date()
    // Energy-based endpointing (for engines with no live transcript).
    private var heardSpeech = false
    private var lastLoud = Date()
    private let speechLevel: Float = 0.04
    private var sttIsNative: Bool {
        let e = UserDefaults.standard.string(forKey: "voice.stt.engine")
        return e != "model" && e != "server"
    }
    private var streamTask: Task<Void, Never>?
    private var speakingTurnID = ""

    /// How long the transcription must stay unchanged before we treat the turn as
    /// finished (native engine only — Whisper has no live partials, so there the
    /// user taps the orb to end the turn).
    private let endpointSilence: TimeInterval = 1.6

    private var seeded = false

    init(client: OpenWebUIClient, completions: ChatCompletionsClient, models: [OWModel]) {
        self.client = client
        self.completions = completions
        self.models = models
        self.model = models.first?.id
        voice.client = client   // enables the "server" STT engine
        voice.$partialText
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.partialChanged(t) }
            .store(in: &cancellables)
        voice.$level
            .receive(on: RunLoop.main)
            .sink { [weak self] lvl in self?.levelChanged(lvl) }
            .store(in: &cancellables)
        voice.$error
            .receive(on: RunLoop.main)
            .sink { [weak self] e in if let e { self?.error = e } }
            .store(in: &cancellables)
        // Recover the loop if neural TTS fails to produce audio.
        tts.$neuralError
            .receive(on: RunLoop.main)
            .sink { [weak self] e in
                guard let self, let e, self.phase == .speaking else { return }
                self.error = e
                self.afterSpeaking()
            }
            .store(in: &cancellables)
    }

    // MARK: - Session control

    func toggleSession() {
        if active { stop() } else { Task { await startSession() } }
    }

    /// Loads an existing server chat so voice continues it (one-time, used when
    /// opening the voice screen from a chat's voice button). Carries the chat's
    /// model and its saved per-conversation voice.
    func seedOnce(chatID: String?, messages: [OWMessage], model seedModel: String? = nil) {
        guard !seeded else { return }
        seeded = true
        self.chatID = chatID
        turns = messages.map { m in
            Turn(id: m.id,
                 role: m.role == .user ? "user" : "assistant",
                 text: m.content,
                 at: m.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date())
        }
        model = seedModel ?? messages.last(where: { $0.role == .assistant })?.model ?? model
        if let id = chatID { ttsVoice = UserDefaults.standard.string(forKey: Self.voiceKey(id)) ?? "" }
    }

    /// Sets this conversation's TTS voice (and remembers it for the chat).
    func setVoice(_ v: String) {
        ttsVoice = v
        if let id = chatID { UserDefaults.standard.set(v, forKey: Self.voiceKey(id)) }
    }

    private static func voiceKey(_ id: String) -> String { "voice.chat.\(id).ttsVoice" }

    /// Clears everything for a brand-new conversation (the Voz tab always starts fresh).
    func reset() {
        stop()
        turns = []; reply = ""; liveText = ""; error = nil
        chatID = nil; seeded = false; ttsVoice = ""
    }

    func startSession() async {
        guard !active else { return }
        active = true; error = nil; reply = ""
        tts.duplexSession = true   // play-AND-record so barge-in can listen mid-reply
        enableProximity()
        await listen()
    }

    func stop() {
        active = false
        // Save before tearing the turn down. Ending the session used to throw the
        // whole conversation away: `persist()` ran inside `streamTask`, so
        // cancelling it cancelled the save's very first request and nothing
        // reached the server — with a raw CancellationError shown as the reason.
        schedulePersist()
        streamTask?.cancel(); streamTask = nil
        silenceTimer?.invalidate(); silenceTimer = nil
        bargeMonitor.stop()
        tts.onSpeechFinished = nil
        tts.duplexSession = false
        tts.stop()
        voice.cancel()
        disableProximity()
        phase = .idle
        liveText = ""
    }

    // MARK: - Proximity (raise-to-ear → earpiece, else loudspeaker)

    private var proximityObserver: NSObjectProtocol?

    private func enableProximity() {
        #if os(iOS)
        UIDevice.current.isProximityMonitoringEnabled = true
        NotificationCenter.default
            .publisher(for: UIDevice.proximityStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.tts.applyProximityRoute()
            }
            .store(in: &cancellables)
        #endif
    }

    private func disableProximity() {
        #if os(iOS)
        // Os observers do Combine já serão cancelados automaticamente via cancellables
        UIDevice.current.isProximityMonitoringEnabled = false
        #endif
    }

    /// Tap the orb mid-turn: end listening early, or skip the spoken reply.
    func tapOrb() {
        switch phase {
        case .listening: endTurn()
        case .speaking:  bargeIn()
        case .thinking, .idle: break
        }
    }

    // MARK: - Listen (STT)

    private func listen() async {
        guard active else { return }
        reply = ""; liveText = ""; lastPartial = ""
        heardSpeech = false
        guard await voice.start() else { active = false; phase = .idle; return }
        phase = .listening
        lastChange = Date(); lastLoud = Date()
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSilence() }
        }
    }

    private func partialChanged(_ t: String) {
        guard phase == .listening else { return }
        liveText = t
        if t != lastPartial { lastPartial = t; lastChange = Date() }
    }

    private func levelChanged(_ lvl: Float) {
        guard phase == .listening else { return }
        if lvl > speechLevel { heardSpeech = true; lastLoud = Date() }
    }

    private func checkSilence() {
        guard phase == .listening else { return }
        if sttIsNative {
            // Native has a live transcript — end on a pause after real words.
            guard !lastPartial.isEmpty else { return }
            if Date().timeIntervalSince(lastChange) > endpointSilence { endTurn() }
        } else {
            // Server/Whisper: no live transcript → end on a pause after hearing speech.
            guard heardSpeech else { return }
            if Date().timeIntervalSince(lastLoud) > endpointSilence { endTurn() }
        }
    }

    private func endTurn() {
        guard phase == .listening else { return }
        silenceTimer?.invalidate(); silenceTimer = nil
        phase = .thinking          // freeze the silence watcher; stop() finalizes STT
        Task {
            let text = await voice.stop()
            guard active else { return }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { await listen(); return }   // heard nothing → keep listening
            turns.append(Turn(role: "user", text: t))
            liveText = ""
            ask(t)
        }
    }

    // MARK: - Think (LLM)

    private func ask(_ userText: String) {
        guard let model else { error = L("Nenhum modelo disponível."); phase = .idle; return }
        phase = .thinking
        reply = ""
        var msgs = [OWChatMessageInput(role: "system", text: Self.systemPrompt)]
        for t in turns { msgs.append(OWChatMessageInput(role: t.role, text: t.text)) }
        let replyTurn = Turn(role: "assistant", text: "")
        turns.append(replyTurn)
        speakingTurnID = replyTurn.id
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await u in self.completions.stream(model: model, messages: msgs) {
                    if Task.isCancelled { return }
                    switch u {
                    case .textDelta(let d):
                        self.reply += d
                        if let i = self.turns.lastIndex(where: { $0.id == replyTurn.id }) {
                            self.turns[i].text = self.reply
                        }
                    case .error(let m): self.error = m
                    default: break
                    }
                }
                self.schedulePersist()
                self.speak()
            } catch is CancellationError {
                // The user ended the session or cut in — not a failure to report.
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.afterSpeaking()
            }
        }
    }

    /// Saves the conversation to Open WebUI so it shows up in "Conversas"
    /// Runs the save outside `streamTask`, so stopping the reply never cancels it.
    /// Chained onto the previous save so two turns can't race on the same chat —
    /// two concurrent first-turn saves would each create a chat.
    private func schedulePersist() {
        let previous = persistTask
        persistTask = Task { @MainActor [weak self] in
            await previous?.value
            await self?.persist()
        }
    }

    /// (creates the chat on the first reply, then updates it each turn).
    private func persist() async {
        guard let model else { return }
        let msgs: [OWMessage] = turns.compactMap { t in
            let txt = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !txt.isEmpty else { return nil }
            return OWMessage(id: t.id,
                             role: t.role == "user" ? .user : .assistant,
                             content: txt,
                             model: t.role == "user" ? nil : model,
                             timestamp: t.at.timeIntervalSince1970)
        }
        guard msgs.count >= 2 else { return }
        let firstUser = turns.first { $0.role == "user" }?.text ?? L("Conversa de voz")
        let title = String(firstUser.prefix(50))
        do {
            if let id = chatID {
                // Merge-safe: appends only unseen turns, keeps web-side data.
                try await client.syncChat(id: id, localMessages: msgs, model: model)
            } else {
                let id = try await client.createChat(title: title, model: model, messages: msgs)
                chatID = id
                if !ttsVoice.isEmpty { UserDefaults.standard.set(ttsVoice, forKey: Self.voiceKey(id)) }
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Speak (TTS)

    private func speak() {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard active, !t.isEmpty else { afterSpeaking(); return }
        phase = .speaking
        tts.voiceOverride = ttsVoice.isEmpty ? nil : ttsVoice
        tts.onSpeechFinished = { [weak self] in self?.afterSpeaking() }
        tts.toggle(t, id: speakingTurnID)
        // Listen for the user cutting in (barge-in) while the reply plays.
        let bargeOn = UserDefaults.standard.object(forKey: "voice.bargein.enabled") as? Bool ?? true
        if bargeOn { bargeMonitor.start { [weak self] in self?.bargeIn() } }
    }

    /// User started talking over the reply → stop speaking and listen.
    private func bargeIn() {
        guard phase == .speaking else { return }
        bargeMonitor.stop()
        tts.onSpeechFinished = nil   // transition ourselves (AVAudioPlayer.stop fires no callback)
        tts.stop()
        afterSpeaking()
    }

    private func afterSpeaking() {
        bargeMonitor.stop()
        tts.onSpeechFinished = nil
        guard active else { phase = .idle; return }
        Task { await listen() }
    }

    static let systemPrompt = """
    Você é um companheiro de voz amigável, falando português do Brasil. \
    Responda de forma curta e natural (1 a 3 frases), como numa conversa falada. \
    Nada de listas, markdown ou emojis — apenas fala fluida.
    """
}
