import AppKit

/// Vim keybindings for the editor: normal, insert, visual and visual-line modes with the everyday motions
/// (h j k l w b e 0 ^ $ gg G { }), operators (d c y with motions, dd cc yy, x X D C s S J r ~ p P), counts,
/// undo/redo, and search through the find bar (/ n N). Yanks go to Vim's own register, not the clipboard.
@MainActor
final class VimEngine {
    enum Mode: String { case insert = "INSERT", normal = "NORMAL", visual = "VISUAL", visualLine = "VISUAL LINE" }

    weak var tv: LaTeXTextView?
    var mode: Mode = .normal { didSet { tv?.needsDisplay = true; onModeChange?(mode) } }
    var onModeChange: ((Mode) -> Void)?
    /// ":" (go to line) is handed to the window.
    var onCommandLine: (() -> Void)?

    private var count = ""
    private var pending = ""
    private var register = ""
    private var registerLinewise = false
    private var anchor = 0

    init(textView: LaTeXTextView) { tv = textView }

    private var ns: NSString { (tv?.string ?? "") as NSString }
    private var loc: Int { tv?.selectedRange().location ?? 0 }
    private var n: Int { max(1, Int(count) ?? 1) }

    // MARK: Keys

    /// Returns true if the key was handled (and shouldn't reach the text view).
    func handle(_ event: NSEvent) -> Bool {
        guard let tv else { return false }
        let ctrl = event.modifierFlags.contains(.control)
        let cmd = event.modifierFlags.contains(.command)
        if cmd { return false }   // menu shortcuts keep working in every mode
        let isEsc = event.keyCode == 53 || (ctrl && event.charactersIgnoringModifiers == "[")

        if mode == .insert {
            guard isEsc else { return false }
            if tv.latexDelegate?.textViewCompletionKey(tv, .dismiss) == true { return true }
            mode = .normal
            let line = ns.lineRange(for: NSRange(location: loc, length: 0))
            if loc > line.location { place(loc - 1) }
            return true
        }
        if isEsc { count = ""; pending = ""; if mode != .normal { exitVisual() }; return true }
        guard let ch = event.characters, !ch.isEmpty else { return true }
        if ctrl {
            switch event.charactersIgnoringModifiers {
            case "r": for _ in 0..<n { tv.undoManager?.redo() }; count = ""
            case "d": for _ in 0..<12 { tv.moveDown(nil) }
            case "u": for _ in 0..<12 { tv.moveUp(nil) }
            default: break
            }
            return true
        }
        // Arrow keys behave as h j k l.
        switch event.keyCode {
        case 123: return key("h")
        case 124: return key("l")
        case 125: return key("j")
        case 126: return key("k")
        default: return key(ch)
        }
    }

    private func key(_ k: String) -> Bool {
        // Counts (0 alone is a motion).
        if let d = Int(k), (d > 0 || !count.isEmpty), pending != "r" { count += k; return true }
        if pending == "r" { replaceChar(k); return true }
        // "gg", or an operator followed by "gg" (dgg, ygg, cgg).
        if pending.hasSuffix("g") {
            pending = String(pending.dropLast())
            if k == "g" { motionThenAct(.lineTop(Int(count))) } else { pending = "" }
            count = ""
            return true
        }

        switch k {
        case "h": motionThenAct(.left)
        case "l": motionThenAct(.right)
        case "j": motionThenAct(.down)
        case "k": motionThenAct(.up)
        case "w": motionThenAct(.wordForward)
        case "b": motionThenAct(.wordBack)
        case "e": motionThenAct(.wordEnd)
        case "0": motionThenAct(.lineStart)
        case "^": motionThenAct(.firstNonBlank)
        case "$": motionThenAct(.lineEnd)
        case "G": motionThenAct(.lineBottom(Int(count)))
        case "}": motionThenAct(.paragraphForward)
        case "{": motionThenAct(.paragraphBack)
        case "g": pending = (["d", "c", "y"].contains(pending) ? pending : "") + "g"; return true
        case "d", "c", "y":
            if mode == .visual || mode == .visualLine { operate(k, on: visualRange(), linewise: mode == .visualLine); exitVisual(); break }
            if pending == k { linewiseOp(k) } else { pending = k; return true }
        case "x": if mode != .normal { operate("d", on: visualRange(), linewise: mode == .visualLine); exitVisual() } else { charOp("d", forward: true) }
        case "X": charOp("d", forward: false)
        case "s": charOp("c", forward: true)
        case "S": linewiseOp("c")
        case "D": operate("d", on: NSRange(location: loc, length: lineEnd(loc) - loc), linewise: false)
        case "C": operate("c", on: NSRange(location: loc, length: lineEnd(loc) - loc), linewise: false)
        case "p": paste(after: true)
        case "P": paste(after: false)
        case "u": for _ in 0..<n { tv?.undoManager?.undo() }
        case "J": joinLines()
        case "r": pending = "r"; return true
        case "~": toggleCase()
        case "i": enterInsert(at: mode == .normal ? loc : visualRange().location)
        case "a": enterInsert(at: min(lineEnd(loc), loc + 1))
        case "I": enterInsert(at: firstNonBlank(loc))
        case "A": enterInsert(at: lineEnd(loc))
        case "o": openLine(below: true)
        case "O": openLine(below: false)
        case "v": if mode == .visual { exitVisual() } else { anchor = loc; mode = .visual; updateVisual(loc) }
        case "V": if mode == .visualLine { exitVisual() } else { anchor = loc; mode = .visualLine; updateVisual(loc) }
        case ">", "<": shift(k == ">")
        case "/": find(.showFindInterface)
        case "n": find(.nextMatch)
        case "N": find(.previousMatch)
        case ":": onCommandLine?()
        default: break
        }
        count = ""
        return true
    }

