import Foundation

public enum Fuzzy {
    /// Subsequence match score (higher is better), nil when `query` isn't a subsequence of `candidate`.
    /// Rewards consecutive runs, word starts and prefix matches, like Xcode's Open Quickly.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased()), c = Array(candidate.lowercased()), orig = Array(candidate)
        var qi = 0, score = 0, run = 0
        var prevMatched = -2
        for (i, ch) in c.enumerated() where qi < q.count {
            guard ch == q[qi] else { run = 0; continue }
            var s = 1
            if i == prevMatched + 1 { run += 1; s += 4 * run } else {
                run = 0
                // Gaps between matched characters cost a little, so "sec" prefers "Section" over "Show Caret".
                if prevMatched >= 0 { s -= min(i - prevMatched - 1, 6) }
            }
            if i == 0 { s += 8 }
            else {
                let p = orig[i - 1]
                if p == " " || p == "/" || p == "_" || p == "-" || p == "." || p == "\\" || p == "{" || (orig[i].isUppercase && p.isLowercase) { s += 6 }
            }
            score += s
            prevMatched = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score - (c.count - q.count) / 4
    }

    /// Ranges (character offsets) of matched characters, for bolding results.
    public static func matchedIndices(_ query: String, _ candidate: String) -> [Int] {
        let q = Array(query.lowercased()), c = Array(candidate.lowercased())
        var qi = 0
        var out: [Int] = []
        for (i, ch) in c.enumerated() where qi < q.count && ch == q[qi] { out.append(i); qi += 1 }
        return qi == q.count ? out : []
    }
}

/// Line diff for version history (Myers via CollectionDifference).
public enum LineDiff {
    public enum Kind: Sendable { case same, added, removed }
    public struct Line: Identifiable, Sendable {
        public var id: Int
        public var kind: Kind
        public var text: String
        public var oldNumber: Int?
        public var newNumber: Int?
    }

    public static func diff(old: String, new: String) -> [Line] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        let d = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in d {
            switch change {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var out: [Line] = []
        var i = 0, j = 0, id = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                out.append(Line(id: id, kind: .removed, text: a[i], oldNumber: i + 1)); i += 1
            } else if j < b.count, inserted.contains(j) {
                out.append(Line(id: id, kind: .added, text: b[j], newNumber: j + 1)); j += 1
            } else if i < a.count, j < b.count {
                out.append(Line(id: id, kind: .same, text: b[j], oldNumber: i + 1, newNumber: j + 1)); i += 1; j += 1
            } else { break }
            id += 1
        }
        return out
    }

    /// Only the changed lines with `context` unchanged lines around them; gaps become nil separators.
    public static func hunks(_ lines: [Line], context: Int = 2) -> [Line?] {
        let changed = lines.indices.filter { lines[$0].kind != .same }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for c in changed { for k in max(0, c - context)...min(lines.count - 1, c + context) { keep.insert(k) } }
        var out: [Line?] = []
        var last = -1
        for k in keep.sorted() {
            if last >= 0 && k != last + 1 { out.append(nil) }
            out.append(lines[k]); last = k
        }
        return out
    }
}
