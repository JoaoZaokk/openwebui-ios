import AVFoundation
import os

/// Listens to the mic **while the assistant is speaking** and fires `onSpeech`
/// when the user starts talking — letting the voice loop cut the reply short
/// (barge-in). Voice-processing (acoustic echo cancellation) is enabled so the
/// assistant's own audio coming out of the speaker is largely removed from the
/// mic and doesn't trip a false interruption.
///
/// Self-contained (its own engine) so it never disturbs the main STT/TTS path.
@MainActor
final class BargeInMonitor {
    private var engine = AVAudioEngine()
    private var running = false
    private var onSpeech: (() -> Void)?

    private static let log = Logger(subsystem: "com.zao.openwebui", category: "barge-in")

    /// Why the last `start()` did not arm, or nil if it did.
    ///
    /// Arming has a precondition nothing enforced: the input node only reports a
    /// usable format once the audio session is in a recording-capable category, and
    /// TTS activating a playback session before this runs leaves `inputFormat` at
    /// 0 Hz. Both failure paths — the format guard and a refused `engine.start()` —
    /// simply returned, so barge-in was dead while its setting still read "on" and
    /// nothing anywhere said why. This is a diagnostic, not UI copy: the reason is
    /// AVFoundation jargon and does not belong in the middle of a voice call.
    private(set) var lastFailure: String?

    /// Whether the monitor is actually listening right now.
    var isArmed: Bool { running }

    /// RMS above `threshold` = sound; `hotNeeded` consecutive hot buffers = real
    /// speech (not a transient). `threshold` comes from the user's sensitivity
    /// setting (higher sensitivity → lower threshold → easier to interrupt).
    nonisolated(unsafe) private var threshold: Float = 0.07
    private let hotNeeded = 4
    nonisolated(unsafe) private var hotCount = 0

    static func thresholdForSensitivity(_ s: Double) -> Float {
        Float(0.13 - max(0, min(1, s)) * 0.11)   // s=0 → 0.13 (hard), s=1 → 0.02 (easy)
    }

    func start(onSpeech: @escaping () -> Void) {
        #if targetEnvironment(simulator)
        return   // no usable mic in the simulator
        #else
        guard !running else { return }
        self.onSpeech = onSpeech
        lastFailure = nil
        hotCount = 0
        let s = UserDefaults.standard.object(forKey: "voice.bargein.sensitivity") as? Double ?? 0.5
        threshold = Self.thresholdForSensitivity(s)
        engine = AVAudioEngine()   // fresh engine each time (reuse is unstable)
        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(true)   // AEC against the speaker output
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            // Leaving voice processing on here would strand the input node in a
            // half-configured state that `stop()` can never undo — it returns early
            // on `guard running`, and running was never set.
            try? input.setVoiceProcessingEnabled(false)
            let session = AVAudioSession.sharedInstance()
            lastFailure = "input format \(format.sampleRate) Hz / \(format.channelCount) ch "
                + "under category \(session.category.rawValue)"
            Self.log.error("barge-in not armed: \(self.lastFailure ?? "", privacy: .public)")
            self.onSpeech = nil
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buf, _ in
            self?.analyze(buf)
        }
        engine.prepare()
        do {
            try engine.start()
            running = true
        } catch {
            running = false
            try? input.setVoiceProcessingEnabled(false)
            input.removeTap(onBus: 0)
            self.onSpeech = nil
            lastFailure = error.localizedDescription
            Self.log.error("barge-in engine refused to start: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        onSpeech = nil
    }

    nonisolated private func analyze(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength); guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { let s = ch[i]; sum += s * s }
        let rms = (sum / Float(n)).squareRoot()
        if rms > threshold {
            hotCount += 1
            if hotCount >= hotNeeded { Task { @MainActor in self.fire() } }
        } else {
            hotCount = max(0, hotCount - 1)
        }
    }

    @MainActor private func fire() {
        guard running, let cb = onSpeech else { return }
        onSpeech = nil
        cb()
    }
}
