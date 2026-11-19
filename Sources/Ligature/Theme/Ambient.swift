import SwiftUI
import AppKit

/// The softly lit surface everything floats on: the theme's canvas with two large, blurred pools of light in the
/// accent hue. It sits under the toolbar and sidebar so their Liquid Glass picks up colour. `pulse` changes when a
/// new PDF arrives and briefly brightens the light around the pages.
struct AmbientBackdrop: View {
    var pulse: Int = 0
    @State private var bloom = false

    var body: some View {
        let dark = theme.isDark
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Color(theme.canvas)
                // Main light, upper right (behind the PDF).
                Ellipse()
                    .fill(accent.opacity(dark ? 0.14 : 0.14))
                    .frame(width: w * 0.75, height: h * 0.8)
                    .blur(radius: 140)
                    .position(x: w * 0.78, y: h * 0.18)
                // Cooler fill light, lower left (behind the editor and sidebar).
                Ellipse()
                    .fill(accent.opacity(dark ? 0.09 : 0.10))
                    .hueRotation(.degrees(-38))
                    .frame(width: w * 0.65, height: h * 0.7)
                    .blur(radius: 150)
                    .position(x: w * 0.12, y: h * 0.92)
                // A faint warm counter-light so it never reads as a flat tint.
                Ellipse()
                    .fill(accent.opacity(dark ? 0.04 : 0.05))
                    .hueRotation(.degrees(70))
                    .frame(width: w * 0.5, height: h * 0.5)
                    .blur(radius: 160)
                    .position(x: w * 0.5, y: h * 0.55)
                // Compile bloom behind the pages.
                RadialGradient(colors: [accent.opacity(dark ? 0.14 : 0.16), .clear], center: UnitPoint(x: 0.74, y: 0.45), startRadius: 0, endRadius: max(w, h) * 0.5)
                    .opacity(bloom ? 1 : 0)
                // Vignette for depth.
                RadialGradient(colors: [.clear, .black.opacity(dark ? 0.35 : 0.06)], center: .center, startRadius: min(w, h) * 0.35, endRadius: max(w, h) * 0.85)
            }
            .compositingGroup()
        }
        .ignoresSafeArea()
        .onChange(of: pulse) { _, _ in
            guard !Preferences.shared.reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.25)) { bloom = true }
            withAnimation(.easeInOut(duration: 1.4).delay(0.3)) { bloom = false }
        }
    }
}

/// A glass rim: a hairline that catches light at the top and fades towards the bottom, plus a faint inner sheen.
struct GlassEdge: ViewModifier {
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        let dark = theme.isDark
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(dark ? 0.22 : 0.9), .white.opacity(dark ? 0.05 : 0.35), Color(theme.hairline)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
    }
}

extension View {
    func glassEdge(cornerRadius: CGFloat = 14) -> some View { modifier(GlassEdge(cornerRadius: cornerRadius)) }

    /// A floating surface: rounded, rimmed, with a soft lifted shadow and a whisper of accent light beneath.
    func floatingSurface(cornerRadius: CGFloat = 16) -> some View {
        let dark = theme.isDark
        return self
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .glassEdge(cornerRadius: cornerRadius)
            .shadow(color: .black.opacity(dark ? 0.45 : 0.10), radius: 22, y: 10)
            .shadow(color: accent.opacity(dark ? 0.04 : 0.05), radius: 30, y: 0)
    }
}

/// Draws a soft glow around each visible PDF page, behind a transparent PDFView.
final class PageGlowView: NSView {
    weak var pdfView: NSView?
    var pageRects: () -> [NSRect] = { [] }
    var glowColor: NSColor = .systemBlue
    var dark = false

    override var isFlipped: Bool { pdfView?.isFlipped ?? false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        for r in pageRects() where r.insetBy(dx: -80, dy: -80).intersects(dirtyRect) {
            ctx.saveGraphicsState()
            // Wide coloured glow…
            let glow = NSShadow()
            glow.shadowColor = glowColor.withAlphaComponent(dark ? 0.16 : 0.24)
            glow.shadowBlurRadius = 36
            glow.shadowOffset = .zero
            glow.set()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
            ctx.restoreGraphicsState()
            ctx.saveGraphicsState()
            // …and a tight contact shadow for lift.
            let lift = NSShadow()
            lift.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.45 : 0.16)
            lift.shadowBlurRadius = 14
            lift.shadowOffset = NSSize(width: 0, height: isFlipped ? 6 : -6)
            lift.set()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
            ctx.restoreGraphicsState()
        }
    }
}

/// A ring shape (outer circle minus inner circle), for glass that only covers a band.
struct Annulus: Shape {
    var thickness: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = max(0, outer - thickness)
        p.addArc(center: c, radius: outer, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
        p.closeSubpath()
        // Opposite winding cuts the hole under the non-zero fill rule.
        p.addArc(center: c, radius: inner, startAngle: .degrees(360), endAngle: .zero, clockwise: true)
        p.closeSubpath()
        return p
    }
}
