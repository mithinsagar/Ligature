import AppKit
import LigatureCore

/// One open text file. Its NSTextStorage is the single source of truth while it's open; the editor view attaches
/// to it and it is written back to disk (debounced) on every change.
@MainActor
final class TextDocument: NSObject, NSTextStorageDelegate, Identifiable {
    let id = UUID()
    let url: URL
    let relativePath: String
    let storage = NSTextStorage()
    let undoManager = UndoManager()
    private(set) var savedText: String
    var selection = NSRange(location: 0, length: 0)
    var scrollY: CGFloat = 0
    var onChange: ((TextDocument) -> Void)?
    /// Called when the undo/redo position moves, so buttons and the history scrubber can refresh.
    var onUndoChange: (() -> Void)?
    private var applyingExternal = false
    /// The text as it was when the file was opened, for "Back to when you opened it".
    let openedText: String
    /// How many edits can be undone / redone (NSUndoManager doesn't expose counts).
    private(set) var undoDepth = 0
    private(set) var redoDepth = 0
    private var observers: [NSObjectProtocol] = []
    /// The project this file belongs to (Visual mode needs it to find figures and the preamble).
    weak var project: ProjectModel?

    var name: String { url.lastPathComponent }
    var kind: Kind { Kind(url.pathExtension) }
    var isDirty: Bool { storage.string != savedText }
    var text: String { storage.string }

    enum Kind {
        case tex, bib, other
        init(_ ext: String) {
            switch ext.lowercased() {
            case "tex", "sty", "cls", "ltx", "dtx", "tikz": self = .tex
            case "bib": self = .bib
            default: self = .other
            }
        }
    }

    init(url: URL, relativePath: String) throws {
        self.url = url
        self.relativePath = relativePath
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        savedText = text
        openedText = text
        super.init()
        storage.delegate = self
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .NSUndoManagerDidCloseUndoGroup, object: undoManager, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.undoManager.groupingLevel == 0, !self.undoManager.isUndoing, !self.undoManager.isRedoing else { return }
                self.undoDepth += 1
                self.redoDepth = 0
                self.onUndoChange?()
            }
        })
        observers.append(nc.addObserver(forName: .NSUndoManagerDidUndoChange, object: undoManager, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.undoDepth = max(0, self.undoDepth - 1)
                self.redoDepth += 1
                self.onUndoChange?()
            }
        })
        observers.append(nc.addObserver(forName: .NSUndoManagerDidRedoChange, object: undoManager, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.undoDepth += 1
                self.redoDepth = max(0, self.redoDepth - 1)
                self.onUndoChange?()
            }
        })
        storage.setAttributedString(NSAttributedString(string: text, attributes: Highlighter.baseAttributes()))
        Highlighter.highlightAll(storage, kind: kind)
    }

    func save() {
        guard isDirty else { return }
        let text = storage.string
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            savedText = text
        } catch {
            NSLog("Ligature: could not save \(url.path): \(error)")
        }
    }

    /// Picks up a change made outside the app, unless there are unsaved edits here.
    func reloadIfChangedOnDisk() -> Bool {
        guard !isDirty, let disk = try? String(contentsOf: url, encoding: .utf8), disk != savedText else { return false }
        applyingExternal = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: disk)
        storage.endEditing()
        applyingExternal = false
        savedText = disk
        Highlighter.highlightAll(storage, kind: kind, project: project)
        return true
    }

    /// Replaces the whole text as one undoable step (used by the "back to…" actions).
    func replaceAll(with text: String, actionName: String) {
        guard text != storage.string else { return }
        let current = storage.string
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { doc in doc.replaceAll(with: current, actionName: actionName) }
        undoManager.setActionName(actionName)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        undoManager.endUndoGrouping()
        rehighlight()
    }

    /// Throws away edits since the last save.
    func revert() {
        guard isDirty else { return }
        applyingExternal = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: savedText)
        storage.endEditing()
        applyingExternal = false
        Highlighter.highlightAll(storage, kind: kind, project: project)
    }

    func rehighlight() {
        storage.beginEditing()
        storage.addAttributes(Highlighter.baseAttributes(), range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        Highlighter.highlightAll(storage, kind: kind, project: project)
    }

    // MARK: NSTextStorageDelegate

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            FoldStore.adjust(textStorage, edited: editedRange, delta: delta)
            CommentAnchors.adjust(textStorage, edited: editedRange, delta: delta)
            Highlighter.highlightEdited(textStorage, range: editedRange, kind: kind, project: project)
            if !applyingExternal { onChange?(self) }
        }
    }
}

/// A file or folder in the project sidebar.
struct FileNode: Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String          // relative to the project root
    var isDirectory: Bool
    var children: [FileNode]?

    var symbol: String {
        if isDirectory { return "folder" }
        switch (name as NSString).pathExtension.lowercased() {
        case "tex", "ltx": return "doc.text"
        case "bib": return "books.vertical"
        case "sty", "cls": return "puzzlepiece.extension"
        case "png", "jpg", "jpeg", "gif", "tiff", "heic", "svg", "eps": return "photo"
        case "pdf": return "doc.richtext"
        case "csv", "dat", "tsv": return "tablecells"
        case "md", "txt": return "text.alignleft"
        default: return "doc"
        }
    }

    var isText: Bool {
        ["tex", "ltx", "bib", "sty", "cls", "dtx", "txt", "md", "csv", "tsv", "dat", "tikz", "bst", "cfg", "def", "clo"].contains((name as NSString).pathExtension.lowercased())
    }

    var isImage: Bool { ["png", "jpg", "jpeg", "pdf", "eps", "gif", "tiff", "heic", "svg"].contains((name as NSString).pathExtension.lowercased()) }

    static let hiddenExtensions: Set<String> = ["aux", "log", "out", "toc", "lof", "lot", "fls", "fdb_latexmk", "bbl", "blg", "xdv", "nav", "snm", "vrb", "bcf", "run.xml", "synctex", "gz", "idx", "ind", "ilg", "dvi"]

    static func scan(root: URL) -> [FileNode] {
        func walk(_ dir: URL, prefix: String, depth: Int) -> [FileNode] {
            guard depth < 8, let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
            var nodes: [FileNode] = []
            for url in items {
                let name = url.lastPathComponent
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if !isDir && hiddenExtensions.contains(url.pathExtension.lowercased()) { continue }
                if isDir && (name == "node_modules" || name.hasPrefix("_minted")) { continue }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                nodes.append(FileNode(name: name, path: path, isDirectory: isDir, children: isDir ? walk(url, prefix: path, depth: depth + 1) : nil))
            }
            return nodes.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        return walk(root, prefix: "", depth: 0)
    }

    static func flatten(_ nodes: [FileNode]) -> [FileNode] {
        nodes.flatMap { [$0] + flatten($0.children ?? []) }
    }
}

/// Watches a folder tree with FSEvents and calls back (on the main queue) when anything inside changes.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let callback: () -> Void

    init(url: URL, callback: @escaping () -> Void) {
        self.callback = callback
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.callback()
        }
        stream = FSEventStreamCreate(nil, cb, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
