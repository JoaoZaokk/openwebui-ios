import SwiftUI

/// A faint engraving + glow texture layered over the UI, à la the Hermes Agent
/// skins (which use a background asset + noise + warm glow). Fully procedural —
/// no bundled assets — and tinted to the active theme. Kept very subtle so text
/// stays readable.
struct ThemeBackdrop: View {
    let theme: Theme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // 1. Warm glow toward the upper-right (Hermes "warmGlow").
                RadialGradient(gradient: Gradient(colors: [theme.accent.opacity(0.28), .clear]),
                               center: UnitPoint(x: 0.82, y: 0.16),
                               startRadius: 0, endRadius: max(w, h) * 0.95)

                // 2. Faint engraving sunburst — classical etching rays.
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width * 0.82, y: size.height * 0.20)
                    let rays = 80
                    let len = max(size.width, size.height) * 1.5
                    for i in 0..<rays {
                        let a = (Double(i) / Double(rays)) * 2 * Double.pi
                        var p = Path()
                        p.move(to: c)
                        p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * len,
                                              y: c.y + CGFloat(sin(a)) * len))
                        ctx.stroke(p, with: .color(theme.fg.opacity(0.06)), lineWidth: 1)
                    }
                }

                // 3. Orb / portal rings at the burst center (Nous "orb").
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width * 0.82, y: size.height * 0.20)
                    for k in 1...5 {
                        let r = CGFloat(k) * size.width * 0.12
                        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                        ctx.stroke(Path(ellipseIn: rect), with: .color(theme.fg.opacity(0.12)), lineWidth: 1.2)
                    }
                }

                // 4. Fine grain (deterministic hash so it never flickers).
                Canvas { ctx, size in
                    let dots = 2200
                    for i in 0..<dots {
                        let fx = abs((sin(Double(i) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1))
                        let fy = abs((sin(Double(i) * 78.233 + 1.0) * 12543.987).truncatingRemainder(dividingBy: 1))
                        let dot = Path(ellipseIn: CGRect(x: fx * size.width, y: fy * size.height, width: 1.1, height: 1.1))
                        ctx.fill(dot, with: .color(theme.fg.opacity(0.06)))
                    }
                }
            }
            .frame(width: w, height: h)
            .blendMode(.screen)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