    // MARK: Motions

    enum Motion { case left, right, down, up, wordForward, wordBack, wordEnd, lineStart, firstNonBlank, lineEnd, lineTop(Int?), lineBottom(Int?), paragraphForward, paragraphBack
        var linewise: Bool { switch self { case .down, .up, .lineTop, .lineBottom: true; default: false } }
        var inclusive: Bool { switch self { case .wordEnd, .lineEnd: true; default: false } }
    }

    private func target(_ m: Motion, from start: Int, times: Int) -> Int {
        var p = start
        for _ in 0..<(isAbsolute(m) ? 1 : times) {
            switch m {
            case .left: p = max(lineStart(p), p - 1)
            case .right: p = min(max(lineStart(p), lineEnd(p) - (mode == .normal && pending.isEmpty ? 1 : 0)), p + 1)
            case .down, .up: p = verticalMove(p, down: { if case .down = m { return true }; return false }())
            case .wordForward: p = nextWordStart(p)
            case .wordBack: p = prevWordStart(p)
            case .wordEnd: p = wordEnd(p)
            case .lineStart: p = lineStart(p)
            case .firstNonBlank: p = firstNonBlank(p)
            case .lineEnd: p = max(lineStart(p), lineEnd(p) - 1)
            case .lineTop(let line): p = lineStartOf(line ?? 1)
            case .lineBottom(let line): p = line.map { lineStartOf($0) } ?? lineStart(ns.length)
            case .paragraphForward: p = paragraphMove(p, forward: true)
            case .paragraphBack: p = paragraphMove(p, forward: false)
            }
        }
        return p
    }

    private func isAbsolute(_ m: Motion) -> Bool { switch m { case .lineTop, .lineBottom, .lineStart, .firstNonBlank: true; default: false } }

    private func motionThenAct(_ m: Motion) {
        let to = target(m, from: loc, times: n)
        if ["d", "c", "y"].contains(pending) {
            let op = pending
            pending = ""
            if m.linewise {
                let a = ns.lineRange(for: NSRange(location: min(loc, to), length: 0)).location
                let b = NSMaxRange(ns.lineRange(for: NSRange(location: max(loc, to), length: 0)))
                operate(op, on: NSRange(location: a, length: b - a), linewise: true)
            } else {
                var a = min(loc, to), b = max(loc, to)
                if m.inclusive { b = min(ns.length, b + 1) }
                // "cw" changes to the end of the word, not the start of the next.
                if op == "c", case .wordForward = m { b = min(b, wordEnd(loc) + 1); a = loc }
                operate(op, on: NSRange(location: a, length: b - a), linewise: false)
            }
            return
        }
        if mode == .visual || mode == .visualLine { updateVisual(to) } else { place(to) }
    }

    // MARK: Operators

    private func operate(_ op: String, on r: NSRange, linewise: Bool) {
        guard let tv, r.length >= 0, NSMaxRange(r) <= ns.length else { return }
        register = ns.substring(with: r)
        registerLinewise = linewise
        switch op {
        case "y":
            place(r.location)
        case "d", "c":
            var del = r
            // Deleting the last line (which has no newline) also takes the newline before it.
            if linewise && op == "d" && NSMaxRange(r) == ns.length && r.location > 0 && !register.hasSuffix("\n") {
                del = NSRange(location: r.location - 1, length: r.length + 1)
                register += "\n"
            }
            if op == "c" && linewise {
                // Keep the line (and its indentation), clear its content.
                let text = ns.substring(with: r)
                let indent = String(text.prefix { $0 == " " || $0 == "\t" })
                let keepNewline = text.hasSuffix("\n") ? 1 : 0
                tv.insertText(indent, replacementRange: NSRange(location: r.location, length: r.length - keepNewline))
                place(r.location + (indent as NSString).length)
                mode = .insert
                return
            }
            tv.insertText("", replacementRange: del)
            if op == "c" { place(del.location); mode = .insert } else { place(min(del.location, max(0, ns.length - 1))); if linewise { place(firstNonBlank(min(del.location, ns.length))) } }
        default: break
        }
    }

