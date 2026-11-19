import AppKit
import LigatureCore

/// Callbacks from the text view to its coordinator.
@MainActor protocol LaTeXTextViewDelegate: AnyObject {
    func textViewHover(_ tv: LaTeXTextView, at index: Int?, pointInView: NSPoint, force: Bool)
    func textViewCommandClick(_ tv: LaTeXTextView, at index: Int) -> Bool
    func textViewDropImages(_ tv: LaTeXTextView, urls: [URL], at index: Int)
    func textViewPasteImage(_ tv: LaTeXTextView, data: Data, type: String)
    func textViewPasteTable(_ tv: LaTeXTextView, text: String) -> Bool
    func textViewCompletionKey(_ tv: LaTeXTextView, _ key: LaTeXTextView.CompletionKey) -> Bool
    func textViewDidType(_ tv: LaTeXTextView)
}

/// The editor surface: TextKit 1 text view with LaTeX-aware typing, snippet tab stops, a current-line highlight,
/// inline issue annotations, hover/force-click peeks and image drops.
final class LaTeXTextView: NSTextView {
    enum CompletionKey { case up, down, accept, tab, dismiss }

    weak var latexDelegate: LaTeXTextViewDelegate?
    var issues: [CompileIssue] = [] { didSet { needsDisplay = true } }
    var kind: TextDocument.Kind = .tex

    // Snippet tab stops (absolute ranges, ordered by visit order).
    private(set) var snippetStops: [NSRange] = []
    private var hoverIndex: Int?
    private var lastPressureStage = 0
    private var commandHoverRange: NSRange?

    // MARK: Setup

    static func make(storage: NSTextStorage) -> LaTeXTextView {
        let lm = NSLayoutManager()
        lm.allowsNonContiguousLayout = true
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 4
        lm.addTextContainer(container)
        storage.addLayoutManager(lm)
        let tv = LaTeXTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        tv.configure()
        return tv
    }

