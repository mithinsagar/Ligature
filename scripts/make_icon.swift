// Draws Ligature's icon: an italic serif "fi" ligature on an ink tile with an accent dot.
import AppKit
let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(srgbRed: 0.09, green: 0.1, blue: 0.11, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 0.17, green: 0.18, blue: 0.21, alpha: 1), NSColor(srgbRed: 0.07, green: 0.075, blue: 0.085, alpha: 1)])!
        .draw(in: path, angle: -90)
    NSColor.white.withAlphaComponent(0.1).setStroke()
    path.lineWidth = 4
    path.stroke()

    let base = NSFont.systemFont(ofSize: 520, weight: .regular)
    let serif = base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 520) } ?? base
    let italic = NSFontManager.shared.convert(serif, toHaveTrait: .italicFontMask)
    let text = NSAttributedString(string: "fi", attributes: [.font: italic, .foregroundColor: NSColor.white, .ligature: 1])
    let ts = text.size()
    text.draw(at: NSPoint(x: body.midX - ts.width / 2, y: body.midY - ts.height / 2 + 10))

    NSColor(srgbRed: 0.43, green: 0.56, blue: 0.98, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: body.midX + 175, y: body.minY + 150, width: 100, height: 100)).fill()
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
