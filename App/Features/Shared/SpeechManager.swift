import AVFoundation
import SwiftUI
import FluidAudio
import OpenWebUIKit
#if os(iOS)
import UIKit
#endif

/// Text-to-speech with three engines, chosen in Settings:
/// - **native**: Apple `AVSpeechSynthesizer`, in the app's UI language
///   (instant, robotic).
/// - **neural**: FluidAudio **PocketTTS** (CoreML/ANE, much more natural), in
///   the pack matching the app's UI language — Portuguese, English, Spanish,
///   French, German or Italian. ~550 MB per language, downloaded on first use
///   and then synthesized on-device. Any other UI language has no pack upstream
///   and falls back to the native voice.
/// - **server**: the Open WebUI instance's own `/audio/speech`.
@MainActor
final class SpeechManager: NSObject, ObservableObject {
    static let shared = SpeechManager()

    @Published private(set) var speakingID: String?
    @Published private(set) var preparingID: String?   // neural: downloading/synthesizing
    @Published var neuralReady = false
    @Published var neuralError: String?

    /// One-shot hook fired when an utterance finishes (or is cancelled) playing.
    /// The hands-free voice loop uses it to advance to the next turn.
    var onSpeechFinished: (() -> Void)?

    /// Fired when this manager could not produce audio for what it was handed —
    /// the counterpart of `onSpeechFinished`, since a turn that never plays gets
    /// no finish callback and would otherwise hang the loop forever.
    ///
    /// The loop used to learn about that by watching the `@Published neuralError`
    /// string, which is not a failure channel: `speakNeural`'s "no PocketTTS pack
    /// for this language" branch writes it and then speaks anyway, natively. The
    /// loop read that as "TTS died" and reopened the microphone on top of the
    /// assistant's own voice — in any of the 36 UI languages with no pack, i.e.
    /// most of them. Only the paths that genuinely produce no audio call this.
    ///
    /// The message is nil when there is nothing to say about it: a reply that
    /// strips down to no speakable text never plays either, but it is not an
    /// error to put on screen.
    ///
    /// Unlike `onSpeechFinished` this is not one-shot — nothing consumes it, so
    /// it stays installed for the whole turn. Like the finish hook it belongs to
    /// whoever set it; this class never clears either one.
    var onSpeechFailed: ((String?) -> Void)?

    /// Injected at launch — lets the "server" TTS engine reach Open WebUI.
    var client: OpenWebUIClient?
    /// Voices advertised by the server's TTS engine (loaded on demand).
    @Published var serverVoices: [OWVoice] = []
    /// Per-conversation server voice; when set, overrides the global Settings voice.
    var voiceOverride: String?
    /// When true (hands-free voice mode), TTS uses a play-AND-record session so the
    /// barge-in monitor can listen while the assistant speaks.
    var duplexSession = false

    // MARK: - Streaming queue
    //
    // A reply is spoken sentence by sentence as the model writes it, instead of
    // waiting for the whole thing: `toggle()` used to be called once the stream
    // had finished, so in hands-free mode the time to the first word was the
    // model's entire generation plus a full synthesis of the result — total
    // silence for both.

    private var chunks: [String] = []
    private var chunkID: String?
    /// True once the caller promises no further chunks, so the finish callback
    /// waits for the last one instead of firing between sentences.
    private var chunkClosed = false
    private var speakingChunk = false
    /// Reply whose queue was abandoned after a synthesis failure. Later
    /// sentences for it are dropped rather than retried: with a dead server
    /// every one of them would fail the same way, publishing one error per
    /// sentence for the rest of the reply.
    private var failedChunkID: String?

    /// Synthesis started for the sentence at the head of `chunks`, before its
    /// turn to play arrives.
    ///
    /// This holds the *task*, not the finished bytes, and that distinction is
    /// the whole design. Holding bytes meant a sentence whose turn came while
    /// its request was still in flight found nothing ready and started a
    /// second, duplicate synthesis — most likely on exactly the short sentences
    /// ("Sim.", "Claro.") that finish playing before a round trip completes.
    /// Holding the task lets that case await the one job already running.
    ///
    /// Carries the turn, the exact text and the engine, so a queue that moved
    /// on — or an engine switched mid-reply — cannot consume the wrong audio.
    private var pendingSynthesis: (id: String, text: String, engine: String, task: Task<Data, Error>)?

