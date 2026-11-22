import AppKit

/// Which regions of each open document are folded in the code view. Ranges are kept in step with edits; an
/// edit that touches a fold unfolds it.
@MainActor
enum FoldStore {
    private static var folds: [ObjectIdentifier: [NSRange]] = [:]

    static func folds(_ storage: NSTextStorage) -> [NSRange] { folds[ObjectIdentifier(storage)] ?? [] }

    static func isFolded(_ range: NSRange, in storage: NSTextStorage) -> Bool { folds(storage).contains(range) }

    static func fold(_ range: NSRange, in storage: NSTextStorage) {
        var list = folds(storage).filter { NSIntersectionRange($0, range).length == 0 }
        list.append(range)
        folds[ObjectIdentifier(storage)] = list
    }

    static func unfold(_ range: NSRange, in storage: NSTextStorage) {
        folds[ObjectIdentifier(storage)] = folds(storage).filter { $0 != range }
    }

    /// Unfolds whatever contains `location` (the caret moved inside). Returns true if anything changed.
    @discardableResult
    static func unfold(containing location: Int, in storage: NSTextStorage) -> Bool {
        let list = folds(storage)
        let kept = list.filter { !(location > $0.location && location <= NSMaxRange($0)) }
        guard kept.count != list.count else { return false }
        folds[ObjectIdentifier(storage)] = kept
        return true
    }

    static func unfoldAll(in storage: NSTextStorage) { folds[ObjectIdentifier(storage)] = nil }

    /// Keeps folds in place after an edit (`edited` is the range after the edit, `delta` the change in length).
    static func adjust(_ storage: NSTextStorage, edited: NSRange, delta: Int) {
        let list = folds(storage)
        guard !list.isEmpty else { return }
        let oldEnd = NSMaxRange(edited) - delta
        folds[ObjectIdentifier(storage)] = list.compactMap { f in
            if NSMaxRange(f) < edited.location { return f }
            if f.location > oldEnd { return NSRange(location: f.location + delta, length: f.length) }
            return nil
        }
    }
}
