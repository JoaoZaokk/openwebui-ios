import SwiftUI

/// A color theme, mirroring the Odysseus web app's theme system (see
/// `static/js/theme.js`). The web stores 5 base colors per theme — bg, fg,
/// panel, border, red(accent) — and derives the rest:
///   userBubble = bg · aiBubble = panel · bubbleBorder = border ·
///   brand/send/toggle = red.
/// We reproduce that here and add a `green` positive accent (used natively for
/// "installed/active/connected" cues) derived from the theme's lightness.
struct Theme: Equatable, Identifiable {
    let id: String              // matches the web theme key (e.g. "claude")
    let name: String            // display label
    let isDark: Bool
    let font: AppFontFamily     // each brand theme carries its own typeface
    let backdrop: Bool          // faint engraving/glow texture behind the UI (Hermes-style)

    var bg: Color
    var fg: Color
    var panel: Color
    var border: Color
    var accent: Color           // --red, used for the brand + primary actions
    var green: Color
    var userBubble: Color
    var aiBubble: Color
    var secondaryText: Color

    /// Build a theme from base colors (+ optional `advanced` overrides for
    /// bubbles) and a brand font.
    init(id: String, name: String,
         bg: String, fg: String, panel: String, border: String, red: String,
         font: AppFontFamily = .mono, backdrop: Bool = false,
         userBubbleBg: String? = nil, aiBubbleBg: String? = nil) {
        let dark = Theme.isDarkHex(bg)
        self.id = id
        self.name = name
        self.isDark = dark
        self.font = font
        self.backdrop = backdrop
        self.bg = Color(hex: bg)
        self.fg = Color(hex: fg)
        self.panel = Color(hex: panel)
        self.border = Color(hex: border)
        self.accent = Color(hex: red)
        // Web defaults: userBubble→bg, aiBubble→panel (advanced overrides win).
        self.userBubble = Color(hex: userBubbleBg ?? bg)
        self.aiBubble = Color(hex: aiBubbleBg ?? panel)
        self.secondaryText = Color(hex: fg).opacity(0.55)
        // The web has no per-theme green; pick one that reads on this background.
        self.green = Color(hex: dark ? "5fd97a" : "2f9e5b")
    }

    static func == (l: Theme, r: Theme) -> Bool { l.id == r.id }

    /// Returns a copy whose surfaces are semi-transparent, so a frosted/vibrancy
    /// backdrop shows through (used by the "transparência" setting).
    func translucent(_ on: Bool) -> Theme {
        guard on else { return self }
        var t = self
        let a = 0.66
        t.bg = bg.opacity(a)
        t.panel = panel.opacity(a)
        t.userBubble = userBubble.opacity(a)
        t.aiBubble = aiBubble.opacity(a)
        return t
    }

    // MARK: - Catalog (the web's 16 built-in themes, in the same order)

