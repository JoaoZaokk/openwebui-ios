import SwiftUI
import Foundation

/// The languages the app ships UI translations for. Raw value = the `.lproj`
/// folder name (and `\.locale` identifier).
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case ptBR = "pt-BR"
    case en   = "en"
    case ja   = "ja"
    case hi   = "hi"
    case bn   = "bn"

    public var id: String { rawValue }

    /// Name shown in the language's own script (endonym).
    public var endonym: String {
        switch self {
        case .ptBR: "Português"
        case .en:   "English"
        case .ja:   "日本語"
        case .hi:   "हिन्दी"
        case .bn:   "বাংলা"
        }
    }

    public var flag: String {
        switch self {
        case .ptBR: "🇧🇷"
        case .en:   "🇺🇸"
        case .ja:   "🇯🇵"
        case .hi:   "🇮🇳"
        case .bn:   "🇧🇩"
        }
    }
}

/// Holds the app's effective UI language and lets the user override the device
/// default at runtime. Two delivery paths, both driven by `current`:
///   • SwiftUI `Text("literal")` / `Text(LocalizedStringKey(var))` re-resolve
///     through `.environment(\.locale,)` (verified live for ja/hi).
///   • Non-View strings (errors, enum labels) go through `L(_:)`, which reads a
///     thread-safe cached bundle (the selected `.lproj`).
/// We deliberately do NOT touch `AppleLanguages` — that would pollute the
/// device-language auto-detection on the next launch.
public final class LanguageManager: ObservableObject {
    public static let shared = LanguageManager()

    private static let overrideKey = "app.language.override"

    /// nil = automatic (follow the device language).
    @Published public private(set) var override: AppLanguage?
    /// The language actually in effect right now.
    @Published public private(set) var current: AppLanguage

    // Thread-safe snapshot of the active `.lproj`, read by `L()` which runs off
    // the main thread (background JSON decode, networking error paths). Kept
    // separate from the `@Published` properties to avoid a data race.
    private static let bundleLock = NSLock()
    private static var activeBundle: Bundle = .main

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.overrideKey)
        let ov = stored.flatMap(AppLanguage.init(rawValue:))
        self.override = ov
        self.current = ov ?? Self.deviceLanguage()
        Self.setActiveBundle(for: current)
    }

    public var isAutomatic: Bool { override == nil }

    public var locale: Locale { Locale(identifier: current.rawValue) }

    /// Bundle for the current language's `.lproj` (main-thread convenience).
    public var bundle: Bundle { Self.computeBundle(for: current) }

    /// Apply a language, or pass `nil` for automatic (device) detection.
    public func set(_ lang: AppLanguage?) {
        override = lang
        if let lang {
            UserDefaults.standard.set(lang.rawValue, forKey: Self.overrideKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.overrideKey)
        }
        current = lang ?? Self.deviceLanguage()
        Self.setActiveBundle(for: current)
    }

    /// First device-preferred language we support; English otherwise.
    public static func deviceLanguage() -> AppLanguage {
        for pref in Locale.preferredLanguages {
            let code = pref.lowercased()
            if code.hasPrefix("pt") { return .ptBR }
            if code.hasPrefix("ja") { return .ja }
            if code.hasPrefix("hi") { return .hi }
            if code.hasPrefix("bn") { return .bn }
            if code.hasPrefix("en") { return .en }
        }
        return .en
    }

    // MARK: - Thread-safe bundle snapshot

    private static func computeBundle(for lang: AppLanguage) -> Bundle {
        if let p = Bundle.main.path(forResource: lang.rawValue, ofType: "lproj"),
           let b = Bundle(path: p) {
            return b
        }
        return .main
    }

    private static func setActiveBundle(for lang: AppLanguage) {
        let b = computeBundle(for: lang)
        bundleLock.lock(); activeBundle = b; bundleLock.unlock()
    }

    /// The cached `.lproj` for the current language — safe to read from any thread.
    static var snapshotBundle: Bundle {
        _ = shared   // ensure the singleton initialized the snapshot
        bundleLock.lock(); defer { bundleLock.unlock() }
        return activeBundle
    }
}

/// Localizes `key` using the app's currently-selected language bundle. Use this
/// for strings created outside SwiftUI `Text` (errors, enum labels, computed
/// messages). `key` is the Portuguese source string. Thread-safe.
public func L(_ key: String, _ args: CVarArg...) -> String {
    let s = LanguageManager.snapshotBundle.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? s : String(format: s, arguments: args)
}
