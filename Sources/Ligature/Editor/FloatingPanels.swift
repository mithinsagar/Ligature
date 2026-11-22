import AppKit
import SwiftUI
import PDFKit
import LigatureCore

/// A borderless child window that hosts SwiftUI content next to a rect in a view, without taking focus.
@MainActor
final class FloatingPanel {
    private var panel: NSPanel?
    private var host: NSHostingView<AnyView>?
    private(set) var isVisible = false
    private var hideWork: DispatchWorkItem?

    func show<V: View>(_ view: V, near rect: NSRect, in source: NSView, preferAbove: Bool = false, gap: CGFloat = 6) {
        guard let window = source.window else { return }
        hideWork?.cancel()
        let root = AnyView(view.environment(\.colorScheme, ThemeManager.shared.theme.isDark ? .dark : .light))
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .floating
            p.ignoresMouseEvents = false
            p.becomesKeyOnlyIfNeeded = true
            p.animationBehavior = .none
            let h = NSHostingView(rootView: root)
            h.sizingOptions = [.intrinsicContentSize]
            p.contentView = h
            panel = p
            host = h
        } else {
            host?.rootView = root
        }
        guard let panel, let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let inWindow = source.convert(rect, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        var origin = NSPoint(x: onScreen.minX - 6, y: onScreen.minY - size.height - gap)
        if preferAbove || origin.y < (window.screen?.visibleFrame.minY ?? 0) + 8 {
            origin.y = onScreen.maxY + gap
        }
        // Keep it within the source view's visible area (e.g. a token scrolled just out of view).
        let visible = window.convertToScreen(source.convert(source.visibleRect, to: nil))
        origin.y = min(max(origin.y, visible.minY - 10), visible.maxY - size.height + 10)
        if let screen = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        if !isVisible || panel.alphaValue < 1 {
            panel.alphaValue = isVisible ? panel.alphaValue : 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Preferences.shared.reduceMotion ? 0 : 0.12
                panel.animator().alphaValue = 1
            }
        }
        isVisible = true
    }

    func hide(animated: Bool = true) {
        guard isVisible, let panel else { return }
        isVisible = false
        let work = DispatchWorkItem { [weak panel] in
            panel?.parent?.removeChildWindow(panel!)
            panel?.orderOut(nil)
        }
        hideWork = work
        if animated && !Preferences.shared.reduceMotion {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.1
                panel.animator().alphaValue = 0
            }, completionHandler: { if !work.isCancelled { work.perform() } })
        } else {
            work.perform()
        }
    }

    var frame: NSRect { panel?.frame ?? .zero }
}

// MARK: Completion list

@Observable @MainActor
final class CompletionState {
    var items: [CompletionItem] = []
    var selected = 0
    var query = ""
    var onAccept: ((Int) -> Void)?
}

struct CompletionList: View {
    @Bindable var state: CompletionState

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 1) {
                        ForEach(Array(state.items.enumerated()), id: \.element.id) { i, item in
                            CompletionRow(item: item, query: state.query, selected: i == state.selected)
                                .id(i)
                                .onTapGesture { state.onAccept?(i) }
                                .onHover { if $0 { state.selected = i } }
                        }
                    }
                    .padding(5)
                }
                .onChange(of: state.selected) { _, i in withAnimation(.easeOut(duration: 0.08)) { proxy.scrollTo(i) } }
            }
            .frame(height: min(CGFloat(state.items.count) * 29 + 10, 272))
            if let item = state.items[safe: state.selected] {
                HStack(spacing: 6) {
                    Text(item.snippet.replacingOccurrences(of: #"\$\{?\d:?([^}]*)\}?"#, with: "$1", options: .regularExpression).replacingOccurrences(of: "\n", with: " ⏎ "))
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineLimit(1)
                        .foregroundStyle(Color(theme.secondary))
                    Spacer()
                    KeyCap(text: "⏎")
                    KeyCap(text: "⇥")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(theme.text).opacity(0.03))
            }
        }
        .frame(width: 330)
        .background(Color(theme.surface), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .glassEdge(cornerRadius: 11)
        .shadow(color: .black.opacity(theme.isDark ? 0.5 : 0.16), radius: 16, y: 8)
        .padding(18)
    }
}