    /// True while a queued reply is being spoken — the voice loop uses it to arm
    /// barge-in the moment real audio starts, not before.
    var isSpeakingQueue: Bool { speakingChunk }

    /// Which engine `pendingSynthesis` was started against, so a mid-reply
    /// engine switch cannot hand PocketTTS audio to a server turn.
    private var engineName: String { UserDefaults.standard.string(forKey: "voice.tts.engine") ?? "native" }

    /// Appends one sentence to the current reply's queue. The first call for an
    /// id starts it; later calls extend it.
    func enqueue(_ text: String, id: String) {
        guard failedChunkID != id else { return }   // this reply's TTS already died
        let clean = SpokenText.strip(text)
        guard !clean.isEmpty else { return }
        if chunkID != id {
            stop()          // a new reply supersedes whatever was playing
            chunkID = id
            chunkClosed = false
        }
        chunks.append(clean)
        pump()
        // pump() bails out while a sentence is playing, so without this the
        // sentence that just arrived would not begin synthesizing until the
        // current one finished — exactly the gap prefetching removes.
        if let cur = chunkID { prefetchNext(id: cur) }
    }

    /// No more sentences are coming for `id`. Fires the finish callback now if
    /// everything queued has already been spoken.
    func closeQueue(id: String) {
        guard chunkID == id else { return }
        chunkClosed = true
        if !speakingChunk && chunks.isEmpty { finished() }
    }

    private func clearQueue() {
        chunks.removeAll()
        chunkID = nil
        chunkClosed = false
        speakingChunk = false
        failedChunkID = nil
        discardPrefetch()
    }

    /// Drops the speculative synthesis. Anything that invalidates the queue has
    /// to call this, or a later sentence could consume audio belonging to a turn
    /// that is already over.
    private func discardPrefetch() {
        pendingSynthesis?.task.cancel()
        pendingSynthesis = nil
    }

    /// One sentence failed to synthesize or play. Abandons the rest of that
    /// reply's queue and publishes the reason.
    ///
    /// Without it the failure paths would leave `speakingChunk` true forever:
    /// `pump()` is gated on it, so no later sentence would ever be dispatched,
    /// and `closeQueue()` — which only fires the finish callback when
    /// `!speakingChunk` — would become a permanent no-op. The turn could then
    /// never end on its own.
    private func chunkFailed(_ id: String, _ message: String) {
        preparingID = nil
        if chunkID == id {
            chunks.removeAll()
            chunkID = nil
            chunkClosed = false
            speakingChunk = false
            failedChunkID = id
            discardPrefetch()
        }
        fail(message)
    }

