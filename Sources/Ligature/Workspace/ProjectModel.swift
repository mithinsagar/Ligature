import SwiftUI
import AppKit
import LigatureCore

/// What the editor exposes to the rest of the window.
@MainActor protocol EditorControlling: AnyObject {
    func reveal(line: Int, column: Int?, flash: Bool)
    func insertSnippet(_ snippet: String)
    func insertPlain(_ text: String)
    func wrapSelection(prefix: String, suffix: String)
    func selectedText() -> String
    func focus()
    func caretRect() -> NSRect?
    func caretInMath() -> Bool
    func highlightWord(_ word: String, nearLine line: Int)
}

/// What the PDF preview exposes.
@MainActor protocol PDFControlling: AnyObject {
    func show(page: Int, rects: [CGRect])
    func print()
}

enum SidebarTab: String, CaseIterable, Identifiable {
    case files, outline, issues, symbols, citations, history
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .files: "folder"
        case .outline: "list.bullet.indent"
        case .issues: "exclamationmark.triangle"
        case .symbols: "sum"
        case .citations: "quote.opening"
        case .history: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        }
    }
    var title: String {
        switch self {
        case .files: "Files"
        case .outline: "Outline"
        case .issues: "Issues"
        case .symbols: "Symbols"
        case .citations: "Citations"
        case .history: "History"
        }
    }
}

/// One open project: a folder, its main .tex file, the open documents, and the latest compile.
@Observable @MainActor
final class ProjectModel {
    let root: URL
    var mainFile: String { didSet { Recents.shared.touch(root, main: mainFile); scheduleStructure(); scheduleCompile(delay: 0.05) } }
    var tree: [FileNode] = []
    var openDocs: [TextDocument] = []
    var activeDoc: TextDocument?

    enum CompileState: Equatable { case idle, running, success, failed, noEngine }
    var compileState: CompileState = .idle
    var lastDuration: TimeInterval?
    var lastCompiled: Date?
    var issues: [CompileIssue] = []
    var pdfData: Data?
    var pdfVersion = 0
    var synctex: SyncTeX?
    var engine: EngineLocator.Found?
    var pageCount = 0

    var outline: [OutlineItem] = []
    var bibEntries: [BibEntry] = []
    var words = 0
    var snapshots: [Snapshot] = []

    var layout: Preferences.Layout = .split
    var sidebarTab: SidebarTab = .outline
    var showSidebar = true
    var caretLine = 1
    var caretColumn = 1
    var currentSection: OutlineItem?

    // Sheets and overlays
    var showPalette = false
    var tableDraft: TableModel?
    var tableReplaceRange: NSRange?
    var showFigureSheet = false
    var pendingFigureURL: URL?
    var showCitationSheet = false
    var showNewFile = false
    var showRename = false
    /// Edits made since the last compile started (shown when live compile is off).
    var hasUncompiledChanges = false
    /// Set after the project folder is renamed: the window reopens at this URL and this model goes inert.
    var movedTo: URL?
    var downloads: [DownloadRecord] = []
    var showDownloads = false
    var toast: Toast?

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        var symbol: String
        var text: String
        var tint: Color? = nil
        var actionTitle: String? = nil
        var action: (() -> Void)? = nil
        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    weak var editor: EditorControlling?
    weak var pdf: PDFControlling?

    private let compiler = CompileService()
    private var watcher: FolderWatcher?
    private var compileTask: Task<Void, Never>?
    private var structureTask: Task<Void, Never>?
    private var treeTask: Task<Void, Never>?
    /// A compile is running; edits made meanwhile queue exactly one follow-up instead of cancelling it.
    private var compiling = false
    private var followUp: Bool?   // nil = none queued, else whether the queued one is manual
    private var compileSerial = 0
    /// The last finished state, restored if a compile is cancelled.
    private var settledState: CompileState = .idle
    /// Bumped when a compile you started lands, to play the scan animation over the PDF.
    var scanToken = 0
    private var lastErrorCount = 0