private struct CompletionRow: View {
    let item: CompletionItem
    let query: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.opacity(selected ? 0.22 : 0.13))
                if let g = item.glyph {
                    Text(g).font(.system(size: 13, design: .serif)).foregroundStyle(tint)
                } else {
                    Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint)
                }
            }
            .frame(width: 20, height: 20)
            HighlightedText(text: item.label, query: query, font: .system(size: 12.5, design: .monospaced))
                .foregroundStyle(Color(theme.text))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(item.detail)
                .font(.system(size: 11))
                .foregroundStyle(Color(theme.secondary))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? accent.opacity(0.14) : .clear))
        .contentShape(Rectangle())
    }

    var symbol: String {
        switch item.kind {
        case .command: "chevron.left.forwardslash.chevron.right"
        case .environment: "curlybraces"
        case .label: "tag"
        case .citation: "quote.opening"
        case .file: "doc.text"
        case .symbol: "function"
        case .package: "shippingbox"
        case .snippet: "text.badge.plus"
        }
    }

    var tint: Color {
        switch item.kind {
        case .command, .symbol: Color(theme.command)
        case .environment: Color(theme.environment)
        case .label, .citation: Color(theme.reference)
        case .file, .package: Color(theme.math)
        case .snippet: accent
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: Peeks

enum PeekContent: Equatable {
    case math(image: NSImage?, error: String?, display: Bool)
    case reference(key: String, item: OutlineItem?, snippet: String?, math: NSImage?)
    case citation(BibEntry?, key: String)
    case image(NSImage?, path: String)
    case command(name: String, detail: String?, package: String?, glyph: String?)
    case file(path: String, exists: Bool, firstLines: String?)
}

struct PeekCard: View {
    let content: PeekContent
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch content {
            case .math(let image, let error, _):
                mathBody(image: image, error: error)
            case .reference(let key, let item, let snippet, let math):
                header(symbol: "tag.fill", title: key, subtitle: item.map { "\(kindName($0.kind)) · \(($0.file as NSString).lastPathComponent):\($0.line)" } ?? "No \\label with this name")
                if let item, item.kind != .label { Text(item.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color(theme.text)) }
                if let math { tinted(math).frame(maxWidth: 460) }
                else if let snippet { Text(snippet).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(theme.secondary)).lineLimit(4) }
                footer(item == nil ? "Labels are suggested as you type \\ref{" : "⌘-click to jump")
            case .citation(let entry, let key):
                if let e = entry {
                    header(symbol: "quote.opening", title: e.title.isEmpty ? key : e.title, subtitle: [e.authorsShort, e.year].filter { !$0.isEmpty }.joined(separator: " · "))
                    if !e.venue.isEmpty { Text(e.venue).font(.system(size: 11.5).italic()).foregroundStyle(Color(theme.secondary)) }
                    HStack(spacing: 6) {
                        Text("@\(e.type)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(theme.environment))
                        Text(key).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(theme.reference))
                        Spacer()
                        if let doi = e.fields["doi"] { Text("doi:\(doi)").font(.system(size: 10.5)).foregroundStyle(Color(theme.secondary)).lineLimit(1) }
                    }
                    footer("⌘-click to open in \((e.file as NSString).lastPathComponent)")
                } else {
                    header(symbol: "questionmark.circle", title: key, subtitle: "Not in any .bib file")
                    footer("Add it from the Citations panel (DOI, arXiv or title search)")
                }
            case .image(let image, let path):
                header(symbol: "photo", title: (path as NSString).lastPathComponent, subtitle: image.map { "\(Int($0.size.width)) × \(Int($0.size.height))" } ?? "File not found")
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 280, maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            case .command(let name, let detail, let package, let glyph):
                HStack(spacing: 10) {
                    if let glyph { Text(glyph).font(.system(size: 26, design: .serif)).foregroundStyle(Color(theme.text)).frame(minWidth: 30) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\\" + name).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Color(theme.command))
                        if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Color(theme.text)) }
                    }
                }
                if let package { footer("From the \(package) package") }
            case .file(let path, let exists, let lines):
                header(symbol: exists ? "doc.text" : "doc.badge.ellipsis", title: path, subtitle: exists ? "⌘-click to open" : "File doesn't exist yet · ⌘-click to create it")
                if let lines { Text(lines).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(theme.secondary)).lineLimit(6) }
            }
        }
        .padding(12)
        .frame(minWidth: 180, maxWidth: 480, alignment: .leading)
        .background(Color(theme.surface), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .glassEdge(cornerRadius: 12)
        .shadow(color: .black.opacity(theme.isDark ? 0.5 : 0.15), radius: 18, y: 8)
        .shadow(color: accent.opacity(theme.isDark ? 0.07 : 0.06), radius: 24)
        .padding(20)
        .fixedSize()
    }

    @ViewBuilder func mathBody(image: NSImage?, error: String?) -> some View {
        if let image {
            tinted(image).frame(maxWidth: 520)
        } else if let error {
            Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(Color(theme.warning))
        } else {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Rendering…").font(.system(size: 11.5)).foregroundStyle(Color(theme.secondary)) }
        }
        if let caption { footer(caption) }
    }

    func tinted(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .renderingMode(.template)
            .interpolation(.high)
            .foregroundStyle(Color(theme.text))
            .frame(width: min(image.size.width, 520), height: min(image.size.height, 520) * (min(image.size.width, 520) / max(image.size.width, 1)))
    }

    func header(symbol: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(accent).frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(theme.text)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Color(theme.secondary))
            }
        }
    }

    func footer(_ s: String) -> some View {
        Text(s).font(.system(size: 10.5)).foregroundStyle(Color(theme.secondary).opacity(0.85))
    }

    func kindName(_ k: OutlineItem.Kind) -> String {
        switch k {
        case .figure: "Figure"
        case .table: "Table"
        case .label: "Label"
        case .frame: "Slide"
        default: k.rawValue.capitalized
        }
    }
}

