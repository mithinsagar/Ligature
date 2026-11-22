import SwiftUI
import UniformTypeIdentifiers
import LigatureCore

@main
struct LigatureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Welcome to Ligature", id: "welcome") {
            WelcomeView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands { AppCommands() }

        WindowGroup("Project", id: "project", for: URL.self) { $url in
            ProjectWindow(url: url)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1440, height: 900)

        // The PDF in a window of its own (e.g. on a second display), for the project at this root.
        WindowGroup("PDF", id: "pdf", for: URL.self) { $root in
            DetachedPDFWindow(root: root)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 760, height: 980)

        Window("Keyboard Shortcuts", id: "shortcuts") {
            ShortcutsView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = ThemeManager.shared
        // Test hook: open a project straight away (LIGATURE_OPEN=/path/to/project).
        if let path = ProcessInfo.processInfo.environment["LIGATURE_OPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                OpenProjectBridge.shared.open?(URL(fileURLWithPath: path))
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting with edits since the last compile asks whether to keep them.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let dirty = ProjectModel.openModels.allObjects.filter { !$0.dirtyPaths.isEmpty && $0.movedTo == nil }
            guard !dirty.isEmpty else { return .terminateNow }
            let files = dirty.flatMap { m in m.dirtyPaths.sorted().map { "\(m.name)/\(($0 as NSString).lastPathComponent)" } }
            let alert = NSAlert()
            alert.messageText = "Save your latest edits before quitting?"
            alert.informativeText = "Edited since the last compile: \(files.joined(separator: ", ")). Ligature keeps what you last compiled either way."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                dirty.forEach { $0.saveAll() }
                return .terminateNow
            case .alertSecondButtonReturn:
                dirty.forEach { $0.discardChanges() }
                return .terminateNow
            default:
                return .terminateCancel
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { OpenProjectBridge.shared.showWelcome?() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls { OpenProjectBridge.shared.open?(u) }
    }
}

/// Lets AppKit callbacks (Finder opens, Dock reopen, test hooks) reach SwiftUI's window actions.
@MainActor final class OpenProjectBridge {
    static let shared = OpenProjectBridge()
    var open: ((URL) -> Void)?
    var showWelcome: (() -> Void)?
    var showSettings: (() -> Void)?
}

/// Hosts one project. A file URL opens its folder with that file as the main file.
struct ProjectWindow: View {
    let url: URL?
    @State private var model: ProjectModel?
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let model {
                WorkspaceView(model: model)
            } else {
                Color(theme.canvas).frame(minWidth: 900, minHeight: 560)
            }
        }
        .onAppear {
            OpenProjectBridge.shared.open = { u in openWindow(id: "project", value: u) }
            OpenProjectBridge.shared.showWelcome = { openWindow(id: "welcome") }
            guard model == nil else { return }
            var isDir: ObjCBool = false
            // A restored window whose project no longer exists closes itself instead of showing nothing.
            guard let url, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                DispatchQueue.main.async { dismiss() }
                return
            }
            if isDir.boolValue {
                model = ProjectModel(root: url)
            } else {
                model = ProjectModel(root: url.deletingLastPathComponent(), preferredMain: url.lastPathComponent)
            }
            dismissWindow(id: "welcome")
        }
    }
}

// MARK: Menus

