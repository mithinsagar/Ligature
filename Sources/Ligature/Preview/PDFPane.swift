import SwiftUI
import PDFKit
import LigatureCore

/// The PDF preview with its floating controls.
struct PDFPane: View {
    @Bindable var model: ProjectModel
    @State private var state = PDFState()
    @State private var hoveringControls = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack(alignment: .bottom) {
            // Transparent: the pages float on the window's ambient backdrop.
            Color.clear
            if model.pdfData != nil {
                PDFRepresentable(model: model, state: state)
                    .transition(.opacity)
            } else {
                placeholder
            }
            if model.pdfData != nil {
                controls
                    .padding(.bottom, 14)
                    .opacity(hoveringControls || state.recentlyChanged ? 1 : 0.88)
                    .onHover { hoveringControls = $0 }
            }
            if model.showLogs {
                LogsPane(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.panel, value: model.pdfData == nil)
        .animation(.panel, value: model.showLogs)
        .onReceive(NotificationCenter.default.publisher(for: .init("LigatureTestDetach"))) { n in
            if (n.object as? URL) == model.root { openWindow(id: "pdf", value: model.root) }  // test hook
        }
    }

    @ViewBuilder var placeholder: some View {
        switch model.compileState {
        case .noEngine:
            EngineMissingView(model: model)
        case .running:
            VStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                Text("Typesetting…").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color(theme.secondary))
                Text("The first compile downloads the packages your document needs.")
                    .font(.system(size: 11)).foregroundStyle(Color(theme.secondary).opacity(0.8))
            }
        case .failed:
            VStack(spacing: 10) {
                EmptyState(symbol: "exclamationmark.triangle", title: "No PDF yet", message: "Fix the first error and the preview appears here.")
                    .frame(height: 130)
                Button { model.showLogs = true } label: { Label("View Logs", systemImage: "doc.text.magnifyingglass") }.buttonStyle(.ligSecondary)
            }
        default:
            VStack(spacing: 10) {
                EmptyState(symbol: "doc.richtext", title: "Preview", message: "Compile to see your document.")
                    .frame(height: 130)
                Button("Compile") { model.compile(manual: true) }.buttonStyle(.ligPrimary).keyboardShortcut("r")
            }
        }
    }

    var controls: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "chevron.up", help: "Previous page", size: 26) { state.view?.goToPreviousPage(nil) }
            Text("\(state.page) / \(max(state.pages, 1))")
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Color(theme.text))
                .frame(minWidth: 46)
            IconButton(symbol: "chevron.down", help: "Next page", size: 26) { state.view?.goToNextPage(nil) }
            divider
            IconButton(symbol: "minus.magnifyingglass", help: "Zoom out", shortcut: "⌘−", size: 26) { state.zoom(by: -1) }
            ZoomLabel(state: state)
            IconButton(symbol: "plus.magnifyingglass", help: "Zoom in", shortcut: "⌘+", size: 26) { state.zoom(by: 1) }
            divider
            IconButton(symbol: "text.viewfinder", help: "Show caret position in PDF", shortcut: "⌘⇧J", size: 26) { model.syncToPDF() }
            IconButton(symbol: "play.rectangle", help: "Present full screen (arrows to move, Esc to stop)", size: 26) {
                if let d = model.pdfData { PresentationController.start(data: d, page: state.page, screen: state.view?.window?.screen) }
            }
            if !model.pdfDetached {
                IconButton(symbol: "macwindow.on.rectangle", help: "Open the PDF in its own window", size: 26) {
                    openWindow(id: "pdf", value: model.root)
                }
            }
            IconButton(symbol: "doc.text.magnifyingglass", help: "Logs and output files", size: 26, selected: model.showLogs) { model.showLogs.toggle() }
                .overlay(alignment: .topTrailing) {
                    if model.errorCount > 0 {
                        Text("\(model.errorCount)")
                            .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3.5).frame(minWidth: 13, minHeight: 13)
                            .background(Capsule().fill(Color(theme.error)))
                            .offset(x: 3, y: -2)
                            .allowsHitTesting(false)
                    }
                }
            IconButton(symbol: Preferences.shared.pdfDarkPaper ? "moon.fill" : "moon", help: "Dark paper", size: 26, selected: Preferences.shared.pdfDarkPaper) {
                Preferences.shared.pdfDarkPaper.toggle()
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .glassEffect(.regular.interactive(), in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    var divider: some View { Rectangle().fill(Color(theme.hairline)).frame(width: 1, height: 16).padding(.horizontal, 4) }
}

/// The zoom percentage: click to fit the page width, double-click for 100%.
private struct ZoomLabel: View {
    let state: PDFState
    @State private var hovering = false

    var body: some View {
        Text("\(state.displayPercent)%")
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .foregroundStyle(Color(theme.text))
            .frame(minWidth: 44, minHeight: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(theme.text).opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { state.resetZoom() }
            .onTapGesture(count: 1) { state.fitWidth() }
            .onHover { h in withAnimation(.hover) { hovering = h } }
            .help("100% fits the page to the width · click or double-click to return to it · right-click for more")
            .contextMenu {
                Button("Fit Width") { state.fitWidth() }
                Button("Fit Whole Page") { state.fitHeight() }
                Divider()
                Button("Zoom In") { state.zoom(by: 1) }
                Button("Zoom Out") { state.zoom(by: -1) }
            }
    }
}

@Observable @MainActor
final class PDFState {
    weak var view: SyncPDFView?
    var page = 1
    var pages = 0
    var scale: CGFloat = 1
    var recentlyChanged = false
    /// While true the page keeps fitting the pane as it resizes. Any manual zoom turns it off.
    var fitMode = true
    /// Fit the whole page (height) rather than the width.
    var fitToHeight = false
    /// The scale at which the page exactly fits the pane's width. Shown as 100%; zoom steps are relative to it.
    var fitBase: CGFloat = 1
    private var fitRetries = 0

    /// The zoom as shown: 100% = page fits the width.
    var displayPercent: Int { Int((scale / max(fitBase, 0.01) * 100).rounded()) }

    /// Gap between the page and the pane edges when fitting the width.
    static let margin: CGFloat = 28
    /// Zoom steps, as multiples of the fit-width scale (1.0 = 100%).
    static let stops: [CGFloat] = [0.5, 0.67, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0]

    /// PDFKit's internal scroll view.
    var scrollView: NSScrollView? { view?.documentView?.enclosingScrollView }

    /// The zoom actually on screen (PDFKit folds pinch magnification into scaleFactor).
    var effectiveScale: CGFloat { view?.scaleFactor ?? 1 }

    /// Re-reads the zoom after a pinch or any other change.
    func syncScale() {
        let s = effectiveScale
        if abs(s - scale) > 0.001 { scale = s }
    }

    private func setScale(_ s: CGFloat, animated: Bool) {
        guard let v = view else { return }
        v.autoScales = false
        if let sv = scrollView, abs(sv.magnification - 1) > 0.001 { sv.magnification = 1 }
        if animated && !Preferences.shared.reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                v.scaleFactor = s
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.settleLayout() }
            }
        } else {
            v.scaleFactor = s
            settleLayout()
        }
        scale = s
    }

    /// PDFKit keeps its document view at the widest size it has had, so after the pane shrinks the page sits
    /// off-centre in a too-wide canvas. Relaying out shrinks it back and keeps the page centred.
    func settleLayout() {
        guard let v = view else { return }
        v.layoutDocumentView()
        if let sv = scrollView, let doc = v.documentView {
            let clip = sv.contentView
            // Narrower than the pane (zoomed out): centre it instead of pinning it to the left edge.
            let slack = clip.bounds.width - doc.frame.width
            if slack > -0.5 {
                let x = -max(slack, 0) / 2
                if abs(clip.bounds.origin.x - x) > 0.5 {
                    clip.setBoundsOrigin(NSPoint(x: x, y: clip.bounds.origin.y))
                    sv.reflectScrolledClipView(clip)
                }
            }
        }
    }

    func zoom(by direction: Int) {
        updateFitBase()
        let current = effectiveScale / fitBase
        let next = direction > 0 ? (Self.stops.first { $0 > current + 0.01 } ?? Self.stops.last!) : (Self.stops.last { $0 < current - 0.01 } ?? Self.stops.first!)
        if abs(next - 1) < 0.001 { fitWidth(); return }
        fitMode = false
        setScale(next * fitBase, animated: true)
    }

    /// 100% = fit width.
    func resetZoom() { fitWidth() }

    /// The scale that fits the widest page in the pane with equal margins, or nil before layout.
    func computeFitScale() -> CGFloat? {
        guard let v = view, let doc = v.document, doc.pageCount > 0 else { return nil }
        let pageWidth = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.bounds(for: v.displayBox).width }.max() ?? 612
        // The clip view excludes any visible scroller, so the gaps come out equal.
        let viewWidth = scrollView?.contentView.frame.width ?? v.bounds.width
        guard viewWidth > 120 else { return nil }
        // PDFKit scales the page-break margins with the page, so the canvas is (page + 2 margins) × scale wide.
        // Fitting that to the pane leaves no slack, so the page is centred with equal gaps at every size.
        return viewWidth / (pageWidth + Self.margin * 2)
    }

    func updateFitBase() {
        if let f = computeFitScale() { fitBase = f }
    }

    /// The scale that shows a whole page (its height, and its width if that's tighter).
    func computeFitHeightScale() -> CGFloat? {
        guard let v = view, let doc = v.document, doc.pageCount > 0, let w = computeFitScale() else { return nil }
        let pageHeight = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.bounds(for: v.displayBox).height }.max() ?? 792
        let viewHeight = scrollView?.contentView.frame.height ?? v.bounds.height
        guard viewHeight > 120 else { return nil }
        return min(w, viewHeight / (pageHeight + Self.margin * 2))
    }

    /// What fitting currently means (width or whole page).
    func targetFitScale() -> CGFloat? { fitToHeight ? computeFitHeightScale() : computeFitScale() }

    /// Refits in the current fit mode (after a resize).
    func refit(animated: Bool = false) { fitToHeight ? fitHeight(animated: animated) : fitWidth(animated: animated) }

    /// Shows a whole page at once; keeps doing so as the pane resizes.
    func fitHeight(animated: Bool = true) {
        updateFitBase()
        guard let f = computeFitHeightScale() else { return }
        fitMode = true
        fitToHeight = true
        setScale(f, animated: animated)
        // Bring the current page fully into view.
        if let p = view?.currentPage { view?.go(to: p) }
    }

    /// Fits the widest page to the pane with an equal gap on both sides (shown as 100%). Before the pane has
    /// its real size, it waits and tries again rather than fitting to a sliver (which showed as 25%).
    func fitWidth(animated: Bool = true) {
        guard let f = computeFitScale() else {
            guard view?.document != nil, fitRetries < 40 else { return }
            fitRetries += 1
            fitMode = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.fitWidth(animated: false) }
            return
        }
        fitRetries = 0
        fitBase = f
        fitMode = true
        fitToHeight = false
        setScale(f, animated: animated)
    }
}