    private func linewiseOp(_ op: String) {
        pending = ""
        let first = ns.lineRange(for: NSRange(location: loc, length: 0))
        var end = NSMaxRange(first)
        for _ in 1..<n { if end < ns.length { end = NSMaxRange(ns.lineRange(for: NSRange(location: end, length: 0))) } }
        operate(op, on: NSRange(location: first.location, length: end - first.location), linewise: true)
    }

    private func charOp(_ op: String, forward: Bool) {
        let a = forward ? loc : max(lineStart(loc), loc - n)
        let b = forward ? min(lineEnd(loc), loc + n) : loc
        guard b > a || op == "c" else { return }
        operate(op, on: NSRange(location: a, length: b - a), linewise: false)
    }

    private func paste(after: Bool) {
        guard let tv, !register.isEmpty else { return }
        let text = String(repeating: register, count: n)
        if registerLinewise {
            let line = ns.lineRange(for: NSRange(location: loc, length: 0))
            var at = after ? NSMaxRange(line) : line.location
            var insert = text.hasSuffix("\n") ? text : text + "\n"
            if after && at == ns.length && !(ns.length > 0 && ns.character(at: ns.length - 1) == 10) { insert = "\n" + String(insert.dropLast()); at = ns.length }
            tv.insertText(insert, replacementRange: NSRange(location: at, length: 0))
            place(firstNonBlank(min(at + (insert.hasPrefix("\n") ? 1 : 0), ns.length)))
        } else {
            let at = after ? min(lineEnd(loc), loc + (ns.length > 0 ? 1 : 0)) : loc
            tv.insertText(text, replacementRange: NSRange(location: at, length: 0))
            place(at + (text as NSString).length - 1)
        }
    }

    private func joinLines() {
        guard let tv else { return }
        for _ in 0..<n {
            let end = lineEnd(loc)
            guard end < ns.length else { return }
            var next = end + 1
            while next < ns.length, [32, 9].contains(ns.character(at: next)) { next += 1 }
            tv.insertText(" ", replacementRange: NSRange(location: end, length: next - end))
            place(end)
        }
    }

    private func replaceChar(_ k: String) {
        pending = ""
        guard let tv, loc < lineEnd(loc) else { return }
        let at = loc
        tv.insertText(k, replacementRange: NSRange(location: at, length: 1))
        place(at)
    }

    private func toggleCase() {
        guard let tv, loc < lineEnd(loc) else { return }
        let r = NSRange(location: loc, length: min(n, lineEnd(loc) - loc))
        let s = ns.substring(with: r)
        let flipped = String(s.map { $0.isUppercase ? Character($0.lowercased()) : Character($0.uppercased()) })
        tv.insertText(flipped, replacementRange: r)
        place(min(NSMaxRange(r), max(lineStart(loc), lineEnd(loc) - 1)))
    }

    private func shift(_ right: Bool) {
        guard let tv else { return }
        if mode == .normal { tv.setSelectedRange(ns.lineRange(for: NSRange(location: loc, length: 0))) } else { tv.setSelectedRange(visualRange()) }
        tv.shiftLines(right: right)
        exitVisual()
    }

    private func openLine(below: Bool) {
        guard let tv else { return }
        let line = ns.lineRange(for: NSRange(location: loc, length: 0))
        let indent = String(ns.substring(with: line).prefix { $0 == " " || $0 == "\t" })
        if below {
            let end = lineEnd(loc)
            tv.insertText("\n" + indent, replacementRange: NSRange(location: end, length: 0))
            place(end + 1 + (indent as NSString).length)
        } else {
            tv.insertText(indent + "\n", replacementRange: NSRange(location: line.location, length: 0))
            place(line.location + (indent as NSString).length)
        }
        mode = .insert
    }

    private func enterInsert(at p: Int) {
        if mode != .normal { exitVisual() }
        place(p)
        mode = .insert
    }

    private func find(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        tv?.performTextFinderAction(item)
    }

    // MARK: Visual

    private func visualRange() -> NSRange {
        guard let tv else { return NSRange() }
        return tv.selectedRange()
    }

