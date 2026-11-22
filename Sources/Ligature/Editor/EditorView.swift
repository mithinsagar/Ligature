import SwiftUI
import AppKit
import LigatureCore

/// The editor for the project's active document: SwiftUI wrapper around `EditorController`.
struct EditorView: NSViewRepresentable {
    let model: ProjectModel

    func makeNSView(context: Context) -> NSScrollView {
        let controller = EditorController(model: model)
        context.coordinator.controller = controller
        model.editor = controller
        return controller.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let c = context.coordinator.controller
        // Reading these registers observation, so theme/prefs/document changes re-run this.
        let prefs = Preferences.shared
        let signature = "\(ThemeManager.shared.theme.id)|\(ThemeManager.shared.accentNS)|\(prefs.editorFontSize)|\(prefs.lineSpacing)|\(prefs.wrapLines)|\(prefs.lineNumbers)|\(prefs.spellCheck)|\(prefs.visualMode)|\(prefs.editorFontName)|\(prefs.keybindings)|\(prefs.spellLanguage)|\(prefs.grammarCheck)"
        c?.attach(model.activeDoc)
        c?.applySettings(signature: signature)
        c?.setIssues(model.issues, live: model.liveIssues)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var controller: EditorController? }
}

@MainActor
final class EditorController: NSObject, NSTextViewDelegate, LaTeXTextViewDelegate, EditorControlling {
    let model: ProjectModel
    let scrollView = NSScrollView()
    private(set) var textView: LaTeXTextView
    private let ruler: LineNumberRuler
    private weak var document: TextDocument?
    private let placeholderStorage = NSTextStorage()
    private let visualGlyphs = VisualGlyphs()
    private var lastSignature = ""

    private let completionPanel = FloatingPanel()
    private let completion = CompletionState()
    private var completionReplace = NSRange(location: NSNotFound, length: 0)
    private var completionContext: CompletionContext?

    private let peekPanel = FloatingPanel()
    private var peekTask: Task<Void, Never>?
    private var peekToken: String?

    private let mathPanel = FloatingPanel()
    private let selectionPanel = FloatingPanel()
    private var selectionTask: Task<Void, Never>?
    private var mathTask: Task<Void, Never>?
    private var mathKey: String?

