import AppKit
import LigatureCore

/// A rendered stand-in for a stretch of source in the editor: an equation, a figure, a table, the title block,
/// the collapsed preamble, or a folded region in the code view.
///
/// The source stays in the text storage untouched. Its first character carries `Highlighter.anchorKey` (this
/// object) and lays out as one blank glyph of the widget's size; the rest carry `Highlighter.widgetKey`, take no
/// space, and their line breaks stop breaking lines, so the whole stretch collapses into the widget.
final class WidgetRef: NSObject {
    enum Kind { case inlineMath, displayMath, figure, table, title, preamble, preambleShown, fold }

    struct Figure {
        var images: [NSImage?]
        var names: [String]
        var widthFraction: CGFloat
        var caption: String
        var label: String
    }

    enum Payload {
        case image(NSImage)
        case figure(Figure)
        case table(TableModel)
        case title(title: String, author: String, date: String)
        case text(String)
    }

    let kind: Kind
    let payload: Payload
    /// Inline widgets: the glyph's size. Blocks: width is ignored (they span the column), height is the line's.
    let size: NSSize

    init(kind: Kind, payload: Payload, size: NSSize) {
        self.kind = kind
        self.payload = payload
        self.size = size
    }

    var isBlock: Bool { [.displayMath, .figure, .table, .title, .preamble].contains(kind) }
    /// Clicking these does something other than placing the caret.
    var isButton: Bool { [.table, .preamble, .preambleShown, .fold].contains(kind) }

    // MARK: Sizing

    static let blockPadding: CGFloat = 10

    @MainActor static func figureHeight(_ f: Figure, columnWidth: CGFloat, captionFont: NSFont) -> CGFloat {
        let imgs = f.images
        let count = max(1, imgs.count)
        let total = min(columnWidth, max(120, columnWidth * f.widthFraction))
        let each = (total - CGFloat(count - 1) * 10) / CGFloat(count)
        let h = imgs.map { img -> CGFloat in
            guard let img, img.size.width > 0 else { return 90 }
            return min(340, each * img.size.height / img.size.width)
        }.max() ?? 90
        let cap = f.caption.isEmpty ? 0 : captionHeight(f, width: columnWidth - 40, font: captionFont) + 8
        return h + cap + blockPadding * 2 + 8
    }

