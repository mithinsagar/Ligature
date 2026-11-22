import Foundation

/// One problem reported by a compile: an error, a warning or a bad box, tied to a file and line when TeX said where.
public struct CompileIssue: Identifiable, Hashable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        case error = 0, warning = 1, badBox = 2
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: String { "\(severity.rawValue)|\(file ?? "")|\(line ?? 0)|\(message)" }
    public var severity: Severity
    /// Path relative to the project root when it could be resolved, else as TeX printed it.
    public var file: String?
    public var line: Int?
    public var message: String
    /// The source snippet TeX showed after "l.<n>", used to find the offending command.
    public var context: String?
    /// 1-based column and length of the offending text, when known (the live checker knows; TeX doesn't).
    public var column: Int?
    public var length: Int?
    /// Found by the as-you-type checker rather than a compile.
    public var isLive = false

    public init(severity: Severity, file: String?, line: Int?, message: String, context: String? = nil, column: Int? = nil, length: Int? = nil, isLive: Bool = false) {
        self.severity = severity; self.file = file; self.line = line; self.message = message; self.context = context
        self.column = column; self.length = length; self.isLive = isLive
    }
}

/// Reads Tectonic's stderr and the TeX `.log` into a de-duplicated, ordered issue list.
public enum LogParser {
    public static func parse(stderr: String, log: String?, mainFile: String) -> [CompileIssue] {
        var issues: [CompileIssue] = []
        var seen = Set<String>()
        func add(_ i: CompileIssue) {
            let key = "\(i.severity.rawValue)|\(i.line ?? -1)|\(i.message.prefix(80))"
            if seen.insert(key).inserted { issues.append(i) }
        }

        // Tectonic: "error: chapters/intro.tex:12: Undefined control sequence"
        for raw in stderr.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            for (prefix, sev) in [("error: ", CompileIssue.Severity.error), ("warning: ", .warning)] where line.hasPrefix(prefix) {
                let body = String(line.dropFirst(prefix.count))
                if let m = fileLineMessage(body) {
                    add(CompileIssue(severity: sev, file: m.file, line: m.line, message: m.message))
                }
            }
        }

