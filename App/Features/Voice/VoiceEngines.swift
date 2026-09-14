import Foundation
import OpenWebUIKit

/// Which engine turns speech into text.
///
/// Stored as a raw string in `UserDefaults` because that is what the Settings
/// `Picker` binds to. Everything that *reads* it goes through this enum rather
/// than comparing string literals of its own, so the questions call sites
/// actually ask (does this engine stream partials while recording? does it
/// need raw audio saved? does it need Speech authorization?) are answered in
/// one place instead of once per file.
///
/// No `.endpoint` case here: unlike Odysseus, this app has no user-configured
/// speech endpoint feature.
enum STTEngine: String, CaseIterable, Identifiable {
    /// Apple's `SFSpeechRecognizer`.
    case native
    /// Whisper (or Parakeet) running on the device.
    case model
    /// The Open WebUI server's own `/api/v1/audio/transcriptions`.
    case server

    static let key = "voice.stt.engine"

    /// An unset or unrecognised value is the native engine — the one that needs
    /// nothing configured and always exists.
    static var current: STTEngine {
        STTEngine(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .native
    }

    var id: String { rawValue }

    /// True only for Apple's recognizer, the one engine that reports a
    /// transcript while the user is still talking. Everything else transcribes
    /// a finished recording, so the voice loop has to end the turn on loudness
    /// instead of on the transcript going quiet.
    var hasLivePartials: Bool { self == .native }

    /// Every other engine transcribes a finished recording, so it needs the raw
    /// buffer rather than Apple's live stream.
    var needsRawCapture: Bool { self != .native }

    /// Only Apple's engine goes through `SFSpeechRecognizer`, so only it needs
    /// speech-recognition authorization on top of the microphone.
    var needsSpeechAuthorization: Bool { self == .native }

    var label: String {
        switch self {
        case .native: return L("Nativo iOS")
        case .model:  return L("Modelo on-device")
        case .server: return L("Servidor")
        }
    }
}