    /// Starts the next queued sentence, if nothing is playing.
    private func pump() {
        guard !speakingChunk, !chunks.isEmpty, let id = chunkID else { return }
        speakingChunk = true
        let next = chunks.removeFirst()
        let engine = engineName
        if let p = pendingSynthesis, p.id == id, p.text == next, p.engine == engine {
            // Already synthesized, or still in flight — either way, wait on the
            // job that is already running rather than starting a second one.
            pendingSynthesis = nil
            preparingID = id
            neuralError = nil
            speechGeneration &+= 1
            let generation = speechGeneration
            VoiceLog.log("tts.toca", "motor=\(engine) PREFETCH restam=\(chunks.count) \"\(next.prefix(40))\"")
            neuralTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let data = try await p.task.value
                    // The turn can end while this is awaited (barge-in, stop).
                    guard self.isCurrent(generation) else { return }
                    self.play(data, id: id)
                } catch is CancellationError {
                    if self.isCurrent(generation) { self.preparingID = nil }
                } catch {
                    guard self.isCurrent(generation) else { return }
                    self.chunkFailed(id, OWFailure.msg(error))
                }
            }
        } else {
            // Whatever was being prefetched is not what plays next.
            discardPrefetch()
            VoiceLog.log("tts.toca", "motor=\(engine) restam=\(chunks.count) \"\(next.prefix(40))\"")
            dispatchSpeak(next, id: id)
        }
        prefetchNext(id: id)
    }

    /// Starts synthesizing the sentence that will play next, while the current
    /// one is still playing.
    ///
    /// The sentence queue removed the wait for the *whole* reply but left a full
    /// synthesis of dead air at every sentence boundary — the next job only
    /// began once the previous sentence had finished playing. On the server
    /// engine that is one HTTP round trip per sentence; on the neural engine one
    /// PocketTTS pass per sentence. Both are perfectly hideable behind the
    /// sentence already playing.
    ///
    /// The sibling app prefetches only for network engines, on the grounds that
    /// a second neural synthesis would compete with the one being played. That
    /// does not hold here: this fork's neural path synthesizes a whole WAV and
    /// then hands it to `AVAudioPlayer`, so the Neural Engine is idle for the
    /// entire playback and the prefetch has it to itself.
    ///
    /// Native is excluded because it has nothing to prefetch: `AVSpeechUtterance`
    /// is synthesized by the system as it speaks, with no buffer to prepare.
    private func prefetchNext(id: String) {
        let engine = engineName
        guard pendingSynthesis == nil, let text = chunks.first else { return }
        // The neural pack is a ~550 MB load with no in-flight dedupe: prefetching
        // before the *playing* sentence has finished loading it would start a
        // second copy of exactly that load. Once the pack is in memory, every
        // later sentence prefetches normally.
        if engine == "neural" {
            guard let pack = Self.pocketPack(for: LanguageManager.shared.current),
                  pocket != nil, pocketLanguage == pack else { return }
        }
        guard let make = synthesizer(for: engine) else { return }
        let task = Task<Data, Error> { try await Self.timed(text, make) }
        pendingSynthesis = (id: id, text: text, engine: engine, task: task)
        VoiceLog.log("tts.prefetch", "iniciada \"\(text.prefix(40))\"")
    }

    /// Text → audio bytes for one of the two engines that produce a buffer, or
    /// nil when that engine has nothing to produce it with (no server client, no
    /// language pack).
    ///
    /// Everything the engine needs is resolved *here*, on the main actor, and
    /// captured: the returned closure cannot then fail for want of a pack or a
    /// client, and both callers get to decide what a missing one means — the
    /// server engine reports it, the neural one falls back to the native voice.
    private func synthesizer(for engine: String) -> ((String) async throws -> Data)? {
        switch engine {
        case "server":
            guard let client else { return nil }
            let voice = voiceOverride ?? serverVoice, model = serverModel
            return { try await client.speech(text: $0, voice: voice, model: model) }
        case "neural":
            guard let pack = Self.pocketPack(for: LanguageManager.shared.current) else { return nil }
            let voice = neuralVoice
            return { [weak self] text in
                guard let self else { throw CancellationError() }
                let m = try await self.ensurePocket(pack)
                // The pack is only proven usable once it has loaded, so the flag
                // the Settings screen watches is set here rather than up front.
                self.neuralReady = true
                return try await m.synthesize(text: text, voice: voice)
            }
        default:
            return nil
        }
    }

    /// Runs a synthesizer and times it.
    ///
    /// Timed because "the voice is slow" is otherwise unfalsifiable: this number
    /// against the `p.duration` logged at playback says whether synthesis is
    /// slower than speech itself — the only case where a deeper prefetch would
    /// buy anything.
    private static func timed(_ clean: String,
                              _ make: @escaping (String) async throws -> Data) async throws -> Data {
        let t0 = Date()
        let data = try await make(clean)
        VoiceLog.log("tts.sintetizou", String(format: "%.0f ms — %d chars — %d KB",
                                              Date().timeIntervalSince(t0) * 1000,
                                              clean.count, data.count / 1024))
        return data
    }

    /// Routes already-stripped text to the configured engine.
    private func dispatchSpeak(_ clean: String, id: String) {
        if useServer { speakServer(clean, id: id) }
        else if useNeural { speakNeural(clean, id: id) }
        else { speakNative(clean, id: id) }
    }

    /// Common tail of both buffered engines: claim the session, hand the bytes
    /// to a player, start it.
    private func play(_ data: Data, id: String) {
        do {
            activateTTSSession()
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            player = p
            preparingID = nil
            speakingID = id
            VoiceLog.log("tts.áudio", String(format: "%.1f s", p.duration))
            p.play()
        } catch {
            chunkFailed(id, OWFailure.msg(error))
        }
    }

    /// Puts the audio session into the play-and-record configuration the
    /// barge-in monitor needs, before any audio exists.
    ///
    /// The voice loop calls it as it enters `.speaking`, so echo cancellation is
    /// set up ahead of the first spoken sentence rather than after the first
    /// synthesis. That ordering used to be implicit — every engine activated the
    /// session on its way in and barge-in was armed on the line right after
    /// `toggle()` returned — but the queue arms barge-in *before* handing the
    /// first sentence over, so the session has to be claimed by someone else.
    func prepareDuplexSession() {
        activateTTSSession()
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        VoiceLog.log("sessão", "categoria=\(s.category.rawValue) modo=\(s.mode.rawValue) duplex=\(duplexSession)")
        #endif
    }

    /// Configures the session for playback. Failures used to be four `try?`s, so
    /// a session the OS refused to configure produced silent no-audio and nothing
    /// else — while `VoiceInputManager` raises a localized error for the very same
    /// failure on the recording side. It is reported now: `neuralError` is the
    /// channel the voice UI already renders.
    private func activateTTSSession() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        do {
            if duplexSession {
                try s.setCategory(.playAndRecord, mode: .voiceChat,
                                  options: [.duckOthers, .allowBluetoothA2DP])
                try s.setActive(true)
                applyProximityRoute()
            } else {
                try s.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try s.setActive(true)
            }
        } catch {
            fail(L("Áudio indisponível: %@", OWFailure.msg(error)))
        }
        #endif
    }

    /// In hands-free voice mode: loudspeaker when the phone is away from the ear,
    /// earpiece when held to it (driven by the proximity sensor). Call on each TTS
    /// start and whenever proximity changes.
    func applyProximityRoute() {
        #if os(iOS)
        guard duplexSession else { return }
        let near = UIDevice.current.proximityState
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(near ? .none : .speaker)
        #endif
    }

    private let synth = AVSpeechSynthesizer()
    /// Read fresh on every utterance — the user can change the app language at
    /// any time and the next 🔊 must follow it (a stored constant is what made
    /// English replies come out in a Portuguese voice).
    private var language: String { LanguageManager.shared.current.speechLocale }

    // Neural (PocketTTS). One manager per language pack — `pocketLanguage`
    // records which pack is loaded so switching the app language swaps it
    // instead of speaking German with the Portuguese weights.
    private var pocket: PocketTtsManager?
    private var pocketLanguage: PocketTtsLanguage?
    private var player: AVAudioPlayer?
    private var neuralTask: Task<Void, Never>?

    var useNeural: Bool { UserDefaults.standard.string(forKey: "voice.tts.engine") == "neural" }
    var useServer: Bool { UserDefaults.standard.string(forKey: "voice.tts.engine") == "server" }
    private var neuralVoice: String { UserDefaults.standard.string(forKey: "voice.tts.pocketVoice") ?? "alba" }
    private var serverVoice: String { UserDefaults.standard.string(forKey: "voice.tts.serverVoice") ?? "" }
    private var serverModel: String { UserDefaults.standard.string(forKey: "voice.tts.serverModel") ?? "" }

    override init() { super.init(); synth.delegate = self }

    func isSpeaking(_ id: String) -> Bool { speakingID == id }
    func isPreparing(_ id: String) -> Bool { preparingID == id }

    /// Speak `text` for message `id`, or stop if it's already active (toggle).
    func toggle(_ text: String, id: String) {
        if speakingID == id || preparingID == id { stop(); return }
        stop()
        let clean = SpokenText.strip(text)
        // Nothing speakable left (a reply that was only a think block, or bare
        // markdown punctuation). No audio will play and no delegate will fire,
        // so whoever is waiting on this turn has to be told now.
        guard !clean.isEmpty else { onSpeechFailed?(nil); return }
        dispatchSpeak(clean, id: id)
    }

    /// Loads the voices the server's TTS engine offers (for the Settings picker).
    func loadServerVoices() async {
        guard let client else { return }
        serverVoices = await client.audioVoices()
    }

    func stop() {
        clearQueue()
        speechGeneration &+= 1
        neuralTask?.cancel(); neuralTask = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        currentUtterance = nil
        player?.stop(); player = nil
        speakingID = nil; preparingID = nil
        // Neither hook is cleared here. `player.stop()` above fires no delegate
        // callback, so stopping is precisely the moment the owner still has to
        // decide whether the turn ended — and the owner does nil both, at each
        // of its own transitions.
    }

    // MARK: - Native (AVSpeechSynthesizer)

    private func speakNative(_ clean: String, id: String) {
        activateTTSSession()
        let u = AVSpeechUtterance(string: clean)
        u.voice = Self.bestVoice(for: language)
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        currentUtterance = u
        speakingID = id
        synth.speak(u)
    }

    // MARK: - Neural (PocketTTS)

    /// The PocketTTS pack for the app's UI language, or nil when upstream ships
    /// none. Kyutai publishes six packs; everything else falls back to the
    /// native voice rather than reading, say, Japanese with Italian weights.
    static func pocketPack(for lang: AppLanguage) -> PocketTtsLanguage? {
        switch lang {
        case .ptBR:             return .portuguese
        case .en:               return .english
        case .es:               return .spanish
        case .fr:               return .french24L   // upstream ships only the 24-layer French pack
        case .de, .deAT, .deCH: return .german
        case .it:               return .italian
        default:                return nil
        }
    }

    /// True when the neural engine can actually speak the current UI language.
    var neuralAvailableForCurrentLanguage: Bool {
        Self.pocketPack(for: LanguageManager.shared.current) != nil
    }

    /// Proactively downloads + loads the PocketTTS pack for the current language
    /// (so the first 🔊 isn't a multi-minute wait). Safe to call repeatedly.
    func prepareNeural() {
        guard preparingID == nil else { return }
        let lang = LanguageManager.shared.current
        guard let pack = Self.pocketPack(for: lang) else {
            neuralError = L("Voz neural indisponível para %@ — usando a voz nativa.", lang.endonym)
            return
        }
        guard pocket == nil || pocketLanguage != pack else { return }
        preparingID = "__prepare__"
        neuralError = nil
        neuralTask = Task {
            do { _ = try await ensurePocket(pack); neuralReady = true }
            // Any `toggle` calls `stop()`, which cancels this task — so the user
            // starting to speak mid-download painted FluidAudio's raw "cancelled"
            // as a download failure. Their own cancellation is not an error.
            catch { if !Task.isCancelled { neuralError = OWFailure.msg(error) } }
            if preparingID == "__prepare__" { preparingID = nil }
        }
    }

    /// Which utterance the manager is currently serving.
    ///
    /// A cancelled task does not stop where it was cancelled — it resumes at its
    /// next suspension point, by which time the *next* utterance has already
    /// claimed `preparingID`, `neuralError` and `player`. Every one of those
    /// writes used to be unconditional, so tapping 🔊 on a second message wiped
    /// the spinner the second one had just set: it synthesized in silence with its
    /// button reading idle. Comparing ids is not enough — stop-then-replay of the
    /// *same* message hands the stale task a matching id. A counter bumped on
    /// every start and every stop is what actually settles who owns the state.
    private var speechGeneration = 0

    /// True while this task is still the one whose output anyone wants.
    private func isCurrent(_ generation: Int) -> Bool {
        generation == speechGeneration && !Task.isCancelled
    }

    /// The utterance the native engine is speaking, so a delegate callback from
    /// one that has been superseded cannot end the turn that replaced it.
    ///
    /// `stopSpeaking(at: .immediate)` fires `didCancel`, which arrives one
    /// main-actor hop later and funnels into `finished()` exactly like a normal
    /// end. That was harmless while a reply was a single utterance — the `stop()`
    /// and the callback belonged to the same turn — but the queue makes
    /// `enqueue` stop a still-playing reply on behalf of the *next* one, whose
    /// finish hook is already installed. The stale cancellation would then end
    /// the new turn before its first sentence had been spoken.
    private var currentUtterance: AVSpeechUtterance?

    private func speakNeural(_ clean: String, id: String) {
        let lang = LanguageManager.shared.current
        // No pack for this language: say so once and still speak, natively.
        // Silently swapping engines would look like the neural setting is
        // ignored; refusing to speak at all would be worse.
        //
        // This writes `neuralError` on a path that goes on to SPEAK, which is
        // why nothing may read that string as "TTS failed" — see
        // `onSpeechFailed`.
        guard let make = synthesizer(for: "neural") else {
            neuralError = L("Voz neural indisponível para %@ — usando a voz nativa.", lang.endonym)
            speakNative(clean, id: id)
            return
        }
        speakBuffered(clean, id: id, make)
    }

    // MARK: - Server (Open WebUI /audio/speech)

    private func speakServer(_ clean: String, id: String) {
        guard let make = synthesizer(for: "server") else {
            // Synchronous bail-out: it still has to release the queue, or the
            // turn hangs exactly the way an async failure would.
            chunkFailed(id, L("Servidor de voz indisponível."))
            return
        }
        speakBuffered(clean, id: id, failure: { L("TTS do servidor falhou: %@", $0) }, make)
    }

    /// Common body of both engines that produce a finished audio buffer: claim
    /// the turn, synthesize, hand the bytes to `play`.
    ///
    /// It replaces two copies of the same shape that had already drifted apart.
    /// The turn can end while synthesis is awaited (barge-in, stop, a newer
    /// reply), which is what the generation guard before every write is for.
    ///
    /// `failure` wraps the decoded error text, so a dead server stays
    /// distinguishable from a failed on-device synthesis.
    private func speakBuffered(_ clean: String, id: String,
                               failure: @escaping (String) -> String = { $0 },
                               _ make: @escaping (String) async throws -> Data) {
        preparingID = id
        neuralError = nil
        // Claim the audio session now, synchronously, exactly as speakNative
        // does. It used to happen inside the task, after synthesis — but the mic
        // tap was then installed while the session was still `.playback` and the
        // input node reported 0 Hz, so barge-in silently never armed for neural
        // or server TTS.
        activateTTSSession()
        speechGeneration &+= 1
        let generation = speechGeneration
        neuralTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await Self.timed(clean, make)
                guard self.isCurrent(generation) else { return }
                self.play(data, id: id)
            } catch is CancellationError {
                if self.isCurrent(generation) { self.preparingID = nil }
            } catch {
                guard self.isCurrent(generation) else { return }
                self.chunkFailed(id, failure(OWFailure.msg(error)))
            }
        }
    }

    /// Drops the in-memory manager when its pack was deleted from disk, so the
    /// next 🔊 re-downloads instead of speaking from a half-freed cache.
    func forgetPack(_ pack: PocketTtsLanguage) {
        guard pocketLanguage == pack else { return }
        stop()
        pocket = nil
        pocketLanguage = nil
        neuralReady = false
    }

    /// Loads (downloading on first use) the manager for `pack`, reusing the
    /// cached one only when it's the same pack — each language is a separate
    /// ~550 MB download and a separate set of weights.
    private func ensurePocket(_ pack: PocketTtsLanguage) async throws -> PocketTtsManager {
        if let pocket, pocketLanguage == pack { return pocket }
        neuralReady = false
        let m = PocketTtsManager(language: pack, precision: .int8)
        try await m.initialize()
        // The cache only exists once FluidAudio has created it, so flag it after
        // the first load rather than up front.
        NeuralVoiceStore.excludeCacheFromBackup()
        pocket = m
        pocketLanguage = pack
        return m
    }

    /// A real failure to produce audio: shown on the Settings screen and handed
    /// to the voice loop. The loop must never read `neuralError` itself — that
    /// string has a second writer (the missing-pack notice) which goes on to
    /// speak.
    private func fail(_ text: String) {
        neuralError = text
        onSpeechFailed?(text)
    }

    // MARK: - Helpers

    /// Best installed voice for `lang`, degrading region → language → nil.
    /// Returning nil is deliberate: AVSpeechSynthesizer then picks the system
    /// default, which is far better than reading e.g. Japanese with a Brazilian
    /// voice just because that identifier happened to be hard-coded.
    private static func bestVoice(for lang: String) -> AVSpeechSynthesisVoice? {
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            switch v.quality { case .premium: return 3; case .enhanced: return 2; default: return 1 }
        }
        let installed = AVSpeechSynthesisVoice.speechVoices()
        let exact = installed
            .filter { $0.language.caseInsensitiveCompare(lang) == .orderedSame }
            .sorted { rank($0) > rank($1) }
        if let v = exact.first { return v }

        // "de-AT" with no Austrian voice installed should still speak German,
        // not fall through to the system default (often English).
        let base = lang.split(separator: "-").first.map(String.init) ?? lang
        let sameLanguage = installed
            .filter { $0.language.lowercased().hasPrefix(base.lowercased() + "-") }
            .sorted { rank($0) > rank($1) }
        if let v = sameLanguage.first { return v }

        return AVSpeechSynthesisVoice(language: lang) ?? AVSpeechSynthesisVoice(language: base)
    }

}

