import SwiftUI
import Foundation

/// The languages the app ships UI translations for. Raw value = the `.lproj`
/// folder name (and `\.locale` identifier).
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case ptBR = "pt-BR"     // development/base language (keys = literals, no .lproj)
    case en   = "en"
    case es   = "es"
    case fr   = "fr"
    case it   = "it"
    case de   = "de"
    case deAT = "de-AT"
    case deCH = "de-CH"
    case nl   = "nl"
    case pl   = "pl"
    case cs   = "cs"
    case sk   = "sk"
    case sl   = "sl"
    case hr   = "hr"
    case bg   = "bg"
    case mk   = "mk"
    case sr   = "sr"
    case uk   = "uk"
    case be   = "be"
    case ru   = "ru"
    case tr   = "tr"
    case hu   = "hu"
    case vi   = "vi"
    case ind  = "id"        // Indonesian — case can't be `id` (clashes with Identifiable.id)
    case ms   = "ms"
    case ja   = "ja"
    case ko   = "ko"
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case hi   = "hi"
    case bn   = "bn"
    case ar   = "ar"
    case fa   = "fa"
    case ur   = "ur"
    case ps   = "ps"

    public var id: String { rawValue }

    /// Name shown in the language's own script (endonym).
    public var endonym: String {
        switch self {
        case .ptBR: "Português"
        case .en:   "English"
        case .es:   "Español"
        case .fr:   "Français"
        case .it:   "Italiano"
        case .de:   "Deutsch"
        case .deAT: "Deutsch (Österreich)"
        case .deCH: "Deutsch (Schweiz)"
        case .nl:   "Nederlands"
        case .pl:   "Polski"
        case .cs:   "Čeština"
        case .sk:   "Slovenčina"
        case .sl:   "Slovenščina"
        case .hr:   "Hrvatski"
        case .bg:   "Български"
        case .mk:   "Македонски"
        case .sr:   "Српски"
        case .uk:   "Українська"
        case .be:   "Беларуская"
        case .ru:   "Русский"
        case .tr:   "Türkçe"
        case .hu:   "Magyar"
        case .vi:   "Tiếng Việt"
        case .ind:  "Bahasa Indonesia"
        case .ms:   "Bahasa Melayu"
        case .ja:   "日本語"
        case .ko:   "한국어"
        case .zhHans: "简体中文"
        case .zhHant: "繁體中文"
        case .hi:   "हिन्दी"
        case .bn:   "বাংলা"
        case .ar:   "العربية"
        case .fa:   "فارسی"
        case .ur:   "اردو"
        case .ps:   "پښتو"
        }
    }

    public var flag: String {
        switch self {
        case .ptBR: "🇧🇷"; case .en: "🇺🇸"; case .es: "🇪🇸"; case .fr: "🇫🇷"
        case .it: "🇮🇹"; case .de: "🇩🇪"; case .deAT: "🇦🇹"; case .deCH: "🇨🇭"
        case .nl: "🇳🇱"; case .pl: "🇵🇱"; case .cs: "🇨🇿"; case .sk: "🇸🇰"
        case .sl: "🇸🇮"; case .hr: "🇭🇷"; case .bg: "🇧🇬"; case .mk: "🇲🇰"
        case .sr: "🇷🇸"; case .uk: "🇺🇦"; case .be: "🇧🇾"; case .ru: "🇷🇺"
        case .tr: "🇹🇷"; case .hu: "🇭🇺"; case .vi: "🇻🇳"; case .ind: "🇮🇩"
        case .ms: "🇲🇾"; case .ja: "🇯🇵"; case .ko: "🇰🇷"; case .zhHans: "🇨🇳"
        case .zhHant: "🇹🇼"; case .hi: "🇮🇳"; case .bn: "🇧🇩"; case .ar: "🇸🇦"
        case .fa: "🇮🇷"; case .ur: "🇵🇰"; case .ps: "🇦🇫"
        }
    }

    /// Right-to-left scripts (drive `\.layoutDirection`).
    public var isRTL: Bool { self == .ar || self == .fa || self == .ur || self == .ps }

    /// Best shipped match for a device/system BCP-47 code (e.g. "ja-JP", "zh-Hant-TW", "de-CH").
    static func match(_ code: String) -> AppLanguage? {
        let c = code.lowercased()
        if c.hasPrefix("pt") { return .ptBR }
        if c.hasPrefix("zh") {
            if c.contains("hant") || c.contains("-tw") || c.contains("-hk") || c.contains("-mo") { return .zhHant }
            return .zhHans
        }
        if c.hasPrefix("de") {
            if c.contains("-at") { return .deAT }
            if c.contains("-ch") { return .deCH }
            return .de
        }
        let map: [String: AppLanguage] = [
            "en": .en, "es": .es, "fr": .fr, "it": .it, "nl": .nl, "pl": .pl, "cs": .cs,
            "sk": .sk, "sl": .sl, "hr": .hr, "bg": .bg, "mk": .mk, "sr": .sr,
            "uk": .uk, "be": .be, "ru": .ru, "tr": .tr, "hu": .hu, "vi": .vi,
            "id": .ind, "in": .ind, "ms": .ms, "ja": .ja, "ko": .ko,
            "hi": .hi, "bn": .bn, "ar": .ar, "fa": .fa, "ur": .ur, "ps": .ps,
        ]
        return map[String(c.prefix(2))]
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

    /// Layout direction for the active language (RTL for ar/fa/ur/ps).
    public var layoutDirection: LayoutDirection { current.isRTL ? .rightToLeft : .leftToRight }

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
            if let lang = AppLanguage.match(pref) { return lang }
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
