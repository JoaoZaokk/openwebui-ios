import SwiftUI
import OpenWebUIKit

@main
struct OpenWebUIApp: App {
    @StateObject private var app = AppState()
    @StateObject private var themes = ThemeStore()
    // Singleton, observed (not owned) — @ObservedObject is the correct wrapper.
    @ObservedObject private var lang = LanguageManager.shared
    @ObservedObject private var modelAliases = ModelAliases.shared

    init() { FontLoader.registerBundledFonts() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(themes)
                .environmentObject(lang)
                .environmentObject(modelAliases)
                .environment(\.theme, themes.effectiveTheme)
                // Drives SwiftUI `Text("literal")` localization; the picker flips
                // this and `L(_:)`'s bundle together via LanguageManager.
                .environment(\.locale, lang.locale)
                .environment(\.layoutDirection, lang.layoutDirection)   // RTL for ar/fa/ur/ps
                .preferredColorScheme(themes.theme.isDark ? .dark : .light)
                .tint(themes.theme.accent)
                // Dynamic Type is honored up to XXL; the accessibility sizes
                // would overflow the composer/chips/toolbars. Appearance
                // .scaledSize applies the same clamp to point-sized fonts.
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                // Font family is read by the non-View `Font.ody` helper via a
                // global; bump identity so the whole tree re-renders on change.
                // The language code is folded in so a language switch rebuilds
                // the tree and re-resolves every localized string.
                .id("\(themes.fontFamily)#\(lang.current.rawValue)")
                #if os(macOS)
                // The app draws its own controls; suppress AppKit's default
                // bordered chrome, and give the window desktop-sized bounds.
                .buttonStyle(.plain)
                .textFieldStyle(.plain)
                .frame(minWidth: 900, minHeight: 560)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        #endif
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var themes: ThemeStore
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            if themes.transparency {
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            }
            theme.bg.ignoresSafeArea()
            switch app.phase {
            case .launching: LaunchView()
            case .login:     LoginView()
            case .main:      MainView(app: app)
            }
        }
        .overlay {
            if theme.backdrop { ThemeBackdrop(theme: theme) }
            if themes.background != .none {
                AnimatedBackground(pattern: themes.background, tint: theme.accent)
            }
        }
        .task {
            // Reconcile the home-screen icon with the active (saved/default) theme.
            // After a clean install or update this fixes any icon↔theme drift; it's a
            // no-op (and shows no alert) when they already match.
            AppIconManager.apply(themeID: themes.theme.id)
            SpeechManager.shared.client = app.client   // enables server-side TTS
            await app.bootstrap()
        }
    }
}

struct LaunchView: View {
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(spacing: 20) {
            BrandMark(size: 72)
            ProgressView().tint(theme.accent)
        }
    }
}

/// The app's brand mark — a per-theme glyph (each company's stylized logo) with
/// an "OI" stamp. Claude → starburst, ChatGPT/Codex → OpenAI blossom, Gemini →
/// spark, Hermes → a figure (OI sits opposite the face), else a chat/spark.
struct BrandMark: View {
    @Environment(\.theme) private var theme
    var size: CGFloat = 32
    var showOI: Bool = true

    enum Kind { case claude, openai, gemini, openwebui, hermes, generic }
    private var kind: Kind {
        switch theme.id {
        case "claude", "claude_code": return .claude
        case "gpt", "codex": return .openai
        case "gemini": return .gemini
        case "openwebui": return .openwebui
        case "hermes", "hermes_teal", "hermes_noir": return .hermes
        default: return .generic
        }
    }