extension SpeechManager: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.finished(utterance: u) }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.finished(utterance: u) }
    }
}

extension SpeechManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finished(player: player) }
    }
}

private extension SpeechManager {
    /// Both callbacks arrive one main-actor hop after the fact, by which time a
    /// newer sentence — or a whole newer reply — may already own the manager.
    /// Only the source that is still the current one may end a turn.
    func finished(utterance u: AVSpeechUtterance) {
        guard u === currentUtterance else { return }
        currentUtterance = nil
        finished()
    }

    func finished(player p: AVAudioPlayer) {
        guard p === player else { return }
        finished()
    }

    func finished() {
        speakingID = nil
        if speakingChunk {
            speakingChunk = false
            // More sentences ready: keep going without telling the caller the
            // reply is over.
            if !chunks.isEmpty { pump(); return }
            // Nothing queued but the model is still writing — wait for the next
            // sentence rather than ending the turn mid-reply.
            guard chunkClosed else { return }
            chunkID = nil
        }
        let cb = onSpeechFinished
        onSpeechFinished = nil
        cb?()
    }
}

/// The PocketTTS voices (from FluidInference/pocket-tts-coreml).
///
/// The same 26 names ship in **every** language pack — only the acoustic
/// embedding behind each name differs (verified against the repo tree: all of
/// `v2.1/{english,spanish,french_24l,german,italian,portuguese}/constants_bin/`
/// hold an identical set of `<voice>.safetensors`). So one list serves all
/// languages, and a voice the user picked keeps working after switching.
enum PocketVoices {
    static let all = [
        "alba", "anna", "azelma", "bill_boerst", "caro_davy", "charles", "cosette",
        "eponine", "estelle", "eve", "fantine", "george", "giovanni", "jane", "javert",
        "jean", "juergen", "lola", "marius", "mary", "michael", "paul", "peter_yearsley",
        "rafael", "stuart_bell", "vera",
    ]
}