struct AppCommands: Commands {
    @FocusedValue(\.project) private var project
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project…") { openWindow(id: "welcome") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New File…") { project?.showNewFile = true }
                .keyboardShortcut("n")
                .disabled(project == nil)
            Button("Open…") { openPanel() }
                .keyboardShortcut("o")
            Button("Import…") { importPanel() }.keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Rename Project…") { project?.showRename = true }
                .disabled(project == nil)
            Menu("Open Recent") {
                ForEach(Recents.shared.items.prefix(10)) { r in
                    Button(r.name) { openWindow(id: "project", value: r.url) }
                }
            }
        }
        CommandGroup(after: .saveItem) {
            Button("Save") { project?.saveAll() }
                .keyboardShortcut("s")
                .disabled(project == nil)
            Button("Download PDF…") { if let p = project { ExportMenu(model: p).exportPDF() } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(project?.pdfData == nil)
            Button("Quick Download PDF") { project?.quickDownload() }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(project?.pdfData == nil)
            Button("Download as Word…") { if let p = project { ExportMenu(model: p).exportWord() } }
            Button("Download as Markdown…") { if let p = project { ExportMenu(model: p).exportDocument(.markdown) } }
            Button("Download as Web Page…") { if let p = project { ExportMenu(model: p).exportDocument(.html) } }
                .disabled(project == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print PDF…") { project?.pdf?.print() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(project?.pdfData == nil)
        }
        CommandMenu("Typeset") {
            Button("Compile") { project?.compile(manual: true) }.keyboardShortcut("r")
            Button("Show Caret in PDF") { project?.syncToPDF() }.keyboardShortcut("j", modifiers: [.command, .shift])
            Divider()
            Toggle("Live Compile", isOn: Binding(get: { Preferences.shared.liveCompile }, set: { v in
                if let p = project { p.setLiveCompile(v) } else { Preferences.shared.liveCompile = v }
            }))
                .keyboardShortcut("l", modifiers: [.command, .option])
            Toggle("PDF Follows Caret", isOn: Binding(get: { Preferences.shared.followCaret }, set: { Preferences.shared.followCaret = $0 }))
            Toggle("Dark Paper", isOn: Binding(get: { Preferences.shared.pdfDarkPaper }, set: { Preferences.shared.pdfDarkPaper = $0 }))
        }
        CommandMenu("Insert") {
            Button("Table…") { project?.tableReplaceRange = nil; project?.tableDraft = TableModel(rows: 3, columns: 3) }.keyboardShortcut("t", modifiers: [.command, .option])
            Button("Figure…") { project?.showFigureSheet = true }.keyboardShortcut("g", modifiers: [.command, .option])
            Button("Citation…") { project?.showCitationSheet = true }.keyboardShortcut("c", modifiers: [.command, .option, .shift])
            Divider()
            Button("Bold") { project?.editor?.wrapSelection(prefix: "\\textbf{", suffix: "}") }.keyboardShortcut("b")
            Button("Italic") { project?.editor?.wrapSelection(prefix: "\\textit{", suffix: "}") }.keyboardShortcut("i")
            Button("Underline") { project?.editor?.wrapSelection(prefix: "\\underline{", suffix: "}") }.keyboardShortcut("u")
            Button("Inline Math") { project?.editor?.wrapSelection(prefix: "$", suffix: "$") }.keyboardShortcut("m", modifiers: [.command, .shift])
            Divider()
            Button("Add Comment…") { project?.beginComment() }.keyboardShortcut("m", modifiers: [.command, .option])
            Button("Toggle Comment") { NSApp.sendAction(#selector(LaTeXTextView.toggleComment(_:)), to: nil, from: nil) }.keyboardShortcut("/")
        }
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }.keyboardShortcut("/", modifiers: [.command, .option])
        }
        CommandGroup(before: .toolbar) {
            Button("Command Palette…") { project?.showPalette = true }.keyboardShortcut("k")
            Button("Quick Open…") { project?.showPalette = true }.keyboardShortcut("p")
            Button("Go to Line…") { PaletteSeed.shared.text = ":"; project?.showPalette = true }.keyboardShortcut("l")
            Button("Find in Project…") {
                if let sel = project?.editor?.selectedText(), !sel.isEmpty, !sel.contains("\n") { project?.searchQuery = sel }
                project?.sidebarTab = .search; project?.showSidebar = true
            }.keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Editor Only") { withAnimation(.panel) { project?.layout = .editor } }.keyboardShortcut("1")
            Button("Editor and PDF") { withAnimation(.panel) { project?.layout = .split } }.keyboardShortcut("2")
            Button("PDF Only") { withAnimation(.panel) { project?.layout = .preview } }.keyboardShortcut("3")
            Button("Focus Mode") { withAnimation(.panel) { project?.focusMode.toggle() } }.keyboardShortcut(.return, modifiers: [.command, .option])
            Button("Present PDF") {
                if let p = project, let d = p.pdfData { PresentationController.start(data: d, page: (p.pdf as? PDFRepresentable.Coordinator)?.state?.page ?? 1, screen: NSApp.keyWindow?.screen) }
            }.keyboardShortcut("p", modifiers: [.command, .option])
            Button("Fit PDF Width") { (project?.pdf as? PDFRepresentable.Coordinator)?.state?.fitWidth() }
            Button("Fit Whole PDF Page") { (project?.pdf as? PDFRepresentable.Coordinator)?.state?.fitHeight() }
            Divider()
            Button("Fold") { project?.editor?.fold(.foldHere) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Unfold") { project?.editor?.fold(.unfoldHere) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Fold All") { project?.editor?.fold(.foldAll) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift])
            Button("Unfold All") { project?.editor?.fold(.unfoldAll) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])
            Divider()
            Button("Bigger Text") { Preferences.shared.editorFontSize = min(24, Preferences.shared.editorFontSize + 1) }.keyboardShortcut("=")
            Button("Smaller Text") { Preferences.shared.editorFontSize = max(10, Preferences.shared.editorFontSize - 1) }.keyboardShortcut("-")
            Divider()
            ForEach(SidebarTab.allCases) { tab in
                Button("Show \(tab.title)") { project?.sidebarTab = tab; project?.showSidebar = true }
            }
            Divider()
        }
    }

    /// A .zip project, a Word document or a Markdown file becomes a new project.
    func importPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["zip", "docx", "md", "markdown", "odt", "rtf", "html"].compactMap { UTType(filenameExtension: $0) }
        p.prompt = "Import"
        p.message = "Choose a .zip project, a Word document or a Markdown file"
        guard p.runModal() == .OK, let u = p.url else { return }
        do { openWindow(id: "project", value: try ProjectImporter.importFile(u)) } catch {
            let a = NSAlert(); a.messageText = "Couldn't import \(u.lastPathComponent)"; a.informativeText = error.localizedDescription; a.runModal()
        }
    }

    func openPanel() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.prompt = "Open"
        if p.runModal() == .OK, let u = p.url { openWindow(id: "project", value: u) }
    }
}
