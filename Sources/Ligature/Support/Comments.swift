import Foundation
import AppKit
import CryptoKit

/// A comment on a stretch of a file, with replies, like a review comment in a word processor. Kept in
/// Application Support (never inside the project), so the project stays plain LaTeX.
struct Comment: Codable, Identifiable, Equatable {
    struct Reply: Codable, Identifiable, Equatable {
        var id = UUID()
        var author: String
        var date: Date
        var text: String
    }

    var id = UUID()
    var file: String
    /// Where it was last known to be, and the text it was attached to (used to find it again after edits
    /// made outside the app).
    var location: Int
    var length: Int
    var quote: String
    var author: String
    var date: Date
    var text: String
    var resolved = false
    var replies: [Reply] = []
    /// The commented text was deleted.
    var orphaned = false
}

enum CommentStore {
    static func url(for root: URL) -> URL {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ligature/Comments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(digest).json")
    }

    static func load(root: URL) -> [Comment] {
        guard let data = try? Data(contentsOf: url(for: root)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Comment].self, from: data)) ?? []
    }

    static func save(_ comments: [Comment], root: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(comments) { try? data.write(to: url(for: root), options: .atomic) }
    }

    /// Finds where a comment's text is now: its old place if unchanged, else the nearest copy of the quote.
    static func locate(_ c: Comment, in text: String) -> NSRange? {
        let ns = text as NSString
        let old = NSRange(location: c.location, length: c.length)
        if NSMaxRange(old) <= ns.length, ns.substring(with: old) == c.quote { return old }
        guard !c.quote.isEmpty else { return nil }
        var best: NSRange?
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: c.quote, options: [], range: search)
            if r.location == NSNotFound { break }
            if best == nil || abs(r.location - c.location) < abs(best!.location - c.location) { best = r }
            search = NSRange(location: NSMaxRange(r), length: ns.length - NSMaxRange(r))
        }
        return best
    }
}

/// Live positions of comments in open documents, kept in step with every edit (like folds).
@MainActor
enum CommentAnchors {
    private static var ranges: [ObjectIdentifier: [UUID: NSRange]] = [:]

    static func all(_ storage: NSTextStorage) -> [UUID: NSRange] { ranges[ObjectIdentifier(storage)] ?? [:] }
    static func set(_ id: UUID, _ r: NSRange?, in storage: NSTextStorage) { ranges[ObjectIdentifier(storage), default: [:]][id] = r }

    /// Shifts comments after an edit; an edit inside a comment grows or shrinks it; deleting all of it empties it.
    static func adjust(_ storage: NSTextStorage, edited: NSRange, delta: Int) {
        guard var list = ranges[ObjectIdentifier(storage)], !list.isEmpty else { return }
        let oldEnd = NSMaxRange(edited) - delta
        for (id, r) in list {
            if NSMaxRange(r) <= edited.location { continue }
            if r.location >= oldEnd { list[id] = NSRange(location: r.location + delta, length: r.length); continue }
            // Overlap: keep what survives.
            let start = min(r.location, edited.location)
            let end = max(NSMaxRange(r) + delta, start)
            list[id] = NSRange(location: start, length: max(0, end - start))
        }
        ranges[ObjectIdentifier(storage)] = list
    }
}
