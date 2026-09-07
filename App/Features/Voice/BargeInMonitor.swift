import Foundation
import OpenWebUIKit
#if os(iOS)
import AVFoundation
import FluidAudio
#endif

/// Listens to the mic while the assistant speaks and fires `onSpeech` when the
/// user starts talking, letting the voice loop cut in (barge-in).
///
/// Detection is a neural voice-activity detector, not a loudness threshold.
/// Device traces from the sibling app showed why: echo cancellation works so
/// well that the assistant's own voice reads as ~0.000 RMS, which collapses any
/// adaptive noise floor to zero and leaves a fixed threshold deciding alone —
/// and the residual echo that leaks through (0.006–0.022 RMS) lands in the *same
/// range* as the user's actual speech (0.038–0.206), with a leak excursion at
/// 0.046 sitting above the quietest voice. No amplitude threshold can separate
/// those two populations, which is exactly what the previous version of this
/// file tried to do: at the shipping sensitivity its threshold was 0.075 —
/// above the quietest voice, so a soft-spoken user could not interrupt at all —
/// and at maximum sensitivity 0.02, inside the residual band, so the assistant
/// cut itself off. This asks a model whether the sound is a human voice instead,
/// and leaves loudness only the job of rejecting what is too quiet to have come
/// from the room.
///
/// Self-contained (its own engine) so it never disturbs the main STT/TTS path.
///
/// The arithmetic — the sensitivity mapping, the decimation, the RMS — lives in
/// `OpenWebUIKit.BargeIn`, where it can be tested without an audio device. What
/// is left here is the AVFoundation glue, and it is iOS-only: `AVAudioSession`
/// does not exist on macOS, and the previous version of this file broke that
/// target outright by reaching for it.
#if os(iOS)
@MainActor
final class BargeInMonitor {
    private var engine = AVAudioEngine()
    private var running = false
    private var onSpeech: (() -> Void)?

    /// Shared across the app: the model is a few MB and loading it per turn
    /// would add a stall to every reply.
    private static var vad: VadManager?
    private static var vadLoadFailed = false

    /// Guards the two values `start()` computes on the MainActor and `analyze`
    /// then reads on the audio thread. A second lock rather than `bufLock`: that
    /// one is taken around the per-buffer sample bookkeeping, while these are
    /// written once per armed sentence and only read afterwards, so sharing
    /// would put a write-once slot inside the hot critical section for nothing.
    private let cfgLock = NSLock()

    /// Never read before `start()` overwrites it — the tap that calls `analyze`
    /// is installed after — so this initial value only keeps the slot
    /// non-optional, at the slider's shipping default.
    nonisolated(unsafe) private var storedTuning = BargeIn.Tuning(sensitivity: 0.5)

    nonisolated private var tuning: BargeIn.Tuning {
        get { cfgLock.lock(); defer { cfgLock.unlock() }; return storedTuning }
        set { cfgLock.lock(); storedTuning = newValue; cfgLock.unlock() }
    }

    private var speechChunks = 0

    // MARK: - Resampling buffer
    //
    // The mic runs at the hardware rate (48 kHz on iPhone); the VAD model is
    // fixed at 16 kHz and 4096-sample chunks.

    private let bufLock = NSLock()
    nonisolated(unsafe) private var pending: [Float] = []
    /// Mean square of the *raw* samples behind each entry of `pending`, kept in
    /// step with it. The loudness gate has to be measured over the same span the
    /// model classifies, and in the units it was calibrated in on device.
    nonisolated(unsafe) private var pendingSq: [Float] = []
    nonisolated(unsafe) private var busy = false

    /// Guarded by `cfgLock`, like the tuning: same write-once-per-`start()`,
    /// read-per-buffer traffic across the audio thread.
    nonisolated(unsafe) private var storedDecimation = 3

    nonisolated private var decimation: Int {
        get { cfgLock.lock(); defer { cfgLock.unlock() }; return storedDecimation }
        set { cfgLock.lock(); storedDecimation = newValue; cfgLock.unlock() }
    }

    /// Downloads and loads the VAD model. Call when the voice screen opens so the
    /// first reply isn't delayed by it.
    static func prepare() async {
        guard vad == nil, !vadLoadFailed else { return }
        do {
            vad = try await VadManager()
            VoiceLog.log("vad.load", "pronto")
        } catch {
            vadLoadFailed = true
            VoiceLog.log("vad.load", "FALHOU: \(error.localizedDescription) — barge-in ficará indisponível")
        }
    }