    init(model: ProjectModel) {
        self.model = model
        textView = LaTeXTextView.make(storage: placeholderStorage)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !Preferences.shared.wrapLines
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.clipsToBounds = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        ruler = LineNumberRuler(textView: textView)
        ruler.clipsToBounds = true
        // The gutter floats over the text's left edge (macOS lets content run under rulers), so the text view
        // starts its text after the gutter.
        ruler.onThicknessChange = { [weak scrollView, weak textView] w in
            textView?.gutterInset = (scrollView?.rulersVisible ?? false) ? w : 0
        }
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = Preferences.shared.lineNumbers
        textView.gutterInset = scrollView.rulersVisible ? ruler.ruleThickness : 0
        super.init()
        textView.delegate = self
        textView.latexDelegate = self
        textView.layoutManager?.delegate = visualGlyphs
        completion.onAccept = { [weak self] i in self?.acceptCompletion(at: i) }
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hideFloating()
                if let d = self?.document { d.scrollY = self?.scrollView.contentView.bounds.origin.y ?? 0 }
            }
        }
        // Equations typeset in the background appear as soon as they're ready.
        NotificationCenter.default.addObserver(forName: .visualMathReady, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVisual() }
        }
        ruler.isFolded = { [weak self] r in
            guard let s = self?.document?.storage else { return false }
            return MainActor.assumeIsolated { FoldStore.isFolded(r, in: s) }
        }
        ruler.onToggleFold = { [weak self] r in MainActor.assumeIsolated { self?.toggleFold(r) } }
        textView.commentRanges = { [weak self] storage in
            guard let self else { return [] }
            return MainActor.assumeIsolated {
                let anchors = CommentAnchors.all(storage)
                return self.model.comments.compactMap { c in anchors[c.id].map { ($0, self.model.focusedComment == c.id, c.resolved) } }
            }
        }
        textView.onColumnWidthChange = { [weak self] w in
            MainActor.assumeIsolated {
                guard abs(Highlighter.columnWidth - w) > 24 else { return }
                Highlighter.columnWidth = w
                self?.refreshVisualSoon()
            }
        }
    }

    // MARK: Folding

    private var foldTask: Task<Void, Never>?

    /// Recomputes where the code can fold (debounced while typing).
    func updateFoldRegions(now: Bool = false) {
        foldTask?.cancel()
        guard let doc = document, doc.kind == .tex else { ruler.foldRegions = [:]; return }
        let work = { [weak self] in
            guard let self, let doc = self.document else { return }
            let regions = Folding.regions(in: doc.text)
            self.ruler.foldRegions = Dictionary(regions.map { ($0.startLine, $0.range) }, uniquingKeysWith: { a, _ in a })
        }
        if now { work(); return }
        foldTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            work()
        }
    }

    func toggleFold(_ r: NSRange) {
        guard let doc = document, NSMaxRange(r) <= doc.storage.length else { return }
        if FoldStore.isFolded(r, in: doc.storage) {
            FoldStore.unfold(r, in: doc.storage)
        } else {
            // Keep the caret out of what's about to disappear.
            let sel = textView.selectedRange().location
            if sel > r.location && sel <= NSMaxRange(r) { textView.setSelectedRange(NSRange(location: r.location, length: 0)) }
            FoldStore.fold(r, in: doc.storage)
        }
        doc.rehighlight()
        ruler.needsDisplay = true
    }

    enum FoldAction { case foldHere, unfoldHere, foldAll, unfoldAll }

    func fold(_ action: FoldAction) {
        guard let doc = document, doc.kind == .tex, !Preferences.shared.visualMode else { return }
        updateFoldRegions(now: true)
        let regions = Folding.regions(in: doc.text)
        let caret = ruler.line(forCharacter: textView.selectedRange().location)
        switch action {
        case .foldHere:
            // The innermost region around the caret that isn't folded yet.
            if let r = regions.filter({ $0.startLine <= caret && caret <= $0.endLine && !FoldStore.isFolded($0.range, in: doc.storage) })
                .min(by: { $0.endLine - $0.startLine < $1.endLine - $1.startLine }) { toggleFold(r.range) }
        case .unfoldHere:
            if let r = FoldStore.folds(doc.storage).first(where: { ruler.line(forCharacter: $0.location) == caret }) { toggleFold(r) }
        case .foldAll:
            // Top-level regions only (folding a section folds what's inside it anyway).
            let top = regions.filter { r in !regions.contains { o in o != r && o.startLine <= r.startLine && o.endLine >= r.endLine && o.range.length > r.range.length } }
            let sel = textView.selectedRange().location
            for r in top where !(sel > r.range.location && sel <= NSMaxRange(r.range)) { FoldStore.fold(r.range, in: doc.storage) }
            doc.rehighlight()
            ruler.needsDisplay = true
        case .unfoldAll:
            FoldStore.unfoldAll(in: doc.storage)
            doc.rehighlight()
            ruler.needsDisplay = true
        }
    }

    func textDidChange(_ notification: Notification) { updateFoldRegions() }

    /// Re-runs Visual mode's formatting for the open document (new equation images, a resized column, the
    /// preamble opened or closed).
    func refreshVisual() {
        guard Preferences.shared.visualMode, let doc = document, doc.kind == .tex else { return }
        let ns = textView.string as NSString
        let reveal = Highlighter.visualReveal(at: textView.selectedRange().location, in: ns)
        Highlighter.revealRange = reveal
        Highlighter.highlightVisual(doc.storage, reveal: reveal, batch: true, project: model)
    }

    private var visualRefreshTask: Task<Void, Never>?
    private var lastPreambleExpanded = false
    private func refreshVisualSoon() {
        visualRefreshTask?.cancel()
        visualRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.refreshVisual()
        }
    }

    /// Visual mode opens below the folded preamble rather than inside it.
    private func moveCaretOutOfPreambleIfVisual() {
        guard Preferences.shared.visualMode, !Highlighter.preambleExpanded, let doc = document, doc.kind == .tex else { return }
        let ns = textView.string as NSString
        let start = ns.range(of: "\\begin{document}")
        guard start.location != NSNotFound, textView.selectedRange().location < NSMaxRange(start) else { return }
        textView.setSelectedRange(NSRange(location: NSMaxRange(start), length: 0))
    }

    // MARK: Document switching

    func attach(_ doc: TextDocument?) {
        guard doc !== document else { return }
        if let old = document {
            old.selection = textView.selectedRange()
            old.scrollY = scrollView.contentView.bounds.origin.y
        }
        hideFloating()
        document = doc
        let storage = doc?.storage ?? placeholderStorage
        textView.layoutManager?.replaceTextStorage(storage)
        textView.kind = doc?.kind ?? .other
        textView.isEditable = doc != nil
        textView.setIssues(issuesFor(doc), from: model.issues)
        ruler.issueLines = issueLines(for: doc)
        ruler.invalidate()
        if let doc {
            let sel = NSRange(location: min(doc.selection.location, storage.length), length: 0)
            textView.setSelectedRange(sel)
            moveCaretOutOfPreambleIfVisual()
            updateFoldRegions(now: true)
            let y = doc.scrollY
            DispatchQueue.main.async { [weak self] in
                self?.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
                self?.scrollView.reflectScrolledClipView(self!.scrollView.contentView)
                self?.focus()
            }
        }
        updateCaret()
    }

    func applySettings(signature: String) {
        guard signature != lastSignature else { return }
        let first = lastSignature.isEmpty
        lastSignature = signature
        let t = ThemeManager.shared.theme
        scrollView.backgroundColor = t.editor
        scrollView.hasHorizontalScroller = !Preferences.shared.wrapLines
        let visual = Preferences.shared.visualMode
        scrollView.rulersVisible = Preferences.shared.lineNumbers && !visual
        textView.gutterInset = scrollView.rulersVisible ? ruler.ruleThickness : 0
        textView.visualColumn = visual
        // Vim on or off.
        if Preferences.shared.keybindings == "vim" {
            if textView.vim == nil {
                let v = VimEngine(textView: textView)
                v.onModeChange = { [weak self] m in self?.model.vimMode = m.rawValue }
                v.onCommandLine = { [weak self] in PaletteSeed.shared.text = ":"; self?.model.showPalette = true }
                textView.vim = v
                model.vimMode = v.mode.rawValue
            }
        } else if textView.vim != nil {
            textView.vim = nil
            model.vimMode = nil
        }
        if visual { moveCaretOutOfPreambleIfVisual() }
        Highlighter.revealRange = visual ? Highlighter.visualReveal(at: textView.selectedRange().location, in: textView.string as NSString) : nil
        textView.applyTheme()
        if !first { for d in model.openDocs { d.rehighlight() } }
        ruler.invalidate()
    }

    func setIssues(_ issues: [CompileIssue], live: [String: [CompileIssue]] = [:]) {
        textView.setIssues(issuesFor(document), from: issues)
        ruler.issueLines = issueLines(for: document)
    }

    /// This file's problems: the live checker's first (they match the text as it is now), then the compile's.
    private func issuesFor(_ doc: TextDocument?) -> [CompileIssue] {
        guard let doc else { return [] }
        let live = model.liveIssues[doc.relativePath] ?? []
        return live + model.issues.filter { ($0.file ?? model.mainFile) == doc.relativePath && $0.line != nil }
    }

    private func issueLines(for doc: TextDocument?) -> [Int: CompileIssue.Severity] {
        var out: [Int: CompileIssue.Severity] = [:]
        for i in issuesFor(doc) { if let l = i.line { out[l] = min(out[l] ?? .badBox, i.severity) } }
        return out
    }

    // MARK: EditorControlling

    func reveal(line: Int, column: Int?, flash: Bool) {
        let ns = textView.string as NSString
        guard let r = LaTeXText.range(ofLine: line, in: ns) else { return }
        let loc = r.location + min(max(0, (column ?? 1) - 1), r.length)
        textView.setSelectedRange(NSRange(location: loc, length: 0))
        // Centre the line rather than pinning it to an edge.
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(forCharacterRange: r)
            let g = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: g, in: tc)
            let visible = scrollView.contentView.bounds
            let target = max(0, rect.midY + textView.textContainerOrigin.y - visible.height / 2)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Preferences.shared.reduceMotion ? 0 : 0.28
                ctx.allowsImplicitAnimation = true
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
            }
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        if flash { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.textView.flash(range: r) } }
        focus()
    }

    func insertSnippet(_ snippet: String) {
        guard document != nil else { return }
        textView.insertSnippet(snippet)
        focus()
    }

    func insertPlain(_ text: String) {
        guard document != nil else { return }
        textView.insertText(text, replacementRange: textView.selectedRange())
        focus()
    }

    func wrapSelection(prefix: String, suffix: String) { textView.wrap(prefix: prefix, suffix: suffix) }
    func selectedText() -> String { (textView.string as NSString).substring(with: textView.selectedRange()) }
    func focus() { textView.window?.makeFirstResponder(textView) }

    func caretRect() -> NSRect? {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return nil }
        let sel = textView.selectedRange()
        let g = lm.glyphIndexForCharacter(at: min(sel.location, max(0, (textView.string as NSString).length - 1)))
        var r = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 0), in: tc)
        r.origin.x += textView.textContainerOrigin.x
        r.origin.y += textView.textContainerOrigin.y
        return r
    }

    /// Finds the PDF word in the source near `line` and marks it strongly. SyncTeX only knows lines (often the
    /// last line of a paragraph), so this searches a few lines either side and picks the closest match.
    func highlightWord(_ raw: String, nearLine line: Int) {
        let ligatures = ["\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl", "\u{FB03}": "ffi", "\u{FB04}": "ffl", "\u{2019}": "'", "\u{2018}": "'", "\u{201C}": "``", "\u{201D}": "''"]
        var word = raw
        for (k, v) in ligatures { word = word.replacingOccurrences(of: k, with: v) }
        word = word.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces).subtracting(CharacterSet(charactersIn: "-")))
        if word.hasSuffix("-") { word.removeLast() }   // hyphenated at a line break: match the first half
        guard word.count >= 1 else { return }
        let ns = textView.string as NSString
        guard let center = LaTeXText.range(ofLine: line, in: ns) else { return }
        // Search window: about 12 lines before and 3 after the reported line.
        let startLine = max(1, line - 12), endLine = line + 3
        let start = LaTeXText.range(ofLine: startLine, in: ns)?.location ?? 0
        let endR = LaTeXText.range(ofLine: endLine, in: ns) ?? NSRange(location: ns.length, length: 0)
        let window = NSRange(location: start, length: NSMaxRange(endR) - start)
        let pattern = "(?<![A-Za-z0-9\\\\])" + NSRegularExpression.escapedPattern(for: word) + (raw.hasSuffix("-") ? "" : "(?![A-Za-z0-9])")
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        let matches = re.matches(in: textView.string, range: window).map(\.range)
        guard let best = matches.min(by: { abs($0.location - center.location) < abs($1.location - center.location) }) else { return }
        textView.setSelectedRange(NSRange(location: best.location, length: 0))
        textView.scrollRangeToVisible(best)
        textView.flashWord(range: best)
    }

    func caretInMath() -> Bool { LaTeXText.math(at: textView.selectedRange().location, in: textView.string as NSString) != nil }

    var selectionRange: NSRange { textView.selectedRange() }
    func select(_ r: NSRange) { textView.setSelectedRange(r); textView.scrollRangeToVisible(r) }

    // MARK: NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? { document?.undoManager }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateCaret()
        scheduleSelectionActions()
        revealCaretLineIfVisual()
        scheduleMathPreview()
        if completionPanel.isVisible {
            let sel = textView.selectedRange()
            if sel.location < completionReplace.location || sel.location > NSMaxRange(completionReplace) + 1 { hideCompletion() }
        }
    }

    func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range affectedCharRange: NSRange) -> Int {
        // Only prose gets spell-checked: anything coloured as syntax (commands, math, refs, comments) is skipped.
        guard affectedCharRange.location < (textView.string as NSString).length else { return value }
        let color = textView.textStorage?.attribute(.foregroundColor, at: affectedCharRange.location, effectiveRange: nil) as? NSColor
        return color == ThemeManager.shared.theme.text ? value : 0
    }

    /// In Visual mode the caret's line shows raw LaTeX; move that reveal when the caret changes line.
    private func revealCaretLineIfVisual() {
        guard let doc = document else { return }
        let loc = textView.selectedRange().location
        // The caret moved into a fold: open it.
        if !Preferences.shared.visualMode {
            if FoldStore.unfold(containing: loc, in: doc.storage) { doc.rehighlight() }
            return
        }
        guard doc.kind == .tex else { return }
        let ns = textView.string as NSString
        // Moving into the folded preamble opens it.
        if !Highlighter.preambleExpanded {
            let start = ns.range(of: "\\begin{document}")
            if start.location != NSNotFound, loc < start.location, textView.window?.firstResponder === textView {
                Highlighter.preambleExpanded = true
            }
        }
        let reveal = Highlighter.visualReveal(at: loc, in: ns)
        guard reveal != Highlighter.revealRange || Highlighter.preambleExpanded != lastPreambleExpanded else { return }
        Highlighter.revealRange = reveal
        lastPreambleExpanded = Highlighter.preambleExpanded
        Highlighter.highlightVisual(doc.storage, reveal: reveal, batch: true, project: model)
    }

    private func updateCaret() {
        let sel = textView.selectedRange()
        let ns = textView.string as NSString
        let line = ruler.line(forCharacter: sel.location)
        let lineStart = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0)).location
        if model.caretLine != line || model.caretColumn != sel.location - lineStart + 1 {
            model.caretLine = line
            model.caretColumn = sel.location - lineStart + 1
            model.updateCurrentSection()
        }
        if Preferences.shared.followCaret, model.layout == .split { followCaretSoon() }
    }

    private var followTask: Task<Void, Never>?
    private func followCaretSoon() {
        followTask?.cancel()
        followTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            model.syncToPDF()
        }
    }

    // MARK: LaTeXTextViewDelegate

    func textViewDidType(_ tv: LaTeXTextView) {
        hidePeek()
        updateCompletion()
    }

    func textViewCompletionKey(_ tv: LaTeXTextView, _ key: LaTeXTextView.CompletionKey) -> Bool {
        guard completionPanel.isVisible, !completion.items.isEmpty else { return false }
        switch key {
        case .up:
            completion.selected = (completion.selected - 1 + completion.items.count) % completion.items.count
        case .down:
            completion.selected = (completion.selected + 1) % completion.items.count
        case .accept, .tab:
            acceptCompletion(at: completion.selected)
        case .dismiss:
            hideCompletion()
        }
        return true
    }

    func textViewCommandClick(_ tv: LaTeXTextView, at index: Int) -> Bool {
        guard let token = LaTeXText.token(at: index, in: tv.string as NSString) else { return false }
        switch token {
        case .argument(let command, let value, _):
            if ["ref", "eqref", "cref", "Cref", "autoref", "pageref", "nameref", "vref"].contains(command),
               let label = model.labels.first(where: { $0.title == value }) {
                model.open(path: label.file, line: label.line)
                return true
            }
            if command.hasPrefix("cite") || ["parencite", "textcite", "autocite", "nocite"].contains(command),
               let e = model.bibEntries.first(where: { $0.key == value }) {
                model.open(path: e.file, line: e.line)
                return true
            }
            if ["input", "include", "subfile"].contains(command) {
                let path = resolveRelative(Outline.resolve(value, from: ""))
                if FileManager.default.fileExists(atPath: model.root.appendingPathComponent(path).path) { model.open(path: path) }
                else { model.createFile(named: path) }
                return true
            }
            if command == "includegraphics", let path = resolveImage(value) {
                NSWorkspace.shared.open(model.root.appendingPathComponent(path))
                return true
            }
            if command == "label" {
                model.sidebarTab = .outline
                return true
            }
        case .command:
            return false
        }
        return false
    }

    /// Paths in \input are relative to the main file's folder.
    private func resolveRelative(_ p: String) -> String {
        let mainDir = (model.mainFile as NSString).deletingLastPathComponent
        return mainDir.isEmpty ? p : (mainDir as NSString).appendingPathComponent(p)
    }

    private func resolveImage(_ value: String) -> String? {
        let base = resolveRelative(value)
        let fm = FileManager.default
        if (base as NSString).pathExtension.isEmpty {
            for ext in ["pdf", "png", "jpg", "jpeg", "eps"] where fm.fileExists(atPath: model.root.appendingPathComponent(base + "." + ext).path) { return base + "." + ext }
            return nil
        }
        return fm.fileExists(atPath: model.root.appendingPathComponent(base).path) ? base : nil
    }

    func textViewDropImages(_ tv: LaTeXTextView, urls: [URL], at index: Int) {
        tv.setSelectedRange(NSRange(location: index, length: 0))
        for url in urls {
            guard let path = model.importImage(url) else { continue }
            let label = (path as NSString).deletingPathExtension.components(separatedBy: "/").last?.lowercased()
                .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression) ?? "figure"
            tv.insertSnippet("\\begin{figure}[htbp]\n\t\\centering\n\t\\includegraphics[width=0.8\\linewidth]{\(path)}\n\t\\caption{${1:Caption}}\n\t\\label{fig:\(label)}\n\\end{figure}\n$0")
        }
        model.showToast("photo.badge.plus", urls.count == 1 ? "Figure added" : "\(urls.count) figures added")
    }

    func textViewPasteImage(_ tv: LaTeXTextView, data: Data, type: String) {
        let dir = model.root.appendingPathComponent("figures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("pasted-\(f.string(from: Date())).\(type)")
        guard (try? data.write(to: url)) != nil else { return }
        textViewDropImages(tv, urls: [url], at: tv.selectedRange().location)
    }

    func textViewActivateWidget(_ tv: LaTeXTextView, _ widget: WidgetRef, range: NSRange) {
        guard let doc = document else { return }
        switch widget.kind {
        case .table:
            let ns = tv.string as NSString
            guard let table = TableModel.parse(latex: ns.substring(with: range)) else { return }
            model.tableReplaceRange = range
            model.tableDraft = table
        case .preamble, .preambleShown:
            Highlighter.preambleExpanded.toggle()
            if !Highlighter.preambleExpanded { moveCaretOutOfPreambleIfVisual() }
            refreshVisual()
        case .fold:
            FoldStore.unfold(range, in: doc.storage)
            doc.rehighlight()
        default:
            break
        }
    }

    func textViewDidPasteRich(_ tv: LaTeXTextView, latex: String, plain: String, at location: Int) {
        let inserted = NSRange(location: location, length: (latex as NSString).length)
        model.showToast("doc.richtext", "Pasted with formatting", actionTitle: "Paste as plain text") { [weak self, weak tv] in
            guard let tv, let self, self.document != nil, NSMaxRange(inserted) <= (tv.string as NSString).length,
                  (tv.string as NSString).substring(with: inserted) == latex else { return }
            tv.insertText(plain, replacementRange: inserted)
        }
    }

    func textViewPasteTable(_ tv: LaTeXTextView, text: String) -> Bool {
        guard let table = TableModel.parse(delimited: text), table.columns >= 2, table.rows >= 2 else { return false }
        model.tableReplaceRange = nil
        model.tableDraft = table
        return true
    }

    // MARK: Completion

    enum CompletionContext { case command, label, citation, environment, file, image, package }

    private static let contextRE: [(NSRegularExpression, CompletionContext)] = [
        (try! NSRegularExpression(pattern: #"\\(?:ref|eqref|cref|Cref|autoref|pageref|nameref|vref)\{([^}]*)$"#), .label),
        (try! NSRegularExpression(pattern: #"\\(?:cite[a-zA-Z]*|parencite|textcite|autocite|nocite)(?:\[[^\]]*\])*\{(?:[^}]*,\s*)?([^,}]*)$"#), .citation),
        (try! NSRegularExpression(pattern: #"\\begin\{([^}]*)$"#), .environment),
        (try! NSRegularExpression(pattern: #"\\(?:input|include|subfile)\{([^}]*)$"#), .file),
        (try! NSRegularExpression(pattern: #"\\includegraphics(?:\[[^\]]*\])?\{([^}]*)$"#), .image),
        (try! NSRegularExpression(pattern: #"\\(?:usepackage|RequirePackage)(?:\[[^\]]*\])?\{(?:[^}]*,\s*)?([^,}]*)$"#), .package),
        (try! NSRegularExpression(pattern: #"\\([A-Za-z]+)$"#), .command),
    ]

    private func updateCompletion() {
        guard let doc = document, doc.kind == .tex else { hideCompletion(); return }
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        guard sel.length == 0 else { hideCompletion(); return }
        let lineStart = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
        let start = max(lineStart, sel.location - 200)
        let before = ns.substring(with: NSRange(location: start, length: sel.location - start))
        let bns = before as NSString
        for (re, ctx) in Self.contextRE {
            guard let m = re.firstMatch(in: before, range: NSRange(location: 0, length: bns.length)) else { continue }
            let q = bns.substring(with: m.range(at: 1))
            var items: [CompletionItem]
            var replace = NSRange(location: start + m.range(at: 1).location, length: m.range(at: 1).length)
            switch ctx {
            case .command:
                guard !q.isEmpty else { hideCompletion(); return }
                items = rank(Catalog.commands + userMacros(), query: "\\" + q, key: \.label)
                replace = NSRange(location: replace.location - 1, length: replace.length + 1)
            case .label:
                let labels = model.labels.map { CompletionItem(kind: .label, label: $0.title, detail: labelDetail($0), snippet: $0.title) }
                items = rank(labels, query: q, key: \.label)
            case .citation:
                let cites = model.bibEntries.map { CompletionItem(kind: .citation, label: $0.key, detail: [$0.authorsShort, $0.year].filter { !$0.isEmpty }.joined(separator: " "), snippet: $0.key) }
                items = rank(cites, query: q, key: \.label, also: { item in self.model.bibEntries.first { $0.key == item.label }?.title ?? "" })
            case .environment:
                let envs = Catalog.environments.map { CompletionItem(kind: .environment, label: $0.name, detail: $0.detail, snippet: $0.body) }
                items = rank(envs, query: q, key: \.label)
            case .file:
                let files = model.texFiles.filter { $0 != model.mainFile }.map { p -> CompletionItem in
                    let rel = (p as NSString).deletingPathExtension
                    return CompletionItem(kind: .file, label: rel, detail: "TeX file", snippet: rel)
                }
                items = rank(files, query: q, key: \.label)
            case .image:
                let imgs = FileNode.flatten(model.tree).filter { $0.isImage && !$0.isDirectory }.map {
                    CompletionItem(kind: .file, label: $0.path, detail: ($0.name as NSString).pathExtension.uppercased(), snippet: $0.path)
                }
                items = rank(imgs, query: q, key: \.label)
            case .package:
                let pk = Catalog.packages.map { CompletionItem(kind: .package, label: $0.0, detail: $0.1, snippet: $0.0) }
                items = rank(pk, query: q, key: \.label)
            }
            guard !items.isEmpty, !(items.count == 1 && items[0].label == q && ctx != .environment) else { hideCompletion(); return }
            completion.items = Array(items.prefix(60))
            completion.query = ctx == .command ? "\\" + q : q
            if completionContext != ctx || !completionPanel.isVisible { completion.selected = 0 }
            completion.selected = min(completion.selected, completion.items.count - 1)
            completionReplace = replace
            completionContext = ctx
            showCompletionPanel(at: replace.location)
            return
        }
        hideCompletion()
    }

    private func labelDetail(_ item: OutlineItem) -> String {
        let prefix = item.title.split(separator: ":").first.map(String.init) ?? ""
        switch prefix {
        case "fig": return "Figure · \((item.file as NSString).lastPathComponent)"
        case "tab": return "Table · \((item.file as NSString).lastPathComponent)"
        case "eq": return "Equation · \((item.file as NSString).lastPathComponent)"
        case "sec", "ch", "chap": return "Section · \((item.file as NSString).lastPathComponent)"
        default: return "\((item.file as NSString).lastPathComponent):\(item.line)"
        }
    }

    /// \newcommand definitions found in the project, offered alongside the built-in commands.
    private func userMacros() -> [CompletionItem] {
        var out: [CompletionItem] = []
        let re = try! NSRegularExpression(pattern: #"\\(?:newcommand|renewcommand|DeclareMathOperator)\*?\{?\\([A-Za-z]+)\}?(?:\[(\d)\])?"#)
        for path in model.texFiles {
            guard let t = model.text(of: path) else { continue }
            let ns = t as NSString
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                let args = m.range(at: 2).location != NSNotFound ? Int(ns.substring(with: m.range(at: 2))) ?? 0 : 0
                let snippet = "\\" + name + (0..<args).map { "{$\($0 + 1)}" }.joined()
                out.append(CompletionItem(kind: .snippet, label: "\\" + name, detail: "Your macro", snippet: snippet))
            }
        }
        return out
    }

    private func rank(_ items: [CompletionItem], query: String, key: KeyPath<CompletionItem, String>, also: ((CompletionItem) -> String)? = nil) -> [CompletionItem] {
        if query.isEmpty { return items }
        var seen = Set<String>()
        return items.compactMap { item -> (CompletionItem, Int)? in
            let s1 = Fuzzy.score(query, item[keyPath: key])
            let s2 = also.flatMap { Fuzzy.score(query, $0(item)) }.map { $0 - 6 }
            guard let s = [s1, s2].compactMap({ $0 }).max() else { return nil }
            // Prefix matches first, then shorter labels.
            let bonus = item[keyPath: key].lowercased().hasPrefix(query.lowercased()) ? 50 : 0
            return (item, s + bonus - item[keyPath: key].count / 6)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
        .filter { seen.insert($0.id).inserted }
    }

    private func showCompletionPanel(at location: Int) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        let g = lm.glyphIndexForCharacter(at: min(location, max(0, (textView.string as NSString).length - 1)))
        var r = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
        r.origin.x += textView.textContainerOrigin.x
        r.origin.y += textView.textContainerOrigin.y
        hidePeek()
        mathPanel.hide(animated: false)
        let wasVisible = completionPanel.isVisible
        completionPanel.show(CompletionList(state: completion), near: r, in: textView, gap: -14)
    }

    private func hideCompletion() {
        completionPanel.hide(animated: false)
        completionContext = nil
    }

    private func acceptCompletion(at i: Int) {
        guard let item = completion.items[safe: i], let ctx = completionContext else { return }
        let ns = textView.string as NSString
        var replace = completionReplace
        hideCompletion()
        guard NSMaxRange(replace) <= ns.length else { return }
        switch ctx {
        case .command:
            textView.insertSnippet(item.snippet, replacing: replace)
        case .environment:
            // Replace the partial name and the auto-inserted "}", then expand the body.
            if NSMaxRange(replace) < ns.length, ns.character(at: NSMaxRange(replace)) == 125 { replace.length += 1 }
            let begin = replace.location - 7  // "\begin{"
            guard begin >= 0 else { return }
            let full = NSRange(location: begin, length: NSMaxRange(replace) - begin)
            let extra = item.label == "figure" || item.label == "table" ? "[htbp]" : (item.label == "minipage" ? "{${9:0.45\\linewidth}}" : (item.label == "tabular" ? "{${9:lll}}" : ""))
            let body = item.snippet.contains("$") ? item.snippet : (item.snippet.isEmpty ? "$1" : item.snippet)
            textView.insertSnippet("\\begin{\(item.label)}\(extra)\n\t\(body)\n\\end{\(item.label)}$0", replacing: full)
        default:
            textView.insertText(item.snippet, replacementRange: replace)
            let after = replace.location + (item.snippet as NSString).length
            let s = textView.string as NSString
            if after < s.length, s.character(at: after) == 125 { textView.setSelectedRange(NSRange(location: after + 1, length: 0)) }
        }
    }

    // MARK: Hover peeks

    func textViewHover(_ tv: LaTeXTextView, at index: Int?, pointInView: NSPoint, force: Bool) {
        guard Preferences.shared.hoverPeeks || force, let index, !completionPanel.isVisible else {
            peekTask?.cancel()
            if index == nil || !peekContains(pointInView) { hidePeek() }
            return
        }
        let ns = tv.string as NSString
        let tokenRange: NSRange
        let content: () async -> PeekContent?
        if let token = LaTeXText.token(at: index, in: ns) {
            switch token {
            case .argument(let command, let value, let range):
                tokenRange = range
                content = { [weak self] in await self?.peek(command: command, value: value) }
            case .command(let name, let range):
                tokenRange = range
                content = { [weak self] in self?.peek(commandName: name) }
            }
        } else if Preferences.shared.mathPreview == false, let m = LaTeXText.math(at: index, in: ns) {
            tokenRange = m.range
            content = { [weak self] in await self?.peek(math: m.content, display: m.display) }
        } else {
            peekTask?.cancel()
            hidePeek()
            return
        }
        let key = "\(tokenRange.location):\(tokenRange.length)"
        if key == peekToken && peekPanel.isVisible { return }
        peekTask?.cancel()
        peekTask = Task { @MainActor [weak self] in
            if !force { try? await Task.sleep(for: .milliseconds(420)) }
            guard !Task.isCancelled, let self, let c = await content(), !Task.isCancelled else { return }
            self.peekToken = key
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let g = lm.glyphRange(forCharacterRange: tokenRange, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: g, in: tc)
            rect.origin.x += tv.textContainerOrigin.x
            rect.origin.y += tv.textContainerOrigin.y
            self.mathPanel.hide(animated: false)
            self.peekPanel.show(PeekCard(content: c), near: rect, in: tv, gap: -14)
        }
    }

    private func peekContains(_ p: NSPoint) -> Bool { false }

    private func hidePeek() {
        peekTask?.cancel()
        peekPanel.hide()
        peekToken = nil
    }

    /// A small "Comment" button beside a selection, once the selection settles.
    private func scheduleSelectionActions() {
        selectionTask?.cancel()
        selectionPanel.hide(animated: false)
        let sel = textView.selectedRange()
        guard sel.length > 0, document != nil, !completionPanel.isVisible else { return }
        selectionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, self.textView.selectedRange() == sel, NSEvent.pressedMouseButtons == 0,
                  let lm = self.textView.layoutManager, let tc = self.textView.textContainer else { return }
            let g = lm.glyphRange(forCharacterRange: NSRange(location: NSMaxRange(sel) - 1, length: 1), actualCharacterRange: nil)
            var r = lm.boundingRect(forGlyphRange: g, in: tc)
            r.origin.x += self.textView.textContainerOrigin.x
            r.origin.y += self.textView.textContainerOrigin.y
            self.selectionPanel.show(SelectionActions(comment: { [weak self] in
                self?.selectionPanel.hide(animated: false)
                self?.model.beginComment()
            }), near: r, in: self.textView, gap: 4)
        }
    }

    private func hideFloating() {
        selectionPanel.hide(animated: false)
        hidePeek()
        hideCompletion()
        mathPanel.hide(animated: false)
    }

    private func peek(command: String, value: String) async -> PeekContent? {
        if ["ref", "eqref", "cref", "Cref", "autoref", "pageref", "nameref", "vref", "label"].contains(command) {
            let item = model.outline.first { $0.label == value && $0.kind != .label } ?? model.labels.first { $0.title == value }
            var snippet: String?
            var math: NSImage?
            if let item, let text = model.text(of: item.file) {
                let ns = text as NSString
                if let r = LaTeXText.range(ofLine: item.line, in: ns) {
                    if let m = LaTeXText.math(at: r.location + max(0, r.length - 1), in: ns) ?? LaTeXText.math(at: r.location, in: ns),
                       let engine = model.engine, let result = await MathRenderer.shared.render(math: m.content, display: m.display, preamble: preamble(), engine: engine),
                       case .pdf(let data) = result {
                        math = MathImage.make(from: data)
                    } else {
                        let start = max(0, item.line - 2)
                        snippet = (start..<(item.line + 2)).compactMap { LaTeXText.range(ofLine: $0 + 1, in: ns).map { ns.substring(with: $0) } }.joined(separator: "\n")
                    }
                }
            }
            return .reference(key: value, item: item, snippet: snippet, math: math)
        }
        if command.hasPrefix("cite") || ["parencite", "textcite", "autocite", "nocite"].contains(command) {
            return .citation(model.bibEntries.first { $0.key == value }, key: value)
        }
        if command == "includegraphics" {
            let path = resolveImage(value)
            return .image(path.flatMap { NSImage(contentsOf: model.root.appendingPathComponent($0)) }, path: path ?? value)
        }
        if ["input", "include", "subfile"].contains(command) {
            let path = resolveRelative(Outline.resolve(value, from: ""))
            let text = model.text(of: path)
            return .file(path: path, exists: text != nil, firstLines: text.map { $0.components(separatedBy: "\n").prefix(6).joined(separator: "\n") })
        }
        if command == "usepackage" || command == "documentclass" || command == "begin" || command == "end" {
            let detail = Catalog.packages.first { $0.0 == value }?.1 ?? Catalog.environments.first { $0.name == value }?.detail
            return detail.map { .command(name: value, detail: $0, package: nil, glyph: nil) }
        }
        return nil
    }

    private func peek(commandName: String) -> PeekContent? {
        let label = "\\" + commandName
        let sym = Catalog.symbols.first { $0.command == label || $0.command.hasPrefix(label + "{") }
        let cmd = Catalog.commands.first { $0.label == label }
        guard sym != nil || cmd != nil || ErrorAdvisor.packageFor[commandName] != nil else { return nil }
        return .command(name: commandName, detail: sym?.name.capitalized ?? cmd?.detail, package: sym?.package ?? ErrorAdvisor.packageFor[commandName], glyph: sym?.glyph)
    }

    private func peek(math: String, display: Bool) async -> PeekContent? {
        guard let engine = model.engine, let r = await MathRenderer.shared.render(math: math, display: display, preamble: preamble(), engine: engine) else { return nil }
        switch r {
        case .pdf(let d): return .math(image: MathImage.make(from: d), error: nil, display: display)
        case .failed(let e): return .math(image: nil, error: e, display: display)
        }
    }

    private func preamble() -> String { LaTeXText.preamble(of: model.text(of: model.mainFile) ?? "").body }

    // MARK: Live equation preview

    private func scheduleMathPreview() {
        mathTask?.cancel()
        guard Preferences.shared.mathPreview, let doc = document, doc.kind == .tex, !completionPanel.isVisible else { mathPanel.hide(); mathKey = nil; return }
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        guard sel.length == 0, let m = LaTeXText.math(at: sel.location, in: ns) else { mathPanel.hide(); mathKey = nil; return }
        let key = m.content
        mathTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(self?.mathPanel.isVisible == true ? 120 : 380))
            guard !Task.isCancelled, let self, let engine = self.model.engine else { return }
            if !self.mathPanel.isVisible { self.showMath(.math(image: nil, error: nil, display: m.display), range: m.range) }
            guard let r = await MathRenderer.shared.render(math: m.content, display: m.display, preamble: self.preamble(), engine: engine), !Task.isCancelled else { return }
            let content: PeekContent
            switch r {
            case .pdf(let d): content = .math(image: MathImage.make(from: d), error: nil, display: m.display)
            case .failed(let e):
                // Keep the last good render while the user is mid-edit.
                if self.mathKey != nil { return }
                content = .math(image: nil, error: e, display: m.display)
            }
            self.mathKey = key
            self.showMath(content, range: m.range)
        }
    }

    private func showMath(_ content: PeekContent, range: NSRange) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        // Anchor under the last line of the math block, aligned with its start.
        let g = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: g, in: tc)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        let first = lm.boundingRect(forGlyphRange: NSRange(location: g.location, length: 1), in: tc)
        rect.origin.x = first.minX + textView.textContainerOrigin.x
        rect.size.width = 10
        hidePeek()
        mathPanel.show(PeekCard(content: content, caption: "Live preview · uses your preamble"), near: rect, in: textView, gap: -14)
    }
}

/// The quick action shown beside a selection.
private struct SelectionActions: View {
    let comment: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: comment) {
            Label("Comment", systemImage: "text.bubble")
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? accent : Color(theme.text))
        .background(Capsule().fill(Color(theme.surface)))
        .overlay(Capsule().strokeBorder(Color(theme.hairline)))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .onHover { hovering = $0 }
        .help("Comment on the selection (⌥⌘M)")
    }
}

extension LaTeXTextView {
    func setIssues(_ mine: [CompileIssue], from _: [CompileIssue]) { issues = mine }
}
