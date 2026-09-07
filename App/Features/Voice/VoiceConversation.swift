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
    /// `.finishing` is the handoff between one turn and the next: the reply is
    /// over and the microphone is not open yet. It exists because several things
    /// can announce the end of a turn at the same instant (the TTS finish
    /// callback, a barge-in, a TTS failure, `ask()`'s own tail) and two of them
    /// arriving used to queue two `listen()` calls.
    enum Phase: Equatable { case idle, listening, thinking, speaking, finishing }

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
    /// False until this reply has queued its first chunk — see
    /// `SpokenText.openingCut`.
    private var openedThisTurn = false
    /// Reply text received but not yet handed to TTS. Complete sentences are cut
    /// off the front as they arrive, so speaking starts on the first one instead
    /// of after the whole generation.
    private var pendingSpeech = ""

    /// How long the transcription must stay unchanged before we treat the turn as
    /// finished (native engine only — Whisper has no live partials, so there the
    /// user taps the orb to end the turn).
    private let endpointSilence: TimeInterval = 1.6

    private var seeded = false

    init(client: OpenWebUIClient, completions: ChatCompletionsClient,
         models: [OWModel], defaultModel: String? = nil) {
        self.client = client
        self.completions = completions
        self.models = models
        // Same remembered pick the chat screen opens with — voice was its own
        // `models.first`, so it reset on every session too.
        self.model = OWModelChoice.resolve(remembered: defaultModel, available: models.map(\.id))
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
        tts.onSpeechFailed = nil
        tts.duplexSession = false
        tts.stop()
        voice.cancel()
        disableProximity()
        phase = .idle
        liveText = ""
        pendingSpeech = ""
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
        case .thinking, .idle, .finishing: break
        }
    }

    // MARK: - Listen (STT)

    private func listen() async {
        // Every exit from here has to leave `.finishing` behind, this one
        // included: nothing else moves out of that phase, so staying in it would
        // park the loop exactly the way the missing guard in afterSpeaking() did.
        // Arriving inactive means stop() ran during the handoff, and `.idle` is
        // the phase it already left.
        guard active else { phase = .idle; return }
        reply = ""; liveText = ""; lastPartial = ""
        heardSpeech = false
        // Release a recorder left running by an interrupted turn — a no-op on the
        // normal path, since cancel() returns at once when nothing is recording.
        // Without it a single stuck engine made every later start() return false,
        // so neither the orb nor "Iniciar conversa" could revive the screen.
        voice.cancel()
        // Failing here ends the session properly instead of only flipping the
        // flags: `active = false; phase = .idle` left the duplex session, the
        // proximity sensor and the barge-in monitor exactly as they were.
        guard await voice.start() else { stop(); return }
        phase = .listening           // the turn handoff is complete
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
        pendingSpeech = ""
        openedThisTurn = false
        var msgs = [OWChatMessageInput(role: "system", text: Self.systemPrompt)]
        for t in turns { msgs.append(OWChatMessageInput(role: t.role, text: t.text)) }
        let replyTurn = Turn(role: "assistant", text: "")
        turns.append(replyTurn)
        speakingTurnID = replyTurn.id
        streamTask = Task { [weak self] in
            guard let self else { return }
            // Timed because the voice loop's wait is not obviously the TTS: with
            // sentence-by-sentence speech the model's own latency to the first
            // sentence is what is left, and there is no way to tell a slow model
            // from a slow synthesis without both marks.
            let t0 = Date()
            var firstDelta = true
            do {
                for try await u in self.completions.stream(model: model, messages: msgs) {
                    if Task.isCancelled { return }
                    switch u {
                    case .textDelta(let d):
                        if firstDelta {
                            firstDelta = false
                            VoiceLog.log("llm.1ºdelta", String(format: "%.0f ms", Date().timeIntervalSince(t0) * 1000))
                        }
                        self.reply += d
                        if let i = self.turns.lastIndex(where: { $0.id == replyTurn.id }) {
                            self.turns[i].text = self.reply
                        }
                        self.pendingSpeech += d
                        self.emitSentences()
                    case .error(let m): self.error = m
                    default: break
                    }
                }
                // Cancelling the consumer of an `AsyncThrowingStream` ends the
                // loop *normally* — the producer turns the cancellation into
                // `continuation.finish()` (see ChatViewModel, which documents
                // this), so `for try await` returns instead of throwing and the
                // `if Task.isCancelled` inside the loop never runs again because
                // no further element arrives. Without this check a barge-in
                // still flushed the half-written sentence and spoke it over the
                // user who had just interrupted.
                if Task.isCancelled { return }
                self.emitSentences(flush: true)
                self.schedulePersist()
                self.finalizeReply(replyTurn.id)
            } catch is CancellationError {
                // The user ended the session or cut in — not a failure to report.
            } catch {
                self.error = OWFailure.msg(error)
                // Same finalization as a clean end. Calling afterSpeaking()
                // directly here jumped straight back to listening while queued
                // sentences were still playing, so the assistant talked into the
                // open microphone of the next turn.
                self.finalizeReply(replyTurn.id)
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
            self.error = OWFailure.msg(error)
        }
    }

    // MARK: - Speak (TTS)

    /// Cuts every complete sentence off `pendingSpeech` and queues it. With
    /// `flush`, whatever is left goes too — the model's last sentence often has
    /// no trailing space to detect.
    ///
    /// The first chunk of a reply is cut by a looser rule
    /// (`SpokenText.openingCut`), for the reason spelled out there.
    private func emitSentences(flush: Bool = false) {
        guard active else { return }
        while let cut = openedThisTurn ? SpokenText.sentenceCut(in: pendingSpeech)
                                       : SpokenText.openingCut(in: pendingSpeech) {
            let sentence = String(pendingSpeech.prefix(cut))
            pendingSpeech.removeFirst(cut)
            queueSpeech(sentence)
        }
        if flush {
            let rest = pendingSpeech
            pendingSpeech = ""
            queueSpeech(rest)
        }
    }

    private func queueSpeech(_ sentence: String) {
        let t = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only a turn that is still thinking (the first sentence) or already
        // speaking may queue audio. Once the turn has been finalized — barge-in,
        // TTS failure, stream error — a late sentence from the still-live stream
        // would otherwise re-enter .speaking on top of a live recording,
        // swapping the audio-session category out from under the recorder.
        guard active, !t.isEmpty, phase == .thinking || phase == .speaking else { return }
        // Ask before committing: `enqueue` silently drops a sentence that is
        // pure markdown, and entering .speaking for one would leave the turn with
        // an empty queue that `closeQueue` could never finish.
        guard SpokenText.isSpeakable(t) else { return }
        VoiceLog.log("tts.frase", "\(openedThisTurn ? "" : "ABERTURA ")\(t.count) chars: \"\(t.prefix(50))\"")
        openedThisTurn = true
        beginSpeaking(turn: speakingTurnID)
        tts.enqueue(t, id: speakingTurnID)
    }

    /// Hands the reply over: if audio is playing, let the queue drain and end the
    /// turn from the finish callback; otherwise end it now. Used by both the
    /// clean end of the stream and the error path, so a mid-reply failure cannot
    /// jump back to listening while sentences are still being spoken.
    private func finalizeReply(_ id: String) {
        if phase == .speaking { tts.closeQueue(id: id) }
        else { afterSpeaking() }   // nothing was ever spoken — empty or failed reply
    }

    /// Enters the speaking phase on the first sentence of a reply.
    private func beginSpeaking(turn: String) {
        guard phase != .speaking else { return }
        phase = .speaking
        tts.voiceOverride = ttsVoice.isEmpty ? nil : ttsVoice
        tts.onSpeechFinished = { [weak self] in self?.afterSpeaking() }
        // Recovers the loop when TTS produces no audio: without it the
        // conversation sits in .speaking forever, waiting for a finish callback
        // that cannot come. This used to watch `SpeechManager.neuralError`, which
        // has a second writer that is not a failure — the "no PocketTTS pack for
        // this language" branch sets it and then speaks anyway, natively. Reading
        // that as "TTS died" reopened the mic over the assistant's own voice, in
        // every one of the 36 languages without a pack.
        tts.onSpeechFailed = { [weak self] message in
            guard let self else { return }
            if let message { self.error = message }
            self.afterSpeaking()
        }
        // The recorder leaves the session in .record/.measurement — a mode that
        // disables system signal processing, i.e. the echo cancellation barge-in
        // depends on. Every engine used to claim the session on its way in, and
        // barge-in was armed on the line right after `toggle()` returned; the
        // queue arms it *before* the first sentence is handed over, so the
        // session has to be configured here.
        tts.prepareDuplexSession()
        let bargeOn = UserDefaults.standard.object(forKey: "voice.bargein.enabled") as? Bool ?? true
        if bargeOn { bargeMonitor.start { [weak self] in self?.bargeIn() } }
    }

    /// User started talking over the reply → drop whatever it was doing and
    /// listen.
    private func bargeIn() {
        guard phase == .speaking else { return }
        VoiceLog.log("barge.corta", "reply=\(reply.count) chars — cancelando stream e fala")
        bargeMonitor.stop()
        // The reply is usually still streaming now that speech starts mid-stream:
        // stopping only the audio left the model writing into `reply`, which
        // listen() had just cleared — so the bubble lost its beginning and the
        // queue kept being fed sentences to speak after the interruption.
        streamTask?.cancel(); streamTask = nil
        // Cancelling alone isn't enough: the stream's tail still runs (see
        // ask()). Dropping the buffered fragment here means that even if
        // something else flushes it, there is nothing left to speak.
        pendingSpeech = ""
        tts.onSpeechFinished = nil   // transition ourselves (AVAudioPlayer.stop fires no callback)
        tts.onSpeechFailed = nil
        tts.stop()
        afterSpeaking()
    }

    /// Ends the current turn and opens the next one — exactly once.
    ///
    /// It neither read nor wrote `phase` before, and `listen()` only reached
    /// `.listening` after `await voice.start()`. Inside that window `bargeIn()`
    /// and the TTS error path still saw `.speaking` and could announce the end of
    /// the same turn a second time; the second `listen()` found the recorder
    /// already running, `voice.start()` returned false, and the session was torn
    /// down with the microphone still live. `.finishing`, set here before
    /// anything can await, is what stops the second call.
    ///
    /// `.thinking` ends a turn here too, and that is not interchangeable with
    /// "only `.speaking`": a reply with nothing speakable in it, or a stream that
    /// failed before the first token, is finalized straight from `.thinking`, and
    /// a speaking-only guard would park the loop in "Pensando…" forever.
    private func afterSpeaking() {
        switch phase {
        case .thinking, .speaking: break
        case .idle, .listening, .finishing: return
        }
        phase = .finishing
        bargeMonitor.stop()
        tts.onSpeechFinished = nil
        tts.onSpeechFailed = nil
        guard active else { phase = .idle; return }
        Task { await listen() }
    }

    static let systemPrompt = """
    Você é um companheiro de voz amigável, falando português do Brasil. \
    Responda de forma curta e natural (1 a 3 frases), como numa conversa falada. \
    Nada de listas, markdown ou emojis — apenas fala fluida.
    """
}