    private func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        smartInsertDeleteEnabled = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainerInset = NSSize(width: 14, height: 18)
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        wantsLayer = true
        applyTheme()
    }

    @MainActor func applyTheme() {
        let t = ThemeManager.shared.theme
        let prefs = Preferences.shared
        backgroundColor = t.editor
        drawsBackground = true
        insertionPointColor = ThemeManager.shared.accentNS
        selectedTextAttributes = [.backgroundColor: t.selection]
        typingAttributes = Highlighter.baseAttributes()
        if prefs.visualMode, kind == .tex {
            let size = prefs.editorFontSize + 2.5
            let serif = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) }
            if let serif { typingAttributes[.font] = serif }
        }
        defaultParagraphStyle = Highlighter.baseAttributes()[.paragraphStyle] as? NSParagraphStyle
        isContinuousSpellCheckingEnabled = prefs.spellCheck
        textContainer?.widthTracksTextView = false
        if !prefs.wrapLines {
            textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            isHorizontallyResizable = true
        } else {
            isHorizontallyResizable = false
            updateContainerWidth()
        }
        needsDisplay = true
    }

    // MARK: Gutter

    /// Width of the line-number gutter floating over the left edge; text starts after it.
    /// Visual mode: text set in a centred column of comfortable reading width.
    var visualColumn = false {
        didSet {
            guard visualColumn != oldValue else { return }
            updateContainerWidth()
            invalidateTextContainerOrigin()
            needsDisplay = true
        }
    }

    /// Horizontal space before the text (and after it, when wrapping).
    var horizontalInset: CGFloat {
        visualColumn ? max(32, (bounds.width - gutterInset - 760) / 2) : textContainerInset.width
    }

    var gutterInset: CGFloat = 0 {
        didSet {
            guard abs(gutterInset - oldValue) > 0.5 else { return }
            updateContainerWidth()
            invalidateTextContainerOrigin()
            needsDisplay = true
        }
    }

    // Computed from the inset rather than super's value: AppKit caches the origin it reads back from this
    // property, so adding to super compounds on every invalidation.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: horizontalInset + gutterInset, y: textContainerInset.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        // The scroll view sizes us to its width minus the floating gutter; take the full width so the
        // current-line band reaches the edge.
        if !isHorizontallyResizable, let clip = enclosingScrollView?.contentView { size.width = max(size.width, clip.bounds.width) }
        super.setFrameSize(size)
        updateContainerWidth()
        if visualColumn { invalidateTextContainerOrigin() }
    }

    /// With wrapping on, the text column is the view width minus both insets and the gutter.
    func updateContainerWidth() {
        guard let tc = textContainer, !isHorizontallyResizable else { return }
        let w = max(60, frame.width - horizontalInset * 2 - gutterInset)
        if abs(tc.size.width - w) > 0.5 { tc.size = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude) }
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer else { return }
        let t = MainActor.assumeIsolated { ThemeManager.shared.theme }
        let ns = string as NSString
        let origin = textContainerOrigin

        // Lines with errors/warnings get a faint wash.
        for issue in issues where issue.line != nil && issue.severity != .badBox {
            guard let r = LaTeXText.range(ofLine: issue.line!, in: ns) else { continue }
            let g = lm.glyphRange(forCharacterRange: NSRange(location: r.location, length: max(r.length, 0)), actualCharacterRange: nil)
            var lineRect = lm.boundingRect(forGlyphRange: g.length > 0 ? g : NSRange(location: g.location, length: 0), in: tc)
            if g.length == 0, g.location < lm.numberOfGlyphs { lineRect = lm.lineFragmentRect(forGlyphAt: g.location, effectiveRange: nil) }
            lineRect.origin.x = 0
            lineRect.size.width = bounds.width
            lineRect.origin.y += origin.y
            guard lineRect.intersects(rect) else { continue }
            (issue.severity == .error ? t.error : t.warning).withAlphaComponent(t.isDark ? 0.09 : 0.06).setFill()
            lineRect.fill()
        }

        // Current line (only when nothing is selected).
        let sel = selectedRange()
        guard sel.length == 0, window?.firstResponder === self else { return }
        let lineRange = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        var rectLine: NSRect
        if ns.length == 0 || lm.numberOfGlyphs == 0 {
            rectLine = NSRect(x: 0, y: origin.y, width: bounds.width, height: (typingAttributes[.font] as? NSFont).map { lm.defaultLineHeight(for: $0) * Preferences.sharedLineSpacing } ?? 20)
        } else if sel.location >= ns.length && (ns.length == 0 || ns.character(at: ns.length - 1) == 10) {
            rectLine = lm.extraLineFragmentRect
            rectLine.origin.y += origin.y
        } else {
            let g = lm.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            rectLine = lm.boundingRect(forGlyphRange: g, in: tc)
            rectLine.origin.y += origin.y
        }
        rectLine.origin.x = 0
        rectLine.size.width = bounds.width
        if rectLine.intersects(rect) {
            t.currentLine.setFill()
            rectLine.fill()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let showInline = MainActor.assumeIsolated { Preferences.shared.inlineIssues }
        guard showInline, !issues.isEmpty, let lm = layoutManager, let tc = textContainer else { return }
        let t = MainActor.assumeIsolated { ThemeManager.shared.theme }
        let ns = string as NSString
        let font = NSFont.systemFont(ofSize: max(10, (MainActor.assumeIsolated { Preferences.shared.editorFontSize }) - 2), weight: .medium)
        var drawnLines = Set<Int>()
        for issue in issues where issue.severity != .badBox {
            guard let line = issue.line, !drawnLines.contains(line), let r = LaTeXText.range(ofLine: line, in: ns) else { continue }
            drawnLines.insert(line)
            let g = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            guard g.length > 0 else { continue }
            let lastGlyph = NSMaxRange(g) - 1
            var used = lm.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            used.origin.x += textContainerOrigin.x
            used.origin.y += textContainerOrigin.y
            guard used.intersects(dirtyRect.insetBy(dx: -400, dy: -2)) else { continue }
            let color = issue.severity == .error ? t.error : t.warning
            let advice = MainActor.assumeIsolated { ErrorAdvisor.advise(issue)?.title }
            let message = (advice ?? issue.message)
            let attr = NSAttributedString(string: message, attributes: [.font: font, .foregroundColor: color])
            let size = attr.size()
            let x = used.maxX + 18
            let available = bounds.width - x - 12
            guard available > 60 else { continue }
            let width = min(size.width, available - 16)
            let pill = NSRect(x: x, y: used.midY - size.height / 2 - 2, width: width + 16, height: size.height + 4)
            color.withAlphaComponent(t.isDark ? 0.16 : 0.1).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            attr.draw(with: NSRect(x: pill.minX + 8, y: pill.minY + 2, width: width, height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        _ = tc
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }

    /// A brief accent wash over a line, fading out. Used when jumping from the PDF, an issue, or the outline.
    func flash(range: NSRange) {
        guard let lm = layoutManager, let tc = textContainer, let layer else { return }
        let g = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var r = lm.boundingRect(forGlyphRange: g.length > 0 ? g : NSRange(location: g.location, length: 1), in: tc)
        r.origin.x = 0
        r.size.width = bounds.width
        r.origin.y += textContainerOrigin.y
        let flashLayer = CALayer()
        flashLayer.frame = r
        flashLayer.backgroundColor = MainActor.assumeIsolated { ThemeManager.shared.accentNS.withAlphaComponent(0.22).cgColor }
        flashLayer.cornerRadius = 3
        layer.addSublayer(flashLayer)
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1
        anim.toValue = 0
        anim.beginTime = CACurrentMediaTime() + 0.35
        anim.duration = 0.9
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        flashLayer.add(anim, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { flashLayer.removeFromSuperlayer() }
    }

    /// A strong, rounded accent mark over one word that pops in, holds, then fades.
    func flashWord(range: NSRange) {
        guard let lm = layoutManager, let tc = textContainer, let layer else { return }
        let g = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var r = lm.boundingRect(forGlyphRange: g, in: tc)
        r.origin.x += textContainerOrigin.x
        r.origin.y += textContainerOrigin.y
        r = r.insetBy(dx: -3, dy: -1)
        let accent = MainActor.assumeIsolated { ThemeManager.shared.accentNS }
        let mark = CALayer()
        mark.frame = r
        mark.cornerRadius = 4
        mark.backgroundColor = accent.withAlphaComponent(0.38).cgColor
        mark.borderColor = accent.withAlphaComponent(0.95).cgColor
        mark.borderWidth = 1.5
        mark.shadowColor = accent.cgColor
        mark.shadowOpacity = 0.7
        mark.shadowRadius = 6
        mark.shadowOffset = .zero
        layer.addSublayer(mark)
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 1.35
        pop.toValue = 1
        pop.damping = 11
        pop.initialVelocity = 6
        pop.duration = pop.settlingDuration
        mark.add(pop, forKey: "pop")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 1.8
        fade.duration = 0.7
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        mark.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { mark.removeFromSuperlayer() }
    }

    // MARK: Typing

    private var autoPair: Bool { MainActor.assumeIsolated { Preferences.shared.autoPair } }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let s = (string as? String) ?? (string as? NSAttributedString)?.string, kind == .tex, autoPair, s.count == 1 else {
            super.insertText(string, replacementRange: replacementRange)
            latexDelegate?.textViewDidType(self)
            return
        }
        let ns = self.string as NSString
        let sel = replacementRange.location != NSNotFound ? replacementRange : selectedRange()
        let next: unichar? = NSMaxRange(sel) < ns.length ? ns.character(at: NSMaxRange(sel)) : nil
        let prev: unichar? = sel.location > 0 ? ns.character(at: sel.location - 1) : nil
        let pairs: [String: String] = ["{": "}", "[": "]", "(": ")", "$": "$"]
        let escaped = prev == 92  // backslash

        // Wrap a selection.
        if sel.length > 0, let close = pairs[s], !escaped {
            let inner = ns.substring(with: sel)
            super.insertText(s + inner + close, replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location + 1, length: (inner as NSString).length))
            latexDelegate?.textViewDidType(self)
            return
        }
        // Step over a closing character we inserted.
        if sel.length == 0, let n = next, ["}", "]", ")", "$"].contains(s), n == (s as NSString).character(at: 0), !escaped {
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
            latexDelegate?.textViewDidType(self)
            return
        }
        // Insert a pair when the next character is whitespace, end, or a closer.
        if let close = pairs[s], !escaped, sel.length == 0 {
            let nextOK = next == nil || [32, 10, 9, 125, 93, 41, 44, 46, 36].contains(next!)
            let dollarOK = s != "$" || (prev == nil || prev == 32 || prev == 10 || prev == 40 || prev == 9)
            if nextOK && dollarOK {
                super.insertText(s + close, replacementRange: sel)
                setSelectedRange(NSRange(location: sel.location + 1, length: 0))
                latexDelegate?.textViewDidType(self)
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
        latexDelegate?.textViewDidType(self)
    }

    override func deleteBackward(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        if kind == .tex, autoPair, sel.length == 0, sel.location > 0, sel.location < ns.length {
            let a = ns.character(at: sel.location - 1), b = ns.character(at: sel.location)
            let pairs: [unichar: unichar] = [123: 125, 91: 93, 40: 41, 36: 36]
            if pairs[a] == b, !(sel.location >= 2 && ns.character(at: sel.location - 2) == 92) {
                insertText("", replacementRange: NSRange(location: sel.location - 1, length: 2))
                return
            }
        }
        super.deleteBackward(sender)
        latexDelegate?.textViewDidType(self)
    }

    override func insertNewline(_ sender: Any?) {
        if latexDelegate?.textViewCompletionKey(self, .accept) == true { return }
        guard kind == .tex else { super.insertNewline(sender); return }
        let ns = string as NSString
        let sel = selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let before = ns.substring(with: NSRange(location: lineRange.location, length: sel.location - lineRange.location))
        let indent = String(before.prefix { $0 == " " || $0 == "\t" })
        let unit = "  "

        // \begin{env}| → newline, indented body, \end{env}
        if let m = before.range(of: #"\\begin\{([^}]+)\}(\[[^\]]*\]|\{[^}]*\})*\s*$"#, options: .regularExpression) {
            let env = String(before[m]).replacingOccurrences(of: #"^\\begin\{([^}]+)\}.*$"#, with: "$1", options: .regularExpression)
            let rest = ns.substring(from: sel.location)
            let alreadyClosed = closesSoon(env: env, in: rest)
            let isList = ["itemize", "enumerate", "description"].contains(env)
            let bodyLine = indent + unit + (isList ? "\\item " : "")
            if alreadyClosed {
                insertText("\n" + bodyLine, replacementRange: sel)
            } else {
                insertText("\n" + bodyLine + "\n" + indent + "\\end{\(env)}", replacementRange: sel)
                setSelectedRange(NSRange(location: sel.location + 1 + (bodyLine as NSString).length, length: 0))
            }
            latexDelegate?.textViewDidType(self)
            return
        }
        // List continuation: "\item text" → new "\item "; an empty "\item " ends the list item.
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\\item") {
            if trimmed == "\\item" {
                insertText(indent, replacementRange: NSRange(location: lineRange.location, length: sel.location - lineRange.location))
                return
            }
            insertText("\n" + indent + "\\item ", replacementRange: sel)
            latexDelegate?.textViewDidType(self)
            return
        }
        insertText("\n" + indent, replacementRange: sel)
        latexDelegate?.textViewDidType(self)
    }

    /// True if `\end{env}` closes this environment before another `\begin{env}` opens (so we don't add a second).
    private func closesSoon(env: String, in rest: String) -> Bool {
        var depth = 0
        let re = try! NSRegularExpression(pattern: #"\\(begin|end)\{"# + NSRegularExpression.escapedPattern(for: env) + #"\}"#)
        let ns = rest as NSString
        for m in re.matches(in: rest, range: NSRange(location: 0, length: min(ns.length, 20000))) {
            if ns.substring(with: m.range(at: 1)) == "begin" { depth += 1 } else {
                if depth == 0 { return true }
                depth -= 1
            }
        }
        return false
    }

    override func insertTab(_ sender: Any?) {
        if latexDelegate?.textViewCompletionKey(self, .tab) == true { return }
        if nextSnippetStop() { return }
        let sel = selectedRange()
        if sel.length > 0 && (string as NSString).substring(with: sel).contains("\n") { shiftLines(right: true); return }
        insertText("  ", replacementRange: sel)
    }

    override func insertBacktab(_ sender: Any?) { shiftLines(right: false) }

    override func moveUp(_ sender: Any?) {
        if latexDelegate?.textViewCompletionKey(self, .up) == true { return }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if latexDelegate?.textViewCompletionKey(self, .down) == true { return }
        super.moveDown(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if latexDelegate?.textViewCompletionKey(self, .dismiss) == true { return }
        if !snippetStops.isEmpty { snippetStops = []; return }
        super.cancelOperation(sender)
    }

    // MARK: Line operations

    func shiftLines(right: Bool) {
        let ns = string as NSString
        let lines = ns.lineRange(for: selectedRange())
        let text = ns.substring(with: lines)
        var out: [String] = []
        for l in text.components(separatedBy: "\n") {
            if l.isEmpty { out.append(l); continue }
            if right { out.append("  " + l) }
            else if l.hasPrefix("  ") { out.append(String(l.dropFirst(2))) }
            else if l.hasPrefix("\t") || l.hasPrefix(" ") { out.append(String(l.dropFirst(1))) }
            else { out.append(l) }
        }
        let replacement = out.joined(separator: "\n")
        insertText(replacement, replacementRange: lines)
        setSelectedRange(NSRange(location: lines.location, length: (replacement as NSString).length - (text.hasSuffix("\n") ? 1 : 0)))
    }

    @objc func toggleComment(_ sender: Any?) {
        let ns = string as NSString
        let lines = ns.lineRange(for: selectedRange())
        let text = ns.substring(with: lines)
        let parts = text.components(separatedBy: "\n")
        let nonEmpty = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("%") }
        let out = parts.map { l -> String in
            if l.trimmingCharacters(in: .whitespaces).isEmpty { return l }
            if allCommented {
                guard let r = l.range(of: "%") else { return l }
                var s = l
                s.removeSubrange(r)
                if let sp = s.range(of: " ", range: r.lowerBound..<s.endIndex), sp.lowerBound == r.lowerBound { s.removeSubrange(sp) }
                return s
            }
            let indent = l.prefix { $0 == " " || $0 == "\t" }
            return indent + "% " + l.dropFirst(indent.count)
        }.joined(separator: "\n")
        insertText(out, replacementRange: lines)
        setSelectedRange(NSRange(location: lines.location, length: (out as NSString).length - (text.hasSuffix("\n") ? 1 : 0)))
    }

    func wrap(prefix: String, suffix: String) {
        let sel = selectedRange()
        let inner = (string as NSString).substring(with: sel)
        insertText(prefix + inner + suffix, replacementRange: sel)
        if sel.length == 0 { setSelectedRange(NSRange(location: sel.location + (prefix as NSString).length, length: 0)) }
        else { setSelectedRange(NSRange(location: sel.location + (prefix as NSString).length, length: (inner as NSString).length)) }
    }

    // MARK: Snippets

    /// Inserts a snippet at the selection (or `replacing` range). `$1…$9` / `${1:default}` are tab stops, `$0` the end.
    func insertSnippet(_ snippet: String, replacing range: NSRange? = nil) {
        let target = range ?? selectedRange()
        let ns = string as NSString
        let lineStart = ns.lineRange(for: NSRange(location: target.location, length: 0)).location
        let indent = String(ns.substring(with: NSRange(location: lineStart, length: target.location - lineStart)).prefix { $0 == " " || $0 == "\t" })
        let selected = target.length > 0 ? ns.substring(with: target) : ""
        let expanded = snippet.replacingOccurrences(of: "\t", with: "  ").replacingOccurrences(of: "\n", with: "\n" + indent)
        let parsed = Self.parseSnippet(expanded, selectedText: selected)
        insertText(parsed.text, replacementRange: target)
        let base = target.location
        snippetStops = parsed.stops.map { NSRange(location: base + $0.location, length: $0.length) }
        if !nextSnippetStop() { setSelectedRange(NSRange(location: base + (parsed.text as NSString).length, length: 0)) }
    }

    /// Returns the plain text and stop ranges (in visit order: 1, 2, …, then 0).
    static func parseSnippet(_ s: String, selectedText: String) -> (text: String, stops: [NSRange]) {
        var out = ""
        var stops: [(Int, NSRange)] = []
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "$", s.index(after: i) < s.endIndex {
                let n = s[s.index(after: i)]
                if n.isNumber {
                    let num = Int(String(n))!
                    let loc = (out as NSString).length
                    var fill = ""
                    if num == 1 && !selectedText.isEmpty { fill = selectedText }
                    out += fill
                    if !stops.contains(where: { $0.0 == num }) { stops.append((num, NSRange(location: loc, length: (fill as NSString).length))) }
                    i = s.index(i, offsetBy: 2)
                    continue
                }
                if n == "{", let close = s[i...].firstIndex(of: "}") {
                    let inner = s[s.index(i, offsetBy: 2)..<close]
                    let parts = inner.split(separator: ":", maxSplits: 1)
                    if let num = Int(parts.first ?? "") {
                        let fill = parts.count > 1 ? String(parts[1]) : ""
                        let loc = (out as NSString).length
                        out += fill
                        stops.append((num, NSRange(location: loc, length: (fill as NSString).length)))
                        i = s.index(after: close)
                        continue
                    }
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        let ordered = stops.sorted { a, b in
            if a.0 == 0 { return false }
            if b.0 == 0 { return true }
            return a.0 < b.0
        }.map(\.1)
        return (out, ordered)
    }

    @discardableResult
    func nextSnippetStop() -> Bool {
        guard !snippetStops.isEmpty else { return false }
        let stop = snippetStops.removeFirst()
        guard NSMaxRange(stop) <= (string as NSString).length else { snippetStops = []; return false }
        setSelectedRange(stop)
        scrollRangeToVisible(stop)
        return true
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let ok = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if ok, !snippetStops.isEmpty, let rep = replacementString {
            let delta = (rep as NSString).length - affectedCharRange.length
            snippetStops = snippetStops.map { r in
                if r.location >= NSMaxRange(affectedCharRange) { return NSRange(location: r.location + delta, length: r.length) }
                if affectedCharRange.location >= r.location && affectedCharRange.location <= NSMaxRange(r) {
                    return NSRange(location: r.location, length: max(0, r.length + delta))
                }
                return r
            }
        }
        return ok
    }

    // MARK: Hover, ⌘-click and force click

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["ligature"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: ["ligature": true]))
    }

    func characterIndex(atViewPoint p: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer, lm.numberOfGlyphs > 0 else { return nil }
        let cp = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let g = lm.glyphIndex(for: cp, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        let glyphRect = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(cp) else { return nil }
        return lm.characterIndexForGlyph(at: g)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let idx = characterIndex(atViewPoint: p)
        updateCommandHover(index: idx, commandDown: event.modifierFlags.contains(.command))
        if idx != hoverIndex {
            hoverIndex = idx
            latexDelegate?.textViewHover(self, at: idx, pointInView: p, force: false)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverIndex = nil
        updateCommandHover(index: nil, commandDown: false)
        latexDelegate?.textViewHover(self, at: nil, pointInView: .zero, force: false)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateCommandHover(index: hoverIndex, commandDown: event.modifierFlags.contains(.command))
    }

    /// With ⌘ held, references look like links (underline + pointing hand), as in Xcode.
    private func updateCommandHover(index: Int?, commandDown: Bool) {
        guard let lm = layoutManager else { return }
        var newRange: NSRange?
        if commandDown, let index, index < (string as NSString).length {
            var eff = NSRange()
            if textStorage?.attribute(Highlighter.refKey, at: index, effectiveRange: &eff) != nil { newRange = eff }
        }
        if newRange != commandHoverRange {
            if let old = commandHoverRange, NSMaxRange(old) <= (string as NSString).length { lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: old) }
            if let r = newRange {
                lm.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: r)
                NSCursor.pointingHand.set()
            } else {
                NSCursor.iBeam.set()
            }
            commandHoverRange = newRange
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.clickCount == 1 {
            let p = convert(event.locationInWindow, from: nil)
            if let idx = characterIndex(atViewPoint: p), latexDelegate?.textViewCommandClick(self, at: idx) == true { return }
        }
        latexDelegate?.textViewHover(self, at: nil, pointInView: .zero, force: false)
        super.mouseDown(with: event)
    }

    override func pressureChange(with event: NSEvent) {
        super.pressureChange(with: event)
        if event.stage == 2 && lastPressureStage < 2 {
            let p = convert(event.locationInWindow, from: nil)
            if let idx = characterIndex(atViewPoint: p) {
                MainActor.assumeIsolated { Haptics.play(.forceClick) }
                latexDelegate?.textViewHover(self, at: idx, pointInView: p, force: true)
            }
        }
        lastPressureStage = event.stage
    }

    override func quickLook(with event: NSEvent) {
        // Force click is handled by pressureChange (peek); keep the system lookup for plain words.
        let p = convert(event.locationInWindow, from: nil)
        if let idx = characterIndex(atViewPoint: p), LaTeXText.token(at: idx, in: string as NSString) != nil || textStorage?.attribute(Highlighter.refKey, at: idx, effectiveRange: nil) != nil {
            return
        }
        super.quickLook(with: event)
    }

    // MARK: Drag & drop, paste

    private func imageURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { ["png", "jpg", "jpeg", "pdf", "eps", "gif", "tiff", "heic", "svg"].contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !imageURLs(sender).isEmpty { return .copy }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = imageURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        let p = convert(sender.draggingLocation, from: nil)
        let idx = characterIndexForInsertion(at: p)
        latexDelegate?.textViewDropImages(self, urls: urls, at: idx)
        return true
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let s = pb.string(forType: .string), s.contains("\t"), s.contains("\n"), latexDelegate?.textViewPasteTable(self, text: s) == true { return }
        if pb.string(forType: .string) == nil {
            if let png = pb.data(forType: .png) { latexDelegate?.textViewPasteImage(self, data: png, type: "png"); return }
            if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                latexDelegate?.textViewPasteImage(self, data: png, type: "png"); return
            }
        }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if let s = NSPasteboard.general.string(forType: .string) { insertText(s, replacementRange: selectedRange()) }
    }
}

extension Preferences {
    @MainActor static var sharedLineSpacing: CGFloat { CGFloat(shared.lineSpacing) }
}
