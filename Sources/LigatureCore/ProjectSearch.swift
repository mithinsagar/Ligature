import Foundation

/// Find (and replace) across a project's files: plain text or regular expressions, optionally case-sensitive
/// and whole-word.
public enum ProjectSearch {
    public struct Options: Equatable, Sendable {
        public var caseSensitive = false
        public var regex = false
        public var wholeWord = false
        public init(caseSensitive: Bool = false, regex: Bool = false, wholeWord: Bool = false) {
            self.caseSensitive = caseSensitive; self.regex = regex; self.wholeWord = wholeWord
        }
    }

    public struct Match: Equatable, Sendable, Identifiable {
        public var id: String { "\(file):\(range.location)" }
        public let file: String
        public let line: Int
        /// The match in the file (UTF-16).
        public let range: NSRange
        /// The whole line, and the match within it.
        public let lineText: String
        public let rangeInLine: NSRange
    }

    /// The compiled pattern, or nil (with a reason) when the regex is invalid.
    public static func expression(_ query: String, _ o: Options) -> Result<NSRegularExpression, Error> {
        var pattern = o.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if o.wholeWord { pattern = "(?<![\\p{L}\\p{N}_])(?:" + pattern + ")(?![\\p{L}\\p{N}_])" }
        do {
            return .success(try NSRegularExpression(pattern: pattern, options: o.caseSensitive ? [] : [.caseInsensitive]))
        } catch {
            return .failure(error)
        }
    }

    public static func find(_ query: String, in text: String, file: String, options o: Options, limit: Int = 2000) -> [Match] {
        guard !query.isEmpty, case .success(let re) = expression(query, o) else { return [] }
        let ns = text as NSString
        var out: [Match] = []
        var lineNo = 1, lineStart = 0, scanned = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
            // Advance the line counter up to the match.
            while true {
                let nl = ns.range(of: "\n", range: NSRange(location: scanned, length: max(0, m.range.location - scanned)))
                if nl.location == NSNotFound { break }
                lineNo += 1
                lineStart = nl.location + 1
                scanned = lineStart
            }
            scanned = max(scanned, lineStart)
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            var lineText = ns.substring(with: lineRange)
            if lineText.hasSuffix("\n") { lineText.removeLast() }
            let inLine = NSRange(location: m.range.location - lineStart, length: min(m.range.length, (lineText as NSString).length - (m.range.location - lineStart)))
            out.append(Match(file: file, line: lineNo, range: m.range, lineText: lineText, rangeInLine: inLine))
            if out.count >= limit { break }
        }
        return out
    }

    /// The text with every match (or only `only`, if given) replaced. With regex on, `$1`… refer to groups.
    public static func replace(_ query: String, with replacement: String, in text: String, options o: Options, only: [NSRange]? = nil) -> (text: String, count: Int) {
        guard !query.isEmpty, case .success(let re) = expression(query, o) else { return (text, 0) }
        let ns = text as NSString
        let template = o.regex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        let keep = only.map(Set.init)
        let out = NSMutableString(string: text)
        var count = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() where m.range.length > 0 {
            if let keep, !keep.contains(m.range) { continue }
            let rep = re.replacementString(for: m, in: text, offset: 0, template: template)
            out.replaceCharacters(in: m.range, with: rep)
            count += 1
        }
        return (out as String, count)
    }
}

extension NSRange: @retroactive Hashable {
    public func hash(into h: inout Hasher) { h.combine(location); h.combine(length) }
}