    /// Returns nil once armed, or the reason it refused. The reason matters:
    /// every failure used to be silent — `lastFailure` had no reader anywhere —
    /// so barge-in could be dead while its setting still read "on" and nothing
    /// said why.
    @discardableResult
    func start(onSpeech: @escaping () -> Void) -> StartFailure? {
        #if targetEnvironment(simulator)
        return .simulator   // no usable mic in the simulator
        #else
        guard Self.vad != nil else {
            let why: StartFailure = Self.vadLoadFailed ? .vadUnavailable : .vadLoading
            VoiceLog.log("barge.start", "sem modelo VAD (\(why)) — não armando")
            return why
        }
        // Re-arming (a new sentence) must not stack a second tap on the input
        // node, so an already-running monitor is torn down first.
        if running { stop() }
        self.onSpeech = onSpeech
        speechChunks = 0
        bufLock.lock(); pending.removeAll(); pendingSq.removeAll(); busy = false; bufLock.unlock()

        let s = UserDefaults.standard.object(forKey: "voice.bargein.sensitivity") as? Double ?? 0.5
        let tuning = BargeIn.Tuning(sensitivity: s)
        self.tuning = tuning

        // The precondition lives here rather than as prose in the caller.
        // `setVoiceProcessingEnabled(true)` needs a session that permits system
        // signal processing; the recorder leaves it on `.record`/`.measurement`,
        // which does not. Reported separately from `.echoCancellation` because
        // this one is a call-ordering mistake in the caller, and saying so is
        // the difference between looking at the mic permission and looking at
        // the line above.
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playAndRecord, session.mode != .measurement else {
            VoiceLog.log("barge.start",
                         "sessão em \(session.category.rawValue)/\(session.mode.rawValue) — não armando")
            return .sessionCategory
        }

        engine = AVAudioEngine()   // fresh engine each time (reuse is unstable)
        let input = engine.inputNode
        // Hard requirement, not the best-effort `try?` it used to be: this is
        // the only thing separating the user's voice from the assistant's
        // coming back through the speaker.
        do {
            try input.setVoiceProcessingEnabled(true)
            VoiceLog.log("barge.aec", "ativado")
        } catch {
            VoiceLog.log("barge.aec", "FALHOU: \(error.localizedDescription) — não armando")
            return .echoCancellation
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            VoiceLog.log("barge.start", "formato inválido: \(format)")
            stop()   // voice processing is already on; leaving it is a leak
            return .microphone
        }
        // Decimation can only go down. Below 16 kHz the rounded ratio collapses
        // to 0 (and then to 1 through max), which would hand the model
        // half-speed audio labelled as 16 kHz — worse than not arming.
        guard format.sampleRate >= 16_000 else {
            VoiceLog.log("barge.start", "taxa \(Int(format.sampleRate)) Hz < 16 kHz — não armando")
            stop()
            return .microphone
        }
        let decimation = max(1, Int((format.sampleRate / 16_000).rounded()))
        self.decimation = decimation

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buf, _ in
            self?.analyze(buf)
        }
        engine.prepare()
        do { try engine.start(); running = true } catch {
            VoiceLog.log("barge.start", "engine falhou: \(error.localizedDescription)")
            stop()   // the tap is installed and VPIO is on; both must come back off
        }
        VoiceLog.log("barge.start", "armado=\(running) rate=\(Int(format.sampleRate)) decim=\(decimation) limiar=\(tuning.threshold) piso=\(tuning.floor) blocos=\(tuning.chunks)")
        return running ? nil : .microphone
        #endif
    }

    /// Tears down whatever `start` managed to set up. Deliberately NOT guarded
    /// on `running`, as it used to be: a `start` that fails after enabling voice
    /// processing or installing the tap leaves both live with `running == false`,
    /// and refusing to clean that up orphans a tap on an engine the next `start`
    /// replaces. Every step here is idempotent.
    func stop() {
        VoiceLog.log("barge.stop")
        running = false
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        onSpeech = nil
        bufLock.lock(); pending.removeAll(); pendingSq.removeAll(); bufLock.unlock()
    }

    /// Audio-thread callback: decimate to 16 kHz and hand full chunks to the
    /// model. Everything expensive happens off this thread.
    nonisolated private func analyze(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength); guard n > 0 else { return }

        let (down, downSq) = BargeIn.decimate(UnsafeBufferPointer(start: ch, count: n), by: decimation)

        var chunk: [Float]?
        var rms: Float = 0
        bufLock.lock()
        pending.append(contentsOf: down)
        pendingSq.append(contentsOf: downSq)
        if !busy, pending.count >= VadManager.chunkSize {
            chunk = Array(pending.prefix(VadManager.chunkSize))
            pending.removeFirst(VadManager.chunkSize)
            rms = BargeIn.rms(ofMeanSquares: pendingSq.prefix(VadManager.chunkSize))
            pendingSq.removeFirst(VadManager.chunkSize)
            busy = true
        }
        // A stalled model must not grow this without bound.
        if pending.count > VadManager.chunkSize * 8 {
            let drop = pending.count - VadManager.chunkSize * 4
            pending.removeFirst(drop)
            pendingSq.removeFirst(min(drop, pendingSq.count))
        }
        bufLock.unlock()

        guard let chunk else { return }

        let floor = tuning.floor
        // Too quiet, across the whole chunk, to be the user talking into the
        // phone. Skipping here also keeps the Neural Engine idle for most of a
        // reply. A miss costs one chunk off the run rather than the whole run:
        // zeroing it threw away a real interruption whenever one window of it
        // happened to fall quiet.
        guard rms > floor else {
            bufLock.lock(); busy = false; bufLock.unlock()
            Task { @MainActor in self.speechChunks = max(0, self.speechChunks - 1) }
            VoiceLog.metered("barge.level", every: 1.0,
                             "\(VoiceLog.bar(rms)) rms=\(String(format: "%.4f", rms)) < piso \(String(format: "%.3f", floor)) (VAD pulado)")
            return
        }

        Task { [weak self] in
            guard let self else { return }
            await self.classify(chunk, rms: rms)
        }
    }

    /// `NSLock.lock()` is unavailable from an async context (an error in Swift
    /// 6), so the release goes through a synchronous helper rather than being
    /// taken inline in `classify`'s defer.
    nonisolated private func releaseBusy() {
        bufLock.lock(); busy = false; bufLock.unlock()
    }

    nonisolated private func classify(_ chunk: [Float], rms: Float) async {
        defer { releaseBusy() }
        guard let vad = await Self.vad else { return }
        guard let results = try? await vad.process(chunk) else { return }
        let prob = results.map(\.probability).max() ?? 0

        await MainActor.run {
            let tuning = self.tuning
            if prob >= tuning.threshold { self.speechChunks += 1 } else { self.speechChunks = 0 }
            VoiceLog.metered("barge.vad", every: 0.5,
                             "\(VoiceLog.bar(rms)) rms=\(String(format: "%.4f", rms)) fala=\(String(format: "%.2f", prob)) limiar=\(tuning.threshold) blocos=\(self.speechChunks)/\(tuning.chunks)")
            if self.speechChunks >= tuning.chunks { self.fire() }
        }
    }

    @MainActor private func fire() {
        VoiceLog.log("barge.FIRE", "rodando=\(running) temCallback=\(onSpeech != nil)")
        guard running, let cb = onSpeech else { return }
        onSpeech = nil
        cb()
    }
}
#else
/// macOS has no `AVAudioSession`, no duplex voice loop and no barge-in — the
/// voice screen is iPhone-only. A no-op keeps `VoiceConversation` compiling for
/// both targets without an `#if` at every call site.
@MainActor
final class BargeInMonitor {
    static func prepare() async {}
    @discardableResult
    func start(onSpeech: @escaping () -> Void) -> StartFailure? { nil }
    func stop() {}
}
#endif