    init(root: URL, preferredMain: String? = nil) {
        let std = root.standardizedFileURL
        self.root = std
        let tree = FileNode.scan(root: std)
        self.tree = tree
        let remembered = Recents.shared.items.first { $0.path == std.path }?.mainFile
        self.mainFile = preferredMain ?? remembered ?? ProjectModel.detectMain(root: std, tree: tree) ?? "main.tex"
        engine = EngineLocator.locate()
        if engine == nil { compileState = .noEngine }
        Recents.shared.touch(self.root, main: mainFile)
        ProjectModel.openModels.add(self)
        watcher = FolderWatcher(url: self.root) { [weak self] in
            Task { @MainActor in self?.filesChangedOnDisk() }
        }
        open(path: mainFile)
        refreshStructure()
        snapshots = HistoryStore.list(root: self.root)
        downloads = DownloadStore.list(root: self.root)
        compile(manual: false)
    }

    var name: String { root.lastPathComponent }
    var mainURL: URL { root.appendingPathComponent(mainFile) }
    var errorCount: Int { issues.filter { $0.severity == .error }.count }
    var warningCount: Int { issues.filter { $0.severity == .warning }.count }
    var texFiles: [String] { FileNode.flatten(tree).filter { !$0.isDirectory && ($0.name.hasSuffix(".tex") || $0.name.hasSuffix(".ltx")) }.map(\.path) }
    var labels: [OutlineItem] { outline.filter { $0.kind == .label } }

    /// The main file is the .tex with \documentclass; prefer main.tex, then the shortest path.
    static func detectMain(root: URL, tree: [FileNode]) -> String? {
        let tex = FileNode.flatten(tree).filter { $0.name.hasSuffix(".tex") }.map(\.path)
        let withClass = tex.filter { path in
            guard let h = try? FileHandle(forReadingFrom: root.appendingPathComponent(path)) else { return false }
            defer { try? h.close() }
            let head = String(data: h.readData(ofLength: 8000), encoding: .utf8) ?? ""
            return head.contains("\\documentclass")
        }
        if withClass.contains("main.tex") { return "main.tex" }
        return withClass.sorted { $0.count < $1.count }.first ?? tex.first
    }

    // MARK: Documents

    @discardableResult
    func open(path: String, line: Int? = nil, column: Int? = nil) -> TextDocument? {
        let rel = path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : path
        if let doc = openDocs.first(where: { $0.relativePath == rel }) {
            activate(doc)
            if let line { DispatchQueue.main.async { self.editor?.reveal(line: line, column: column, flash: true) } }
            return doc
        }
        let url = root.appendingPathComponent(rel)
        let node = FileNode(name: url.lastPathComponent, path: rel, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard node.isText else {
            NSWorkspace.shared.open(url)
            return nil
        }
        guard let doc = try? TextDocument(url: url, relativePath: rel) else { return nil }
        doc.onChange = { [weak self] d in self?.documentDidChange(d) }
        doc.onUndoChange = { [weak self] in self?.undoTick += 1; self?.refreshDirty() }
        openDocs.append(doc)
        activate(doc)
        if let line { DispatchQueue.main.async { self.editor?.reveal(line: line, column: column, flash: true) } }
        return doc
    }

    func activate(_ doc: TextDocument) {
        guard activeDoc !== doc else { return }
        withAnimation(.panel) { activeDoc = doc }
    }

    func close(_ doc: TextDocument) {
        if doc.isDirty {
            let alert = NSAlert()
            alert.messageText = "Save changes to “\(doc.name)”?"
            alert.informativeText = "Your edits since the last compile will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: doc.save()
            case .alertSecondButtonReturn: doc.revert()
            default: return
            }
            refreshDirty()
        }
        guard let i = openDocs.firstIndex(where: { $0 === doc }) else { return }
        withAnimation(.panel) {
            openDocs.remove(at: i)
            if activeDoc === doc { activeDoc = openDocs.isEmpty ? nil : openDocs[min(i, openDocs.count - 1)] }
        }
    }

