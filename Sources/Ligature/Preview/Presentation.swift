import AppKit
import PDFKit
import SwiftUI

/// Presents the PDF full screen, one page at a time, on a black background: arrows, space or a click move
/// between pages, Esc ends. Great for beamer slides.
@MainActor
final class PresentationController: NSObject, NSWindowDelegate {
    private static var current: PresentationController?
    private var window: NSWindow?
    private var savedOptions: NSApplication.PresentationOptions = []

    static func start(data: Data, page: Int, screen: NSScreen?) {
        current?.stop()
        guard let doc = PDFDocument(data: data), let screen = screen ?? NSScreen.main else { return }
        let c = PresentationController()
        current = c
        c.open(doc, page: page, screen: screen)
    }

    private func open(_ doc: PDFDocument, page: Int, screen: NSScreen) {
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.level = .normal
        let view = SlideView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.document = doc
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.pageShadowsEnabled = false
        view.backgroundColor = .black
        view.autoScales = true
        view.autoresizingMask = [.width, .height]
        view.onExit = { [weak self] in self?.stop() }
        if let p = doc.page(at: max(0, min(page - 1, doc.pageCount - 1))) { view.go(to: p) }
        let container = NSView(frame: view.frame)
        container.addSubview(view)
        let hint = NSHostingView(rootView: PresentationHint(pages: doc.pageCount))
        hint.frame = NSRect(x: 0, y: 30, width: screen.frame.width, height: 40)
        hint.autoresizingMask = [.width]
        container.addSubview(hint)
        w.contentView = container
        savedOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        w.setFrame(screen.frame, display: true)
        w.makeKeyAndOrderFront(nil)
        if ProcessInfo.processInfo.environment["LIGATURE_SCRIPT"] == nil { NSApp.activate() }
        w.makeFirstResponder(view)
        window = w
        // The hint fades after a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.6; hint.animator().alphaValue = 0 }
        }
    }

    func stop() {
        NSApp.presentationOptions = savedOptions
        window?.orderOut(nil)
        window = nil
        if Self.current === self { Self.current = nil }
    }

    func windowWillClose(_ notification: Notification) { stop() }
}

/// The slide view: keys and clicks move between pages.
private final class SlideView: PDFView {
    var onExit: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onExit?()                                                  // Esc
        case 124, 125, 49, 121, 36: goToNextPage(nil)                       // → ↓ space pgdn return
        case 123, 126, 116, 51: goToPreviousPage(nil)                        // ← ↑ pgup delete
        case 115: goToFirstPage(nil)                                         // home
        case 119: goToLastPage(nil)                                          // end
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) { goToNextPage(nil) }
    override func rightMouseDown(with event: NSEvent) { goToPreviousPage(nil) }
}

private struct PresentationHint: View {
    let pages: Int
    var body: some View {
        HStack(spacing: 14) {
            Label("Next", systemImage: "arrow.right")
            Label("Previous", systemImage: "arrow.left")
            Label("Exit", systemImage: "escape")
            Text("\(pages) page\(pages == 1 ? "" : "s")").foregroundStyle(.white.opacity(0.6))
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Capsule().fill(.white.opacity(0.12)))
        .frame(maxWidth: .infinity)
    }
}