    static let all: [Theme] = [
        // ── Brand skins — each carries the company's typeface ──
        // Claude (claude.ai): warm cream, clay/coral accent, serif.
        Theme(id: "claude", name: "Claude", bg: "f0eee6", fg: "3d3a34", panel: "ffffff", border: "e4ded2", red: "d97757",
              font: .serif, userBubbleBg: "ebe7dc", aiBubbleBg: "ffffff"),
        // Claude Code (CLI): near-black warm terminal, coral, mono.
        Theme(id: "claude_code", name: "Claude Code", bg: "1a1916", fg: "e8e4d8", panel: "232019", border: "3a352b", red: "d97757",
              font: .mono, userBubbleBg: "2a2620", aiBubbleBg: "1f1d18"),
        // ChatGPT: charcoal, classic teal, Inter-style grotesque sans.
        Theme(id: "gpt", name: "ChatGPT", bg: "212121", fg: "ececec", panel: "171717", border: "3a3a3a", red: "10a37f",
              font: .anthropic, userBubbleBg: "2f2f2f", aiBubbleBg: "171717"),
        // Codex: deep black coding surface, neon green, mono.
        Theme(id: "codex", name: "Codex", bg: "0d0d0d", fg: "d4d4d4", panel: "161616", border: "2a2a2a", red: "00d68f",
              font: .mono, userBubbleBg: "1e1e1e", aiBubbleBg: "121212"),
        // Gemini: light Google surface, Google blue, rounded (Product-Sans-ish).
        Theme(id: "gemini", name: "Gemini", bg: "f0f4f9", fg: "1f1f1f", panel: "ffffff", border: "d6e0ee", red: "1a73e8",
              font: .rounded, userBubbleBg: "e8f0fe", aiBubbleBg: "ffffff"),
        // Open WebUI (traditional): clean neutral dark, blue accent, sans.
        Theme(id: "openwebui", name: "Open WebUI", bg: "0f0f0f", fg: "ececec", panel: "1a1a1a", border: "2c2c2c", red: "4d7cff",
              font: .sans, userBubbleBg: "1f1f1f", aiBubbleBg: "141414"),
        // Hermes (Nous Portal): the real #0000F2 electric blue, near-white, editorial serif + engraving backdrop.
        Theme(id: "hermes", name: "Hermes", bg: "0000f2", fg: "f5f2ea", panel: "0000c4", border: "3a3aff", red: "8a8aff",
              font: .serif, backdrop: true, userBubbleBg: "1a1aff", aiBubbleBg: "0000c0"),
        // Hermes Teal: dark teal config surface, mint, serif.
        Theme(id: "hermes_teal", name: "Hermes Teal", bg: "0d2018", fg: "d8e8d8", panel: "122a1e", border: "2a5540", red: "4fd99a",
              font: .serif, backdrop: true, userBubbleBg: "16352a", aiBubbleBg: "0f2519"),
        // Hermes Noir: pure black, warm gold, serif.
        Theme(id: "hermes_noir", name: "Hermes Noir", bg: "000000", fg: "f0f0ee", panel: "0d0d0d", border: "262626", red: "b8a17a",
              font: .serif, backdrop: true, userBubbleBg: "141414", aiBubbleBg: "0a0a0a"),

        // ── Extras ──
        Theme(id: "midnight",  name: "Midnight",  bg: "0d1117", fg: "c9d1d9", panel: "161b22", border: "30363d", red: "f85149", font: .mono),
        Theme(id: "ocean",     name: "Ocean",     bg: "0b1a2c", fg: "64d2ff", panel: "091422", border: "1e5074", red: "4facfe", font: .mono),
        Theme(id: "forest",    name: "Forest",    bg: "1b2a1b", fg: "a8d5a2", panel: "142414", border: "3d6b3d", red: "7cb871", font: .mono),
        Theme(id: "cyberpunk", name: "Cyberpunk", bg: "0a0a0f", fg: "0ff0fc", panel: "12101a", border: "9b30ff", red: "e040fb", font: .mono),
        Theme(id: "paper",     name: "Paper",     bg: "faf8f5", fg: "3b3836", panel: "ffffff", border: "d5d0c8", red: "c5ac4a", font: .serif),
        Theme(id: "terminal",  name: "Terminal",  bg: "000000", fg: "00ff41", panel: "0a0a0a", border: "003b00", red: "00ff41", font: .mono),
        Theme(id: "lavender",  name: "Lavender",  bg: "f3eef8", fg: "3d3551", panel: "faf7ff", border: "cec3de", red: "9b6dcc", font: .rounded),
        Theme(id: "cute",      name: "Cute",      bg: "fff0f5", fg: "d4608a", panel: "fff8fa", border: "f0c0d0", red: "ff6b9d", font: .rounded),
    ]

    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? all[0] }

    /// Default for a clean install = Hermes, so it matches the primary
    /// (asset-catalog) Hermes-blue app icon out of the box — no icon-change alert.
    static let defaultID = "hermes"
    static let odysseus = named(defaultID)

    // MARK: - Helpers

    /// Relative luminance of a hex color (perceptual), to decide light vs dark.
    static func isDarkHex(_ hex: String) -> Bool {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        // sRGB luma
        return (0.299 * r + 0.587 * g + 0.114 * b) < 0.5
    }
}

// MARK: - Appearance options (font / transparency / background)

/// UI font family. mono/sans/serif/rounded map to Apple system designs;
/// `anthropic` uses the bundled Inter (closest open match to Anthropic's sans),
/// falling back to the system font if Inter isn't present.
enum AppFontFamily: String, CaseIterable, Identifiable {
    case mono, sans, serif, rounded, anthropic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mono: return "Mono"; case .sans: return "Sans"; case .serif: return "Serif"
        case .rounded: return "Rounded"; case .anthropic: return "Anthropic Sans"
        }
    }
    var design: Font.Design {
        switch self {
        case .mono: return .monospaced; case .serif: return .serif
        case .rounded: return .rounded; default: return .default
        }
    }
    var customName: String? { self == .anthropic ? "Inter" : nil }
}