    @MainActor static func captionHeight(_ f: Figure, width: CGFloat, font: NSFont) -> CGFloat {
        let s = NSAttributedString(string: captionString(f), attributes: [.font: font])
        return ceil(s.boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin]).height)
    }

    static func captionString(_ f: Figure) -> String { f.caption }

    @MainActor static func tableHeight(_ t: TableModel, font: NSFont) -> CGFloat {
        let rowH = ceil(font.ascender - font.descender + font.leading) + 10
        let cap = t.caption.isEmpty ? 0 : rowH + 4
        return CGFloat(t.rows) * rowH + cap + blockPadding * 2 + 6
    }

    // MARK: Drawing

    /// Draws into `rect` (the glyph's box; blocks get the full column). The text view is flipped.
    @MainActor func draw(in rect: NSRect, column: NSRect, theme t: Theme, accent: NSColor, fontSize: CGFloat, hovering: Bool) {
        switch (kind, payload) {
        case (.inlineMath, .image(let img)):
            img.draw(in: NSRect(x: rect.minX, y: rect.midY - img.size.height / 2, width: img.size.width, height: img.size.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case (.displayMath, .image(let img)):
            var w = img.size.width, h = img.size.height
            if w > column.width - 20 { let s = (column.width - 20) / w; w *= s; h *= s }
            img.draw(in: NSRect(x: column.midX - w / 2, y: rect.midY - h / 2, width: w, height: h),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case (.figure, .figure(let f)):
            drawFigure(f, rect: rect, column: column, t: t, fontSize: fontSize, hovering: hovering)
        case (.table, .table(let model)):
            drawTable(model, rect: rect, column: column, t: t, accent: accent, fontSize: fontSize, hovering: hovering)
        case (.title, .title(let title, let author, let date)):
            drawTitle(title, author, date, rect: rect, column: column, t: t, fontSize: fontSize)
        case (.preamble, .text(let summary)):
            drawPill(summary, symbol: "chevron.down", rect: NSRect(x: column.minX, y: rect.minY + 6, width: column.width, height: rect.height - 12), t: t, accent: accent, fontSize: fontSize, hovering: hovering, wide: true)
        case (.preambleShown, .text(let label)):
            drawPill(label, symbol: "chevron.up", rect: rect.insetBy(dx: 1, dy: 2), t: t, accent: accent, fontSize: fontSize, hovering: hovering, wide: false)
        case (.fold, .text(let label)):
            drawPill(label, symbol: nil, rect: rect.insetBy(dx: 2, dy: 2), t: t, accent: accent, fontSize: fontSize, hovering: hovering, wide: false)
        default:
            break
        }
    }

    private func card(_ r: NSRect, t: Theme, hovering: Bool) {
        let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        t.text.withAlphaComponent(hovering ? 0.05 : 0.025).setFill()
        path.fill()
        t.hairline.withAlphaComponent(hovering ? 1.4 : 0.9).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    @MainActor private func drawFigure(_ f: Figure, rect: NSRect, column: NSRect, t: Theme, fontSize: CGFloat, hovering: Bool) {
        let cardRect = NSRect(x: column.minX, y: rect.minY + 4, width: column.width, height: rect.height - 8)
        card(cardRect, t: t, hovering: hovering)
        let captionFont = Self.serif(fontSize - 1.5, italic: true)
        let count = max(1, f.images.count)
        let total = min(column.width, max(120, column.width * f.widthFraction))
        let each = (total - CGFloat(count - 1) * 10) / CGFloat(count)
        var x = column.midX - total / 2
        var maxH: CGFloat = 0
        let top = cardRect.minY + Self.blockPadding
        for (i, img) in f.images.enumerated() {
            if let img, img.size.width > 0 {
                let h = min(340, each * img.size.height / img.size.width)
                let w = h * img.size.width / img.size.height
                img.draw(in: NSRect(x: x + (each - w) / 2, y: top, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                maxH = max(maxH, h)
            } else {
                let r = NSRect(x: x, y: top, width: each, height: 90)
                t.text.withAlphaComponent(0.05).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
                let name = f.names[safe: i] ?? "image"
                let s = NSAttributedString(string: "Can't show \(name)", attributes: [.font: NSFont.systemFont(ofSize: fontSize - 3), .foregroundColor: t.secondary])
                let sz = s.size()
                s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
                maxH = max(maxH, 90)
            }
            x += each + 10
        }
        guard !f.caption.isEmpty else { return }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let cap = NSMutableAttributedString()
        if !f.label.isEmpty {
            cap.append(NSAttributedString(string: f.label + "  ", attributes: [.font: NSFont.monospacedSystemFont(ofSize: fontSize - 5, weight: .medium), .foregroundColor: t.reference, .paragraphStyle: para]))
        }
        cap.append(NSAttributedString(string: f.caption, attributes: [.font: captionFont, .foregroundColor: t.secondary, .paragraphStyle: para]))
        cap.draw(with: NSRect(x: column.minX + 20, y: top + maxH + 8, width: column.width - 40, height: 400), options: [.usesLineFragmentOrigin])
    }

    @MainActor private func drawTable(_ m: TableModel, rect: NSRect, column: NSRect, t: Theme, accent: NSColor, fontSize: CGFloat, hovering: Bool) {
        let cardRect = NSRect(x: column.minX, y: rect.minY + 3, width: column.width, height: rect.height - 6)
        card(cardRect, t: t, hovering: hovering)
        let font = Self.serif(fontSize - 1)
        let bold = Self.serif(fontSize - 1, bold: true)
        let rowH = ceil(font.ascender - font.descender + font.leading) + 10
        // Column widths from content, scaled down to fit.
        var widths = (0..<m.columns).map { c in
            (m.cells.map { NSAttributedString(string: Self.plain($0[safe: c] ?? ""), attributes: [.font: bold]).size().width }.max() ?? 20) + 24
        }
        let available = column.width - 40
        let sum = widths.reduce(0, +)
        if sum > available { widths = widths.map { $0 * available / sum } }
        let tableW = widths.reduce(0, +)
        let x0 = column.midX - tableW / 2
        var y = cardRect.minY + Self.blockPadding
        let rule = t.text.withAlphaComponent(0.55)
        func hline(_ y: CGFloat, _ weight: CGFloat) {
            rule.setFill()
            NSRect(x: x0, y: y, width: tableW, height: weight).fill()
        }
        if m.style != .minimal { hline(y, m.style == .booktabs ? 1.2 : 0.6) }
        for (r, row) in m.cells.enumerated() {
            var x = x0
            for c in 0..<m.columns {
                let w = widths[c]
                let para = NSMutableParagraphStyle()
                para.alignment = m.align[safe: c] == .r ? .right : (m.align[safe: c] == .c ? .center : .left)
                para.lineBreakMode = .byTruncatingTail
                let isHead = r == 0 && m.headerRow
                let s = NSAttributedString(string: Self.plain(row[safe: c] ?? ""), attributes: [.font: isHead ? bold : font, .foregroundColor: t.text, .paragraphStyle: para])
                s.draw(with: NSRect(x: x + 10, y: y + 5, width: w - 20, height: rowH - 8), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                if m.style == .grid, c > 0 { rule.setFill(); NSRect(x: x, y: y, width: 0.6, height: rowH).fill() }
                x += w
            }
            y += rowH
            if r == 0 && m.headerRow { hline(y, 0.6) } else if m.style == .grid && r < m.rows - 1 { hline(y, 0.6) }
        }
        if m.style != .minimal { hline(y, m.style == .booktabs ? 1.2 : 0.6) }
        if !m.caption.isEmpty {
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let cap = NSMutableAttributedString()
            if !m.label.isEmpty { cap.append(NSAttributedString(string: m.label + "  ", attributes: [.font: NSFont.monospacedSystemFont(ofSize: fontSize - 5, weight: .medium), .foregroundColor: t.reference, .paragraphStyle: para])) }
            cap.append(NSAttributedString(string: Self.plain(m.caption), attributes: [.font: Self.serif(fontSize - 1.5, italic: true), .foregroundColor: t.secondary, .paragraphStyle: para]))
            cap.draw(with: NSRect(x: column.minX + 20, y: y + 6, width: column.width - 40, height: rowH), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if hovering {
            let hint = NSAttributedString(string: "Click to edit table", attributes: [.font: NSFont.systemFont(ofSize: fontSize - 4, weight: .medium), .foregroundColor: accent])
            let sz = hint.size()
            hint.draw(at: NSPoint(x: cardRect.maxX - sz.width - 12, y: cardRect.minY + 6))
        }
    }

    @MainActor private func drawTitle(_ title: String, _ author: String, _ date: String, rect: NSRect, column: NSRect, t: Theme, fontSize: CGFloat) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 6
        let s = NSMutableAttributedString(string: title + "\n", attributes: [.font: Self.serif(fontSize * 1.75, bold: false), .foregroundColor: t.heading, .paragraphStyle: para])
        if !author.isEmpty { s.append(NSAttributedString(string: author + "\n", attributes: [.font: Self.serif(fontSize * 1.05), .foregroundColor: t.text, .paragraphStyle: para])) }
        if !date.isEmpty { s.append(NSAttributedString(string: date, attributes: [.font: Self.serif(fontSize * 0.95), .foregroundColor: t.secondary, .paragraphStyle: para])) }
        s.draw(with: NSRect(x: column.minX + 10, y: rect.minY + Self.blockPadding, width: column.width - 20, height: rect.height), options: [.usesLineFragmentOrigin])
    }

    @MainActor static func titleHeight(_ title: String, _ author: String, _ date: String, columnWidth: CGFloat, fontSize: CGFloat) -> CGFloat {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 6
        let s = NSMutableAttributedString(string: title + "\n", attributes: [.font: serif(fontSize * 1.75), .paragraphStyle: para])
        if !author.isEmpty { s.append(NSAttributedString(string: author + "\n", attributes: [.font: serif(fontSize * 1.05), .paragraphStyle: para])) }
        if !date.isEmpty { s.append(NSAttributedString(string: date, attributes: [.font: serif(fontSize * 0.95), .paragraphStyle: para])) }
        return ceil(s.boundingRect(with: NSSize(width: columnWidth - 20, height: 2000), options: [.usesLineFragmentOrigin]).height) + blockPadding * 2 + 8
    }

    @MainActor private func drawPill(_ text: String, symbol: String?, rect: NSRect, t: Theme, accent: NSColor, fontSize: CGFloat, hovering: Bool, wide: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: wide ? 9 : rect.height / 2, yRadius: wide ? 9 : rect.height / 2)
        (hovering ? accent.withAlphaComponent(0.14) : t.text.withAlphaComponent(0.06)).setFill()
        path.fill()
        if wide {
            t.hairline.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let font = NSFont.systemFont(ofSize: max(10, fontSize - (wide ? 3 : 3.5)), weight: .medium)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: hovering ? accent : t.secondary, .paragraphStyle: para])
        let sz = s.size()
        var x = wide ? rect.minX + 14 : rect.midX - sz.width / 2 - (symbol == nil ? 0 : 7)
        let room = wide ? rect.width - 50 : sz.width + 1
        s.draw(with: NSRect(x: x, y: rect.midY - sz.height / 2, width: room, height: sz.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        x += sz.width + 6
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: font.pointSize - 1, weight: .semibold)) {
            let tintedImg = VisualMath.tint(img, hovering ? accent : t.secondary)
            let ix = wide ? rect.maxX - img.size.width - 14 : x
            tintedImg.draw(in: NSRect(x: ix, y: rect.midY - img.size.height / 2, width: img.size.width, height: img.size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    static func pillWidth(_ text: String, fontSize: CGFloat, symbol: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: max(10, fontSize - 3.5), weight: .medium)
        return ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width) + (symbol ? 34 : 20)
    }

    // MARK: Helpers

    static func serif(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        var f = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? NSFont.systemFont(ofSize: size)
        if bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
        if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    static func plain(_ s: String) -> String { LaTeXText.plainText(s) }
}
