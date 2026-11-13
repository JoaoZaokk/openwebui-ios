import Foundation

/// What the Return key does in the chat composer on a hardware keyboard.
///
/// A pure function of the modifiers and of the keyboards the person has
/// enabled, so the one case that cannot be tried without the hardware — an IME
/// keyboard, where Return also confirms the characters being composed — is at
/// least pinned by a test.
public enum ReturnKey {

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift   = Modifiers(rawValue: 1 << 0)
        public static let command = Modifiers(rawValue: 1 << 1)
        public static let option  = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    public enum Action: Equatable, Sendable { case send, newline }

    /// Languages whose keyboards compose characters in an input method, so that
    /// Return is also "accept this conversion".
    private static let composing: Set<String> = ["zh", "ja", "ko", "yue"]

    /// - Parameter enabledInputLanguages: `primaryLanguage` of each enabled
    ///   keyboard (`UITextInputMode.activeInputModes`); entries with no
    ///   language, like emoji, are ignored.
    public static func action(modifiers: Modifiers, enabledInputLanguages: [String]) -> Action {
        if modifiers.contains(.command) { return .send }
        if !modifiers.isEmpty { return .newline }
        let ime = enabledInputLanguages.contains { lang in
            guard let primary = lang.split(separator: "-").first else { return false }
            return composing.contains(primary.lowercased())
        }
        return ime ? .newline : .send
    }
}