    func text(of path: String) -> String? {
        if let d = openDocs.first(where: { $0.relativePath == path }) { return d.text }
        return try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // Files are written when you compile or press ⌘S (so what's on disk is what you last compiled). Closing a
    // window or quitting with edits since then asks first.
    private func documentDidChange(_ doc: TextDocument) {
        refreshDirty()
        scheduleStructure()
        hasUncompiledChanges = true
        if Preferences.shared.liveCompile { scheduleCompile(delay: Preferences.shared.compileDelay) }
    }

    /// Turns live compile on or off. Turning it on catches up immediately if there are pending edits.
    func setLiveCompile(_ on: Bool) {
        Preferences.shared.liveCompile = on
        if on && hasUncompiledChanges { compile(manual: false) }
        showToast(on ? "bolt.fill" : "bolt.slash", on ? "Live compile on" : "Live compile off. Press ⌘R to compile")
    }

    func saveAll() {
        guard movedTo == nil else { return }  // the files live somewhere else now
        for d in openDocs { d.save() }
        refreshDirty()
    }

    /// Paths of open documents with edits not yet written to disk.
    var dirtyPaths: Set<String> = []
    /// Bumped whenever an undo position moves (drives the undo/redo buttons).
    var undoTick = 0
    func refreshDirty() {
        let now = Set(openDocs.filter(\.isDirty).map(\.relativePath))
        if now != dirtyPaths { dirtyPaths = now }
    }

    /// Throws away every unsaved edit (back to the last compile or save).
    func discardChanges() {
        for d in openDocs { d.revert() }
        refreshDirty()
        scheduleStructure()
    }

    /// Every open project, for the quit prompt.
    static let openModels = NSHashTable<ProjectModel>.weakObjects()

    private func filesChangedOnDisk() {
        treeTask?.cancel()
        treeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let newTree = FileNode.scan(root: root)
            if newTree != tree { withAnimation(.panel) { tree = newTree } }
            var changed = false
            for d in openDocs where d.reloadIfChangedOnDisk() { changed = true }
            if changed {
                scheduleStructure()
                if Preferences.shared.liveCompile { scheduleCompile(delay: 0.2) }
            }
        }
    }

    // MARK: Files

    func createFile(named name: String, in folder: String? = nil, contents: String = "") {
        var rel = name.trimmingCharacters(in: .whitespaces)
        guard !rel.isEmpty else { return }
        if (rel as NSString).pathExtension.isEmpty { rel += ".tex" }
        if let folder, !folder.isEmpty { rel = folder + "/" + rel }
        let url = root.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { open(path: rel); return }
        let body = contents.isEmpty && rel.hasSuffix(".tex") ? "% \(url.deletingPathExtension().lastPathComponent)\n\n" : contents
        try? body.write(to: url, atomically: true, encoding: .utf8)
        tree = FileNode.scan(root: root)
        open(path: rel)
    }

    func rename(_ node: FileNode, to newName: String) {
        let src = root.appendingPathComponent(node.path)
        let dst = src.deletingLastPathComponent().appendingPathComponent(newName)
        guard !newName.isEmpty, newName != node.name, (try? FileManager.default.moveItem(at: src, to: dst)) != nil else { return }
        let newRel = String(dst.standardizedFileURL.path.dropFirst(root.path.count + 1))
        if let d = openDocs.first(where: { $0.relativePath == node.path }) { close(d); open(path: newRel) }
        if mainFile == node.path { mainFile = newRel }
        tree = FileNode.scan(root: root)
    }

    func trash(_ node: FileNode) {
        let url = root.appendingPathComponent(node.path)
        if let d = openDocs.first(where: { $0.relativePath == node.path }) { close(d) }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        tree = FileNode.scan(root: root)
    }

