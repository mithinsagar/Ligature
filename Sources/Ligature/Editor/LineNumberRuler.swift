import AppKit
import LigatureCore

/// Line numbers in the gutter, with the caret's line emphasised and coloured dots for lines that have issues.
/// Clicking a number selects the line; hovering shows a soft highlight.
final class LineNumberRuler: NSRulerView {
    weak var textView: LaTeXTextView?
    var issueLines: [Int: CompileIssue.Severity] = [:] { didSet { needsDisplay = true } }
    private var hoverLine: Int?
    private var lineStarts: [Int] = [0]
    private var cachedTextLength = -1
    /// Called when the gutter's width changes, so the scroll view can keep text clear of it.
    var onThicknessChange: ((CGFloat) -> Void)?
    /// Foldable regions by the line they start on, whether each is folded, and what clicking a chevron does.
    var foldRegions: [Int: NSRange] = [:] { didSet { needsDisplay = true } }
    var isFolded: ((NSRange) -> Bool)?
    var onToggleFold: ((NSRange) -> Void)?
    private var hoveringGutter = false
    private static let chevronWidth: CGFloat = 14

    init(textView: LaTeXTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSTextView.didChangeSelectionNotification, object: textView)
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func textChanged() { cachedTextLength = -1; updateThickness(); needsDisplay = true }
    @objc private func redraw() { needsDisplay = true }

    override var isFlipped: Bool { true }

    func invalidate() { cachedTextLength = -1; updateThickness(); needsDisplay = true }

    private func rebuildLineStarts() {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        guard ns.length != cachedTextLength else { return }
        var starts = [0]
        starts.reserveCapacity(ns.length / 30)
        let len = ns.length
        let buf = UnsafeMutablePointer<unichar>.allocate(capacity: 8192)
        defer { buf.deallocate() }
        var i = 0
        while i < len {
            let n = min(8192, len - i)
            ns.getCharacters(buf, range: NSRange(location: i, length: n))
            for k in 0..<n where buf[k] == 10 { starts.append(i + k + 1) }
            i += n
        }
        lineStarts = starts
        cachedTextLength = len
    }

    private func updateThickness() {
        rebuildLineStarts()
        let digits = max(3, String(lineStarts.count).count)
        let w = CGFloat(digits) * 8 + 26 + Self.chevronWidth
        if abs(ruleThickness - w) > 0.5 {
            ruleThickness = w
            onThicknessChange?(w)
        }
    }