    private func updateVisual(_ head: Int) {
        guard let tv else { return }
        if mode == .visualLine {
            let a = ns.lineRange(for: NSRange(location: min(anchor, head), length: 0)).location
            let b = NSMaxRange(ns.lineRange(for: NSRange(location: max(anchor, head), length: 0)))
            tv.setSelectedRange(NSRange(location: a, length: b - a))
        } else {
            let a = min(anchor, head), b = min(ns.length, max(anchor, head) + 1)
            tv.setSelectedRange(NSRange(location: a, length: b - a))
        }
        tv.scrollRangeToVisible(NSRange(location: head, length: 0))
    }

    private func exitVisual() {
        let r = visualRange()
        mode = .normal
        place(min(r.location, max(0, ns.length - 1)))
    }

    // MARK: Text geometry

    private func place(_ p: Int) {
        let q = max(0, min(p, ns.length))
        tv?.setSelectedRange(NSRange(location: q, length: 0))
        tv?.scrollRangeToVisible(NSRange(location: q, length: 0))
    }

    private func lineStart(_ p: Int) -> Int { ns.lineRange(for: NSRange(location: min(p, ns.length), length: 0)).location }

    private func lineEnd(_ p: Int) -> Int {
        let r = ns.lineRange(for: NSRange(location: min(p, ns.length), length: 0))
        var e = NSMaxRange(r)
        if e > r.location, e <= ns.length, e > 0, ns.character(at: e - 1) == 10 { e -= 1 }
        return e
    }

    private func firstNonBlank(_ p: Int) -> Int {
        var i = lineStart(p)
        let e = lineEnd(p)
        while i < e, [32, 9].contains(ns.character(at: i)) { i += 1 }
        return i
    }

    private func lineStartOf(_ line: Int) -> Int {
        var l = 1, i = 0
        while l < line, i < ns.length {
            let r = ns.range(of: "\n", range: NSRange(location: i, length: ns.length - i))
            if r.location == NSNotFound { break }
            i = r.location + 1; l += 1
        }
        return firstNonBlank(i)
    }

    private func verticalMove(_ p: Int, down: Bool) -> Int {
        let start = lineStart(p), col = p - start
        if down {
            let end = NSMaxRange(ns.lineRange(for: NSRange(location: p, length: 0)))
            guard end < ns.length || (end == ns.length && end > 0 && ns.character(at: end - 1) == 10 && end != start) else { return p }
            guard end <= ns.length, end != start || p == ns.length else { return p }
            let len = lineEnd(end) - end
            return end + min(col, max(0, len - (pending.isEmpty ? 1 : 0)))
        }
        guard start > 0 else { return p }
        let prev = lineStart(start - 1)
        let len = lineEnd(prev) - prev
        return prev + min(col, max(0, len - (pending.isEmpty ? 1 : 0)))
    }

    private enum CharClass { case space, word, punct }
    private func cls(_ i: Int) -> CharClass {
        guard i < ns.length else { return .space }
        let c = ns.character(at: i)
        if c == 32 || c == 9 || c == 10 { return .space }
        if let u = UnicodeScalar(c), CharacterSet.alphanumerics.contains(u) || c == 95 { return .word }
        return .punct
    }

    private func nextWordStart(_ p: Int) -> Int {
        var i = p
        let start = cls(i)
        if start != .space { while i < ns.length, cls(i) == start { i += 1 } }
        while i < ns.length, cls(i) == .space { i += 1 }
        return min(i, ns.length)
    }

    private func prevWordStart(_ p: Int) -> Int {
        var i = max(0, p - 1)
        while i > 0, cls(i) == .space { i -= 1 }
        let c = cls(i)
        while i > 0, cls(i - 1) == c { i -= 1 }
        return i
    }

    private func wordEnd(_ p: Int) -> Int {
        var i = min(p + 1, ns.length)
        while i < ns.length, cls(i) == .space { i += 1 }
        let c = cls(i)
        while i + 1 < ns.length, cls(i + 1) == c { i += 1 }
        return min(i, max(0, ns.length - 1))
    }

    private func paragraphMove(_ p: Int, forward: Bool) -> Int {
        var line = ns.lineRange(for: NSRange(location: p, length: 0))
        func blank(_ r: NSRange) -> Bool { ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if forward {
            while NSMaxRange(line) < ns.length {
                line = ns.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
                if blank(line) { return line.location }
            }
            return ns.length
        } else {
            while line.location > 0 {
                line = ns.lineRange(for: NSRange(location: line.location - 1, length: 0))
                if blank(line) { return line.location }
            }
            return 0
        }
    }
}
