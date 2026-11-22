import Foundation

/// Small, fast helpers over LaTeX source held as an NSString (UTF-16 offsets, to match NSTextView ranges).
public enum LaTeXText {
    // MARK: Comments

    /// Range of the `%` comment on the line containing `location`, ignoring escaped `\%`.
    public static func commentStart(inLine line: NSString) -> Int? {
        var i = 0
        while i < line.length {
            let c = line.character(at: i)
            if c == 92 /* \ */ { i += 2; continue }
            if c == 37 /* % */ { return i }
            i += 1
        }
        return nil
    }

    /// Removes comments (keeps `\%`, keeps the newline). Lines that were only a comment are dropped entirely.
    public static func stripComments(_ text: String) -> String {
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            let ns = line as NSString
            if let c = commentStart(inLine: ns) {
                let kept = ns.substring(to: c)
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("%") { continue }
                out.append(kept + (kept.hasSuffix("\\") ? "" : "%"))
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: Word count

    /// Words of prose: skips the preamble, comments, command names, math, and arguments of non-prose commands.
    public static func wordCount(_ text: String) -> Int {
        var body = text
        if let r = body.range(of: "\\begin{document}") { body = String(body[r.upperBound...]) }
        if let r = body.range(of: "\\end{document}") { body = String(body[..<r.lowerBound]) }
        body = stripComments(body)
        let patterns = [
            #"\$\$[\s\S]*?\$\$"#, #"\$[^$]*\$"#, #"\\\[[\s\S]*?\\\]"#, #"\\\([\s\S]*?\\\)"#,
            #"\\begin\{(equation|align|gather|multline|eqnarray|displaymath|math|tikzpicture|lstlisting|verbatim|minted)\*?\}[\s\S]*?\\end\{\1\*?\}"#,
            #"\\(label|ref|eqref|cref|Cref|cite|citep|citet|autoref|pageref|includegraphics|input|include|usepackage|documentclass|bibliography|bibliographystyle|url|begin|end|vspace|hspace|setlength|newcommand|renewcommand)\*?(\[[^\]]*\])?\{[^}]*\}"#,
            #"\\[A-Za-z@]+\*?"#, #"[{}\[\]&~^_\\]"#,
        ]
        for p in patterns { body = body.replacingOccurrences(of: p, with: " ", options: .regularExpression) }
        var n = 0
        body.enumerateSubstrings(in: body.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in n += 1 }
        return n
    }

    // MARK: Tokens under the caret

    public enum Token: Equatable, Sendable {
        case command(name: String, range: NSRange)
        /// `\ref{key}`, `\cite{a,b}`, `\label{x}`, `\input{file}`, `\includegraphics{path}`...
        case argument(command: String, value: String, range: NSRange)
    }

    static let argCommands: Set<String> = ["ref", "eqref", "cref", "Cref", "autoref", "pageref", "nameref", "vref",
                                           "cite", "citep", "citet", "citeauthor", "citeyear", "parencite", "textcite", "autocite", "nocite",
                                           "label", "input", "include", "includegraphics", "subfile", "bibliography", "addbibresource",
                                           "usepackage", "RequirePackage", "begin", "end", "documentclass"]

    /// What's at `location`: a command name, or the argument of a referencing command (resolved to the single
    /// comma-separated key under the caret for \cite).
    public static func token(at location: Int, in text: NSString) -> Token? {
        guard text.length > 0 else { return nil }
        let loc = min(max(0, location), text.length)
        let lineRange = text.lineRange(for: NSRange(location: min(loc, text.length - 1), length: 0))
        let line = text.substring(with: lineRange) as NSString
        let offset = loc - lineRange.location

        // Argument tokens: find "\cmd[...]{" whose braces enclose the caret.
        let re = try! NSRegularExpression(pattern: #"\\([A-Za-z]+)\*?(?:\[[^\]]*\])*\{([^{}]*)\}"#)
        for m in re.matches(in: line as String, range: NSRange(location: 0, length: line.length)) {
            let name = line.substring(with: m.range(at: 1))
            let argRange = m.range(at: 2)
            guard argCommands.contains(name), offset >= argRange.location, offset <= NSMaxRange(argRange) else { continue }
            let arg = line.substring(with: argRange) as NSString
            // For key lists, pick the key under the caret.
            var start = 0, end = arg.length
            let local = offset - argRange.location
            for (i, ch) in (arg as String).utf16.enumerated() where ch == 44 /* , */ {
                if i < local { start = i + 1 } else { end = i; break }
            }
            let raw = arg.substring(with: NSRange(location: start, length: end - start))
            let value = raw.trimmingCharacters(in: .whitespaces)
            let r = NSRange(location: lineRange.location + argRange.location + start, length: end - start)
            return .argument(command: name, value: value, range: r)
        }

        // Command token: walk left to a backslash over letters.
        var s = offset
        while s > 0, isLetter(line.character(at: s - 1)) { s -= 1 }
        var e = offset
        while e < line.length, isLetter(line.character(at: e)) { e += 1 }
        if s > 0, line.character(at: s - 1) == 92, e > s {
            return .command(name: line.substring(with: NSRange(location: s, length: e - s)),
                            range: NSRange(location: lineRange.location + s - 1, length: e - s + 1))
        }
        return nil
    }

    static func isLetter(_ c: unichar) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 64 }

    // MARK: Math under the caret

    /// The math content around `location` (inline `$…$`, `\(…\)`, `\[…\]`, `$$…$$` or a display math
    /// environment), plus whether it is display math. Nil when the caret is not in math.
    public static func math(at location: Int, in text: NSString) -> (content: String, range: NSRange, display: Bool)? {
        let windowStart = max(0, location - 4000), windowEnd = min(text.length, location + 4000)
        let window = text.substring(with: NSRange(location: windowStart, length: windowEnd - windowStart))
        let local = location - windowStart
        let envs = "equation|align|gather|multline|flalign|alignat|eqnarray|displaymath|math"
        let patterns: [(String, Bool)] = [
            (#"\\begin\{("# + envs + #")(\*?)\}([\s\S]*?)\\end\{\1\2\}"#, true),
            (#"\\\[([\s\S]*?)\\\]"#, true),
            (#"\$\$([\s\S]*?)\$\$"#, true),
            (#"\\\(([\s\S]*?)\\\)"#, false),
            (#"(?<![\\$])\$([^$\n]+?)(?<!\\)\$"#, false),
        ]
        let ns = window as NSString
        let commentMask = commentRanges(ns)
        for (p, display) in patterns {
            let re = try! NSRegularExpression(pattern: p)
            for m in re.matches(in: window, range: NSRange(location: 0, length: ns.length)) {
                guard local > m.range.location, local < NSMaxRange(m.range) else { continue }
                if commentMask.contains(where: { NSLocationInRange(m.range.location, $0) }) { continue }
                let bodyRange = m.range(at: m.numberOfRanges - 1)
                var body = ns.substring(with: bodyRange)
                var isDisplay = display
                if m.numberOfRanges == 4 {
                    // environment: keep it as an environment so alignment (&, \\) renders.
                    let env = ns.substring(with: m.range(at: 1)) + ns.substring(with: m.range(at: 2))
                    body = "\\begin{\(env)}\(body)\\end{\(env)}"
                    isDisplay = true
                }
                body = body.replacingOccurrences(of: #"\\label\{[^}]*\}"#, with: "", options: .regularExpression)
                // A blank line is a paragraph break, which is an error inside math.
                body = body.replacingOccurrences(of: #"\n[ \t]*(?=\n)"#, with: "", options: .regularExpression)
                if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
                return (body, NSRange(location: m.range.location + windowStart, length: m.range.length), isDisplay)
            }
        }
        return nil
    }

    static func commentRanges(_ s: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var lineStart = 0
        while lineStart < s.length {
            let r = s.lineRange(for: NSRange(location: lineStart, length: 0))
            let line = s.substring(with: r) as NSString
            if let c = commentStart(inLine: line) { out.append(NSRange(location: r.location + c, length: r.length - c)) }
            lineStart = NSMaxRange(r)
        }
        return out
    }

    // MARK: Preamble

    /// Everything before `\begin{document}` minus `\documentclass` (used to render equation previews with the
    /// document's own packages and macros).
    public static func preamble(of text: String) -> (documentClass: String?, body: String) {
        guard let r = text.range(of: "\\begin{document}") else { return (nil, "") }
        let head = stripComments(String(text[..<r.lowerBound]))
        var cls: String?
        if let m = head.range(of: #"\\documentclass(\[[^\]]*\])?\{[^}]*\}"#, options: .regularExpression) {
            cls = String(head[m])
        }
        let body = head.replacingOccurrences(of: #"\\documentclass(\[[^\]]*\])?\{[^}]*\}"#, with: "", options: .regularExpression)
        return (cls, body)
    }

    /// Adds `\usepackage{name}` after the last existing \usepackage (or after \documentclass). Returns nil if it's
    /// already loaded.
    public static func addingPackage(_ name: String, options: String? = nil, to text: String) -> (text: String, line: Int)? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        if text.range(of: #"\\usepackage(\[[^\]]*\])?\{[^}]*\b"# + escaped + #"\b[^}]*\}"#, options: .regularExpression) != nil { return nil }
        var lines = text.components(separatedBy: "\n")
        let stmt = "\\usepackage" + (options.map { "[\($0)]" } ?? "") + "{\(name)}"
        let docBegin = lines.firstIndex { $0.contains("\\begin{document}") } ?? lines.count
        var insertAt: Int?
        for (i, l) in lines.enumerated() where i < docBegin {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\\usepackage") || t.hasPrefix("\\RequirePackage") { insertAt = i + 1 }
        }
        if insertAt == nil, let dc = lines.firstIndex(where: { $0.contains("\\documentclass") }) { insertAt = dc + 1 }
        let at = insertAt ?? 0
        lines.insert(stmt, at: at)
        return (lines.joined(separator: "\n"), at + 1)
    }

    /// The environment names opened but not closed before `location` (innermost last).
    public static func openEnvironments(before location: Int, in text: NSString) -> [String] {
        let head = text.substring(to: min(location, text.length))
        let re = try! NSRegularExpression(pattern: #"\\(begin|end)\{([^}]+)\}"#)
        var stack: [String] = []
        for m in re.matches(in: head, range: NSRange(location: 0, length: (head as NSString).length)) {
            let kind = (head as NSString).substring(with: m.range(at: 1))
            let name = (head as NSString).substring(with: m.range(at: 2))
            if kind == "begin" { stack.append(name) }
            else if let i = stack.lastIndex(of: name) { stack.removeSubrange(i...) }
        }
        return stack
    }

    /// 1-based line number for a UTF-16 offset.
    public static func lineNumber(at location: Int, in text: NSString) -> Int {
        var n = 1
        let end = min(location, text.length)
        var i = 0
        let buf = UnsafeMutablePointer<unichar>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        while i < end {
            let len = min(4096, end - i)
            text.getCharacters(buf, range: NSRange(location: i, length: len))
            for k in 0..<len where buf[k] == 10 { n += 1 }
            i += len
        }
        return n
    }

    /// UTF-16 range of a 1-based line (without the newline).
    public static func range(ofLine line: Int, in text: NSString) -> NSRange? {
        guard line >= 1 else { return nil }
        var current = 1
        var start = 0
        while current < line {
            let r = text.range(of: "\n", options: [], range: NSRange(location: start, length: text.length - start))
            if r.location == NSNotFound { return nil }
            start = NSMaxRange(r)
            current += 1
        }
        let r = text.range(of: "\n", options: [], range: NSRange(location: start, length: text.length - start))
        let end = r.location == NSNotFound ? text.length : r.location
        return NSRange(location: start, length: end - start)
    }

    // MARK: Plain text

    /// Readable text from a short piece of LaTeX (a caption, a table cell, a title): formatting commands keep their
    /// argument, references become their key, other commands and braces disappear, `~` and `\\` become spaces.
    public static func plainText(_ latex: String) -> String {
        var s = latex
        s = s.replacingOccurrences(of: #"(?<!\\)%.*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\(?:label|index|footnote|thanks|vspace|hspace|phantom)\*?\{[^{}]*\}"#, with: "", options: .regularExpression)
        // Formatting commands with one argument: keep the argument (repeat for nesting).
        for _ in 0..<3 {
            s = s.replacingOccurrences(of: #"\\(?:textbf|textit|emph|underline|texttt|textsc|textsf|textrm|textup|mbox|text|mathrm|mathbf|mathit|url|textsuperscript|textsubscript)\{([^{}]*)\}"#, with: "$1", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"\\href\{[^{}]*\}\{([^{}]*)\}"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\(?:ref|eqref|cref|Cref|autoref|pageref|cite|citep|citet|parencite|textcite|autocite)\*?(?:\[[^\]]*\])*\{([^{}]*)\}"#, with: "[$1]", options: .regularExpression)
        // In order: "---" must become an em dash before "--" becomes an en dash.
        let named: [(String, String)] = [("\\LaTeX", "LaTeX"), ("\\TeX", "TeX"), ("\\ldots", "…"), ("\\dots", "…"), ("\\&", "&"), ("\\%", "%"), ("\\$", "$"), ("\\#", "#"), ("\\_", "_"), ("\\{", "{"), ("\\}", "}"), ("---", "—"), ("--", "–"), ("``", "\u{201C}"), ("''", "\u{201D}")]
        for (k, v) in named { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: #"\\\\(\[[^\]]*\])?"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "~", with: " ")
        s = s.replacingOccurrences(of: #"\\[A-Za-z@]+\*?(\[[^\]]*\])?"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<!\\)[{}]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// The argument of the first `\name{…}` in `text`, with nested braces, or nil.
    public static func argument(of name: String, in text: String) -> String? {
        let ns = text as NSString
        let r = ns.range(of: "\\" + name + "{")
        guard r.location != NSNotFound else {
            // Allow an optional argument: \caption[short]{long}
            guard let m = try? NSRegularExpression(pattern: "\\\\" + name + #"\*?(?:\[[^\]]*\])?\{"#).firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return balanced(from: NSMaxRange(m.range), in: ns)
        }
        return balanced(from: NSMaxRange(r), in: ns)
    }

    /// Text from `start` up to the brace that closes the one just before it.
    public static func balanced(from start: Int, in ns: NSString) -> String? {
        var depth = 1
        var i = start
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 92 { i += 2; continue }
            if c == 123 { depth += 1 } else if c == 125 { depth -= 1; if depth == 0 { return ns.substring(with: NSRange(location: start, length: i - start)) } }
            i += 1
        }
        return nil
    }

}
