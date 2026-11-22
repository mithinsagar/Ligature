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
    /// The whole source stretch a widget stands in for (value: its `WidgetRef`): no space, no line breaks.
    nonisolated static let widgetKey = NSAttributedString.Key("ligature.widget")
    /// The first character of a widget's stretch: lays out as one blank glyph of the widget's size.
    nonisolated static let anchorKey = NSAttributedString.Key("ligature.widgetAnchor")
    /// Visual mode: the preamble is shown (as small code) instead of collapsed into a bar.
    static var preambleExpanded = false
    /// Width of the text column, for sizing figures and tables in Visual mode.
    static var columnWidth: CGFloat = 680

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

    static func highlightAll(_ storage: NSTextStorage, kind: TextDocument.Kind, project: ProjectModel? = nil) {
        if kind == .tex && Preferences.shared.visualMode {
            highlightVisual(storage, reveal: revealRange, batch: true, project: project)
            return
        }
        highlight(storage, in: NSRange(location: 0, length: storage.length), kind: kind, full: true)
    }

    /// Recolours the paragraphs touched by an edit; for TeX also re-runs the math pass over a window around it
    /// (so opening or closing a `$` or `\begin{equation}` updates everything it affects nearby).
    static func highlightEdited(_ storage: NSTextStorage, range: NSRange, kind: TextDocument.Kind, project: ProjectModel? = nil) {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        if kind == .tex && Preferences.shared.visualMode {
            let reveal = visualReveal(at: range.location, in: ns)
            revealRange = reveal
            highlightVisual(storage, reveal: reveal, batch: false, project: project)
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
        storage.removeAttribute(widgetKey, range: range)
        storage.removeAttribute(anchorKey, range: range)
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
        applyFolds(storage, size: size)
        if batch { storage.endEditing() }
    }

    /// Collapses the folded regions of the code view into "⋯ n lines" pills.
    static func applyFolds(_ storage: NSTextStorage, size: CGFloat) {
        let ns = storage.string as NSString
        let font = Typo.editorFont(size: size)
        for f in FoldStore.folds(storage) where f.length > 0 && NSMaxRange(f) <= ns.length {
            let lines = ns.substring(with: f).components(separatedBy: "\n").count - 1
            let label = lines > 0 ? "⋯ \(lines) line\(lines == 1 ? "" : "s")" : "⋯"
            let w = WidgetRef(kind: .fold, payload: .text(label), size: NSSize(width: WidgetRef.pillWidth(label, fontSize: size, symbol: false) + 8, height: ceil(font.ascender - font.descender)))
            attach(w, to: f, in: storage)
        }
    }

    /// Puts a widget over `range`: the first character becomes the widget's glyph, the rest collapse into it.
    static func attach(_ w: WidgetRef, to range: NSRange, in storage: NSTextStorage) {
        storage.removeAttribute(hiddenKey, range: range)
        storage.removeAttribute(glyphKey, range: range)
        storage.removeAttribute(.backgroundColor, range: range)
        storage.addAttribute(widgetKey, value: w, range: range)
        storage.addAttribute(anchorKey, value: true, range: NSRange(location: range.location, length: 1))
    }

    // MARK: Visual mode

    private static let vHeading = re(#"\\(part|chapter|section|subsection|subsubsection|paragraph|title)\*?(?:\[[^\]\n]*\])?\{([^\n]*?)\}"#)
    private static let vFormat = re(#"\\(textbf|textit|emph|underline|texttt|textsc)\{([^{}\n]*)\}"#)
    private static let vList = re(#"\\(begin|end)\{(itemize|enumerate|description)\}|\\item\b(\[[^\]\n]*\])? ?"#)
    private static let vRef = re(#"\\(cite|citep|citet|parencite|textcite|autocite|ref|eqref|cref|Cref|autoref|pageref|label)\*?\{([^}\n]*)\}"#)
    private static let vBegin = re(#"\\begin\{([^}\n]+)\}(?:\[[^\]\n]*\]|\{[^}\n]*\})*"#)
    private static let vEnd = re(#"\\end\{[^}\n]+\}"#)
    private static let vCaption = re(#"\\caption(?:\[[^\]\n]*\])?\{([^{}\n]*)\}"#)
    private static let vQuiet = re(#"\\(centering|noindent|maketitle|clearpage|newpage|medskip|bigskip|smallskip)\b[ \t]*"#)
    private static let vTilde = re(#"(?<!\\)~"#)
    private static let vCommand = re(#"\\[A-Za-z@]+\*?|\\\\"#)
    private static let vFigure = re(#"\\begin\{(figure\*?|wrapfigure)\}[\s\S]*?\\end\{\1\}"#)
    private static let vTable = re(#"\\begin\{(table\*?)\}[\s\S]*?\\end\{\1\}|\\begin\{tabular\}[\s\S]*?\\end\{tabular\}"#)
    private static let vGraphic = re(#"\\includegraphics(?:\[([^\]]*)\])?\{([^}]*)\}"#)
    private static let vAbstract = re(#"\\begin\{abstract\}[\s\S]*?\\end\{abstract\}"#)
    private static let vMaketitle = re(#"\\maketitle\b"#)

    /// What Visual mode shows as raw LaTeX around the caret: its line, widened to any equation, figure or table
    /// it sits in, so the whole construct can be edited.
    static func visualReveal(at location: Int, in ns: NSString) -> NSRange {
        let loc = min(max(0, location), ns.length)
        // Right after the folded preamble is "nowhere in particular": nothing opens up.
        let doc = ns.range(of: "\\begin{document}")
        if !preambleExpanded, doc.location != NSNotFound, loc == NSMaxRange(doc) { return NSRange(location: loc, length: 0) }
        var r = ns.lineRange(for: NSRange(location: loc, length: 0))
        if let m = LaTeXText.math(at: loc, in: ns) { r = NSUnionRange(r, ns.lineRange(for: m.range)) }
        let window = NSRange(location: max(0, loc - 6000), length: min(ns.length, loc + 6000) - max(0, loc - 6000))
        for rx in [vFigure, vTable] {
            for m in rx.matches(in: ns as String, range: window) where NSLocationInRange(loc, m.range) || NSMaxRange(m.range) == loc {
                r = NSUnionRange(r, ns.lineRange(for: m.range))
            }
        }
        return r
    }

    /// Formats the source as a document: headings large, emphasis rendered, lists bulleted and numbered, maths
    /// typeset, figures and tables drawn, the title block set, the preamble folded into a bar. Whatever is in
    /// `reveal` (the caret's line or construct) keeps its raw LaTeX so it can be edited.
    static func highlightVisual(_ storage: NSTextStorage, reveal: NSRange?, batch: Bool, project: ProjectModel? = nil) {
        let t = ThemeManager.shared.theme
        let accent = ThemeManager.shared.accentNS
        let size = Preferences.shared.editorFontSize + 2.5
        let serif = WidgetRef.serif(size)
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
        // A line holding nothing but hidden markup shrinks to a hairline instead of leaving a blank line.
        let collapsed = NSMutableParagraphStyle()
        collapsed.minimumLineHeight = 1
        collapsed.maximumLineHeight = 1
        func collapseIfAlone(_ r: NSRange) {
            let line = ns.lineRange(for: r)
            let rest = ns.substring(with: line).replacingOccurrences(of: ns.substring(with: r), with: "")
            guard rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            storage.addAttribute(.paragraphStyle, value: collapsed, range: line)
        }

        // Preamble: small and quiet (folded into a bar further down unless it's expanded).
        let docStart = ns.range(of: "\\begin{document}")
        let bodyStart = docStart.location == NSNotFound ? 0 : NSMaxRange(docStart)
        if docStart.location != NSNotFound {
            storage.addAttributes([.font: Typo.editorFont(size: size - 4), .foregroundColor: t.secondary], range: NSRange(location: 0, length: bodyStart))
        }
        let body = NSRange(location: bodyStart, length: ns.length - bodyStart)
        var comments: [NSRange] = []
        commentRE.enumerateMatches(in: text, range: all) { m, _, _ in if let m { comments.append(m.range) } }
        let inComment: (Int) -> Bool = { loc in comments.contains { NSLocationInRange(loc, $0) } }

        // De-emphasise remaining commands first; specific rules below override.
        vCommand.enumerateMatches(in: text, range: body) { m, _, _ in
            guard let m else { return }
            storage.addAttributes([.font: Typo.editorFont(size: size - 4), .foregroundColor: t.secondary.withAlphaComponent(0.7)], range: m.range)
        }
        // Math source (shown while it's being typeset, or when the caret is in it): tinted, monospaced.
        var mathMatches: [NSRange] = []
        mathRE.enumerateMatches(in: text, range: body) { m, _, _ in
            guard let m, !inComment(m.range.location) else { return }
            mathMatches.append(m.range)
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
            storage.addAttributes([.font: WidgetRef.serif(size * scale, bold: true), .foregroundColor: t.heading, .paragraphStyle: para], range: m.range)
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
            case "textbf": attrs[.font] = WidgetRef.serif(size, bold: true)
            case "textit", "emph": attrs[.font] = WidgetRef.serif(size, italic: true)
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
        styleLists(storage, ns: ns, body: body, size: size, t: t, accent: accent, revealed: revealed, inComment: inComment, hide: hide)
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
        // Environments: \begin{…} reads as a small label; \end{…} disappears.
        vBegin.enumerateMatches(in: text, range: body) { m, _, _ in
            guard let m else { return }
            let name = m.range(at: 1)
            let envName = ns.substring(with: name)
            if ["itemize", "enumerate", "description", "center", "flushleft", "flushright"].contains(envName) {
                // Lists and alignment wrappers read as their content: the \begin line disappears.
                if !revealed(m.range) { hide(m.range); collapseIfAlone(m.range) }
                return
            }
            if envName == "abstract" {
                storage.addAttributes([.font: WidgetRef.serif(size - 1, bold: true), .foregroundColor: t.heading], range: m.range)
                if !revealed(m.range) { storage.addAttribute(glyphKey, value: "A", range: NSRange(location: name.location, length: 1)) }
            } else {
                storage.addAttributes([.font: small, .foregroundColor: t.environment.withAlphaComponent(0.8), .kern: 0.8], range: m.range)
            }
            if !revealed(m.range) {
                hide(NSRange(location: m.range.location, length: name.location - m.range.location))
                hide(NSRange(location: NSMaxRange(name), length: NSMaxRange(m.range) - NSMaxRange(name)))
            }
        }
        vEnd.enumerateMatches(in: text, range: body) { m, _, _ in
            guard let m, !revealed(m.range) else { return }
            hide(m.range)
            collapseIfAlone(m.range)
        }
        // The abstract sits indented, under a centred heading.
        vAbstract.enumerateMatches(in: text, range: body) { m, _, _ in
            guard let m else { return }
            let para = NSMutableParagraphStyle()
            para.lineHeightMultiple = 1.25
            para.paragraphSpacing = 6
            para.headIndent = 34; para.firstLineHeadIndent = 34; para.tailIndent = -34
            storage.addAttribute(.paragraphStyle, value: para, range: m.range)
            storage.addAttribute(.font, value: WidgetRef.serif(size - 1), range: m.range)
            let headPara = NSMutableParagraphStyle()
            headPara.alignment = .center
            headPara.paragraphSpacingBefore = 8
            storage.addAttribute(.paragraphStyle, value: headPara, range: ns.lineRange(for: NSRange(location: m.range.location, length: 0)))
        }
        // Captions read as captions; layout-only commands and ~ spacers vanish.
        vCaption.enumerateMatches(in: text, range: body) { m, _, _ in
            guard let m else { return }
            let content = m.range(at: 1)
            storage.addAttributes([.font: WidgetRef.serif(size - 1.5, italic: true), .foregroundColor: t.secondary], range: content)
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
        for c in comments {
            storage.addAttributes([.foregroundColor: t.comment, .font: WidgetRef.serif(size - 2, italic: true)], range: c)
            storage.removeAttribute(hiddenKey, range: c)
        }
        // The caret's line shows its raw LaTeX, coloured like the code view.
        if let reveal, NSMaxRange(reveal) <= ns.length {
            storage.removeAttribute(hiddenKey, range: reveal)
            storage.removeAttribute(glyphKey, range: reveal)
        }

        placeWidgets(storage, ns: ns, docStart: docStart, body: body, mathMatches: mathMatches, size: size, t: t, revealed: revealed, inComment: inComment, project: project)

        if batch { storage.endEditing() }
        // Hidden characters live in glyph generation, so make every layout manager regenerate.
        if batch { for lm in storage.layoutManagers { lm.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil) } }
    }

    /// Bullets and numbers for \item, nested lists indented, description terms in bold.
    private static func styleLists(_ storage: NSTextStorage, ns: NSString, body: NSRange, size: CGFloat, t: Theme, accent: NSColor,
                                   revealed: (NSRange) -> Bool, inComment: (Int) -> Bool, hide: (NSRange) -> Void) {
        var stack: [(kind: String, count: Int, start: Int)] = []
        var spans: [(range: NSRange, depth: Int)] = []
        var items: [(range: NSRange, term: NSRange?, label: String, depth: Int)] = []
        let bullets = ["•", "◦", "▪", "‣"]
        func roman(_ n: Int) -> String {
            let table = [(10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
            var n = n, out = ""
            for (v, s) in table { while n >= v { out += s; n -= v } }
            return out
        }
        vList.enumerateMatches(in: ns as String, range: body) { m, _, _ in
            guard let m, !inComment(m.range.location) else { return }
            if m.range(at: 1).location != NSNotFound {
                let isBegin = ns.substring(with: m.range(at: 1)) == "begin"
                let kind = ns.substring(with: m.range(at: 2))
                if isBegin { stack.append((kind, 0, m.range.location)) } else if let top = stack.popLast() {
                    spans.append((NSRange(location: top.start, length: NSMaxRange(m.range) - top.start), stack.count + 1))
                }
                return
            }
            let depth = max(1, stack.count)
            var label = bullets[(depth - 1) % bullets.count]
            if let top = stack.last {
                stack[stack.count - 1].count += 1
                let n = stack[stack.count - 1].count
                if top.kind == "enumerate" {
                    switch stack.filter({ $0.kind == "enumerate" }).count {
                    case 1: label = "\(n)."
                    case 2: label = "(\(Character(UnicodeScalar(96 + min(n, 26))!)))"
                    default: label = roman(n) + "."
                    }
                } else if top.kind == "description" { label = "" }
            }
            let term = m.range(at: 3).location != NSNotFound ? m.range(at: 3) : nil
            items.append((m.range, term, label, depth))
        }
        for span in spans.sorted(by: { $0.depth < $1.depth }) {
            let para = NSMutableParagraphStyle()
            para.lineHeightMultiple = 1.3
            para.paragraphSpacing = 3
            para.headIndent = CGFloat(span.depth) * 24
            para.firstLineHeadIndent = CGFloat(span.depth) * 24
            storage.addAttribute(.paragraphStyle, value: para, range: ns.paragraphRange(for: span.range))
        }
        for item in items {
            let para = NSMutableParagraphStyle()
            para.lineHeightMultiple = 1.3
            para.paragraphSpacing = 3
            para.headIndent = CGFloat(item.depth) * 24
            para.firstLineHeadIndent = CGFloat(item.depth) * 24 - (item.label.isEmpty ? 0 : 20)
            storage.addAttribute(.paragraphStyle, value: para, range: ns.paragraphRange(for: item.range))
            guard !revealed(item.range) else { continue }
            let cmd = NSRange(location: item.range.location, length: 5)   // "\item"
            let chars = Array(item.label)
            for (i, ch) in chars.prefix(5).enumerated() {
                storage.addAttributes([.foregroundColor: accent, .font: WidgetRef.serif(size, bold: true), glyphKey: String(ch)], range: NSRange(location: cmd.location + i, length: 1))
            }
            hide(NSRange(location: cmd.location + min(chars.count, 5), length: 5 - min(chars.count, 5)))
            if let term = item.term {
                storage.addAttributes([.font: WidgetRef.serif(size, bold: true), .foregroundColor: t.text], range: term)
                hide(NSRange(location: term.location, length: 1))
                hide(NSRange(location: NSMaxRange(term) - 1, length: 1))
            }
        }
    }

    /// Replaces the preamble, title block, figures, tables and equations with rendered widgets.
    private static func placeWidgets(_ storage: NSTextStorage, ns: NSString, docStart: NSRange, body: NSRange, mathMatches: [NSRange], size: CGFloat, t: Theme,
                                     revealed: (NSRange) -> Bool, inComment: (Int) -> Bool, project: ProjectModel?) {
        let text = ns as String
        var taken: [NSRange] = []
        func free(_ r: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, r).length > 0 } }
        func block(_ w: WidgetRef, _ r: NSRange) {
            guard r.length > 1, free(r) else { return }
            taken.append(r)
            attach(w, to: r, in: storage)
            let para = NSMutableParagraphStyle()
            para.minimumLineHeight = w.size.height
            para.maximumLineHeight = w.size.height
            para.paragraphSpacingBefore = 4
            para.paragraphSpacing = 6
            storage.addAttribute(.paragraphStyle, value: para, range: ns.paragraphRange(for: NSRange(location: r.location, length: 0)))
        }
        let column = columnWidth

        // Preamble: one bar that opens it.
        if docStart.location != NSNotFound {
            let pre = NSRange(location: 0, length: NSMaxRange(docStart))
            if !preambleExpanded {
                let cls = ns.substring(to: pre.length).range(of: #"\\documentclass(\[[^\]]*\])?\{([^}]*)\}"#, options: .regularExpression)
                    .map { String(ns.substring(to: pre.length)[$0]).replacingOccurrences(of: #"^.*\{|\}$"#, with: "", options: .regularExpression) } ?? "document"
                let packages = (try? NSRegularExpression(pattern: #"\\usepackage(?:\[[^\]]*\])?\{([^}]*)\}"#))?.matches(in: text, range: pre)
                    .reduce(0) { $0 + ns.substring(with: $1.range(at: 1)).split(separator: ",").count } ?? 0
                let lines = ns.substring(with: pre).components(separatedBy: "\n").count
                let summary = "Preamble  ·  \(cls)  ·  \(packages) package\(packages == 1 ? "" : "s")  ·  \(lines) lines"
                block(WidgetRef(kind: .preamble, payload: .text(summary), size: NSSize(width: 0, height: 44)), pre)
            } else if !revealed(docStart) {
                let label = "Hide preamble"
                let w = WidgetRef(kind: .preambleShown, payload: .text(label), size: NSSize(width: WidgetRef.pillWidth(label, fontSize: size, symbol: true), height: 22))
                attach(w, to: docStart, in: storage)
                taken.append(docStart)
            }
        }

        // Title block, where \maketitle is.
        if let mk = vMaketitle.firstMatch(in: text, range: body), !revealed(mk.range), !inComment(mk.range.location),
           let rawTitle = LaTeXText.argument(of: "title", in: text) {
            let title = LaTeXText.plainText(rawTitle)
            let author = LaTeXText.argument(of: "author", in: text).map { LaTeXText.plainText($0.replacingOccurrences(of: "\\and", with: "  ·  ")) } ?? ""
            let rawDate = LaTeXText.argument(of: "date", in: text)
            let date = rawDate == nil || rawDate!.contains("\\today") ? Date().formatted(.dateTime.month(.wide).day().year()) : LaTeXText.plainText(rawDate!)
            let h = WidgetRef.titleHeight(title, author, date, columnWidth: column, fontSize: size)
            block(WidgetRef(kind: .title, payload: .title(title: title, author: author, date: date), size: NSSize(width: 0, height: h)), mk.range)
        }

        // Figures: the image(s) and caption.
        vFigure.enumerateMatches(in: text, range: body) { m, _, _ in
            guard let m, !revealed(m.range), !inComment(m.range.location), free(m.range) else { return }
            let src = ns.substring(with: m.range)
            var images: [NSImage?] = []
            var names: [String] = []
            var fraction: CGFloat = 0.8
            vGraphic.enumerateMatches(in: src, range: NSRange(location: 0, length: (src as NSString).length)) { g, _, _ in
                guard let g else { return }
                let opts = g.range(at: 1).location != NSNotFound ? (src as NSString).substring(with: g.range(at: 1)) : ""
                let path = (src as NSString).substring(with: g.range(at: 2))
                names.append((path as NSString).lastPathComponent)
                images.append(project.flatMap { loadImage(path, project: $0) })
                if let w = opts.range(of: #"width\s*=\s*([0-9.]+)\s*\\(linewidth|textwidth|columnwidth|hsize)"#, options: .regularExpression) {
                    let num = String(opts[w]).replacingOccurrences(of: #"^[^0-9.]*([0-9.]+).*$"#, with: "$1", options: .regularExpression)
                    fraction = min(1, max(0.15, CGFloat(Double(num) ?? 0.8)))
                } else if opts.contains("scale") { fraction = 0.6 }
            }
            guard !images.isEmpty else { return }
            let caption = LaTeXText.argument(of: "caption", in: src).map(LaTeXText.plainText) ?? ""
            let label = LaTeXText.argument(of: "label", in: src) ?? ""
            let fig = WidgetRef.Figure(images: images, names: names, widthFraction: fraction, caption: caption, label: label)
            let h = WidgetRef.figureHeight(fig, columnWidth: column, captionFont: WidgetRef.serif(size - 1.5, italic: true))
            block(WidgetRef(kind: .figure, payload: .figure(fig), size: NSSize(width: 0, height: h)), m.range)
        }

        // Tables: drawn natively from the tabular; clicking one opens the table editor.
        vTable.enumerateMatches(in: text, range: body) { m, _, _ in
            guard let m, !revealed(m.range), !inComment(m.range.location), free(m.range) else { return }
            guard let model = TableModel.parse(latex: ns.substring(with: m.range)), model.rows > 0 else { return }
            let h = WidgetRef.tableHeight(model, font: WidgetRef.serif(size - 1))
            block(WidgetRef(kind: .table, payload: .table(model), size: NSSize(width: 0, height: h)), m.range)
        }

        // Equations: typeset images once they're ready (until then the tinted source shows).
        guard let project else { return }
        let preamble = MathRenderer.safePreamble(LaTeXText.preamble(of: project.text(of: project.mainFile) ?? text).body)
        let scale = size / 10
        var wanted: [String] = []
        for r in mathMatches where !revealed(r) && free(r) {
            guard let sn = VisualMath.snippet(for: ns.substring(with: r)) else { continue }
            switch VisualMath.shared.image(sn.snippet, preamble: preamble, scale: scale, color: t.text) {
            case .ready(let img):
                if sn.display {
                    block(WidgetRef(kind: .displayMath, payload: .image(img), size: NSSize(width: 0, height: img.size.height + 14)), r)
                } else {
                    taken.append(r)
                    attach(WidgetRef(kind: .inlineMath, payload: .image(img), size: img.size), to: r, in: storage)
                    // Tall inline maths (fractions, sums) makes room in its paragraph.
                    let natural = ceil(serifLineHeight(size) * 1.3)
                    if img.size.height + 4 > natural {
                        let para = (storage.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                        para.minimumLineHeight = img.size.height + 4
                        storage.addAttribute(.paragraphStyle, value: para, range: ns.paragraphRange(for: r))
                    }
                }
            case .pending:
                wanted.append(sn.snippet)
            case .failed:
                break
            }
        }
        if !wanted.isEmpty { VisualMath.shared.request(wanted, preamble: preamble, engine: project.engine) }
    }

    private static func serifLineHeight(_ size: CGFloat) -> CGFloat {
        let f = WidgetRef.serif(size)
        return f.ascender - f.descender + f.leading
    }

    private static var imageCache: [String: (date: Date, image: NSImage)] = [:]

    /// Loads a figure the way \includegraphics finds it: relative to the main file, extension optional.
    static func loadImage(_ value: String, project: ProjectModel) -> NSImage? {
        let mainDir = (project.mainFile as NSString).deletingLastPathComponent
        let rel = mainDir.isEmpty ? value : (mainDir as NSString).appendingPathComponent(value)
        let fm = FileManager.default
        var candidates = [rel]
        if (rel as NSString).pathExtension.isEmpty { candidates = ["pdf", "png", "jpg", "jpeg"].map { rel + "." + $0 } }
        for c in candidates {
            let url = project.root.appendingPathComponent(c)
            guard let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { continue }
            if let hit = imageCache[url.path], hit.date == date { return hit.image }
            guard let img = NSImage(contentsOf: url) else { return nil }
            imageCache[url.path] = (date, img)
            return img
        }
        return nil
    }
}

/// Applies hidden and substituted characters during glyph generation, and lays widgets out: a widget's first
/// character becomes one blank glyph of the widget's size, the rest of its source takes no space and its line
/// breaks stop breaking lines.
final class VisualGlyphs: NSObject, NSLayoutManagerDelegate {
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let ts = layoutManager.textStorage, glyphRange.length > 0 else { return 0 }
        var newProps: [NSLayoutManager.GlyphProperty]?
        var newGlyphs: [CGGlyph]?
        for i in 0..<glyphRange.length {
            let ci = charIndexes[i]
            guard ci < ts.length else { continue }
            if ts.attribute(Highlighter.anchorKey, at: ci, effectiveRange: nil) != nil {
                if newProps == nil { newProps = Array(UnsafeBufferPointer(start: props, count: glyphRange.length)) }
                newProps![i] = .controlCharacter
            } else if ts.attribute(Highlighter.widgetKey, at: ci, effectiveRange: nil) != nil || ts.attribute(Highlighter.hiddenKey, at: ci, effectiveRange: nil) != nil {
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

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction, forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let ts = layoutManager.textStorage, charIndex < ts.length else { return action }
        if ts.attribute(Highlighter.anchorKey, at: charIndex, effectiveRange: nil) != nil { return .whitespace }
        if ts.attribute(Highlighter.widgetKey, at: charIndex, effectiveRange: nil) != nil { return .zeroAdvancement }
        return action
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer,
                       proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard let ts = layoutManager.textStorage, charIndex < ts.length,
              let w = ts.attribute(Highlighter.widgetKey, at: charIndex, effectiveRange: nil) as? WidgetRef else {
            return layoutManager.typesetter.boundingBox(forControlGlyphAt: glyphIndex, for: textContainer, proposedLineFragment: proposedRect, glyphPosition: glyphPosition, characterIndex: charIndex)
        }
        // Blocks are drawn across the column regardless; a narrow box keeps the typesetter from wrapping the
        // collapsed source that follows onto a line of its own.
        if w.isBlock { return NSRect(x: glyphPosition.x, y: 0, width: 1, height: w.size.height) }
        return NSRect(x: glyphPosition.x, y: 0, width: w.size.width, height: w.size.height)
    }
}
