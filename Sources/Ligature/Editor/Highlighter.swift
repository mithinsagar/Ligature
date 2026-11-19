import AppKit
import LigatureCore

/// Regex-based LaTeX syntax colouring applied directly to a document's text storage.
///
/// Single-line constructs are recoloured immediately for the edited lines; multi-line math is handled by a full
/// pass that runs right away for small files and is debounced for big ones.
@MainActor
enum Highlighter {
    static let refKey = NSAttributedString.Key("ligature.ref")
    /// Visual mode: characters with this attribute take no space (LaTeX markup).
    nonisolated static let hiddenKey = NSAttributedString.Key("ligature.hidden")
    /// Visual mode: draw this string's glyph instead of the character (e.g. "•" for \item).
    nonisolated static let glyphKey = NSAttributedString.Key("ligature.glyph")
    /// Visual mode: the line where raw markup is shown (the caret's line), set by the editor.
    static var revealRange: NSRange?

    static func baseAttributes() -> [NSAttributedString.Key: Any] {
        let prefs = Preferences.shared
        let t = ThemeManager.shared.theme
        let font = Typo.editorFont(size: prefs.editorFontSize)
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = prefs.lineSpacing
        para.lineBreakMode = prefs.wrapLines ? .byWordWrapping : .byClipping
        return [.font: font, .foregroundColor: t.text, .paragraphStyle: para, .ligature: 0, .kern: 0]
    }

    private struct Rule {
        let re: NSRegularExpression
        let group: Int
        let color: (Theme) -> NSColor
        var bold = false
        var italic = false
        var isRef = false
    }