    /// 1-based line for a character index (binary search over line starts).
    func line(forCharacter idx: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= idx { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        rebuildLineStarts()
        let t = MainActor.assumeIsolated { ThemeManager.shared.theme }
        let accent = MainActor.assumeIsolated { ThemeManager.shared.accentNS }
        t.gutter.setFill()
        bounds.fill()

        let fontSize = max(9.5, (MainActor.assumeIsolated { Preferences.shared.editorFontSize }) - 2.5)
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let boldFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        let caretLine = line(forCharacter: sel.location)
        let selEndLine = line(forCharacter: NSMaxRange(sel))
        let relY = convert(NSPoint.zero, from: tv).y
        let originY = tv.textContainerOrigin.y

        let textFont = Typo.editorFont(size: MainActor.assumeIsolated { Preferences.shared.editorFontSize })
        let lineHeight = lm.defaultLineHeight(for: textFont)
        let spacing = MainActor.assumeIsolated { Preferences.sharedLineSpacing }
        var lineNo = line(forCharacter: chars.location)
        while lineNo <= lineStarts.count {
            let charIndex = lineStarts[lineNo - 1]
            if charIndex > NSMaxRange(chars) { break }
            // Lines inside a fold have no place of their own.
            if charIndex < ns.length, let ts = tv.textStorage, ts.attribute(Highlighter.widgetKey, at: charIndex, effectiveRange: nil) != nil,
               ts.attribute(Highlighter.anchorKey, at: charIndex, effectiveRange: nil) == nil {
                lineNo += 1
                continue
            }
            var fragRect: NSRect
            if charIndex < ns.length {
                fragRect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: charIndex), effectiveRange: nil)
            } else {
                fragRect = lm.extraLineFragmentRect
                if fragRect.height == 0 {
                    if ns.length > 0 { break }
                    fragRect = NSRect(x: 0, y: 0, width: 10, height: lineHeight * spacing)
                }
            }
            let y = fragRect.minY + originY + relY
            if y > rect.maxY { break }
            let isCaret = lineNo >= caretLine && lineNo <= selEndLine
            if lineNo == hoverLine {
                t.text.withAlphaComponent(0.05).setFill()
                NSBezierPath(roundedRect: NSRect(x: 4, y: y, width: bounds.width - 8, height: lineHeight * spacing), xRadius: 4, yRadius: 4).fill()
            }
            let label = NSAttributedString(string: "\(lineNo)", attributes: [
                .font: isCaret ? boldFont : font,
                .foregroundColor: isCaret ? t.text.withAlphaComponent(0.85) : t.gutterText,
            ])
            let size = label.size()
            let baselineOffset = max(0, (lineHeight * spacing - size.height) / 2)
            label.draw(at: NSPoint(x: bounds.width - size.width - 12 - Self.chevronWidth, y: y + baselineOffset))
            if let region = foldRegions[lineNo] {
                let folded = isFolded?(region) ?? false
                if folded || hoveringGutter {
                    let name = folded ? "chevron.right" : "chevron.down"
                    if let img = NSImage(systemSymbolName: name, accessibilityDescription: folded ? "Unfold" : "Fold")?.withSymbolConfiguration(.init(pointSize: fontSize - 2.5, weight: .bold)) {
                        let tinted = VisualMath.tint(img, folded ? accent : (lineNo == hoverLine ? t.text.withAlphaComponent(0.8) : t.gutterText))
                        let r = NSRect(x: bounds.width - Self.chevronWidth - 2 + (Self.chevronWidth - img.size.width) / 2, y: y + (lineHeight * spacing - img.size.height) / 2, width: img.size.width, height: img.size.height)
                        tinted.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    }
                }
            }

            if let sev = issueLines[lineNo] {
                let color = sev == .error ? t.error : (sev == .warning ? t.warning : t.secondary)
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 6, y: y + baselineOffset + size.height / 2 - 3, width: 6, height: 6)).fill()
            } else if isCaret && sel.length == 0 {
                accent.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: NSRect(x: 2, y: y + 3, width: 2.5, height: lineHeight * spacing - 6), xRadius: 1.25, yRadius: 1.25).fill()
            }
            lineNo += 1
        }
        // Hairline separating gutter and text.
        t.hairline.withAlphaComponent(0.5).setFill()
        NSRect(x: bounds.width - 0.5, y: bounds.minY, width: 0.5, height: bounds.height).intersection(rect).fill()
    }

    // MARK: Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func lineAt(_ event: NSEvent) -> Int? {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        let p = tv.convert(event.locationInWindow, from: nil)
        let cp = NSPoint(x: 10, y: p.y - tv.textContainerOrigin.y)
        guard lm.numberOfGlyphs > 0 else { return 1 }
        let g = lm.glyphIndex(for: cp, in: tc)
        return line(forCharacter: lm.characterIndexForGlyph(at: g))
    }

    override func mouseMoved(with event: NSEvent) {
        let l = lineAt(event)
        if l != hoverLine {
            hoverLine = l
            needsDisplay = true
        }
    }

    override func mouseEntered(with event: NSEvent) { hoveringGutter = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hoverLine = nil; hoveringGutter = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard let tv = textView, let l = lineAt(event), l - 1 < lineStarts.count else { return }
        // The chevron column folds and unfolds.
        let x = convert(event.locationInWindow, from: nil).x
        if x > bounds.width - Self.chevronWidth - 4, let region = foldRegions[l] {
            onToggleFold?(region)
            return
        }
        let start = lineStarts[l - 1]
        let end = l < lineStarts.count ? lineStarts[l] : (tv.string as NSString).length
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: start, length: end - start))
    }
}
