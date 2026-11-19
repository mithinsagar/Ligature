import Foundation

/// Structure of a document: sections, figures, tables, labels and included files, per source file.
public struct OutlineItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case part, chapter, section, subsection, subsubsection, paragraph, figure, table, label, input, todo, frame

        /// Nesting depth used for indentation (lower = higher in the tree).
        public var depth: Int {
            switch self {
            case .part: 0
            case .chapter: 1
            case .section, .frame: 2
            case .subsection: 3
            case .subsubsection: 4
            case .paragraph: 5
            case .figure, .table, .label, .input, .todo: 6
            }
        }

        public var isHeading: Bool { depth <= 5 }
    }

    public var id: String { "\(file)#\(line)#\(kind.rawValue)#\(title)" }
    public var kind: Kind
    public var title: String
    public var file: String
    public var line: Int
    public var label: String?
}

public enum Outline {
    static let headingRE = try! NSRegularExpression(
        pattern: #"\\(part|chapter|section|subsection|subsubsection|paragraph)(\*?)\s*(?:\[([^\]]*)\])?\s*\{((?:[^{}]|\{[^{}]*\})*)\}"#)
    static let labelRE = try! NSRegularExpression(pattern: #"\\label\{([^}]+)\}"#)
    static let inputRE = try! NSRegularExpression(pattern: #"\\(input|include|subfile)\{([^}]+)\}"#)
    static let captionRE = try! NSRegularExpression(pattern: #"\\caption(?:\[[^\]]*\])?\{((?:[^{}]|\{[^{}]*\})*)\}"#)
    static let beginRE = try! NSRegularExpression(pattern: #"\\begin\{(figure|table|frame)\*?\}(?:\{([^}]*)\})?"#)
    static let endRE = try! NSRegularExpression(pattern: #"\\end\{(figure|table|frame)\*?\}"#)
    static let frametitleRE = try! NSRegularExpression(pattern: #"\\frametitle\{([^}]*)\}"#)
    static let todoRE = try! NSRegularExpression(pattern: #"(?:%\s*(TODO|FIXME)[:\s]\s*(.*)|\\todo(?:\[[^\]]*\])?\{([^}]*)\})"#)

    /// Items of one file in source order.
    public static func items(in text: String, file: String) -> [OutlineItem] {
        var out: [OutlineItem] = []
        var openFloat: (kind: OutlineItem.Kind, line: Int, index: Int)?
        var lineNo = 0
        text.enumerateLines { raw, _ in
            lineNo += 1
            let ns = raw as NSString
            let codeEnd = LaTeXText.commentStart(inLine: ns) ?? ns.length
            let code = ns.substring(to: codeEnd)
            let full = NSRange(location: 0, length: (code as NSString).length)

            if let m = todoRE.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
                let t = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ns.substring(with: m.range(at: 3))
                out.append(OutlineItem(kind: .todo, title: t.isEmpty ? "TODO" : t, file: file, line: lineNo))
            }
            for m in headingRE.matches(in: code, range: full) {
                let cn = code as NSString
                let kind = OutlineItem.Kind(rawValue: cn.substring(with: m.range(at: 1)))!
                let short = m.range(at: 3).location != NSNotFound ? cn.substring(with: m.range(at: 3)) : nil
                let title = clean(short ?? cn.substring(with: m.range(at: 4)))
                out.append(OutlineItem(kind: kind, title: title, file: file, line: lineNo))
            }
            for m in beginRE.matches(in: code, range: full) {
                let cn = code as NSString
                let kind = OutlineItem.Kind(rawValue: cn.substring(with: m.range(at: 1)))!
                var title = kind == .figure ? "Figure" : kind == .table ? "Table" : "Slide"
                if kind == .frame, m.range(at: 2).location != NSNotFound { title = clean(cn.substring(with: m.range(at: 2))) }
                out.append(OutlineItem(kind: kind, title: title, file: file, line: lineNo))
                openFloat = (kind, lineNo, out.count - 1)
            }
            if let f = openFloat {
                let cn = code as NSString
                if f.kind != .frame, let m = captionRE.firstMatch(in: code, range: full) {
                    out[f.index].title = clean(cn.substring(with: m.range(at: 1)))
                }
                if f.kind == .frame, let m = frametitleRE.firstMatch(in: code, range: full) {
                    out[f.index].title = clean(cn.substring(with: m.range(at: 1)))
                }
            }
            for m in labelRE.matches(in: code, range: full) {
                let key = (code as NSString).substring(with: m.range(at: 1))
                // Attach to the nearest preceding heading/float when it's on the same or next line.
                if let last = out.indices.last, out[last].kind != .label, out[last].label == nil, lineNo - out[last].line <= 12,
                   out[last].kind != .todo, out[last].kind != .input {
                    out[last].label = key
                }
                out.append(OutlineItem(kind: .label, title: key, file: file, line: lineNo, label: key))
            }
            if endRE.firstMatch(in: code, range: full) != nil { openFloat = nil }
            for m in inputRE.matches(in: code, range: full) {
                out.append(OutlineItem(kind: .input, title: (code as NSString).substring(with: m.range(at: 2)), file: file, line: lineNo))
            }
        }
        return out
    }

    /// The flattened outline of a project starting at the main file and following \input/\include in order.
    /// `read` returns the text of a project-relative path (with or without ".tex"), or nil if missing.
    public static func project(main: String, read: (String) -> String?) -> [OutlineItem] {
        var visited = Set<String>()
        func walk(_ file: String) -> [OutlineItem] {
            guard visited.insert(file).inserted, let text = read(file) else { return [] }
            var result: [OutlineItem] = []
            for item in items(in: text, file: file) {
                if item.kind == .input {
                    let target = resolve(item.title, from: file)
                    result.append(item)
                    result += walk(target)
                } else {
                    result.append(item)
                }
            }
            return result
        }
        return walk(main)
    }

    /// `\input{chapters/intro}` → "chapters/intro.tex" (paths are relative to the main file's folder in LaTeX).
    public static func resolve(_ ref: String, from _: String) -> String {
        var p = ref.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("./") { p.removeFirst(2) }
        if (p as NSString).pathExtension.isEmpty { p += ".tex" }
        return p
    }

    /// Strips simple formatting commands for display ("\textbf{Fast} \emph{proofs}" → "Fast proofs").
    public static func clean(_ s: String) -> String {
        var t = s
        for _ in 0..<3 {
            t = t.replacingOccurrences(of: #"\\(textbf|textit|emph|texttt|textsc|underline|mathrm|text|textrm|textsf)\{([^{}]*)\}"#, with: "$2", options: .regularExpression)
        }
        t = t.replacingOccurrences(of: #"\\(\\|newline|LaTeX|TeX)"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "~", with: " ")
        t = t.replacingOccurrences(of: #"[{}]"#, with: "", options: .regularExpression)
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}
