import AppKit

/// Turns formatted text from the pasteboard (Word, Pages, Google Docs, a web page) into LaTeX: headings become
/// sections, bold/italic/underline/links/superscripts their commands, lists itemize/enumerate, tables tabular.
/// Plain text, LaTeX, and code (monospaced rich text from editors) are left alone.
@MainActor
enum RichPaste {
    static func latex(from pb: NSPasteboard) -> String? {
        let plain = pb.string(forType: .string) ?? ""
        // Already LaTeX: paste it as it is.
        if plain.range(of: #"\\[A-Za-z]+\s*[\{\[]"#, options: .regularExpression) != nil { return nil }
        var attr: NSAttributedString?
        if let html = pb.data(forType: .html) {
            attr = NSAttributedString(html: html, options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        } else if let rtf = pb.data(forType: .rtf) {
            attr = NSAttributedString(rtf: rtf, documentAttributes: nil)
        }
        guard let attr, attr.length > 0, !isCode(attr) else { return nil }
        let out = convert(attr)
        guard !out.isEmpty, out != escape(plain.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return out
    }

    /// Code editors put monospaced rich text on the pasteboard; that should paste as plain text.
    private static func isCode(_ a: NSAttributedString) -> Bool {
        var mono = 0, total = 0
        a.enumerateAttribute(.font, in: NSRange(location: 0, length: a.length)) { v, r, _ in
            total += r.length
            if let f = v as? NSFont, f.isFixedPitch || f.fontDescriptor.symbolicTraits.contains(.monoSpace) { mono += r.length }
        }
        return total > 0 && Double(mono) / Double(total) > 0.8
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\textbackslash{}"
            case "&", "%", "$", "#", "_", "{", "}": out += "\\" + String(ch)
            case "~": out += "\\textasciitilde{}"
            case "^": out += "\\textasciicircum{}"
            case "\u{00A0}": out += "~"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: Conversion

    static func convert(_ a: NSAttributedString) -> String {
        let ns = a.string as NSString
        let bodySize = dominantFontSize(a)
        var out: [String] = []
        var listStack: [String] = []          // "itemize" / "enumerate"
        var listObjects: [NSTextList] = []
        let headingLevels = headingSizes(a, bodySize: bodySize)
        var table: (id: ObjectIdentifier, cells: [Int: [Int: String]])?

        func closeLists(to depth: Int) {
            while listStack.count > depth {
                out.append(String(repeating: "  ", count: listStack.count - 1) + "\\end{\(listStack.removeLast())}")
                listObjects.removeLast()
            }
        }
        func flushTable() {
            guard let t = table else { return }
            table = nil
            let rows = t.cells.keys.sorted()
            let cols = (t.cells.values.flatMap(\.keys).max() ?? 0) + 1
            var lines = ["\\begin{tabular}{\(String(repeating: "l", count: cols))}", "  \\hline"]
            for (i, r) in rows.enumerated() {
                let row = (0..<cols).map { t.cells[r]?[$0] ?? "" }
                lines.append("  " + row.joined(separator: " & ") + " \\\\")
                if i == 0 { lines.append("  \\hline") }
            }
            lines.append("  \\hline")
            lines.append("\\end{tabular}")
            out.append("\\begin{table}[htbp]\n  \\centering\n" + lines.map { "  " + $0 }.joined(separator: "\n") + "\n\\end{table}")
        }

        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            let style = range.length > 0 ? a.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle : nil

            // Table cells.
            if let block = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first {
                closeLists(to: 0)
                let id = ObjectIdentifier(block.table)
                if table?.id != id { flushTable(); table = (id, [:]) }
                let cell = inline(a, range).trimmingCharacters(in: .whitespaces)
                let prev = table!.cells[block.startingRow]?[block.startingColumn]
                table!.cells[block.startingRow, default: [:]][block.startingColumn] = prev.map { $0 + " " + cell } ?? cell
                return
            }
            flushTable()

            var r = range
            // Lists: HTML import keeps the marker ("\t•\t", "1.\t") at the start; drop it.
            let lists = style?.textLists ?? []
            if !lists.isEmpty {
                let text = ns.substring(with: r)
                if let m = text.range(of: #"^\t?[^\t]{0,8}\t"#, options: .regularExpression) {
                    let cut = (String(text[m]) as NSString).length
                    r = NSRange(location: r.location + cut, length: max(0, r.length - cut))
                }
                // A different list at some level (e.g. numbered right after bulleted) starts a new environment.
                let same = zip(listObjects, lists).prefix { $0 === $1 }.count
                closeLists(to: min(lists.count, same))
                while listStack.count < lists.count {
                    let list = lists[listStack.count]
                    let ordered = [.decimal, .lowercaseAlpha, .uppercaseAlpha, .lowercaseRoman, .uppercaseRoman, .lowercaseLatin, .uppercaseLatin, .decimal].contains(list.markerFormat)
                    let env = ordered ? "enumerate" : "itemize"
                    out.append(String(repeating: "  ", count: listStack.count) + "\\begin{\(env)}")
                    listStack.append(env)
                    listObjects.append(list)
                }
                out.append(String(repeating: "  ", count: listStack.count) + "\\item " + inline(a, r).trimmingCharacters(in: .whitespaces))
                return
            }
            closeLists(to: 0)

            let body = inline(a, r).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { return }
            // Headings: noticeably bigger than the body text, short, one line.
            let size = averageFontSize(a, r)
            let plainLength = ns.substring(with: r).trimmingCharacters(in: .whitespaces).count
            if plainLength < 160, !body.contains("\n") {
                let heading = stripOuterFormatting(body)
                let commands = ["section", "subsection", "subsubsection"]
                if size >= bodySize * 1.12, let level = headingLevels.firstIndex(where: { abs($0 - size.rounded()) < 0.5 }) {
                    out.append("\\\(commands[min(level, 2)]){\(heading)}"); return
                }
                if size >= bodySize * 1.02, isAllBold(a, r) { out.append("\\subsubsection{\(heading)}"); return }
            }
            out.append(body)
        }
        closeLists(to: 0)
        flushTable()

        // Blank line between paragraphs, but keep list and table lines together.
        var joined = ""
        for (i, line) in out.enumerated() {
            if i > 0 {
                let prev = out[i - 1].trimmingCharacters(in: .whitespaces)
                let cur = line.trimmingCharacters(in: .whitespaces)
                let tight = (prev.hasPrefix("\\item") || prev.hasPrefix("\\begin{itemize}") || prev.hasPrefix("\\begin{enumerate}") || prev.hasPrefix("\\end{itemize}") || prev.hasPrefix("\\end{enumerate}"))
                    && (cur.hasPrefix("\\item") || cur.hasPrefix("\\begin{itemize}") || cur.hasPrefix("\\begin{enumerate}") || cur.hasPrefix("\\end{"))
                joined += tight ? "\n" : "\n\n"
            }
            joined += line
        }
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One paragraph's runs as LaTeX: bold, italic, underline, links, super/subscripts.
    private static func inline(_ a: NSAttributedString, _ range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var out = ""
        a.enumerateAttributes(in: range) { attrs, r, _ in
            var text = (a.string as NSString).substring(with: r)
            text = text.replacingOccurrences(of: "\u{FFFC}", with: "")   // images aren't carried over
            text = text.replacingOccurrences(of: "\u{2028}", with: " ").replacingOccurrences(of: "\t", with: " ")
            guard !text.isEmpty else { return }
            let lead = String(text.prefix { $0 == " " }), trail = String(text.reversed().prefix { $0 == " " })
            var core = escape(text.trimmingCharacters(in: .whitespaces))
            guard !core.isEmpty else { out += text; return }
            let traits = (attrs[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            if traits.contains(.bold) { core = "\\textbf{\(core)}" }
            if traits.contains(.italic) { core = "\\textit{\(core)}" }
            if let u = attrs[.underlineStyle] as? Int, u != 0, attrs[.link] == nil { core = "\\underline{\(core)}" }
            if let sup = attrs[.superscript] as? Int, sup != 0 { core = sup > 0 ? "\\textsuperscript{\(core)}" : "\\textsubscript{\(core)}" }
            else if let off = attrs[.baselineOffset] as? CGFloat, abs(off) > 1 { core = off > 0 ? "\\textsuperscript{\(core)}" : "\\textsubscript{\(core)}" }
            if let link = attrs[.link] {
                let url = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if !url.isEmpty { core = "\\href{\(url.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "#", with: "\\#"))}{\(core)}" }
            }
            out += lead + core + trail
        }
        // Merge "\textbf{a}\textbf{b}" runs split by attribute boundaries.
        for cmd in ["textbf", "textit", "underline"] {
            out = out.replacingOccurrences(of: "}\\\(cmd){", with: "")
        }
        return out
    }

    private static func stripOuterFormatting(_ s: String) -> String {
        var t = s
        for cmd in ["textbf", "textit"] where t.hasPrefix("\\\(cmd){") && t.hasSuffix("}") {
            t = String(t.dropFirst(cmd.count + 2).dropLast())
        }
        return t
    }

    /// Font sizes used for headings (bigger than the body text), largest first: section, subsection, …
    private static func headingSizes(_ a: NSAttributedString, bodySize: CGFloat) -> [CGFloat] {
        var sizes = Set<CGFloat>()
        a.enumerateAttribute(.font, in: NSRange(location: 0, length: a.length)) { v, _, _ in
            if let f = v as? NSFont, f.pointSize >= bodySize * 1.12 { sizes.insert(f.pointSize.rounded()) }
        }
        return sizes.sorted(by: >)
    }

    private static func dominantFontSize(_ a: NSAttributedString) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        a.enumerateAttribute(.font, in: NSRange(location: 0, length: a.length)) { v, r, _ in
            if let f = v as? NSFont { weights[f.pointSize.rounded(), default: 0] += r.length }
        }
        return weights.max { $0.value < $1.value }?.key ?? 12
    }

    private static func averageFontSize(_ a: NSAttributedString, _ range: NSRange) -> CGFloat {
        var sum: CGFloat = 0, n = 0
        a.enumerateAttribute(.font, in: range) { v, r, _ in
            if let f = v as? NSFont { sum += f.pointSize * CGFloat(r.length); n += r.length }
        }
        return n > 0 ? sum / CGFloat(n) : 0
    }

    private static func isAllBold(_ a: NSAttributedString, _ range: NSRange) -> Bool {
        var all = true
        a.enumerateAttribute(.font, in: range) { v, r, stop in
            let text = (a.string as NSString).substring(with: r).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, !((v as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false) { all = false; stop.pointee = true }
        }
        return all
    }
}
