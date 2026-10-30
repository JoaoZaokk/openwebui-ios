import SwiftUI

/// Light from two opposite corners (top-right, bottom-left) and a slightly
/// darker rim. A flat full-screen colour read as a prototype; this gives depth
/// without being noticed. Dark themes are lit in their `glow` tint, light ones
/// in white. Static gradients: no animation, no per-frame cost.
struct ThemeVignette: View {
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let reach = max(w, h) * 0.85
            let k = theme.vignette
            let tint = theme.isDark ? theme.glow : .white
            ZStack {
                RadialGradient(colors: [tint.opacity(k), .clear], center: .topTrailing,
                               startRadius: 0, endRadius: reach)
                    .scaleEffect(x: 1, y: 0.65, anchor: .topTrailing)
                RadialGradient(colors: [tint.opacity(k * 0.8), .clear], center: .bottomLeading,
                               startRadius: 0, endRadius: reach)
                    .scaleEffect(x: 1, y: 0.65, anchor: .bottomLeading)
                RadialGradient(colors: [.clear, .black.opacity(theme.isDark ? k * 3.1 : 0.05)],
                               center: .center,
                               startRadius: hypot(w, h) * 0.3, endRadius: hypot(w, h) * 0.62)
            }
        }
        .opacity(theme.vignette > 0 ? 1 : 0)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// A screen's backdrop: the theme colour, the Hermes engraving where the theme
/// has one, and the corner light. The engraving used to be an overlay above
/// the whole app, so it showed through every message bubble as if they were
/// see-through; here it sits behind the content.
struct ThemeCanvas: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.bg
            if theme.backdrop { ThemeBackdrop(theme: theme) }
            ThemeVignette()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// What sits behind a message bubble: nothing, a neutral glow/shadow (white
/// glow on dark themes, black shadow on light ones), or one in the theme's
/// own light. Chosen per build; Debug captures can pick with
/// `-debug.bubbleEffect none|neutral|accent` to compare.
enum BubbleEffect: String {
    case none, neutral, accent

    static var current: BubbleEffect {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "debug.bubbleEffect"),
           let e = BubbleEffect(rawValue: raw) { return e }
        #endif
        return .accent
    }
}

extension View {
    func bubbleEffect(_ theme: Theme) -> some View {
        modifier(BubbleEffectModifier(theme: theme, effect: .current))
    }
}

private struct BubbleEffectModifier: ViewModifier {
    let theme: Theme
    let effect: BubbleEffect

    func body(content: Content) -> some View {
        switch effect {
        case .none:
            content
        case .neutral:
            content.shadow(color: theme.isDark ? .white.opacity(0.07) : .black.opacity(0.10),
                           radius: 11, y: theme.isDark ? 0 : 4)
        case .accent:
            content.shadow(color: theme.glow.opacity(theme.isDark ? 0.16 : 0.12),
                           radius: 11, y: theme.isDark ? 0 : 4)
        }
    }
}

/// How an assistant reply sits on the screen (Settings › Appearance). `bubble`
/// is the boxed reply up to 1.11; `plain` is the GPT/Claude layout — the reply
/// is text on the page and only code, tables and charts get a card. On an
/// engraved backdrop (the Hermes themes) the engraving shows through plain
/// text, so those themes also get `lane` — the engraving fades behind the text
/// column — and `glass`, a faint panel behind the reply.
enum ReplyStyle: String, CaseIterable, Identifiable {
    case auto, plain, bubble, glass, lane

    static let key = "reply.style"
    var id: String { rawValue }

    /// The style to draw with: `auto` becomes the reading lane on engraved
    /// themes and plain text elsewhere; a lane without an engraving to fade is
    /// plain text. Debug captures can force one with `-debug.replyStyle`.
    func resolved(for theme: Theme) -> ReplyStyle {
        var style = self
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "debug.replyStyle"),
           let forced = ReplyStyle(rawValue: raw) { style = forced }
        #endif
        switch style {
        case .auto: return theme.backdrop ? .lane : .plain
        case .lane: return theme.backdrop ? .lane : .plain
        default: return style
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .auto: return "Automático"
        case .plain: return "Sem balão"
        case .bubble: return "Balão"
        case .glass: return "Vidro"
        case .lane: return "Faixa de leitura"
        }
    }
}

/// The reading lane: the engraving fades behind the column the text runs in.
struct ReadingLane: View {
    @Environment(\.theme) private var theme

    var body: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0),
                               .init(color: theme.bg.opacity(0.5), location: 0.14),
                               .init(color: theme.bg.opacity(0.5), location: 0.86),
                               .init(color: .clear, location: 1)],
                       startPoint: .leading, endPoint: .trailing)
            // It ended at the status bar with a hard edge; it fades out
            // before the top and bottom bars instead.
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                         .init(color: .black, location: 0.18),
                                         .init(color: .black, location: 0.78),
                                         .init(color: .clear, location: 0.95)],
                                 startPoint: .top, endPoint: .bottom))
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

extension View {
    /// Content fades out where it scrolls under the top bar and the composer,
    /// instead of being cut at a hard line.
    func scrollEdgeFade(top: CGFloat = 28, bottom: CGFloat = 14) -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: top)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: bottom)
            }
        }
    }
}

/// Settings row for `ReplyStyle`.
struct ReplyStylePicker: View {
    @Environment(\.theme) private var theme
    @AppStorage(ReplyStyle.key) private var raw = ReplyStyle.auto.rawValue

    var body: some View {
        Picker(selection: $raw) {
            ForEach(ReplyStyle.allCases) { Text($0.title).tag($0.rawValue) }
        } label: {
            Label { Text("Estilo da resposta").font(.ody(.body)).foregroundStyle(theme.fg) }
            icon: { Image(systemName: "text.bubble").foregroundStyle(theme.accent) }
        }
        .tint(theme.secondaryText)
        .accessibilityIdentifier("settings.replyStyle")
    }
}
