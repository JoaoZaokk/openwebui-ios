import SwiftUI
import OpenWebUIKit
#if canImport(UIKit)
import UIKit
#endif

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
    /// Strength of the corner light behind the chat (`ThemeVignette`); 0 = none.
    /// Dark themes tint it with `glow`, light ones with white. Tuned per theme
    /// by eye: it should be felt, not seen.
    let vignette: Double
    let glow: Color
    /// The base colours as hex, for content drawn outside SwiftUI (charts in a
    /// web view take CSS colours).
    let hex: Hex
    struct Hex: Equatable { let bg, fg, panel, accent: String }

    var bg: Color
    var fg: Color
    var panel: Color
    var border: Color
    var accent: Color           // --red, used for the brand + primary actions
    var green: Color
    var userBubble: Color
    var aiBubble: Color
    var secondaryText: Color
    var danger: Color           // semantic error red — never the brand accent
    var onAccent: Color         // text/icon color on accent-filled controls

    /// Build a theme from base colors (+ optional `advanced` overrides for
    /// bubbles) and a brand font.
    init(id: String, name: String,
         bg: String, fg: String, panel: String, border: String, red: String,
         font: AppFontFamily = .mono, backdrop: Bool = false,
         userBubbleBg: String? = nil, aiBubbleBg: String? = nil,
         vignette: Double? = nil, glowHex: String? = nil) {
        let dark = Theme.isDarkHex(bg)
        self.id = id
        self.name = name
        self.isDark = dark
        self.font = font
        self.backdrop = backdrop
        self.vignette = vignette ?? (dark ? 0.09 : 0.42)
        self.glow = Color(hex: glowHex ?? red)
        self.hex = Hex(bg: bg, fg: fg, panel: panel, accent: red)
        self.bg = Color(hex: bg)
        self.fg = Color(hex: fg)
        self.panel = Color(hex: panel)
        self.border = Color(hex: border)
        self.accent = Color(hex: red)
        // Web defaults: userBubble→bg, aiBubble→panel (advanced overrides win).
        let userHex = userBubbleBg ?? bg
        let aiHex = aiBubbleBg ?? panel
        self.userBubble = Color(hex: userHex)
        self.aiBubble = Color(hex: aiHex)
        // Secondary text was a flat 55% of fg, which landed between 1.9:1 and 4.3:1
        // on 11 of the 17 themes. The alpha is now the lowest one that keeps 4.6:1
        // on every surface text can sit on, so it still reads as "quieter than fg".
        self.secondaryText = Color(hex: fg).opacity(Theme.secondaryAlpha(fg: fg, over: [bg, panel, userHex, aiHex]))
        // The web has no per-theme status colours. These two are chosen by the
        // theme's lightness and were measured, not picked: against every theme in
        // `all` (bg, panel, and the 12% tint the error banner paints over them)
        // the old light green "2f9e5b" fell under WCAG AA on 15 of 51 pairs and
        // the old danger pair on 8 — including Hermes, the default. The current
        // values clear 4.5:1 everywhere but two banner tints at 4.4. Errors must
        // never wear the brand accent: several themes use it for non-error
        // meanings, and on `terminal` it *is* the text colour.
        self.green = Color(hex: dark ? "5fd97a" : "20713f")
        self.danger = Color(hex: dark ? "ffa39a" : "a32b1f")
        // Foreground on accent fills: whichever of white / near-black has the higher
        // contrast. The old luma < 0.6 cut-off picked white on coral, teal, blue and
        // red accents at 3.1-3.7:1 (and 1.9:1 on Codex's mint).
        self.onAccent = Theme.contrast(red, "ffffff") >= Theme.contrast(red, "1a1a1a") ? .white : Color(hex: "1a1a1a")
    }

    // Equality is the synthesized memberwise one, on purpose. It used to compare
    // ids alone, and the copy `translucent(true)` returns keeps the id of the
    // theme it came from — so the opaque and see-through variants compared equal,
    // SwiftUI skipped the subtree whose `\.theme` "did not change", and flipping
    // "transparência" repainted nothing until something unrelated forced a
    // rebuild. A flag was then bolted on to tell the two apart; memberwise
    // equality already sees the surfaces differ and needs no flag.

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

    /// Quiet frame for content embedded in a message or surface (code blocks, tool
    /// cards, thumbnails, attachment chips). Half of `border`, so it stays a hint
    /// on every theme; controls and panels keep the full `border`.
    var hairline: Color { border.opacity(0.5) }

    // MARK: - Catalog (the web's 16 built-in themes, in the same order)

    static let all: [Theme] = [
        // ── Brand skins — each carries the company's typeface ──
        // Claude (claude.ai): warm cream, terracotta accent (deepened from coral so white on it passes AA), serif.
        Theme(id: "claude", name: "Claude", bg: "f0eee6", fg: "3d3a34", panel: "ffffff", border: "d6cfbe", red: "ba5937",
              font: .serif, userBubbleBg: "e3ddce", aiBubbleBg: "ffffff"),
        // Claude Code (CLI): near-black warm terminal, coral, mono.
        Theme(id: "claude_code", name: "Claude Code", bg: "1a1916", fg: "e8e4d8", panel: "232019", border: "3a352b", red: "d97757",
              font: .mono, userBubbleBg: "2a2620", aiBubbleBg: "1f1d18"),
        // ChatGPT: charcoal, classic teal, Inter-style grotesque sans.
        Theme(id: "gpt", name: "ChatGPT", bg: "212121", fg: "ececec", panel: "171717", border: "3a3a3a", red: "10a37f",
              font: .anthropic, userBubbleBg: "2f2f2f", aiBubbleBg: "171717", vignette: 0.06),
        // Codex: deep black coding surface, neon green, mono.
        Theme(id: "codex", name: "Codex", bg: "0d0d0d", fg: "d4d4d4", panel: "161616", border: "2a2a2a", red: "00d68f",
              font: .mono, userBubbleBg: "1e1e1e", aiBubbleBg: "121212", vignette: 0.075),
        // Gemini: light Google surface, Google blue, rounded (Product-Sans-ish).
        Theme(id: "gemini", name: "Gemini", bg: "f0f4f9", fg: "1f1f1f", panel: "ffffff", border: "d6e0ee", red: "1a73e8",
              font: .rounded, userBubbleBg: "dbe7fc", aiBubbleBg: "ffffff"),
        // Open WebUI (traditional): clean neutral dark, blue accent, sans.
        Theme(id: "openwebui", name: "Open WebUI", bg: "0f0f0f", fg: "ececec", panel: "1a1a1a", border: "2c2c2c", red: "4d7cff",
              font: .sans, userBubbleBg: "1f1f1f", aiBubbleBg: "141414"),
        // Hermes (Nous Portal blue), toned from the raw #0000F2 — tiring as a whole
        // screen — to a Klein blue leaning indigo; near-white, editorial serif + engraving backdrop.
        Theme(id: "hermes", name: "Hermes", bg: "1220a2", fg: "f5f2ea", panel: "0d1880", border: "3240c8", red: "c2c6ff",
              font: .serif, backdrop: true, userBubbleBg: "1a2cc0", aiBubbleBg: "0d1880"),
        // Hermes Teal: dark teal config surface, mint, serif.
        Theme(id: "hermes_teal", name: "Hermes Teal", bg: "0d2018", fg: "d8e8d8", panel: "122a1e", border: "2a5540", red: "4fd99a",
              font: .serif, backdrop: true, userBubbleBg: "1d4234", aiBubbleBg: "15302a"),
        // Hermes Noir: pure black, warm gold, serif.
        Theme(id: "hermes_noir", name: "Hermes Noir", bg: "000000", fg: "f0f0ee", panel: "0d0d0d", border: "262626", red: "b8a17a",
              font: .serif, backdrop: true, userBubbleBg: "222222", aiBubbleBg: "161616"),

        // ── Extras ──
        Theme(id: "midnight",  name: "Midnight",  bg: "0d1117", fg: "c9d1d9", panel: "161b22", border: "30363d", red: "f85149", font: .mono, userBubbleBg: "1c2430"),
        Theme(id: "ocean",     name: "Ocean",     bg: "0b1a2c", fg: "eef6fb", panel: "091422", border: "1e5074", red: "4facfe", font: .mono, userBubbleBg: "12304c"),
        Theme(id: "forest",    name: "Forest",    bg: "1b2a1b", fg: "eef4ec", panel: "142414", border: "355c35", red: "7cb871", font: .mono, userBubbleBg: "263c26", glowHex: "c8f0b8"),
        Theme(id: "cyberpunk", name: "Cyberpunk", bg: "0a0a0f", fg: "0ff0fc", panel: "12101a", border: "6a22b0", red: "e040fb", font: .mono, userBubbleBg: "1d1232"),
        Theme(id: "paper",     name: "Paper",     bg: "faf8f5", fg: "3b3836", panel: "ffffff", border: "d5d0c8", red: "9c8420", font: .serif, userBubbleBg: "efe9de"),
        Theme(id: "terminal",  name: "Terminal",  bg: "000000", fg: "00ff41", panel: "0a0a0a", border: "003b00", red: "00ff41", font: .mono, userBubbleBg: "001c08", vignette: 0),
        Theme(id: "lavender",  name: "Lavender",  bg: "f3eef8", fg: "3d3551", panel: "faf7ff", border: "cec3de", red: "8254c0", font: .rounded, userBubbleBg: "e6dcf2"),
        Theme(id: "cute",      name: "Cute",      bg: "fff0f5", fg: "a0305a", panel: "fff8fa", border: "f0c0d0", red: "d6336c", font: .rounded, userBubbleBg: "ffe4ed"),
    ]

    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? all[0] }

    /// Default for a clean install = Open WebUI, the skin of the primary
    /// (asset-catalog) "OI" icon — so a first launch changes no icon and shows
    /// no alert. It was Hermes' electric blue while the icon was already the OI.
    static let defaultID = "openwebui"
    static let odysseus = named(defaultID)

    // MARK: - Helpers

    /// Relative luminance of a hex color (perceptual), to decide light vs dark.
    static func isDarkHex(_ hex: String) -> Bool { luma(hex) < 0.5 }

    /// WCAG 2.x contrast ratio between two hex colors (1...21).
    static func contrast(_ a: String, _ b: String) -> Double { ratio(channels(a), channels(b)) }

    /// Lowest fg alpha (0.55...0.9) whose blend keeps 4.6:1 (AA plus a little
    /// margin for rounding) on every surface in `surfaces`. Capped at 0.9 so
    /// secondary text never collapses into primary.
    static func secondaryAlpha(fg: String, over surfaces: [String]) -> Double {
        let f = channels(fg)
        var a = 0.55
        while a < 0.9 {
            let ok = surfaces.allSatisfy { hex in
                let s = channels(hex)
                let mixed: RGB = (f.r * a + s.r * (1 - a), f.g * a + s.g * (1 - a), f.b * a + s.b * (1 - a))
                return ratio(mixed, s) >= 4.6
            }
            if ok { return a }
            a += 0.01
        }
        return 0.9
    }

    private typealias RGB = (r: Double, g: Double, b: Double)

    private static func channels(_ hex: String) -> RGB {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    private static func ratio(_ a: RGB, _ b: RGB) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func lum(_ c: RGB) -> Double { 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b) }
        let la = lum(a), lb = lum(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// sRGB luma of a hex color (0 = black, 1 = white).
    static func luma(_ hex: String) -> Double {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}

// MARK: - Corner radii

/// The three corner radii the UI uses, so one kind of surface is rounded the same
/// everywhere. Chips and pills are `Capsule()`; the colour-swatch miniature in the
/// theme picker is scaled-down art and keeps its own size.
enum Radius {
    /// Thumbnails and image tiles.
    static let thumb: CGFloat = 8
    /// Fields, buttons, code blocks, banners, tool cards, secondary panels.
    static let control: CGFloat = 12
    /// Message bubbles and the composer.
    static let card: CGFloat = 16
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
        case .none: return L("Nenhum"); case .stars: return L("Estrelas")
        case .rain: return L("Chuva"); case .embers: return L("Brasas"); case .petals: return L("Pétalas")
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
            // relativeTo: .body → tracks Dynamic Type (identity at the default
            // Large setting); the app-root `.dynamicTypeSize` cap bounds it.
            return .custom(name, size: size, relativeTo: .body).weight(weight)
        }
        return .system(size: scaledSize(size), weight: weight, design: fontFamily.design)
    }

    /// Dynamic Type for fixed point sizes. On iOS the size scales with the
    /// user's text setting via UIFontMetrics (neutral at the default Large),
    /// clamped at XXL to mirror the app-root `.dynamicTypeSize(...xxLarge)` cap
    /// — SwiftUI's cap only reaches style-based fonts, so pre-scaled point
    /// sizes must clamp themselves. macOS has no Dynamic Type; sizes stay fixed.
    static func scaledSize(_ size: CGFloat) -> CGFloat {
        #if os(iOS)
        var cat = UITraitCollection.current.preferredContentSizeCategory
        if cat == .unspecified { cat = .large }
        if cat > .extraExtraLarge { cat = .extraExtraLarge }
        return UIFontMetrics.default.scaledValue(
            for: size, compatibleWith: UITraitCollection(preferredContentSizeCategory: cat))
        #else
        return size
        #endif
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
    ///
    /// There is deliberately no `design:` parameter: the family the user picked
    /// owns the design (`Appearance.font` reads `fontFamily.design`), so a
    /// per-call design could never take effect. It used to be accepted and
    /// dropped on the floor, and 136 call sites passed `.monospaced` into it.
    static func ody(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        Appearance.font(style: style, weight: weight)
    }
    static func ody(size: CGFloat, weight: Font.Weight = .regular) -> Font {
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
