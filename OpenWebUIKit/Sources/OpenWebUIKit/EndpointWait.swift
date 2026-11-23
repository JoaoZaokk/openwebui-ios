import Foundation

/// How long a pause ends the person's turn in a voice call (Ajustes › Voz).
///
/// Report on build 27: the wait was fixed — 1.6 s for Apple's recognizer, 2.3 s
/// for the engines that end on loudness — and a person who thinks between
/// sentences, or one who wants a snappy reply, had no say. The levels are named
/// like the barge-in sensitivity: high sensitivity ends the turn on a short
/// pause, low waits longer.
public enum EndpointWait: String, CaseIterable, Sendable {
    case automatic = "auto"
    case high = "1"
    case medium = "2"
    case low = "3"

    public static let key = "voice.endpoint.wait"

    /// The wait the app always had, by kind of engine.
    public static let automaticLive: TimeInterval = 1.6
    public static let automaticEnergy: TimeInterval = 2.3

    /// Seconds of quiet that end the turn. `liveTranscript` is true for the
    /// engine that writes a transcript as the person talks (Apple's): there a
    /// pause is measured on the text, elsewhere on the microphone level, which
    /// cannot tell a pause for thought from the end — hence the longer default.
    /// A level the person picked is the same for every engine.
    public func seconds(liveTranscript: Bool) -> TimeInterval {
        switch self {
        case .automatic: return liveTranscript ? Self.automaticLive : Self.automaticEnergy
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        }
    }

    /// The stored choice; anything unknown (or nothing) is `.automatic`.
    public static func stored(_ defaults: UserDefaults = .standard) -> EndpointWait {
        defaults.string(forKey: key).flatMap(EndpointWait.init(rawValue:)) ?? .automatic
    }
}