/// PDFView with SyncTeX clicks, a highlight pulse, and haptic zoom stops.
final class SyncPDFView: PDFView {
    var onSyncClick: ((PDFPage, NSPoint) -> Void)?
    var onScaleChange: ((CGFloat) -> Void)?
    private var lastPressure = 0

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) || event.clickCount == 2 {
            if let page = page(for: p, nearest: true) {
                onSyncClick?(page, convert(p, to: page))
                return
            }
        }
        // Let PDFKit track the click (text selection, links), then treat a click that didn't drag as "show me
        // this in the source".
        super.mouseDown(with: event)
        guard event.clickCount == 1, let window else { return }
        let up = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard hypot(up.x - p.x, up.y - p.y) < 4, let page = page(for: p, nearest: false) else { return }
        let pt = convert(p, to: page)
        if let a = page.annotation(at: pt), a.type == "Link" || a.url != nil || a.action != nil { return }  // links do their own thing
        if let sel = currentSelection, !(sel.string ?? "").isEmpty, (sel.string ?? "").count > 1, sel.pages.contains(page) {
            // A real selection (e.g. after a drag) is left alone.
            if (sel.string ?? "").contains(" ") { return }
        }
        onSyncClick?(page, pt)
    }

    override func pressureChange(with event: NSEvent) {
        super.pressureChange(with: event)
        if event.stage == 2 && lastPressure < 2 {
            let p = convert(event.locationInWindow, from: nil)
            if let page = page(for: p, nearest: true) {
                MainActor.assumeIsolated { Haptics.play(.forceClick) }
                onSyncClick?(page, convert(p, to: page))
            }
        }
        lastPressure = event.stage
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        let s = scaleFactor
        onScaleChange?(s)
    }

    /// Draws a soft accent pulse over rects on a page.
    func pulse(rects: [CGRect], on page: PDFPage) {
        guard let docView = documentView else { return }
        let accent = MainActor.assumeIsolated { ThemeManager.shared.accentNS }
        for r in rects {
            let inView = convert(r.insetBy(dx: -3, dy: -2), from: page)
            let inDoc = docView.convert(inView, from: self)
            let v = NSView(frame: inDoc)
            v.wantsLayer = true
            v.layer?.backgroundColor = accent.withAlphaComponent(0.25).cgColor
            v.layer?.cornerRadius = 3
            v.layer?.borderColor = accent.withAlphaComponent(0.6).cgColor
            v.layer?.borderWidth = 1
            docView.addSubview(v)
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 1
            anim.toValue = 0
            anim.beginTime = CACurrentMediaTime() + 0.6
            anim.duration = 1.0
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
            v.layer?.add(anim, forKey: "fade")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { v.removeFromSuperview() }
        }
    }
}