/// Animated background pattern drawn behind the UI.
enum BackgroundPattern: String, CaseIterable, Identifiable {
    case none, stars, rain, embers, petals
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Nenhum"; case .stars: return "Estrelas"
        case .rain: return "Chuva"; case .embers: return "Brasas"; case .petals: return "Pétalas"
        }
    }
}

/// Global, read by the non-`View` `Font.ody(...)` helpers. Kept in sync by
/// `ThemeStore`; a font change forces a root rebuild so these are re-read.
enum Appearance {
    static var fontFamily: AppFontFamily = .mono

    static func font(style: Font.TextStyle, weight: Font.Weight) -> Font {
        if let name = fontFamily.customName {
            return .custom(name, size: pointSize(style), relativeTo: style).weight(weight)
        }
        return .system(style, design: fontFamily.design, weight: weight)
    }
    static func font(size: CGFloat, weight: Font.Weight) -> Font {
        if let name = fontFamily.customName {
            return .custom(name, fixedSize: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: fontFamily.design)
    }
    static func pointSize(_ s: Font.TextStyle) -> CGFloat {
        switch s {
        case .largeTitle: return 34; case .title: return 28; case .title2: return 22
        case .title3: return 20; case .headline: return 17; case .body: return 17
        case .callout: return 16; case .subheadline: return 15; case .footnote: return 13
        case .caption: return 12; case .caption2: return 11; default: return 17
        }
    }
}

extension Font {
    /// Drop-in for `Font.system` that honors the chosen `AppFontFamily`.
    static func ody(_ style: Font.TextStyle, design: Font.Design = .monospaced, weight: Font.Weight = .regular) -> Font {
        Appearance.font(style: style, weight: weight)
    }
    static func ody(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .monospaced) -> Font {
        Appearance.font(size: size, weight: weight)
    }
}

/// Owns the active theme + appearance options and persists them. Changes
/// re-render the whole app (it's injected into the environment from `OdysseusApp`).
@MainActor
final class ThemeStore: ObservableObject {
    @Published private(set) var theme: Theme
    @Published private(set) var fontFamily: AppFontFamily
    @Published var transparency: Bool { didSet { UserDefaults.standard.set(transparency, forKey: Self.transpKey) } }
    @Published var background: BackgroundPattern { didSet { UserDefaults.standard.set(background.rawValue, forKey: Self.bgKey) } }

    private static let key = "odysseus.theme.id"
    private static let fontKey = "odysseus.font.family"
    private static let transpKey = "odysseus.transparency"
    private static let bgKey = "odysseus.bg.pattern"

    /// Theme actually injected into the environment (transparency applied).
    var effectiveTheme: Theme { theme.translucent(transparency) }

    init() {
        let id = UserDefaults.standard.string(forKey: Self.key) ?? Theme.defaultID
        let t = Theme.named(id)
        theme = t
        // Default to the theme's brand font; a manual override (if any) wins until
        // the next theme switch.
        let fam = AppFontFamily(rawValue: UserDefaults.standard.string(forKey: Self.fontKey) ?? "") ?? t.font
        fontFamily = fam
        Appearance.fontFamily = fam
        transparency = UserDefaults.standard.bool(forKey: Self.transpKey)
        background = BackgroundPattern(rawValue: UserDefaults.standard.string(forKey: Self.bgKey) ?? "") ?? .none
    }

    func select(_ t: Theme) {
        guard t.id != theme.id else { return }
        theme = t
        UserDefaults.standard.set(t.id, forKey: Self.key)
        selectFont(t.font)               // each brand skin applies its own typeface
        AppIconManager.apply(themeID: t.id)   // and its matching home-screen icon
    }

    func selectFont(_ f: AppFontFamily) {
        guard f != fontFamily else { return }
        fontFamily = f
        Appearance.fontFamily = f
        UserDefaults.standard.set(f.rawValue, forKey: Self.fontKey)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = .odysseus
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        switch s.count {
        case 8:
            r = Double((v >> 24) & 0xFF) / 255
            g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255
            a = Double(v & 0xFF) / 255
        default:
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