extension BargeInMonitor {
    /// Why the monitor refused to arm. These are refusals rather than degraded
    /// modes: without echo cancellation the monitor hears the assistant, and
    /// without the model it can only guess from loudness, which measurably does
    /// not work here.
    enum StartFailure {
        /// The model is still downloading/loading — the next sentence will arm
        /// normally, so the user is told nothing.
        case vadLoading
        case vadUnavailable
        case echoCancellation
        /// The audio session is in a category/mode that disables system signal
        /// processing — typically `.record`/`.measurement`, which is where the
        /// recorder leaves it. Distinct from `.echoCancellation`, which is the
        /// engine refusing for some other reason: this one is a call-ordering
        /// mistake in the caller.
        case sessionCategory
        case microphone
        case simulator

        /// nil when there is nothing worth interrupting the user about.
        var message: String? {
            switch self {
            case .vadLoading, .simulator:
                return nil
            case .vadUnavailable:
                return L("Barge-in indisponível: o detector de voz não pôde ser carregado.")
            case .echoCancellation:
                return L("Barge-in indisponível: cancelamento de eco não pôde ser ativado.")
            case .sessionCategory:
                return L("Barge-in indisponível: a sessão de áudio está em modo de gravação.")
            case .microphone:
                return L("Barge-in indisponível: o microfone não pôde ser aberto.")
            }
        }
    }
}