    /// Copies an image into figures/ (unless it's already inside the project) and returns its project path.
    func importImage(_ url: URL) -> String? {
        let std = url.standardizedFileURL
        if std.path.hasPrefix(root.path + "/") { return String(std.path.dropFirst(root.path.count + 1)) }
        let dir = root.appendingPathComponent("figures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appendingPathComponent(url.lastPathComponent.replacingOccurrences(of: " ", with: "-"))
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ", with: "-"))-\(n).\(url.pathExtension)"); n += 1
        }
        guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { return nil }
        tree = FileNode.scan(root: root)
        return "figures/" + dest.lastPathComponent
    }

    // MARK: Compile

    func scheduleCompile(delay: Double) {
        compileTask?.cancel()
        compileTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.compile(manual: false)
        }
    }

    func compile(manual: Bool) {
        compileTask?.cancel()
        guard movedTo == nil else { return }
        if engine == nil { engine = EngineLocator.locate() }
        guard let engine else {
            compileState = .noEngine
            if manual { Haptics.play(.failure) }
            return
        }
        // Never cancel a running compile: let it land, then immediately run one more with the latest text.
        // While typing in live mode this keeps the PDF updating continuously instead of only after a pause.
        if compiling {
            NSLog("Ligature: compile requested while running; queued (manual=\(manual))")
            followUp = (followUp ?? false) || manual
            return
        }
        NSLog("Ligature: compile start manual=\(manual)")
        saveAll()
        hasUncompiledChanges = false
        compiling = true
        compileState = .running
        compileSerial += 1
        let serial = compileSerial
        // Watchdog: a compile that hangs (e.g. waiting on a download) is stopped so the app never gets stuck.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard let self, self.compiling, self.compileSerial == serial else { return }
            self.compiler.cancel()
        }
        Task { @MainActor in
            let result = await compiler.compile(engine: engine, main: mainURL, root: root)
            self.compiling = false
            if !result.cancelled {
                self.apply(result, manual: manual)
            } else if self.followUp == nil {
                // Nothing replaced it: don't leave the status on "Typesetting".
                withAnimation(.panel) { self.compileState = self.settledState }
            }
            if let next = self.followUp {
                self.followUp = nil
                self.compile(manual: next)
            }
        }
    }

    private func apply(_ result: CompileResult, manual: Bool) {
        NSLog("Ligature: compile done manual=\(manual) exit=\(result.exitCode) pdf=\(result.pdf?.count ?? 0) issues=\(result.issues.count) %.2fs", result.duration)
        lastDuration = result.duration
        lastCompiled = Date()
        withAnimation(.panel) { issues = result.issues }
        if let pdf = result.pdf, !pdf.isEmpty {
            pdfData = pdf
            pdfVersion += 1
            synctex = result.synctex
        }
        let errors = errorCount
        let ok = errors == 0 && result.pdf != nil
        if manual && result.pdf != nil { scanToken += 1 }
        withAnimation(.panel) { compileState = ok ? .success : .failed }
        settledState = compileState
        // Haptics only for compiles you asked for; live compiles stay silent.
        if manual { Haptics.play(ok ? .success : .failure) }
        if lastErrorCount > 0 && errors == 0 && !manual { showToast("checkmark.circle.fill", "All errors fixed", tint: .green) }
        lastErrorCount = errors
        if manual, let pdf = result.pdf {
            takeSnapshot(pdf: pdf, pages: pageHeights.isEmpty ? nil : pageHeights.count, errors: errors)
        } else if ok {
            takeSnapshot()
        }
    }

    func showToast(_ symbol: String, _ text: String, tint: Color? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        withAnimation(.panel) { toast = Toast(symbol: symbol, text: text, tint: tint, actionTitle: actionTitle, action: action) }
        let id = toast?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? 2.4 : 4.5)) { [weak self] in
            if self?.toast?.id == id { withAnimation(.panel) { self?.toast = nil } }
        }
    }

    func retryEngine() {
        engine = EngineLocator.locate()
        compileState = engine == nil ? .noEngine : .idle
        if engine != nil { compile(manual: true) }
    }

    // MARK: SyncTeX

    /// Editor caret → PDF.
    func syncToPDF(line: Int? = nil, file: String? = nil) {
        guard let s = synctex, let pdfView = pdf else { return }
        let f = file ?? activeDoc?.relativePath ?? mainFile
        let abs = root.appendingPathComponent(f).path
        guard let hit = s.forward(file: abs, line: line ?? caretLine, pageHeight: { [weak self] p in self?.pageHeight(p) ?? 792 }) else { return }
        pdfView.show(page: hit.page, rects: hit.rects)
    }

    var pageHeights: [Int: Double] = [:]
    func pageHeight(_ page: Int) -> Double { pageHeights[page] ?? 792 }

    /// PDF click → editor.
    func syncToSource(page: Int, point: CGPoint, pageHeight: Double, word: String? = nil) {
        guard let s = synctex, let loc = s.inverse(page: page, point: point, pageHeight: pageHeight) else { return }
        let file = loc.file.hasPrefix("/") ? URL(fileURLWithPath: loc.file).standardizedFileURL.path : root.appendingPathComponent(loc.file).standardizedFileURL.path
        let rel = file.hasPrefix(root.path + "/") ? String(file.dropFirst(root.path.count + 1)) : loc.file
        if layout == .preview { withAnimation(.panel) { layout = .split } }
        open(path: rel, line: loc.line)
        if let word, !word.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.editor?.highlightWord(word, nearLine: loc.line) }
        }
    }

    // MARK: Structure (outline, labels, citations, words)

    func scheduleStructure() {
        structureTask?.cancel()
        structureTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self.refreshStructure()
        }
    }

    func refreshStructure() {
        let items = Outline.project(main: mainFile) { [weak self] path in self?.text(of: path) }
        // Files not reachable from the main file still contribute labels (e.g. while restructuring).
        var all = items
        let visited = Set(items.map(\.file))
        for f in texFiles where !visited.contains(f) && f != mainFile {
            if let t = text(of: f) { all += Outline.items(in: t, file: f).filter { $0.kind == .label } }
        }
        if all != outline { outline = all }
        var bibs: [BibEntry] = []
        for node in FileNode.flatten(tree) where node.name.hasSuffix(".bib") {
            if let t = text(of: node.path) { bibs += BibTeX.parse(t, file: node.path) }
        }
        if bibs != bibEntries { bibEntries = bibs }
        let reachable = Set(items.map(\.file)).union([mainFile])
        words = reachable.reduce(0) { $0 + (text(of: $1).map(LaTeXText.wordCount) ?? 0) }
        updateCurrentSection()
    }

    func updateCurrentSection() {
        guard let doc = activeDoc else { currentSection = nil; return }
        currentSection = outline.last { $0.file == doc.relativePath && $0.kind.isHeading && $0.line <= caretLine }
    }

    // MARK: History

    private func takeSnapshot(pdf: Data? = nil, pages: Int? = nil, errors: Int? = nil) {
        var files: [String: String] = [:]
        for node in FileNode.flatten(tree) where !node.isDirectory {
            let ext = (node.name as NSString).pathExtension.lowercased()
            guard ["tex", "bib", "sty", "cls", "ltx"].contains(ext), let t = text(of: node.path), t.utf8.count < 1_500_000 else { continue }
            files[node.path] = t
        }
        let latest = snapshots.first
        let root = root, words = words
        Task.detached(priority: .utility) {
            let snap = HistoryStore.save(root: root, files: files, words: words, latest: latest, pdf: pdf, pages: pages, errors: errors)
            if let snap { await MainActor.run { self.snapshots.insert(snap, at: 0) } }
        }
    }

    /// Puts every file back the way it was at that version, then compiles. The current state is saved first so
    /// this can itself be undone from History.
    func restoreProject(to snap: Snapshot) {
        takeSnapshot()
        for (path, old) in snap.files {
            if let doc = openDocs.first(where: { $0.relativePath == path }) {
                let current = doc.text
                guard current != old else { continue }
                doc.undoManager.registerUndo(withTarget: doc.storage) { s in s.replaceCharacters(in: NSRange(location: 0, length: s.length), with: current) }
                doc.storage.replaceCharacters(in: NSRange(location: 0, length: doc.storage.length), with: old)
                doc.rehighlight()
            } else {
                let url = root.appendingPathComponent(path)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? old.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        saveAll()
        refreshStructure()
        showToast("arrow.uturn.backward.circle.fill", "Restored the version from \(snap.date.formatted(date: .omitted, time: .shortened))")
        compile(manual: true)
    }

    func restore(file: String, from snap: Snapshot) {
        guard let old = snap.files[file] else { return }
        takeSnapshot()
        if let doc = open(path: file) {
            let range = NSRange(location: 0, length: doc.storage.length)
            doc.undoManager.registerUndo(withTarget: doc.storage) { [current = doc.text] s in
                s.replaceCharacters(in: NSRange(location: 0, length: s.length), with: current)
            }
            doc.storage.replaceCharacters(in: range, with: old)
            doc.rehighlight()
        } else {
            try? old.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        showToast("clock.arrow.circlepath", "Restored \((file as NSString).lastPathComponent)")
    }

    // MARK: Downloads

    /// The name exported files get by default: the main file's name ("report.tex" → "report"), or the
    /// project's name when the main file is the template default "main.tex".
    var exportBaseName: String {
        let base = ((mainFile as NSString).lastPathComponent as NSString).deletingPathExtension
        return base.lowercased() == "main" ? name : base
    }

    /// Saves the PDF straight into ~/Downloads under the default name (adding " 2", " 3"… rather than
    /// overwriting), with no dialog.
    func quickDownload() {
        guard let data = pdfData else { return }
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var url = dir.appendingPathComponent(exportBaseName + ".pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("\(exportBaseName) \(n).pdf"); n += 1 }
        do {
            try data.write(to: url)
            recordDownload(.pdf, to: url)
            showToast("arrow.down.circle.fill", "Saved \(url.lastPathComponent) to Downloads", actionTitle: "Show") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            showToast("exclamationmark.triangle.fill", "Couldn't save: \(error.localizedDescription)", tint: Color(theme.error))
        }
    }

    func recordDownload(_ kind: DownloadRecord.Kind, to url: URL) {
        downloads = DownloadStore.record(root: root, kind: kind, destination: url, pages: kind == .pdf ? pageCountOfLastPDF : nil, words: words)
    }

    var pageCountOfLastPDF: Int? { pageHeights.isEmpty ? nil : pageHeights.count }

    func removeDownload(_ r: DownloadRecord) { downloads = DownloadStore.remove(r, root: root) }

    // MARK: Renaming

    /// Renames the project folder. Returns the new URL; the window reopens on it.
    func renameProject(to raw: String) -> Result<URL, Error> {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty else { return .failure(NSError(domain: "Ligature", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a name."])) }
        let dest = root.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        if dest.standardizedFileURL.path == root.path { return .success(root) }
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            return .failure(NSError(domain: "Ligature", code: 2, userInfo: [NSLocalizedDescriptionKey: "A folder called “\(name)” already exists here."]))
        }
        saveAll()
        compiler.cancel()
        let oldHistory = HistoryStore.directory(for: root)
        let oldDownloads = DownloadStore.directory(for: root)
        do {
            try FileManager.default.moveItem(at: root, to: dest)
        } catch {
            return .failure(error)
        }
        // Keep version history and past downloads with the project.
        let newHistory = HistoryStore.directory(for: dest)
        try? FileManager.default.removeItem(at: newHistory)
        try? FileManager.default.moveItem(at: oldHistory, to: newHistory)
        let newDownloads = DownloadStore.directory(for: dest)
        try? FileManager.default.removeItem(at: newDownloads)
        try? FileManager.default.moveItem(at: oldDownloads, to: newDownloads)
        if let old = Recents.shared.items.first(where: { $0.path == root.path }) { Recents.shared.remove(old) }
        Recents.shared.touch(dest, main: mainFile)
        watcher = nil
        movedTo = dest
        return .success(dest)
    }

    // MARK: Quick fixes

    func apply(_ fix: Advice.Fix) {
        switch fix {
        case .addPackage(let name, let options):
            guard let doc = open(path: mainFile), let r = LaTeXText.addingPackage(name, options: options, to: doc.text) else { return }
            let range = NSRange(location: 0, length: doc.storage.length)
            let old = doc.text
            doc.undoManager.registerUndo(withTarget: doc.storage) { s in s.replaceCharacters(in: NSRange(location: 0, length: s.length), with: old) }
            doc.storage.replaceCharacters(in: range, with: r.text)
            doc.rehighlight()
            editor?.reveal(line: r.line, column: nil, flash: true)
            showToast("shippingbox.fill", "Added \\usepackage{\(name)}")
        case .replace(let line, let find, let with):
            guard let doc = activeDoc, let r = LaTeXText.range(ofLine: line, in: doc.text as NSString) else { return }
            let lineText = (doc.text as NSString).substring(with: r)
            doc.storage.replaceCharacters(in: r, with: lineText.replacingOccurrences(of: find, with: with))
        case .insertAtLineEnd(let line, let text):
            guard let doc = activeDoc, let r = LaTeXText.range(ofLine: line, in: doc.text as NSString) else { return }
            doc.storage.replaceCharacters(in: NSRange(location: NSMaxRange(r), length: 0), with: text)
        }
        compile(manual: false)
    }

    // MARK: Bibliography

    /// Appends BibTeX to the project's first .bib file (creating references.bib if needed).
    func addBibTeX(_ entry: String) -> String? {
        let bibPath = FileNode.flatten(tree).first { $0.name.hasSuffix(".bib") }?.path ?? "references.bib"
        let url = root.appendingPathComponent(bibPath)
        var existing = text(of: bibPath) ?? ""
        let key = BibTeX.parse(entry, file: bibPath).first?.key
        if let key, bibEntries.contains(where: { $0.key == key }) { return key }
        if !existing.isEmpty && !existing.hasSuffix("\n\n") { existing += existing.hasSuffix("\n") ? "\n" : "\n\n" }
        let updated = existing + entry
        if let doc = openDocs.first(where: { $0.relativePath == bibPath }) {
            doc.storage.replaceCharacters(in: NSRange(location: doc.storage.length, length: 0), with: String(updated.dropFirst(doc.storage.length)))
            doc.save()
        } else {
            try? updated.write(to: url, atomically: true, encoding: .utf8)
        }
        tree = FileNode.scan(root: root)
        refreshStructure()
        return key
    }
}