    var body: some View {
        ZStack {
            glyph
            if showOI && size >= 40 { oiStamp }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var glyph: some View {
        switch kind {
        case .claude:    brandLogo("ClaudeLogo", tint: theme.accent)
        case .openai:    brandLogo("OpenAILogo", tint: theme.fg)
        case .gemini:    Image("GeminiLogo").resizable().scaledToFit().padding(size * 0.10)  // keep gradient
        case .openwebui: brandLogo("OpenWebUILogo", tint: theme.fg)
        case .hermes:    brandLogo("HermesLogo", tint: theme.fg)
        case .generic:   GenericMark(color: theme.accent, size: size)
        }
    }

    private func brandLogo(_ name: String, tint: Color) -> some View {
        Image(name).renderingMode(.template).resizable().scaledToFit()
            .foregroundStyle(tint).padding(size * 0.10)
    }

    // "OI" sits exactly in the center, in the inverse (background) color, so it
    // always reads as knocked-out of the brand mark.
    private var oiStamp: some View {
        Text("OI")
            .font(.system(size: size * 0.34, weight: .heavy, design: .rounded))
            .foregroundStyle(theme.bg)
    }
}

/// Claude's burst — tapered spokes radiating from the center.
private struct ClaudeBurst: View {
    let color: Color
    var body: some View {
        Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let spokes = 11, outer = sz.width * 0.46, base = sz.width * 0.06
            for i in 0..<spokes {
                let a = Double(i) / Double(spokes) * 2 * .pi
                let perp = a + .pi / 2
                let tip = CGPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer)
                let b1 = CGPoint(x: c.x + cos(perp) * base, y: c.y + sin(perp) * base)
                let b2 = CGPoint(x: c.x - cos(perp) * base, y: c.y - sin(perp) * base)
                var p = Path(); p.move(to: b1); p.addLine(to: tip); p.addLine(to: b2); p.closeSubpath()
                ctx.fill(p, with: .color(color))
            }
        }
    }
}

/// OpenAI-ish blossom — a ring of overlapping circles (the knot, stylized).
private struct OpenAIBlossom: View {
    let color: Color
    var body: some View {
        Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let dist = sz.width * 0.17, r = sz.width * 0.20
            for i in 0..<6 {
                let a = Double(i) / 6 * 2 * .pi
                let pc = CGPoint(x: c.x + cos(a) * dist, y: c.y + sin(a) * dist)
                ctx.stroke(Path(ellipseIn: CGRect(x: pc.x - r, y: pc.y - r, width: r * 2, height: r * 2)),
                           with: .color(color), lineWidth: max(1, sz.width * 0.045))
            }
        }
    }
}

/// Gemini's spark — a 4-pointed star with concave sides.
private struct GeminiSpark: View {
    let color: Color
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: s / 2, y: s / 2), R = s * 0.48
            Path { p in
                let pts = (0..<4).map { i -> CGPoint in
                    let a = Double(i) * .pi / 2 - .pi / 2
                    return CGPoint(x: c.x + cos(a) * R, y: c.y + sin(a) * R)
                }
                p.move(to: pts[0])
                for i in 0..<4 { p.addQuadCurve(to: pts[(i + 1) % 4], control: c) }
                p.closeSubpath()
            }
            .fill(color)
        }
    }
}

/// Hermes' mark — the user-provided Hermes Agent logo (bundled SVG), rendered as
/// a template so it tints to the theme's foreground (white on the dark Hermes
/// skins, dark on light ones).
private struct HermesFigure: View {
    let color: Color
    var body: some View {
        Image("HermesLogo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
    }
}

/// The original Odysseus mark — a sail + wave — used for the non-brand themes.
private struct GenericMark: View {
    let color: Color
    let size: CGFloat
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // Sail (two triangles).
                Path { p in
                    p.move(to: CGPoint(x: w * 0.5, y: h * 0.12))
                    p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.68))
                    p.addLine(to: CGPoint(x: w * 0.18, y: h * 0.68))
                    p.closeSubpath()
                }.fill(color)
                Path { p in
                    p.move(to: CGPoint(x: w * 0.5, y: h * 0.25))
                    p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.68))
                    p.addLine(to: CGPoint(x: w * 0.78, y: h * 0.68))
                    p.closeSubpath()
                }.fill(color.opacity(0.6))
                // Wave.
                Path { p in
                    p.move(to: CGPoint(x: w * 0.12, y: h * 0.78))
                    p.addQuadCurve(to: CGPoint(x: w * 0.5, y: h * 0.82), control: CGPoint(x: w * 0.31, y: h * 0.70))
                    p.addQuadCurve(to: CGPoint(x: w * 0.88, y: h * 0.78), control: CGPoint(x: w * 0.69, y: h * 0.92))
                }.stroke(color, style: StrokeStyle(lineWidth: max(2, size * 0.08), lineCap: .round))
            }
        }
    }
}