        guard let log else { return sorted(issues) }
        let lines = log.components(separatedBy: "\n")
        var fileStack: [String] = [mainFile]
        var i = 0
        while i < lines.count {
            let l = lines[i]
            trackFiles(l, stack: &fileStack)

            if l.hasPrefix("! ") {
                // "! Undefined control sequence." followed (soon) by "l.12 the offending \foo"
                var message = String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if message.hasSuffix(".") { message.removeLast() }
                var lineNo: Int?
                var context: String?
                var j = i + 1
                while j < min(lines.count, i + 12) {
                    let n = lines[j]
                    if n.hasPrefix("l."), let sp = n.firstIndex(of: " ") ?? Optional(n.endIndex) {
                        lineNo = Int(n[n.index(n.startIndex, offsetBy: 2)..<sp])
                        context = String(n[sp...]).trimmingCharacters(in: .whitespaces)
                        break
                    }
                    if n.hasPrefix("! ") { break }
                    j += 1
                }
                let file = current(fileStack)
                // Prefer to enrich the stderr version (which has the right file) with the context.
                if let k = issues.firstIndex(where: { $0.severity == .error && $0.line == lineNo && $0.message.hasPrefix(message.prefix(20)) }) {
                    if issues[k].context == nil { issues[k].context = context }
                } else {
                    add(CompileIssue(severity: .error, file: file, line: lineNo, message: message, context: context))
                }
            } else if l.contains("Warning:") && (l.hasPrefix("LaTeX Warning:") || l.hasPrefix("Package ") || l.hasPrefix("Class ") || l.hasPrefix("LaTeX Font Warning:")) {
                // Warnings may wrap over continuation lines that start with "(pkg)" or spaces.
                var text = l
                var j = i + 1
                while j < lines.count, !lines[j].isEmpty, lines[j].hasPrefix("(") || lines[j].hasPrefix("    ") {
                    let cont = lines[j].replacingOccurrences(of: #"^\([A-Za-z0-9@\-]+\)\s*"#, with: "", options: .regularExpression)
                    text += " " + cont.trimmingCharacters(in: .whitespaces)
                    j += 1
                }
                // TeX hard-wraps log lines at 79 columns.
                var k = j - 1
                while lines[k].count >= 79, k + 1 < lines.count, !lines[k + 1].isEmpty {
                    text += lines[k + 1]; k += 1; j = k + 1
                }
                let message = text
                    .replacingOccurrences(of: #"^(LaTeX|LaTeX Font|Package [^ ]+|Class [^ ]+) Warning:\s*"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                let lineNo = firstInt(after: "input line ", in: text)
                // Font substitutions are typographic notes, like bad boxes, not problems with the source.
                let severity: CompileIssue.Severity = l.hasPrefix("LaTeX Font Warning:") ? .badBox : .warning
                // "input line N" refers to whatever file is open; if that's a package, the line isn't the user's.
                let inProject = fileStack.last != "\u{0}"
                add(CompileIssue(severity: severity, file: lineNo == nil || !inProject ? nil : current(fileStack), line: inProject ? lineNo : nil,
                                 message: message.hasSuffix(".") ? String(message.dropLast()) : message))
                i = max(i, j - 1)
            } else if l.hasPrefix("Overfull \\hbox") || l.hasPrefix("Underfull \\hbox") || l.hasPrefix("Overfull \\vbox") || l.hasPrefix("Underfull \\vbox") {
                let lineNo = firstInt(after: "at lines ", in: l) ?? firstInt(after: "at line ", in: l)
                let msg = l.components(separatedBy: " in paragraph").first?
                    .components(separatedBy: " detected at").first?
                    .components(separatedBy: " has occurred").first ?? l
                let inProject = fileStack.last != "\u{0}"
                add(CompileIssue(severity: .badBox, file: inProject ? current(fileStack) : nil, line: inProject ? lineNo : nil, message: msg))
            }
            i += 1
        }
        return sorted(issues)
    }

    static func sorted(_ issues: [CompileIssue]) -> [CompileIssue] {
        issues.enumerated().sorted { a, b in
            if a.element.severity != b.element.severity { return a.element.severity < b.element.severity }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// "path/file.tex:12: message" → parts. Paths may contain spaces but not ':' followed by digits.
    /// Tectonic names files as they were \input, so "sections/results:12:" means sections/results.tex.
    static func fileLineMessage(_ s: String) -> (file: String, line: Int, message: String)? {
        let re = try! NSRegularExpression(pattern: #"^([^:]+?(\.(?:tex|sty|cls|bib|ltx|dtx|bbl|aux))?):(\d+):\s*(.*)$"#)
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              let n = Int(ns.substring(with: m.range(at: 3))) else { return nil }
        let message = ns.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)
        // XeTeX font-loading chatter and empty continuation lines are not problems.
        if message.isEmpty || message.hasPrefix("Requested font") || message.hasPrefix("-> ") { return nil }
        let file = ns.substring(with: m.range(at: 1)) + (m.range(at: 2).location == NSNotFound ? ".tex" : "")
        return (file, n, message.hasSuffix(".") ? String(message.dropLast()) : message)
    }

    static func firstInt(after marker: String, in s: String) -> Int? {
        guard let r = s.range(of: marker) else { return nil }
        let digits = s[r.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// TeX prints "(./chapters/intro.tex" when it opens a file and ")" when it closes one. Good enough to
    /// attribute log-only issues to the right file in multi-file projects.
    static func trackFiles(_ line: String, stack: inout [String]) {
        var idx = line.startIndex
        while idx < line.endIndex {
            let c = line[idx]
            if c == "(" {
                let rest = line[line.index(after: idx)...]
                let name = rest.prefix { !$0.isWhitespace && $0 != ")" && $0 != "(" }
                if name.hasSuffix(".tex") || name.hasSuffix(".ltx") {
                    var n = String(name)
                    if n.hasPrefix("./") { n.removeFirst(2) }
                    stack.append(n)
                } else {
                    stack.append("\u{0}")  // some other file (sty, cls, fd): keep balance
                }
                idx = line.index(idx, offsetBy: max(1, name.count + 1), limitedBy: line.endIndex) ?? line.endIndex
                continue
            } else if c == ")" {
                if stack.count > 1 { stack.removeLast() }
            }
            idx = line.index(after: idx)
        }
    }

    /// The innermost open .tex file (other kinds of files are kept on the stack as placeholders).
    static func current(_ stack: [String]) -> String? { stack.last { $0 != "\u{0}" } }
}
