import Foundation
@preconcurrency import AVFoundation
import Speech
import OpenWebUIKit

/// Records the mic and transcribes to text using the engine chosen in Settings:
/// **native** (`SFSpeechRecognizer`), **model** (a downloaded Whisper/Parakeet
/// ggml via whisper.cpp) or **server** (the Open WebUI server's own STT).
///
/// Audio strategy: the tap copies *raw* mono samples at the hardware rate during
/// recording, then we resample the WHOLE recording to 16 kHz in a single pass at
/// stop. (Per-buffer resampling fragmented the converter's state and produced
/// garbage audio → Whisper guessed random languages and returned nothing.)
@MainActor
final class VoiceInputManager: ObservableObject {
    @Published var isRecording = false
    @Published var processing = false
    @Published var partialText = ""
    @Published var error: String?
    /// Live mic loudness (RMS, ~0…1) — drives energy-based endpointing for engines
    /// that have no live transcript (server / Whisper).
    @Published var level: Float = 0

    // A FRESH engine is created for every recording — reusing one instance across
    // start/stop is unstable on macOS (the 2nd use hung the audio HAL on the main
    // thread and then crashed). A new engine means a clean input node + tap.
    private var engine = AVAudioEngine()

    private static let targetRate: Double = 16_000
    private static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                    sampleRate: targetRate, channels: 1, interleaved: false)!

    // The one piece of state the audio thread really shares, guarded by `lock`.
    // The other four used to carry the same annotation and none of them earned
    // it: `hwRate` and `sawFinal` are read and written on the main actor only,
    // and `request`/`captureToModel` are now copied into the tap's closure
    // before it exists (see `installTap`) instead of being reached through
    // `self` from the render thread.
    nonisolated(unsafe) private var rawSamples: [Float] = []
    private var hwRate: Double = 48_000
    private var captureToModel = false
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var sawFinal = false
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?

    /// True while the on-device model is being read into memory (seconds for a
    /// q5, minutes the first time a Core ML encoder is compiled), so the UI can
    /// say so instead of looking frozen.
    @Published private(set) var loadingModel = false
    /// Set when the last transcription ended in an error (as opposed to a clean
    /// "heard nothing"): the pending recording is kept for a retry in that case.
    private(set) var lastTranscriptionFailed = false
    /// The recording saved to disk by the last `stop()`, until it is transcribed.
    private(set) var pending: PendingAudioStore.Pending?

    private var activeModelID: String { UserDefaults.standard.string(forKey: "voice.stt.model") ?? "" }
    /// Keeps Apple's dictation on the device instead of letting it send audio to
    /// Apple's servers. Off by default: the on-device model is the less accurate
    /// of the two, and forcing it unconditionally — which is what this file used
    /// to do — is the likeliest cause of "it keeps mangling my words".
    private var onDeviceOnly: Bool { UserDefaults.standard.bool(forKey: "voice.stt.onDeviceOnly") }

    /// Injected at startup — required for the "server" STT engine.
    var client: OpenWebUIClient?

    // MARK: - Start

    func start() async -> Bool {
        #if targetEnvironment(simulator)
        error = L("Microfone só funciona no iPhone (não no simulador).")
        return false
        #else
        // Re-entrancy guard: never start a second recording while one is active or
        // a transcription is still running (this was the 2nd-tap freeze/crash).
        guard !isRecording, !processing else { return false }
        error = nil; partialText = ""; sawFinal = false
        lock.withLock { rawSamples = [] }

        let stt = STTEngine.current
        if stt == .model && installedModelURL() == nil {
            error = L("Nenhum modelo Whisper baixado/selecionado. Baixe um em Ajustes › Voz e modelos (ou use o motor Nativo).")
            return false
        }
        guard await requestPermissions() else {
            error = L("Permissão de microfone/voz negada (Ajustes do iPhone).")
            return false
        }
        // State may have changed while awaiting permission.
        guard !isRecording, !processing else { return false }
        // Tear down any leftover engine/tap and build a brand-new engine.
        tearDownEngine()
        engine = AVAudioEngine()

        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            self.error = L("Áudio indisponível: %@", error.localizedDescription)
            return false
        }
        #endif

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            deactivateSession()
            self.error = L("Microfone indisponível.")
            return false
        }
        hwRate = inputFormat.sampleRate
        // Every non-native engine transcribes a finished recording, so they all
        // need the raw buffer rather than Apple's live stream.
        captureToModel = stt.needsRawCapture

        if stt == .native {
            // Apple ships no auto-detecting recognizer, so "detect" degrades to
            // the app language here; only the Whisper engines can actually guess.
            let want = SpeechLanguage.pinned() ?? LanguageManager.shared.current
            guard let rec = Self.recognizer(for: want), rec.isAvailable else {
                deactivateSession()
                error = L("Reconhecimento de voz indisponível para %@ neste aparelho.", want.endonym)
                return false
            }
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = onDeviceOnly && rec.supportsOnDeviceRecognition
            request = req
            task = rec.recognitionTask(with: req) { [weak self] result, err in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.partialText = result.bestTranscription.formattedString
                        if result.isFinal { self.sawFinal = true }
                    }
                    if let err { self.error = L("Reconhecimento: %@", err.localizedDescription); self.sawFinal = true }
                }
            }
        }

        // Both are final before the tap exists — `captureToModel` a few lines up,
        // `request` in the native branch above — so the render thread reads
        // immutable copies instead of main-actor properties. It used to read
        // `self.request` on every buffer while `stop()`/`cancel()` set it to nil
        // from the main actor: an unsynchronized read of a reference, i.e. a use
        // of a released object away from the guard. Taking `lock` inside the tap
        // would fix the race and buy a worse one — unbounded blocking on the
        // real-time audio thread, which drops buffers.
        let req = request
        let toModel = captureToModel
        input.installTap(onBus: 0, bufferSize: 8192, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let lvl = Self.rms(buffer)
            Task { @MainActor in self.level = lvl }
            VoiceLog.metered("mic.level", every: 0.5,
                             "\(VoiceLog.bar(lvl)) rms=\(String(format: "%.4f", lvl))")
            if toModel { self.captureRaw(buffer) }
            else { req?.append(buffer) }
        }

        do {
            engine.prepare()
            try engine.start()
            isRecording = true
            return true
        } catch {
            input.removeTap(onBus: 0)
            deactivateSession()
            self.error = error.localizedDescription
            return false
        }
        #endif
    }

    // MARK: - Stop

    func stop() async -> String {
        guard isRecording else { return "" }
        isRecording = false
        tearDownEngine()
        request?.endAudio()
        deactivateSession()

        let engineNow = STTEngine.current
        if engineNow != .native {
            // Save first, transcribe second (the Redoma pattern): from here on a
            // death of the process — jetsam under a big model, a watchdog, a
            // dropped connection — costs a retry, not the words.
            guard let frames = finishedFrames() else { return "" }
            let language = engineNow == .model ? nil : SpeechLanguage.pinned()?.sttServerCode
            let p = PendingAudioStore.save(frames: frames, engine: engineNow.rawValue, modelID: activeModelID, language: language)
            pending = p
            let text = await transcribe(frames: frames, engine: engineNow, modelID: activeModelID, language: language)
            if let p, !lastTranscriptionFailed { PendingAudioStore.delete(p); pending = nil }
            return text
        }

        for _ in 0..<30 { if sawFinal { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
        task?.cancel(); task = nil; request = nil
        let text = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && error == nil { error = L("Não captei nenhuma fala.") }
        return text
    }

    func cancel() {
        guard isRecording else { return }
        isRecording = false
        tearDownEngine()
        task?.cancel(); task = nil; request = nil
        deactivateSession()
    }

    /// Stops the engine and removes its tap, tolerating a not-running engine.
    /// Removing the tap before deallocating the engine avoids dangling callbacks.
    private func tearDownEngine() {
        let e = engine
        e.inputNode.removeTap(onBus: 0)
        if e.isRunning { e.stop() }
        level = 0
    }

    /// Deactivates the audio session (iOS only — macOS has no AVAudioSession).
    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: - Finished recording

    /// Snapshot of the take as 16 kHz mono, normalized, or nil when it is too
    /// short to mean anything. Frees the raw buffer (a 2-minute take at 48 kHz
    /// is ~23 MB) — the frames are what every engine consumes from here on.
    private func finishedFrames() -> [Float]? {
        let raw = lock.withLock { let r = rawSamples; rawSamples = []; return r }
        guard raw.count > Int(hwRate * 0.3) else {   // < ~0.3 s
            error = L("Áudio muito curto — toque, fale e toque de novo pra parar.")
            return nil
        }
        var frames = resampleTo16k(raw, from: hwRate)
        normalize(&frames)
        return frames
    }

    /// Runs the given engine over finished frames. Used by `stop()` and by the
    /// recovery of a pending recording, which replays the engine, model and
    /// language chosen when it was recorded.
    func transcribe(frames: [Float], engine: STTEngine, modelID: String, language: String?) async -> String {
        lastTranscriptionFailed = false
        switch engine {
        case .server: return await transcribeWithServer(frames: frames, language: language)
        case .model:  return await transcribeWithWhisper(frames: frames, modelID: modelID)
        case .native: return ""
        }
    }

    /// Transcribes a recording left over by an earlier run. Bumps the attempt
    /// counter before the engine loads (a model that killed the app must not
    /// be loaded forever) and deletes the file on success.
    func transcribe(pending p: PendingAudioStore.Pending) async -> String? {
        guard let frames = PendingAudioStore.frames(of: p) else { PendingAudioStore.delete(p); return nil }
        let q = PendingAudioStore.bumpAttempts(p)
        let engine = STTEngine(rawValue: q.engine) ?? .model
        // The take replays the model it was recorded for; when that model is
        // gone (deleted to free space after the jetsam, or a take whose sidecar
        // was never written), the one selected now is the user's answer.
        let recorded = VoiceCatalog.all.first { $0.id == q.modelID }
        let modelID = recorded.flatMap(installedModelURL(for:)) != nil ? q.modelID : activeModelID
        let text = await transcribe(frames: frames, engine: engine, modelID: modelID, language: q.language)
        if !lastTranscriptionFailed { PendingAudioStore.delete(q) }
        return text.isEmpty ? nil : text
    }

    // MARK: - Whisper / Parakeet (on device)

    private func transcribeWithWhisper(frames: [Float], modelID: String) async -> String {
        guard let model = VoiceCatalog.all.first(where: { $0.id == modelID }),
              let url = installedModelURL(for: model) else {
            // Not a clean "heard nothing": the take must survive so the user
            // can pick a model and try again.
            error = L("Nenhum modelo Whisper selecionado."); lastTranscriptionFailed = true; return ""
        }
        processing = true; defer { processing = false }

        // A fixed language beats "auto" (auto guesses romanian on imperfect
        // audio), so the setting defaults to one. Language-tuned models pin
        // their own language regardless — a pt-tuned checkpoint cannot honour a
        // request for German — and only the universal ones read the setting.
        // Parakeet detects the language itself and ignores the code.
        let lang = model.lang.whisperCode ?? Self.chosenWhisperCode()
        let coreMLBytes = ModelDownloadManager.shared.coreMLBytes(model)

        do {
            let text = try await STTRunner.shared.transcribe(
                model: model, url: url, coreMLBytes: coreMLBytes, samples: frames, language: lang,
                onLoading: { Task { @MainActor in self.loadingModel = true } })
                .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
                .replacingOccurrences(of: "[ Silence ]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            loadingModel = false
            if text.isEmpty { error = L("Não captei nenhuma fala.") }
            return text
        } catch {
            loadingModel = false
            lastTranscriptionFailed = true
            self.error = (error as? LocalizedError)?.errorDescription ?? L("Falha na transcrição: %@", error.localizedDescription)
            return ""
        }
    }

    // MARK: - Server STT

    /// Everything the upload-based transcriber does around the one call that
    /// differs: the WAV wrapper and the empty-result message.
    private func transcribeUpload(frames: [Float], _ send: (Data) async throws -> String) async rethrows -> String {
        processing = true; defer { processing = false }
        let t = try await send(WAV.encode(frames, sampleRate: 16_000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { error = L("Não captei nenhuma fala.") }
        return t
    }

    private func transcribeWithServer(frames: [Float], language: String?) async -> String {
        guard let client else { error = L("Servidor de voz indisponível."); lastTranscriptionFailed = true; return "" }
        do {
            return try await transcribeUpload(frames: frames) { wav in
                try await client.transcribe(audio: wav, filename: "speech.wav", mime: "audio/wav", language: language ?? "")
            }
        } catch {
            lastTranscriptionFailed = true
            self.error = L("Transcrição (servidor): %@", error.localizedDescription)
            return ""
        }
    }

    /// Apple's recognizer for the app's UI language, degrading region →
    /// language → nil. Built per recording (not stored) so switching the app
    /// language takes effect on the very next tap; a fixed pt-BR instance is
    /// what made the mic transcribe every language as Portuguese.
    ///
    /// Returns nil rather than `SFSpeechRecognizer()` when nothing matches.
    /// That last resort was the device-locale recognizer, so the ten shipped
    /// languages Apple has no model for (sl, mk, sr, be, bn, ps, lv, lb, ug,
    /// bo) silently transcribed into whatever the *phone* was set to — and it
    /// made the caller's "unavailable for %@" guard dead code, because this
    /// never returned nil. Being told dictation isn't available beats getting
    /// a paragraph of the wrong language.
    private static func recognizer(for lang: AppLanguage) -> SFSpeechRecognizer? {
        let tag = lang.speechLocale
        // Bare codes resolve: Apple canonicalizes "en" to a region of its own
        // choosing even though supportedLocales() only ever lists en-US, en-GB…
        if let r = SFSpeechRecognizer(locale: Locale(identifier: tag)), r.isAvailable { return r }

        let base = tag.split(separator: "-").first.map(String.init) ?? tag
        let supported = SFSpeechRecognizer.supportedLocales()
        // supportedLocales() is a Set, so pick the region deterministically
        // instead of letting hash order decide between en-US and en-IN.
        let regions = supported
            .map { $0.identifier.replacingOccurrences(of: "_", with: "-") }
            .filter { $0.lowercased().hasPrefix(base.lowercased() + "-") }
            .sorted()
        // The device's own region first when it speaks the same language.
        let preferred = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        for candidate in ([preferred] + regions) where regions.contains(candidate) {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: candidate)), r.isAvailable { return r }
        }
        return nil
    }

    /// Whisper language code for the universal models: the pinned speech
    /// language, or "auto" when the user asked the engine to guess (or the
    /// pinned language has no Whisper code, like Uyghur).
    static func chosenWhisperCode() -> String {
        SpeechLanguage.pinned()?.sttServerCode ?? "auto"
    }

    private func installedModelURL() -> URL? {
        guard let model = VoiceCatalog.all.first(where: { $0.id == activeModelID }) else { return nil }
        return installedModelURL(for: model)
    }

    private func installedModelURL(for model: VoiceModel) -> URL? {
        let url = ModelDownloadManager.shared.localURL(model)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Audio plumbing

    /// Mean RMS loudness of the first channel (cheap, runs inside the tap).
    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength); guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { let s = ch[i]; sum += s * s }
        return (sum / Float(n)).squareRoot()
    }

    /// Copies raw mono samples (hardware rate) — fast + safe inside the tap.
    nonisolated private func captureRaw(_ buffer: AVAudioPCMBuffer) {
        guard let chans = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let chCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        if chCount == 1 {
            _ = mono.withUnsafeMutableBufferPointer { memcpy($0.baseAddress!, chans[0], n * MemoryLayout<Float>.size) }
        } else {
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<chCount { s += chans[c][i] }
                mono[i] = s / Float(chCount)
            }
        }
        lock.withLock { rawSamples.append(contentsOf: mono) }
    }

    /// One-pass resample of the whole recording → 16 kHz mono (continuous, so no
    /// fragmentation artifacts).
    private func resampleTo16k(_ samples: [Float], from rate: Double) -> [Float] {
        guard rate != Self.targetRate else { return samples }
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFormat, to: Self.targetFormat),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return samples
        }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        _ = samples.withUnsafeBufferPointer { memcpy(inBuf.floatChannelData![0], $0.baseAddress!, samples.count * MemoryLayout<Float>.size) }

        let outCap = AVAudioFrameCount(Double(samples.count) * Self.targetRate / rate) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: outCap) else { return samples }
        var done = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if done { status.pointee = .noDataNow; return nil }
            done = true; status.pointee = .haveData; return inBuf
        }
        guard let ch = outBuf.floatChannelData?[0] else { return samples }
        return Array(UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
    }

    /// Peak-normalizes quiet recordings so Whisper has enough signal.
    private func normalize(_ x: inout [Float]) {
        var peak: Float = 0
        for v in x { peak = max(peak, abs(v)) }
        guard peak > 0.0001, peak < 0.97 else { return }
        let gain = 0.97 / peak
        for i in x.indices { x[i] *= gain }
    }

    private func requestPermissions() async -> Bool {
        let mic = await withCheckedContinuation { c in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        guard mic else { return false }
        guard STTEngine.current.needsSpeechAuthorization else { return true }
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        return speech
    }
}