    private static func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }

    private static let texRules: [Rule] = [
        Rule(re: re(#"\\[A-Za-z@]+\*?"#), group: 0, color: { $0.command }),
        Rule(re: re(#"\\[^A-Za-z@\s]"#), group: 0, color: { $0.special }),
        Rule(re: re(#"[{}\[\]]"#), group: 0, color: { $0.brace }),
        Rule(re: re(#"[&~^_]"#), group: 0, color: { $0.special }),
        Rule(re: re(#"\\[A-Za-z@]+\*?(\[[^\]\n]*\])"#), group: 1, color: { $0.brace }),
        Rule(re: re(#"\\(begin|end)\{([^}\n]*)\}"#), group: 2, color: { $0.environment }, bold: true),
        Rule(re: re(#"\\(begin|end)(?=\{)"#), group: 0, color: { $0.environment }),
        Rule(re: re(#"\\(part|chapter|section|subsection|subsubsection|paragraph|frametitle|title)\*?(?:\[[^\]\n]*\])?\{([^\n]*)\}"#), group: 2, color: { $0.heading }, bold: true),
        Rule(re: re(#"\\(?:ref|eqref|cref|Cref|autoref|pageref|nameref|cite|citep|citet|citeauthor|citeyear|parencite|textcite|autocite|nocite|label|input|include|includegraphics|subfile|bibliography|addbibresource|usepackage|documentclass)\*?(?:\[[^\]\n]*\])*\{([^}\n]*)\}"#), group: 1, color: { $0.reference }, isRef: true),
    ]

    private static let mathRE = re(#"(?<!\\)\$\$[\s\S]*?(?<!\\)\$\$|(?<![\\$])\$(?:[^$\\\n]|\\.)+?(?<!\\)\$|\\\[[\s\S]*?\\\]|\\\([\s\S]*?\\\)|\\begin\{(equation|align|gather|multline|flalign|alignat|eqnarray|displaymath|math)(\*?)\}[\s\S]*?\\end\{\1\2\}"#)
    private static let commentRE = re(#"(?<!\\)%.*$"#, [.anchorsMatchLines])

    private static let bibRules: [Rule] = [
        Rule(re: re(#"@[A-Za-z]+"#), group: 0, color: { $0.environment }, bold: true),
        Rule(re: re(#"@[A-Za-z]+\s*\{\s*([^,\s]+)"#), group: 1, color: { $0.reference }),
        Rule(re: re(#"^\s*([A-Za-z\-_]+)\s*="#, [.anchorsMatchLines]), group: 1, color: { $0.command }),
        Rule(re: re(#"[{}"]"#), group: 0, color: { $0.brace }),
    ]

    static func highlightAll(_ storage: NSTextStorage, kind: TextDocument.Kind) {
        if kind == .tex && Preferences.shared.visualMode {
            highlightVisual(storage, reveal: revealRange, batch: true)
            return
        }
        highlight(storage, in: NSRange(location: 0, length: storage.length), kind: kind, full: true)
    }

    /// Recolours the paragraphs touched by an edit; for TeX also re-runs the math pass over a window around it
    /// (so opening or closing a `$` or `\begin{equation}` updates everything it affects nearby).
    static func highlightEdited(_ storage: NSTextStorage, range: NSRange, kind: TextDocument.Kind) {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        if kind == .tex && Preferences.shared.visualMode {
            let line = ns.lineRange(for: NSRange(location: min(range.location, ns.length), length: 0))
            revealRange = line
            highlightVisual(storage, reveal: line, batch: false)
            return
        }
        let para = ns.paragraphRange(for: NSRange(location: min(range.location, ns.length), length: min(range.length, ns.length - min(range.location, ns.length))))
        if storage.length < 30_000 {
            highlight(storage, in: NSRange(location: 0, length: storage.length), kind: kind, full: true, batch: false)
        } else {
            // Big files: widen to ±3000 characters to catch multi-line math around the edit.
            let start = max(0, para.location - 3000), end = min(ns.length, NSMaxRange(para) + 3000)
            let window = ns.paragraphRange(for: NSRange(location: start, length: end - start))
            highlight(storage, in: window, kind: kind, full: false, batch: false)
        }
    }

    /// `batch` wraps the changes in begin/endEditing; it must be false when called from inside processEditing.
    private static func highlight(_ storage: NSTextStorage, in range: NSRange, kind: TextDocument.Kind, full: Bool, batch: Bool = true) {
        guard range.length > 0, kind != .other else {
            if kind == .other, range.length > 0 { storage.addAttribute(.foregroundColor, value: ThemeManager.shared.theme.text, range: range) }
            return
        }
        let t = ThemeManager.shared.theme
        let size = Preferences.shared.editorFontSize
        let font = Typo.editorFont(size: size)
        let bold = Typo.editorBold(size: size)
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        let text = storage.string

        if batch { storage.beginEditing() }
        storage.addAttributes([.foregroundColor: t.text, .font: font], range: range)
        storage.removeAttribute(refKey, range: range)
        storage.removeAttribute(.underlineStyle, range: range)
        storage.removeAttribute(hiddenKey, range: range)
        storage.removeAttribute(glyphKey, range: range)
        storage.removeAttribute(.backgroundColor, range: range)
        if let para = baseAttributes()[.paragraphStyle] { storage.addAttribute(.paragraphStyle, value: para, range: range) }

        let rules = kind == .bib ? bibRules : texRules
        for rule in rules {
            rule.re.enumerateMatches(in: text, range: range) { m, _, _ in
                guard let m else { return }
                let r = m.range(at: rule.group)
                guard r.location != NSNotFound, r.length > 0 else { return }
                storage.addAttribute(.foregroundColor, value: rule.color(t), range: r)
                if rule.bold { storage.addAttribute(.font, value: bold, range: r) }
                if rule.italic { storage.addAttribute(.font, value: italic, range: r) }
                if rule.isRef {
                    let cmd = (text as NSString).substring(with: m.range).components(separatedBy: CharacterSet(charactersIn: "{[*")).first ?? ""
                    storage.addAttribute(refKey, value: cmd, range: r)
                }
            }
        }

        if kind == .tex {
            // Math: tint the whole region, keep commands inside readable but in the math hue.
            mathRE.enumerateMatches(in: text, range: range) { m, _, _ in
                guard let m else { return }
                storage.addAttribute(.foregroundColor, value: t.math, range: m.range)
            }
        }
        // Comments win over everything.
        commentRE.enumerateMatches(in: text, range: range) { m, _, _ in
            guard let m else { return }
            storage.addAttributes([.foregroundColor: t.comment, .font: italic], range: m.range)
            storage.removeAttribute(refKey, range: m.range)
        }
        if batch { storage.endEditing() }
    }

    // MARK: Visual mode

    private static let vHeading = re(#"\\(part|chapter|section|subsection|subsubsection|paragraph|title)\*?(?:\[[^\]\n]*\])?\{([^\n]*?)\}"#)
    private static let vFormat = re(#"\\(textbf|textit|emph|underline|texttt|textsc)\{([^{}\n]*)\}"#)
    private static let vItem = re(#"\\item\b ?"#)
    private static let vRef = re(#"\\(cite|citep|citet|parencite|textcite|autocite|ref|eqref|cref|Cref|autoref|pageref|label)\*?\{([^}\n]*)\}"#)
    private static let vBegin = re(#"\\begin\{([^}\n]+)\}(?:\[[^\]\n]*\]|\{[^}\n]*\})*"#)
    private static let vEnd = re(#"\\end\{[^}\n]+\}"#)
    private static let vCaption = re(#"\\caption(?:\[[^\]\n]*\])?\{([^{}\n]*)\}"#)
    private static let vQuiet = re(#"\\(centering|noindent|maketitle|clearpage|newpage|medskip|bigskip|smallskip)\b[ \t]*"#)
    private static let vTilde = re(#"(?<!\\)~"#)
    private static let vCommand = re(#"\\[A-Za-z@]+\*?|\\\\"#)

    /// Formats the source as prose: headings large, emphasis rendered, markup hidden, lists bulleted, citations
    /// and references as pills, math tinted. The line in `reveal` keeps its raw LaTeX so it can be edited.
    static func highlightVisual(_ storage: NSTextStorage, reveal: NSRange?, batch: Bool) {
        let t = ThemeManager.shared.theme
        let accent = ThemeManager.shared.accentNS
        let size = Preferences.shared.editorFontSize + 2.5
        let serifDesc = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
        let serif = serifDesc.flatMap { NSFont(descriptor: $0, size: size) } ?? NSFont.systemFont(ofSize: size)
        func serifSized(_ s: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
            var f = serifDesc.flatMap { NSFont(descriptor: $0, size: s) } ?? NSFont.systemFont(ofSize: s)
            if bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
            if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
            return f
        }
        let mono = Typo.editorFont(size: size - 2.5)
        let small = NSFont.systemFont(ofSize: size - 4, weight: .semibold)
        let base = NSMutableParagraphStyle()
        base.lineHeightMultiple = 1.3
        base.paragraphSpacing = 6
        let text = storage.string
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        guard all.length > 0 else { return }
        let revealed: (NSRange) -> Bool = { r in reveal.map { NSIntersectionRange($0, r).length > 0 || NSLocationInRange(r.location, $0) } ?? false }

        if batch { storage.beginEditing() }
        storage.setAttributes([.font: serif, .foregroundColor: t.text, .paragraphStyle: base], range: all)

        func hide(_ r: NSRange) { if r.length > 0 { storage.addAttribute(hiddenKey, value: true, range: r) } }

        // Preamble: small and quiet.
        let docStart = ns.range(of: "\\begin{document}")
        let bodyStart = docStart.location == NSNotFound ? 0 : NSMaxRange(docStart)
        if docStart.location != NSNotFound {
            storage.addAttributes([.font: Typo.editorFont(size: size - 4), .foregroundColor: t.secondary], range: NSRange(location: 0, length: bodyStart))
        }
        let body = NSRange(location: bodyStart, length: ns.length - bodyStart)

        // De-emphasise remaining commands first; specific rules below override.
        vCommand.enumerateMatches(in: text, range: body) { m, _, _ in
            guard let m else { return }
            storage.addAttributes([.font: Typo.editorFont(size: size - 4), .foregroundColor: t.secondary.withAlphaComponent(0.7)], range: m.range)
        }
        // Math: tinted, monospaced, with a faint wash.
        mathRE.enumerateMatches(in: text, range: body) { m, _, _ in
            guard let m else { return }
            storage.addAttributes([.font: mono, .foregroundColor: t.math, .backgroundColor: t.math.withAlphaComponent(0.08)], range: m.range)
        }
        vHeading.enumerateMatches(in: text, range: body) { m, _, _ in
            guard let m else { return }
            let kind = ns.substring(with: m.range(at: 1))
            let content = m.range(at: 2)
            let scale: CGFloat = ["title": 2.0, "part": 2.0, "chapter": 1.85, "section": 1.5, "subsection": 1.28, "subsubsection": 1.12][kind] ?? 1.0
            let para = NSMutableParagraphStyle()
            para.lineHeightMultiple = 1.15
            para.paragraphSpacingBefore = 14 * scale
            para.paragraphSpacing = 6
            storage.addAttributes([.font: serifSized(size * scale, bold: true), .foregroundColor: t.heading, .paragraphStyle: para], range: m.range)
            if !revealed(m.range) {
                hide(NSRange(location: m.range.location, length: content.location - m.range.location))
                hide(NSRange(location: NSMaxRange(content), length: NSMaxRange(m.range) - NSMaxRange(content)))
            }
        }
        vFormat.enumerateMatches(in: text, range: body) { m, _, _ in
            guard let m else { return }
            let cmd = ns.substring(with: m.range(at: 1))
            let content = m.range(at: 2)
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: t.text]
            switch cmd {
            case "textbf": attrs[.font] = serifSized(size, bold: true)
            case "textit", "emph": attrs[.font] = serifSized(size, italic: true)
            case "underline": attrs[.font] = serif; attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case "texttt": attrs[.font] = mono
            default: attrs[.font] = NSFont.systemFont(ofSize: size - 2, weight: .medium)
            }
            storage.addAttributes(attrs, range: content)
            if !revealed(m.range) {
                hide(NSRange(location: m.range.location, length: content.location - m.range.location))
                hide(NSRange(location: NSMaxRange(content), length: 1))
            }
        }
        vItem.enumerateMatches(in: text, range: body) { m, _, _ in
            guard let m, !revealed(m.range) else { return }
            storage.addAttributes([.foregroundColor: accent, .font: serifSized(size, bold: true), glyphKey: "•"], range: NSRange(location: m.range.location, length: 1))
            hide(NSRange(location: m.range.location + 1, length: 4))
        }
        vRef.enumerateMatches(in: text, range: body) { m, _, _ in
            guard let m else { return }
            let cmd = ns.substring(with: m.range(at: 1))
            let content = m.range(at: 2)
            let isLabel = cmd == "label"
            storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: size - 4.5, weight: .medium),
                                   .foregroundColor: isLabel ? t.secondary.withAlphaComponent(0.6) : t.reference,
                                   .backgroundColor: isLabel ? NSColor.clear : t.reference.withAlphaComponent(0.12),
                                   refKey: cmd], range: content)
            if !revealed(m.range) {
                hide(NSRange(location: m.range.location, length: content.location - m.range.location))
                hide(NSRange(location: NSMaxRange(content), length: 1))
            }
        }
        // Environments: \begin{figure} reads as a small "FIGURE" label; \end{…} disappears.
        vBegin.enumerateMatches(in: text, range: body) { m, _, _ in
            guard let m else { return }
            let name = m.range(at: 1)
            storage.addAttributes([.font: small, .foregroundColor: t.environment.withAlphaComponent(0.8), .kern: 0.8], range: m.range)
            if !revealed(m.range) {
                hide(NSRange(location: m.range.location, length: name.location - m.range.location))
                hide(NSRange(location: NSMaxRange(name), length: NSMaxRange(m.range) - NSMaxRange(name)))
            }
        }
        vEnd.enumerateMatches(in: text, range: body) { m, _, _ in
            guard let m, !revealed(m.range) else { return }
            hide(m.range)
        }
        // Captions read as captions; layout-only commands and ~ spacers vanish.
        vCaption.enumerateMatches(in: text, range: body) { m, _, _ in
            guard let m else { return }
            let content = m.range(at: 1)
            storage.addAttributes([.font: serifSized(size - 1.5, italic: true), .foregroundColor: t.secondary], range: content)
            if !revealed(m.range) {
                hide(NSRange(location: m.range.location, length: content.location - m.range.location))
                hide(NSRange(location: NSMaxRange(content), length: 1))
            }
        }
        vQuiet.enumerateMatches(in: text, range: body) { m, _, _ in
            guard let m, !revealed(m.range) else { return }
            hide(m.range)
        }
        vTilde.enumerateMatches(in: text, range: body) { m, _, _ in
            guard let m, !revealed(m.range) else { return }
            storage.addAttributes([glyphKey: " ", .foregroundColor: t.text], range: m.range)
        }
        commentRE.enumerateMatches(in: text, range: all) { m, _, _ in
            guard let m else { return }
            storage.addAttributes([.foregroundColor: t.comment, .font: NSFontManager.shared.convert(serifSized(size - 2), toHaveTrait: .italicFontMask)], range: m.range)
            storage.removeAttribute(hiddenKey, range: m.range)
        }
        // The caret's line shows its raw LaTeX, coloured like the code view.
        if let reveal, NSMaxRange(reveal) <= ns.length {
            storage.removeAttribute(hiddenKey, range: reveal)
            storage.removeAttribute(glyphKey, range: reveal)
        }
        if batch { storage.endEditing() }
        // Hidden characters live in glyph generation, so make every layout manager regenerate.
        if batch { for lm in storage.layoutManagers { lm.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil) } }
    }
}

/// Applies visual mode's hidden and substituted characters during glyph generation.
final class VisualGlyphs: NSObject, NSLayoutManagerDelegate {
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let ts = layoutManager.textStorage, glyphRange.length > 0 else { return 0 }
        var newProps: [NSLayoutManager.GlyphProperty]?
        var newGlyphs: [CGGlyph]?
        for i in 0..<glyphRange.length {
            let ci = charIndexes[i]
            guard ci < ts.length else { continue }
            if ts.attribute(Highlighter.hiddenKey, at: ci, effectiveRange: nil) != nil {
                if newProps == nil { newProps = Array(UnsafeBufferPointer(start: props, count: glyphRange.length)) }
                newProps![i] = .null
            } else if let sub = ts.attribute(Highlighter.glyphKey, at: ci, effectiveRange: nil) as? String, let u = sub.utf16.first {
                var ch = u
                var g: CGGlyph = 0
                if CTFontGetGlyphsForCharacters(aFont as CTFont, &ch, &g, 1) {
                    if newGlyphs == nil { newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length)) }
                    newGlyphs![i] = g
                }
            }
        }
        guard newProps != nil || newGlyphs != nil else { return 0 }
        let g = newGlyphs ?? Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        let p = newProps ?? Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        layoutManager.setGlyphs(g, properties: p, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        return glyphRange.length
    }
}