struct PDFRepresentable: NSViewRepresentable {
    let model: ProjectModel
    let state: PDFState

    func makeNSView(context: Context) -> NSView {
        let c = context.coordinator
        let container = NSView()
        container.wantsLayer = true
        let v = SyncPDFView()
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.pageShadowsEnabled = false
        v.autoScales = false
        v.displayBox = .cropBox
        v.backgroundColor = .clear
        v.pageBreakMargins = NSEdgeInsets(top: PDFState.margin, left: PDFState.margin, bottom: PDFState.margin, right: PDFState.margin)
        // Never draw outside the pane (AppKit views don't clip by default since macOS 14).
        container.clipsToBounds = true
        v.clipsToBounds = true
        v.translatesAutoresizingMaskIntoConstraints = false
        let glow = PageGlowView()
        glow.pdfView = v
        glow.autoresizingMask = [.width, .height]
        glow.pageRects = { [weak v] in
            guard let v else { return [] }
            return v.visiblePages.map { v.convert($0.bounds(for: v.displayBox), from: $0) }
        }
        container.addSubview(glow)
        container.addSubview(v)
        c.glow = glow
        c.state = state
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor), v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.topAnchor.constraint(equalTo: container.topAnchor), v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        c.view = v
        c.container = container
        state.view = v
        model.pdf = c
        v.onSyncClick = { [weak model] page, point in
            guard let model, let doc = page.document else { return }
            let index = doc.index(for: page) + 1
            // The word under the pointer, so the editor can mark it exactly.
            let word = page.selectionForWord(at: point)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            model.syncToSource(page: index, point: point, pageHeight: Double(page.bounds(for: .mediaBox).height), word: word)
        }
        v.onScaleChange = { _ in state.fitMode = false; state.syncScale() }
        // Pinch-to-zoom may go to PDFKit's internal scroll view, which never tells PDFView; watch the gesture
        // itself and read the zoom back afterwards so the percentage keeps up.
        c.magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .smartMagnify]) { [weak v] event in
            if let v, event.window === v.window, v.bounds.contains(v.convert(event.locationInWindow, from: nil)) {
                state.fitMode = false
                DispatchQueue.main.async { state.syncScale(); c.refreshGlow() }
            }
            return event
        }
        container.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: container, queue: .main) { _ in
            MainActor.assumeIsolated {
                c.paneResized()
                // The PDF view's own layout lags the container's, so measure again once it has settled.
                DispatchQueue.main.async { c.paneResized() }
            }
        }
        NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: v, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let p = v.currentPage, let d = v.document { state.page = d.index(for: p) + 1 }
            }
        }
        NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: v, queue: .main) { _ in
            MainActor.assumeIsolated { state.syncScale() }
        }
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged, .PDFViewDocumentChanged, .PDFViewDisplayModeChanged] {
            NotificationCenter.default.addObserver(forName: name, object: v, queue: .main) { _ in
                MainActor.assumeIsolated { c.refreshGlow() }
            }
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let c = context.coordinator
        let dark = Preferences.shared.pdfDarkPaper
        c.applyAppearance(dark: dark)
        c.glow?.frame = nsView.bounds
        c.glow?.glowColor = ThemeManager.shared.accentNS
        c.glow?.dark = ThemeManager.shared.theme.isDark
        c.refreshGlow()
        if c.loadedVersion != model.pdfVersion, let data = model.pdfData {
            // A compile you started is revealed by a wave; live updates just crossfade.
            let reveal = model.scanToken != c.lastScanToken
            c.lastScanToken = model.scanToken
            c.load(data, version: model.pdfVersion, state: state, model: model, reveal: reveal)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, PDFControlling {
        weak var view: SyncPDFView?
        weak var container: NSView?
        weak var glow: PageGlowView?
        weak var observedClip: NSClipView?
        private var lastFitWidth: CGFloat = 0
        weak var observedWindow: NSWindow?
        private var settleWork: DispatchWorkItem?
        var magnifyMonitor: Any?
        weak var state: PDFState?
        var lastScanToken = 0
        /// Test hook: stretch the reveal so it can be captured.
        static var slowdown: Double = 1

        // MARK: Compile reveal

        /// The new PDF is already in place under a snapshot of the old one. An organic wave grows from the
        /// centre of the page and cuts the snapshot away, so the update and the animation are one motion. Its
        /// edge is a thin band of glass: frosted, with a soft accent halo and a bright rim, clipped to the pages.
        /// Visible page rects in the container's coordinates.
        func currentPageRects() -> [CGRect] {
            guard let v = view, let container else { return [] }
            return v.visiblePages.map { container.convert(v.convert($0.bounds(for: v.displayBox), from: $0), from: v) }
                .map { $0.intersection(container.bounds) }.filter { !$0.isNull && $0.width > 2 && $0.height > 2 }
        }

        /// Draws the visible pages (white paper + content) at their on-screen positions into a Retina bitmap.
        func renderVisiblePages(in container: NSView) -> NSImage? {
            guard let v = view else { return nil }
            let bounds = container.bounds
            let scale = container.window?.backingScaleFactor ?? 2
            let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
            guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.scaleBy(x: scale, y: scale)
            let dark = Preferences.shared.pdfDarkPaper
            for page in v.visiblePages {
                let r = container.convert(v.convert(page.bounds(for: v.displayBox), from: page), from: v)
                guard r.intersects(bounds) else { continue }
                ctx.saveGState()
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(r)
                let box = page.bounds(for: v.displayBox)
                ctx.translateBy(x: r.minX, y: r.minY)
                ctx.scaleBy(x: r.width / box.width, y: r.height / box.height)
                ctx.translateBy(x: -box.minX, y: -box.minY)
                page.draw(with: v.displayBox, to: ctx)
                ctx.restoreGState()
            }
            guard let cg = ctx.makeImage() else { return nil }
            var img = NSImage(cgImage: cg, size: bounds.size)
            if dark, let ci = CIImage(cgImage: cg).applyingFilter("CIColorInvert").applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: Float.pi]) as CIImage?,
               let out = CIContext().createCGImage(ci, from: ci.extent) {
                img = NSImage(cgImage: out, size: bounds.size)
            }
            return img
        }

        func playReveal(snapshot: NSImageView, pages measured: [CGRect], in container: NSView) {
            // Everything happens in one overlay view on top of the PDF, so layer order and coordinates are
            // ours (AppKit may reorder a view's own sublayers, and the PDF view sits above them).
            let image = snapshot.image
            snapshot.removeFromSuperview()
            let bounds = container.bounds
            let overlay = NSView(frame: bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.wantsLayer = true
            overlay.layerUsesCoreImageFilters = true
            container.addSubview(overlay)
            guard let root = overlay.layer, let image else { overlay.removeFromSuperview(); return }

            let pages = measured.map { overlay.convert($0, from: container) }
            let area = pages.reduce(CGRect.null) { $0.union($1) }
            let focus = area.isNull ? bounds : area
            let center = CGPoint(x: focus.midX, y: focus.midY)
            let reach = [CGPoint(x: focus.minX, y: focus.minY), CGPoint(x: focus.maxX, y: focus.minY),
                         CGPoint(x: focus.minX, y: focus.maxY), CGPoint(x: focus.maxX, y: focus.maxY)]
                .map { hypot($0.x - center.x, $0.y - center.y) }.max()! * 1.06
            let duration = 1.1 * Self.slowdown
            let frames = 44
            let times = (0...frames).map { Double($0) / Double(frames) }
            // A ripple: perfect circles from the centre, easing out (quick start, long gentle settle).
            let ease: (Double) -> Double = { 1 - pow(1 - min(max($0, 0), 1), 3) }
            let radii = times.map { max(2, reach * ease($0 / 0.85)) }
            let blobs = radii.map { Self.circle(center: center, radius: $0) }

            func animate(_ layer: CALayer, _ key: String, _ values: [Any], timing: [NSNumber]? = nil) {
                let a = CAKeyframeAnimation(keyPath: key)
                a.values = values
                a.keyTimes = timing ?? times.map { NSNumber(value: $0) }
                a.duration = duration
                a.calculationMode = .linear
                a.fillMode = .forwards
                a.isRemovedOnCompletion = false
                layer.add(a, forKey: key)
            }

            // 1. The old page, cut away from the inside out to reveal the new one beneath.
            let old = CALayer()
            old.frame = bounds
            old.contents = image
            old.contentsGravity = .resize
            old.contentsScale = container.window?.backingScaleFactor ?? 2
            let cut = CAShapeLayer()
            cut.frame = bounds
            cut.fillRule = .evenOdd
            let holed: (CGPath) -> CGPath = { p in
                let m = CGMutablePath()
                m.addRect(bounds.insetBy(dx: -4, dy: -4))
                m.addPath(p)
                return m
            }
            cut.path = holed(blobs.last!)
            old.mask = cut
            animate(cut, "path", blobs.map(holed))
            root.addSublayer(old)

            // 2. The glass edge, clipped to the pages.
            let edge = CALayer()
            edge.frame = bounds
            let clip = CAShapeLayer()
            clip.frame = bounds
            let clipPath = CGMutablePath()
            (pages.isEmpty ? [bounds] : pages).forEach { clipPath.addRect($0) }
            clip.path = clipPath
            edge.mask = clip
            let accent = ThemeManager.shared.accentNS
            let fade: [NSNumber] = [0, 1, 1, 0.85, 0]
            let fadeTimes: [NSNumber] = [0, 0.08, 0.55, 0.8, 1]

            // Frosted band just inside the wavefront.
            let frost = CALayer()
            frost.frame = bounds
            if let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.5]) { frost.backgroundFilters = [blur] }
            let frostMask = CAShapeLayer()
            frostMask.frame = bounds
            frostMask.fillColor = nil
            frostMask.strokeColor = NSColor.black.cgColor
            frostMask.path = blobs.last
            frost.mask = frostMask
            animate(frostMask, "path", blobs)
            animate(frostMask, "lineWidth", times.map { 18 * (1 - $0) + 5 })
            edge.addSublayer(frost)


            // Liquid-glass lens riding the wavefront: Core Image's torus lens bends the page in a thin ring.
            if let torus = CIFilter(name: "CITorusLensDistortion") {
                torus.name = "torus"
                let scale = container.window?.backingScaleFactor ?? 2
                torus.setValue(CIVector(x: center.x * scale, y: center.y * scale), forKey: kCIInputCenterKey)
                torus.setValue(14 * scale, forKey: kCIInputWidthKey)
                torus.setValue(1.6, forKey: "inputRefraction")
                torus.setValue(radii.last! * scale, forKey: kCIInputRadiusKey)
                let lens = CALayer()
                lens.frame = bounds
                lens.backgroundFilters = [torus]
                animate(lens, "backgroundFilters.torus.inputRadius", radii.map { $0 * scale })
                edge.addSublayer(lens)
            }

            // Soft bloom from the centre.
            let bloom = CAGradientLayer()
            bloom.type = .radial
            bloom.colors = [accent.withAlphaComponent(0.22).cgColor, accent.withAlphaComponent(0.06).cgColor, NSColor.clear.cgColor]
            bloom.startPoint = CGPoint(x: 0.5, y: 0.5)
            bloom.endPoint = CGPoint(x: 1, y: 1)
            let side = reach * 2.2
            bloom.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            bloom.position = center
            animate(bloom, "transform.scale", times.map { 0.05 + 0.95 * ease($0 * 1.1) })
            animate(bloom, "opacity", [0, 1, 0.6, 0] as [NSNumber], timing: [0, 0.12, 0.5, 1])
            edge.insertSublayer(bloom, at: 0)

            // The leading glass ring and two trailing rings, each a bright tint line with a white highlight.
            for i in 0..<3 {
                let delay = Double(i) * 0.11
                let ringRadii = times.map { max(1, reach * 0.98 * ease(($0 - delay) / 0.8)) }
                let ringPaths = ringRadii.map { Self.circle(center: center, radius: $0) }
                let alpha: [NSNumber] = times.map { t in
                    let local = (t - delay) / 0.8
                    guard local > 0 else { return 0 }
                    return NSNumber(value: max(0, 1 - local) * (i == 0 ? 1 : 0.55))
                }
                let width: CGFloat = i == 0 ? 2.6 : 1.4
                let halo = CAShapeLayer()
                halo.frame = bounds
                halo.fillColor = nil
                halo.strokeColor = accent.withAlphaComponent(0.55).cgColor
                halo.lineWidth = width + 3
                halo.shadowColor = accent.cgColor
                halo.shadowOpacity = 0.8
                halo.shadowRadius = 9
                halo.shadowOffset = .zero
                halo.path = ringPaths.last
                animate(halo, "path", ringPaths)
                animate(halo, "opacity", alpha)
                edge.addSublayer(halo)
                for (color, w) in [(accent.withAlphaComponent(0.95), width), (NSColor.white.withAlphaComponent(0.9), width * 0.4)] {
                    let rim = CAShapeLayer()
                    rim.frame = bounds
                    rim.fillColor = nil
                    rim.strokeColor = color.cgColor
                    rim.lineWidth = w
                    rim.path = ringPaths.last
                    animate(rim, "path", ringPaths)
                    animate(rim, "opacity", alpha)
                    edge.addSublayer(rim)
                }
            }
            root.addSublayer(edge)

            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { overlay.removeFromSuperview() }
        }

        /// A circle drawn with the same 160 points as `blob`, so Core Animation can morph between frames.
        static func circle(center: CGPoint, radius r: CGFloat) -> CGPath {
            let path = CGMutablePath()
            for i in 0..<160 {
                let a = Double(i) / 160 * 2 * .pi
                let p = CGPoint(x: center.x + r * CGFloat(cos(a)), y: center.y + r * CGFloat(sin(a)))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            return path
        }

        /// A softly wobbling closed shape: a circle whose radius ripples with a few low harmonics that drift
        /// and calm down as it grows. Always 160 points so Core Animation can morph between frames.
        static func blob(center: CGPoint, radius r: CGFloat, t: Double) -> CGPath {
            let n = 160
            let amp = 0.055 * (1 - t) + 0.014
            let path = CGMutablePath()
            for i in 0..<n {
                let a = Double(i) / Double(n) * 2 * .pi
                let wobble = amp * (sin(3 * a + 5.0 * t + 0.6) + 0.55 * sin(5 * a - 4.0 * t + 1.9) + 0.3 * sin(2 * a + 3.0 * t))
                let rr = r * CGFloat(1 + wobble)
                let p = CGPoint(x: center.x + rr * CGFloat(cos(a)), y: center.y + rr * CGFloat(sin(a)))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            return path
        }
        var loadedVersion = -1
        private var darkApplied: Bool?

        /// PDFKit's internal scroll view paints an opaque background; clear it so the backdrop shows through.
        func clearPDFBackground() {
            guard let v = view else { return }
            var stack: [NSView] = [v]
            while let s = stack.popLast() {
                if let sv = s as? NSScrollView { sv.drawsBackground = false; sv.backgroundColor = .clear; sv.contentView.drawsBackground = false }
                if let cv = s as? NSClipView { cv.drawsBackground = false }
                stack += s.subviews
            }
        }

        func refreshGlow() {
            clearPDFBackground()
            glow?.needsDisplay = true
            // Follow scrolling: the PDF's own clip view only exists once a document is shown.
            if let clip = view?.documentView?.enclosingScrollView?.contentView, clip !== observedClip {
                observedClip = clip
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.glow?.needsDisplay = true }
                }
                // The clip view is what fit-width measures, so refit whenever its width really changes
                // (window resize, maximise, full screen, sidebar or divider moves).
                clip.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.paneResized() }
                }
            }
            // A final pass once the window stops changing (end of a drag, zoom, or full-screen transition),
            // when every view has its final size.
            if let window = view?.window, window !== observedWindow {
                observedWindow = window
                for name in [NSWindow.didEndLiveResizeNotification, NSWindow.didExitFullScreenNotification, NSWindow.didEnterFullScreenNotification] {
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.paneResized(force: true)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.paneResized(force: true) }
                        }
                    }
                }
            }
        }

        /// Keeps 100% meaning "fits the width" at any pane size: in fit mode the page refits, otherwise the
        /// manual zoom stays put and the percentage is recomputed against the new width.
        func paneResized(force: Bool = false) {
            guard let state else { return }
            if !force, let clip = observedClip {
                let w = clip.frame.width
                guard abs(w - lastFitWidth) > 0.5 else { return }
                lastFitWidth = w
            }
            if let clip = observedClip { lastFitWidth = clip.frame.width }
            if state.fitMode { state.refit() } else { state.updateFitBase(); state.settleLayout() }
            refreshGlow()
            // Window animations (maximise, restore, full screen) and PDFKit's own layout can land after the
            // last notification, so measure once more when the size has been still for a moment.
            settleWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let state = self.state else { return }
                if state.fitMode {
                    if let f = state.targetFitScale(), abs(f - state.effectiveScale) > 0.001 { state.refit() }
                    else { state.settleLayout() }
                } else { state.updateFitBase() }
                self.refreshGlow()
            }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        func applyAppearance(dark: Bool) {
            guard let v = view else { return }
            if darkApplied != dark {
                darkApplied = dark
                if dark {
                    // Invert the page and rotate hue back so colours keep their identity; the background is
                    // pre-inverted so it ends up matching the canvas.
                    let invert = CIFilter(name: "CIColorInvert")!
                    let hue = CIFilter(name: "CIHueAdjust")!
                    hue.setValue(Float.pi, forKey: kCIInputAngleKey)
                    v.wantsLayer = true
                    v.contentFilters = [invert, hue]
                } else {
                    v.contentFilters = []
                }
            }
            v.backgroundColor = .clear
        }


        /// Swaps in a new PDF without a flash: snapshot the current view, load the new document at the same
        /// position and scale, then fade the snapshot away.
        func load(_ data: Data, version: Int, state: PDFState, model: ProjectModel, reveal: Bool = false) {
            guard let v = view, let container, let doc = PDFDocument(data: data) else { return }
            let firstLoad = v.document == nil
            // Picture of the old pages, drawn by us (a view snapshot doesn't capture PDFKit's tiles), plus where
            // they sit, measured before the swap while the layout is valid.
            var snapshot: NSImageView?
            let oldPages = firstLoad ? [] : currentPageRects()
            if !firstLoad, let img = renderVisiblePages(in: container) {
                let iv = NSImageView(frame: container.bounds)
                iv.image = img
                iv.imageScaling = .scaleAxesIndependently
                iv.wantsLayer = true
                container.addSubview(iv)
                snapshot = iv
            }
            let scroll = v.documentView?.enclosingScrollView
            let origin = scroll?.contentView.bounds.origin
            let scale = v.scaleFactor
            let auto = v.autoScales
            v.document = doc
            var heights: [Int: Double] = [:]
            for i in 0..<doc.pageCount { heights[i + 1] = Double(doc.page(at: i)?.bounds(for: .mediaBox).height ?? 792) }
            model.pageHeights = heights
            state.pages = doc.pageCount
            if firstLoad {
                DispatchQueue.main.async { state.fitWidth(animated: false) }
            } else {
                v.autoScales = auto
                if !auto { v.scaleFactor = scale }
                v.layoutDocumentView()
                if let origin, let scroll {
                    scroll.contentView.scroll(to: origin)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            loadedVersion = version
            if let p = v.currentPage { state.page = doc.index(for: p) + 1 }
            if let snapshot {
                if reveal && !Preferences.shared.reduceMotion {
                    playReveal(snapshot: snapshot, pages: oldPages, in: container)
                } else {
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = Preferences.shared.reduceMotion ? 0 : 0.16
                        snapshot.animator().alphaValue = 0
                    }, completionHandler: { snapshot.removeFromSuperview() })
                }
            }
            state.recentlyChanged = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { state.recentlyChanged = false }
        }

        func show(page: Int, rects: [CGRect]) {
            guard let v = view, let doc = v.document, let p = doc.page(at: page - 1) else { return }
            let target = rects.first ?? CGRect(x: 0, y: p.bounds(for: .mediaBox).height, width: 1, height: 1)
            // Centre the rect vertically.
            let visibleHeight = v.bounds.height / max(v.scaleFactor, 0.1)
            let dest = PDFDestination(page: p, at: CGPoint(x: 0, y: target.maxY + visibleHeight / 2 - target.height))
            v.go(to: dest)
            v.pulse(rects: rects, on: p)
        }

        func print() {
            guard let v = view, let doc = v.document else { return }
            let info = NSPrintInfo.shared
            if let op = doc.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) {
                op.run()
            } else {
                v.print(with: info, autoRotate: true)
            }
        }
    }
}

/// Shown when no TeX engine is installed.
struct EngineMissingView: View {
    let model: ProjectModel
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(accent)
            Text("Install a TeX engine").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(theme.text))
            Text("Ligature uses Tectonic, a small, modern engine that downloads only the packages your document needs. Install it once with Homebrew:")
                .font(.system(size: 12)).foregroundStyle(Color(theme.secondary)).multilineTextAlignment(.center).frame(maxWidth: 340)
            HStack(spacing: 8) {
                Text("brew install tectonic").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Color(theme.text))
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install tectonic", forType: .string)
                    copied = true
                }
                .buttonStyle(.ligChip(selected: copied))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .card(cornerRadius: 9)
            Text("Already have MacTeX? Choose latexmk in Settings → Engine.")
                .font(.system(size: 11)).foregroundStyle(Color(theme.secondary).opacity(0.8))
            Button("Check Again") { model.retryEngine() }.buttonStyle(.ligSecondary)
        }
        .padding(30)
    }
}
