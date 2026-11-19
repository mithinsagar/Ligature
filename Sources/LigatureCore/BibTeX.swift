import Foundation

public struct BibEntry: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public var type: String
    public var key: String
    public var fields: [String: String]
    public var file: String
    public var line: Int

    public var title: String { BibTeX.clean(fields["title"] ?? "") }
    public var year: String { fields["year"] ?? (fields["date"].map { String($0.prefix(4)) } ?? "") }
    public var venue: String { BibTeX.clean(fields["journal"] ?? fields["booktitle"] ?? fields["publisher"] ?? fields["eprinttype"].map { "\($0) \(fields["eprint"] ?? "")" } ?? "") }
    /// "Vaswani, Shazeer et al." style.
    public var authorsShort: String {
        let names = (fields["author"] ?? fields["editor"] ?? "").components(separatedBy: " and ").map { BibTeX.lastName(BibTeX.clean($0)) }.filter { !$0.isEmpty }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) & \(names[1])"
        default: return "\(names[0]) et al."
        }
    }
}

public enum BibTeX {
    /// Tolerant parser: handles nested braces, quoted values, `#` concatenation of simple parts and @string macros
    /// are ignored. Skips @comment/@preamble/@string.
    public static func parse(_ text: String, file: String) -> [BibEntry] {
        let s = Array(text.utf16)
        var entries: [BibEntry] = []
        var i = 0
        var line = 1
        func peek(_ k: Int = 0) -> UInt16? { i + k < s.count ? s[i + k] : nil }
        func advance() { if s[i] == 10 { line += 1 }; i += 1 }
        func skipSpace() { while let c = peek(), c == 32 || c == 9 || c == 10 || c == 13 { advance() } }
        func readWord() -> String {
            var out: [UInt16] = []
            while let c = peek(), !(c == 44 || c == 61 || c == 123 || c == 125 || c == 40 || c == 41 || c == 32 || c == 10 || c == 9 || c == 13 || c == 35 || c == 34) {
                out.append(c); advance()
            }
            return String(utf16CodeUnits: out, count: out.count)
        }
        func readBraced() -> String {
            // at "{"
            var depth = 0
            var out: [UInt16] = []
            while let c = peek() {
                if c == 123 { depth += 1; if depth > 1 { out.append(c) } }
                else if c == 125 { depth -= 1; if depth == 0 { advance(); break }; out.append(c) }
                else { out.append(c) }
                advance()
            }
            return String(utf16CodeUnits: out, count: out.count)
        }
        func readQuoted() -> String {
            advance() // "
            var depth = 0
            var out: [UInt16] = []
            while let c = peek() {
                if c == 123 { depth += 1 } else if c == 125 { depth -= 1 }
                if c == 34 && depth == 0 { advance(); break }
                out.append(c); advance()
            }
            return String(utf16CodeUnits: out, count: out.count)
        }

        while i < s.count {
            guard s[i] == 64 /* @ */ else { advance(); continue }
            let entryLine = line
            advance()
            let type = readWord().lowercased()
            skipSpace()
            guard let open = peek(), open == 123 || open == 40 else { continue }
            if ["comment", "preamble", "string"].contains(type) { _ = readBraced(); continue }
            advance()
            skipSpace()
            let key = readWord().trimmingCharacters(in: .whitespaces)
            var fields: [String: String] = [:]
            while let c = peek() {
                if c == 125 || c == 41 { advance(); break }
                if c == 44 || c == 32 || c == 10 || c == 9 || c == 13 { advance(); continue }
                let name = readWord().lowercased()
                skipSpace()
                guard peek() == 61 else { if name.isEmpty { advance() }; continue }
                advance(); skipSpace()
                var value = ""
                while true {
                    skipSpace()
                    if peek() == 123 { value += readBraced() }
                    else if peek() == 34 { value += readQuoted() }
                    else { value += readWord() }
                    skipSpace()
                    if peek() == 35 { advance(); continue }  // # concatenation
                    break
                }
                if !name.isEmpty { fields[name] = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
            }
            if !key.isEmpty { entries.append(BibEntry(type: type, key: key, fields: fields, file: file, line: entryLine)) }
        }
        return entries
    }

    /// Removes braces and the common accent commands for display.
    public static func clean(_ s: String) -> String {
        var t = s
        let accents: [String: String] = [#"\"a"#: "ä", #"\"o"#: "ö", #"\"u"#: "ü", #"\'e"#: "é", #"\`e"#: "è", #"\'a"#: "á", #"\~n"#: "ñ", #"\c c"#: "ç", #"\ss"#: "ß", #"\&"#: "&", "--": "–"]
        for (k, v) in accents { t = t.replacingOccurrences(of: k, with: v) }
        t = t.replacingOccurrences(of: #"\\[A-Za-z]+\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[{}]"#, with: "", options: .regularExpression)
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// "Vaswani, Ashish" → "Vaswani"; "Ashish Vaswani" → "Vaswani".
    public static func lastName(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if let comma = n.firstIndex(of: ",") { return String(n[..<comma]).trimmingCharacters(in: .whitespaces) }
        return n.split(separator: " ").last.map(String.init) ?? n
    }

    /// Formats an entry back to BibTeX (used for entries fetched from arXiv).
    public static func format(type: String, key: String, fields: [(String, String)]) -> String {
        let width = (fields.map(\.0.count).max() ?? 0)
        let body = fields.map { "  \($0.0.padding(toLength: width, withPad: " ", startingAt: 0)) = {\($0.1)}" }.joined(separator: ",\n")
        return "@\(type){\(key),\n\(body)\n}\n"
    }

    /// A readable citation key like "vaswani2017attention" from an author, year and title.
    public static func suggestKey(author: String, year: String, title: String) -> String {
        let last = lastName(clean(author.components(separatedBy: " and ").first ?? author)).lowercased()
            .folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter }
        let stop: Set<String> = ["a", "an", "the", "on", "of", "for", "in", "and", "to", "with", "towards", "toward", "is", "are"]
        let word = clean(title).lowercased().split { !$0.isLetter }.map(String.init).first { !stop.contains($0) } ?? ""
        return (last.isEmpty ? "ref" : last) + year + word
    }
}