// MARK: PDF → template image

enum MathImage {
    /// Renders the first page of a snippet PDF to a template image (alpha = ink), scaled for Retina.
    static func make(from data: Data, scale: CGFloat = 1.55, trim: Bool = false) -> NSImage? {
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return nil }
        let box = page.bounds(for: .cropBox)
        // Render now, while the document is alive (a lazy drawing handler would outlive it).
        let px = (w: Int((box.width * scale * 2).rounded(.up)), h: Int((box.height * scale * 2).rounded(.up)))
        guard px.w > 0, px.h > 0, let ctx = CGContext(data: nil, width: px.w, height: px.h, bitsPerComponent: 8, bytesPerRow: 0,
                                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale * 2, y: scale * 2)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .cropBox, to: ctx)
        guard var cg = ctx.makeImage() else { return nil }
        if trim, let cropped = trimmed(cg, context: ctx) { cg = cropped }
        let image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
        image.isTemplate = true
        return image
    }

    /// Crops transparent margins (keeping a hair of padding), so a minipage-wide render shrinks to its ink.
    private static func trimmed(_ cg: CGImage, context ctx: CGContext) -> CGImage? {
        guard let data = ctx.data else { return nil }
        let w = cg.width, h = cg.height, row = ctx.bytesPerRow
        let p = data.bindMemory(to: UInt8.self, capacity: row * h)
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            let base = y * row
            for x in 0..<w where p[base + x * 4 + 3] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let pad = 3
        let r = CGRect(x: max(0, minX - pad), y: max(0, minY - pad), width: min(w, maxX + pad + 1) - max(0, minX - pad), height: min(h, maxY + pad + 1) - max(0, minY - pad))
        return cg.cropping(to: r)
    }
}
