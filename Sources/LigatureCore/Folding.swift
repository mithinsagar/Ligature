import Foundation

/// The regions of a LaTeX file that can be folded: environments spanning several lines, sections (up to the
/// next heading of the same or higher level), and the preamble.
public enum Folding {
    public struct Region: Equatable, Sendable {
        /// 1-based line the fold starts on (it stays visible).
        public let startLine: Int
        public let endLine: Int
        /// What collapses: from the end of the start line up to the end of the last line (not its newline).
        public let range: NSRange
    }

    static let headingLevels: [String: Int] = ["part": 0, "chapter": 1, "section": 2, "subsection": 3, "subsubsection": 4, "paragraph": 5]

    public static func regions(in text: String) -> [Region] {
        let ns = text as NSString
        var lines: [NSRange] = []   // content ranges, no newline
        var start = 0
        while start <= ns.length {
            let r = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
            let end = r.location == NSNotFound ? ns.length : r.location
            lines.append(NSRange(location: start, length: end - start))
            if r.location == NSNotFound { break }
            start = end + 1
        }
        var out: [Region] = []
        func region(_ a: Int, _ b: Int) {
            guard b > a, a >= 1, b <= lines.count else { return }
            let from = NSMaxRange(lines[a - 1])
            let to = NSMaxRange(lines[b - 1])
            guard to > from else { return }
            out.append(Region(startLine: a, endLine: b, range: NSRange(location: from, length: to - from)))
        }
        let envRE = try! NSRegularExpression(pattern: #"\\(begin|end)\{([^}]+)\}"#)
        let headRE = try! NSRegularExpression(pattern: #"^\s*\\(part|chapter|section|subsection|subsubsection|paragraph)\*?[\[{]"#)
        var stack: [(String, Int)] = []
        var heads: [(level: Int, line: Int)] = []
        var docLine: Int?
        var endDocLine: Int?
        for (idx, lr) in lines.enumerated() {
            let lineNo = idx + 1
            var line = ns.substring(with: lr)
            if let c = LaTeXText.commentStart(inLine: line as NSString) { line = (line as NSString).substring(to: c) }
            let lns = line as NSString
            for m in envRE.matches(in: line, range: NSRange(location: 0, length: lns.length)) {
                let kind = lns.substring(with: m.range(at: 1)), name = lns.substring(with: m.range(at: 2))
                if name == "document" {
                    if kind == "begin" { docLine = lineNo } else { endDocLine = lineNo }
                    continue
                }
                if kind == "begin" { stack.append((name, lineNo)) }
                else if let i = stack.lastIndex(where: { $0.0 == name }) {
                    region(stack[i].1, lineNo)
                    stack.removeSubrange(i...)
                }
            }
            if let m = headRE.firstMatch(in: line, range: NSRange(location: 0, length: lns.length)) {
                heads.append((headingLevels[lns.substring(with: m.range(at: 1))] ?? 2, lineNo))
            }
        }
        // Sections run until the next heading at the same or a higher level, minus trailing blank lines.
        let lastBody = (endDocLine.map { $0 - 1 }) ?? lines.count
        for (i, h) in heads.enumerated() {
            var end = heads[(i + 1)...].first(where: { $0.level <= h.level })?.line.advanced(by: -1) ?? lastBody
            while end > h.line, ns.substring(with: lines[end - 1]).trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            region(h.line, end)
        }
        if let d = docLine, d > 2 { region(1, d - 1) }
        // One region per start line: keep the largest.
        var best: [Int: Region] = [:]
        for r in out where (best[r.startLine]?.range.length ?? -1) < r.range.length { best[r.startLine] = r }
        return best.values.sorted { $0.startLine < $1.startLine }
    }
}
