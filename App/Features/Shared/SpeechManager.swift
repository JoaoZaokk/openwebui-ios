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
/// - **neural**: FluidAudio **PocketTTS** Portuguese pack (CoreML/ANE, much more
///   natural). Downloads ~550 MB on first use, then synthesizes on-device.
///   Portuguese only — upstream ships one voice list per language pack, so the
///   Settings row labels it and the native engine stays the default.
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

    /// Injected at launch — lets the "server" TTS engine reach Open WebUI.
    var client: OpenWebUIClient?
    /// Voices advertised by the server's TTS engine (loaded on demand).
    @Published var serverVoices: [OWVoice] = []
    /// Per-conversation server voice; when set, overrides the global Settings voice.
    var voiceOverride: String?
    /// When true (hands-free voice mode), TTS uses a play-AND-record session so the
    /// barge-in monitor can listen while the assistant speaks.
    var duplexSession = false

    private func activateTTSSession() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        if duplexSession {
            try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .allowBluetoothA2DP])
            try? s.setActive(true)
            applyProximityRoute()
        } else {
            try? s.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try? s.setActive(true)
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

    // Neural (PocketTTS pt-BR)
    private var pocket: PocketTtsManager?
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
        let clean = Self.strip(text)
        guard !clean.isEmpty else { return }
        if useServer { speakServer(clean, id: id) }
        else if useNeural { speakNeural(clean, id: id) }
        else { speakNative(clean, id: id) }
    }

    /// Loads the voices the server's TTS engine offers (for the Settings picker).
    func loadServerVoices() async {
        guard let client else { return }
        serverVoices = await client.audioVoices()
    }

    func stop() {
        neuralTask?.cancel(); neuralTask = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        player?.stop(); player = nil
        speakingID = nil; preparingID = nil
    }

    // MARK: - Native (AVSpeechSynthesizer)

    private func speakNative(_ clean: String, id: String) {
        activateTTSSession()
        let u = AVSpeechUtterance(string: clean)
        u.voice = Self.bestVoice(for: language)
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        speakingID = id
        synth.speak(u)
    }

    // MARK: - Neural (PocketTTS)

    /// Proactively downloads + loads the PocketTTS pt model (so the first 🔊 isn't
    /// a multi-minute wait). Safe to call repeatedly.
    func prepareNeural() {
        guard pocket == nil, preparingID == nil else { return }
        preparingID = "__prepare__"
        neuralError = nil
        neuralTask = Task {
            do { _ = try await ensurePocket(); neuralReady = true }
            catch { neuralError = msg(error) }
            if preparingID == "__prepare__" { preparingID = nil }
        }
    }

    private func speakNeural(_ clean: String, id: String) {
        preparingID = id
        neuralError = nil
        let voice = neuralVoice
        neuralTask = Task {
            do {
                let m = try await ensurePocket()
                neuralReady = true
                let wav = try await m.synthesize(text: clean, voice: voice)
                if Task.isCancelled { preparingID = nil; return }
                activateTTSSession()
                let p = try AVAudioPlayer(data: wav)
                p.delegate = self
                player = p
                preparingID = nil
                speakingID = id
                p.play()
            } catch is CancellationError {
                preparingID = nil
            } catch {
                neuralError = msg(error)
                preparingID = nil
            }
        }
    }

    // MARK: - Server (Open WebUI /audio/speech)

    private func speakServer(_ clean: String, id: String) {
        guard let client else { neuralError = L("Servidor de voz indisponível."); return }
        preparingID = id
        neuralError = nil
        let voice = voiceOverride ?? serverVoice, model = serverModel
        neuralTask = Task {
            do {
                let data = try await client.speech(text: clean, voice: voice, model: model)
                if Task.isCancelled { preparingID = nil; return }
                activateTTSSession()
                let p = try AVAudioPlayer(data: data)
                p.delegate = self
                player = p
                preparingID = nil
                speakingID = id
                p.play()
            } catch is CancellationError {
                preparingID = nil
            } catch {
                neuralError = L("TTS do servidor falhou: %@", msg(error))
                preparingID = nil
            }
        }
    }

    private func ensurePocket() async throws -> PocketTtsManager {
        if let pocket { return pocket }
        let m = PocketTtsManager(language: .portuguese, precision: .int8)
        try await m.initialize()
        pocket = m
        return m
    }

    private func msg(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? e.localizedDescription }

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

    private static func strip(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "```[\\s\\S]*?```", with: L(" (bloco de código) "), options: .regularExpression)
        t = t.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\*\\*([^*]*)\\*\\*", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "[*_#>]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension SpeechManager: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }
}

extension SpeechManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finished() }
    }
}

private extension SpeechManager {
    func finished() {
        speakingID = nil
        let cb = onSpeechFinished
        onSpeechFinished = nil
        cb?()
    }
}

/// The PocketTTS Portuguese voices (from FluidInference/pocket-tts-coreml).
enum PocketVoices {
    static let portuguese = [
        "alba", "anna", "azelma", "bill_boerst", "caro_davy", "charles", "cosette",
        "eponine", "estelle", "eve", "fantine", "george", "giovanni", "jane", "javert",
        "jean", "juergen", "lola", "marius", "mary", "michael", "paul", "peter_yearsley",
        "rafael", "stuart_bell", "vera",
    ]
}
