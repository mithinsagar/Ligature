import SwiftUI
import UniformTypeIdentifiers
import LigatureCore

/// A project window: sidebar, editor and PDF, with the toolbar, status bar and overlays.
struct WorkspaceView: View {
    @State var model: ProjectModel
    @State private var splitFraction: CGFloat = UserDefaults.standard.object(forKey: "splitFraction") as? CGFloat ?? 0.5
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var hostWindow: NSWindow?
    @State private var closeGuard: CloseGuard?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            ZStack(alignment: .top) {
                content
                if let toast = model.toast {
                    ToastView(toast: toast)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(5)
                }
            }
            .background {
                // Lit backdrop, mirrored under the glass sidebar and toolbar.
                AmbientBackdrop(pulse: model.pdfVersion)
                    .backgroundExtensionEffect()
            }
        }
        .navigationTitle(model.name)
        .navigationSubtitle(subtitle)
        .toolbarTitleMenu {
            Button("Rename Project…", systemImage: "pencil") { model.showRename = true }
            Button("Reveal in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([model.root]) }
            Divider()
            Menu("Main File") {
                ForEach(model.texFiles, id: \.self) { f in
                    Button { model.mainFile = f } label: { if f == model.mainFile { Label(f, systemImage: "checkmark") } else { Text(f) } }
                }
            }
        }
        .toolbar { WorkspaceToolbar(model: model) }
        .toolbar(model.focusMode ? .hidden : .automatic, for: .windowToolbar)
        .overlay(alignment: .top) { if model.focusMode { FocusExitBar(model: model) } }
        .onChange(of: model.focusMode) { _, on in
            withAnimation(.panel) { columnVisibility = on ? .detailOnly : (model.showSidebar ? .all : .detailOnly) }
        }
        .overlay {
            if model.showPalette {
                CommandPalette(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    .zIndex(10)
            }
        }
        .animation(.panel, value: model.showPalette)
        .sheet(item: Binding(get: { model.tableDraft.map { TableDraftBox(table: $0) } }, set: { model.tableDraft = $0?.table })) { box in
            TableBuilderSheet(model: model, initial: box.table)
        }
        .sheet(isPresented: $model.showCitationSheet) { AddCitationSheet(model: model) }
        .sheet(item: $model.errorAssistIssue) { issue in ErrorAssistSheet(model: model, issue: issue) }
        .sheet(isPresented: $model.showFigureSheet) { FigureSheet(model: model) }
        .sheet(isPresented: $model.showNewFile) { NewFileSheet(model: model) }
        .sheet(isPresented: $model.showDownloads) { DownloadsSheet(model: model) }
        .sheet(isPresented: $model.showRename) {
            RenameProjectSheet(model: model)
        }
        .focusedSceneValue(\.project, model)
        .preferredColorScheme(Preferences.shared.themeID == "auto" ? nil : (theme.isDark ? .dark : .light))
        .tint(accent)
        .onChange(of: columnVisibility) { _, v in if !model.focusMode { model.showSidebar = v != .detailOnly } }
        .onChange(of: model.showSidebar) { _, show in
            withAnimation(.panel) { columnVisibility = show ? .all : .detailOnly }
        }
        .onAppear {
            OpenProjectBridge.shared.showSettings = { openSettings() }
            TestScript.runIfRequested(model: model)
        }
        .onChange(of: model.movedTo) { _, url in
            // The folder was renamed: reopen the project from its new location and close this window.
            guard let url else { return }
            let old = hostWindow
            NSLog("Ligature: project moved to \(url.path); closing \(old?.title ?? "nil")")
            openWindow(id: "project", value: url)
            DispatchQueue.main.async { old?.close() }
        }
        .background(WindowReader(window: $hostWindow))
        .onChange(of: hostWindow) { _, w in
            guard let w, closeGuard == nil else { return }
            closeGuard = CloseGuard(window: w) { [weak model] window in
                guard let model, !model.dirtyPaths.isEmpty, model.movedTo == nil else { return true }
                if let g = closeGuard { model.confirmClose(window: window, guard: g) }
                return false
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    var subtitle: String {
        if let s = model.currentSection { return s.title }
        return model.activeDoc?.relativePath ?? model.mainFile
    }

    @ViewBuilder var content: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 0) {
                if model.layout != .preview {
                    EditorColumn(model: model)
                        .floatingSurface(cornerRadius: 16)
                        .padding(.leading, 10)
                        .padding(.trailing, model.layout == .editor ? 10 : 0)
                        .padding(.top, 4)
                        .padding(.bottom, 10)
                        .frame(width: model.layout == .editor ? width : max(330, min(width - 280, width * splitFraction)))
                        .zIndex(1)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if model.layout == .split {
                    SplitDivider(fraction: $splitFraction, totalWidth: width)
                        .zIndex(2)
                }
                if model.layout != .editor {
                    Group {
                        if model.pdfDetached {
                            VStack(spacing: 10) {
                                EmptyState(symbol: "macwindow.on.rectangle", title: "The PDF is in its own window", message: "Close that window to bring it back here.")
                                    .frame(height: 130)
                            }
                        } else {
                            PDFPane(model: model)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.panel, value: model.layout)
        }
    }
}

/// In Focus mode: a thin bar that appears when the pointer reaches the top, to leave Focus mode.
private struct FocusExitBar: View {
    let model: ProjectModel
    @State private var hovering = false
    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.frame(height: 34).contentShape(Rectangle())
            if hovering {
                Button { withAnimation(.panel) { model.focusMode = false } } label: {
                    Label("Leave Focus Mode  ⌥⌘↩", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onHover { h in withAnimation(.hover) { hovering = h } }
    }
}

private struct TableDraftBox: Identifiable {
    let id = UUID()
    let table: TableModel
}

// MARK: Editor column (tabs + editor + status bar)

struct EditorColumn: View {
    @Bindable var model: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.focusMode { EditorTabs(model: model) }
            ZStack {
                EditorView(model: model)
                if model.activeDoc == nil {
                    Color(theme.editor)
                    EmptyState(symbol: "doc.text", title: "No file open", message: "Choose a file in the sidebar, or press ⌘P to open one quickly.")
                }
            }
            if !model.focusMode { StatusBar(model: model) }
        }
        .background(Color(theme.editor))
    }
}

struct EditorTabs: View {
    @Bindable var model: ProjectModel

    var body: some View {
        HStack(spacing: 6) {
            tabs
            ModeSwitch()
            UndoControls(model: model)
                .padding(.trailing, 8)
        }
        .frame(height: 40)
        .background(Color(theme.editor))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(theme.hairline)).frame(height: 0.5) }
    }

    var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.openDocs) { doc in
                    EditorTab(doc: doc, active: model.activeDoc === doc, isMain: doc.relativePath == model.mainFile, dirty: model.dirtyPaths.contains(doc.relativePath),
                              select: { model.activate(doc) },
                              close: { model.close(doc) })
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}

/// Code / Visual, like Overleaf.
struct ModeSwitch: View {
    enum Mode: String, CaseIterable { case code, visual }
    var body: some View {
        SlidingTabs(items: Mode.allCases,
                    selection: Binding(get: { Preferences.shared.visualMode ? .visual : .code }, set: { Preferences.shared.visualMode = $0 == .visual }),
                    symbol: { $0 == .code ? "chevron.left.forwardslash.chevron.right" : "text.book.closed" },
                    title: { $0 == .code ? "Code" : "Visual" }, iconOnly: false, height: 22)
            .fixedSize()
            .help("Code shows the LaTeX source; Visual shows it formatted, with markup hidden except on the line you're editing")
    }
}

/// Undo and redo, plus an edit-history card (hover on Undo, or click the clock) with a scrubber through every
/// edit this session and one-click returns to the last compile or to when the file was opened.
struct UndoControls: View {
    let model: ProjectModel
    @State private var showHistory = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        let _ = model.undoTick
        let doc = model.activeDoc
        let um = doc?.undoManager
        HStack(spacing: 0) {
            IconButton(symbol: "arrow.uturn.backward", help: um?.canUndo == true ? "Undo \(um!.undoActionName)".trimmingCharacters(in: .whitespaces) : "Nothing to undo",
                       shortcut: "⌘Z", size: 26) { um?.undo() }
                .opacity(um?.canUndo == true ? 1 : 0.4)
                .onHover { h in
                    hoverTask?.cancel()
                    guard h, doc != nil else { return }
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(700))
                        if !Task.isCancelled { showHistory = true }
                    }
                }
            IconButton(symbol: "arrow.uturn.forward", help: um?.canRedo == true ? "Redo \(um!.redoActionName)".trimmingCharacters(in: .whitespaces) : "Nothing to redo",
                       shortcut: "⇧⌘Z", size: 26) { um?.redo() }
                .opacity(um?.canRedo == true ? 1 : 0.4)
            IconButton(symbol: "clock.arrow.circlepath", help: "Edit history", size: 26) { showHistory.toggle() }
                .popover(isPresented: $showHistory, arrowEdge: .bottom) { EditHistoryCard(model: model) }
        }
        .disabled(doc == nil)
    }
}

struct EditHistoryCard: View {
    let model: ProjectModel

    var body: some View {
        let _ = model.undoTick
        VStack(alignment: .leading, spacing: 12) {
            if let doc = model.activeDoc {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(accent)
                    Text("Edit history").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(doc.name).font(.system(size: 11)).foregroundStyle(Color(theme.secondary))
                }
                let total = doc.undoDepth + doc.redoDepth
                if total > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: Binding(get: { Double(doc.undoDepth) }, set: { scrub(doc, to: Int($0.rounded())) }),
                               in: 0...Double(total), step: 1)
                        HStack {
                            Text("Earliest").font(.system(size: 10.5)).foregroundStyle(Color(theme.secondary))
                            Spacer()
                            Text(doc.redoDepth == 0 ? "Latest · \(total) edit\(total == 1 ? "" : "s")" : "\(doc.redoDepth) step\(doc.redoDepth == 1 ? "" : "s") back")
                                .font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(accent)
                            Spacer()
                            Text("Latest").font(.system(size: 10.5)).foregroundStyle(Color(theme.secondary))
                        }
                    }
                    Text("Drag to step through your edits. The editor updates as you go.")
                        .font(.system(size: 11)).foregroundStyle(Color(theme.secondary))
                } else {
                    Text("No edits yet since you opened this file.").font(.system(size: 11.5)).foregroundStyle(Color(theme.secondary))
                }
                Divider()
                VStack(spacing: 4) {
                    action("arrow.uturn.backward.circle", "Back to last compile", enabled: doc.isDirty) {
                        doc.replaceAll(with: doc.savedText, actionName: "Back to Last Compile")
                    }
                    action("arrow.counterclockwise.circle", "Back to when you opened it", enabled: doc.text != doc.openedText) {
                        doc.replaceAll(with: doc.openedText, actionName: "Back to Opened Version")
                    }
                    action("clock", "Version history…", enabled: true) {
                        model.sidebarTab = .history
                        model.showSidebar = true
                    }
                }
                Text("Every step here can be undone, and redone.").font(.system(size: 10.5)).foregroundStyle(Color(theme.secondary).opacity(0.8))
            }
        }
        .padding(16)
        .frame(width: 310)
    }

    func action(_ symbol: String, _ title: String, enabled: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(accent)
                Text(title).font(.system(size: 12.5)).foregroundStyle(Color(theme.text))
                Spacer()
            }
            .padding(.horizontal, 8).frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverRow()
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    func scrub(_ doc: TextDocument, to target: Int) {
        while doc.undoDepth > target && doc.undoManager.canUndo { doc.undoManager.undo() }
        while doc.undoDepth < target && doc.undoManager.canRedo { doc.undoManager.redo() }
    }
}

private struct EditorTab: View {
    let doc: TextDocument
    let active: Bool
    let isMain: Bool
    let dirty: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false
    @State private var hoverClose = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: doc.kind == .bib ? "books.vertical" : "doc.text")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(active ? accent : Color(theme.secondary))
            Text(doc.name)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(Color(theme.text).opacity(active ? 1 : 0.75))
            if isMain {
                Image(systemName: "star.fill").font(.system(size: 7.5)).foregroundStyle(accent.opacity(0.8)).help("Main file")
            }
            ZStack {
                if dirty && !hovering {
                    // Unsaved edits: a dot, which turns into the close button on hover (like Xcode).
                    Circle().fill(Color(theme.text).opacity(0.55)).frame(width: 7, height: 7).help("Edited since the last compile")
                } else if hovering || active {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color(theme.text).opacity(hoverClose ? 0.12 : 0)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(theme.secondary))
                    .onHover { h in withAnimation(.hover) { hoverClose = h } }
                    .help("Close tab  ⌘W")
                }
            }
            .frame(width: 16)
        }
        .padding(.leading, 10).padding(.trailing, 5)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? Color(theme.text).opacity(theme.isDark ? 0.09 : 0.06) : Color(theme.text).opacity(hovering ? 0.04 : 0))
        )
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(active ? Color(theme.hairline) : .clear, lineWidth: 0.75))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { h in withAnimation(.hover) { hovering = h } }
        .animation(.hover, value: active)
    }
}

// MARK: Divider with snapping

/// Drag to resize editor/PDF. Snaps (with an alignment haptic) to ⅓, ½ and ⅔; double-click resets to ½.
struct SplitDivider: View {
    @Binding var fraction: CGFloat
    let totalWidth: CGFloat
    @State private var hovering = false
    @State private var dragging = false
    @State private var snappedTo: CGFloat?
    @State private var startFraction: CGFloat = 0.5

    static let stops: [CGFloat] = [1.0 / 3.0, 0.5, 2.0 / 3.0]

    var body: some View {
        ZStack {
            Capsule()
                .fill(dragging || hovering ? accent : Color(theme.secondary).opacity(0.35))
                .shadow(color: accent.opacity(dragging || hovering ? 0.6 : 0), radius: 6)
                .frame(width: 3, height: dragging ? 54 : 34)
                .animation(.press, value: dragging)
                .animation(.hover, value: hovering)
        }
        .frame(width: 9)
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if !dragging { dragging = true; startFraction = fraction }
                    var f = startFraction + v.translation.width / max(totalWidth, 1)
                    f = min(max(f, 0.22), 0.78)
                    if let stop = Self.stops.first(where: { abs($0 - f) * totalWidth < 10 }) {
                        if snappedTo != stop { Haptics.play(.snap); snappedTo = stop }
                        f = stop
                    } else {
                        snappedTo = nil
                    }
                    fraction = f
                }
                .onEnded { _ in
                    dragging = false
                    UserDefaults.standard.set(fraction, forKey: "splitFraction")
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(.panel) { fraction = 0.5 }
            UserDefaults.standard.set(0.5, forKey: "splitFraction")
        }
        .help("Drag to resize · double-click to centre")
    }
}

// MARK: Status bar

struct StatusBar: View {
    @Bindable var model: ProjectModel

    var body: some View {
        HStack(spacing: 4) {
            if let vim = model.vimMode {
                Text("-- \(vim) --")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(vim == "INSERT" ? Color(theme.secondary) : accent)
                    .padding(.horizontal, 6)
                    .help("Vim keybindings (turn off in Settings › Editor)")
            }
            StatusItem(text: "Ln \(model.caretLine), Col \(model.caretColumn)", symbol: nil, help: "Go to line  ⌘L") { model.showPalette = true; PaletteSeed.shared.text = ":" }
            StatusItem(text: "\(model.words.formatted()) words", symbol: "text.word.spacing", help: "Words of prose in the document (commands, math and comments excluded)") {}
            if let s = model.currentSection {
                StatusItem(text: s.title, symbol: "number", help: "Current section") { model.sidebarTab = .outline }
                    .frame(maxWidth: 220)
            }
            Spacer()
            if model.errorCount + model.warningCount > 0 {
                StatusItem(text: "\(model.errorCount)", symbol: "xmark.octagon.fill", tint: model.errorCount > 0 ? Color(theme.error) : nil, help: "Errors") { model.sidebarTab = .issues }
                StatusItem(text: "\(model.warningCount)", symbol: "exclamationmark.triangle.fill", tint: model.warningCount > 0 ? Color(theme.warning) : nil, help: "Warnings") { model.sidebarTab = .issues }
            }
            StatusItem(text: "Live", symbol: Preferences.shared.liveCompile ? "bolt.fill" : "bolt.slash", tint: Preferences.shared.liveCompile ? accent : nil,
                       help: "Live compile: recompile as you type") {
                model.setLiveCompile(!Preferences.shared.liveCompile)
            }
            if let d = model.lastDuration {
                Text(String(format: "%.2f s", d))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color(theme.secondary))
                    .help("Last compile time")
                    .padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Color(theme.editor))
        .overlay(alignment: .top) { Rectangle().fill(Color(theme.hairline)).frame(height: 0.5) }
    }
}

private struct StatusItem: View {
    let text: String
    let symbol: String?
    var tint: Color? = nil
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)) }
                Text(text).lineLimit(1)
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(tint ?? Color(theme.secondary).opacity(hovering ? 1 : 0.9))
            .padding(.horizontal, 6).frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(theme.text).opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { h in withAnimation(.hover) { hovering = h } }
    }
}

// MARK: Toast

struct ToastView: View {
    let toast: ProjectModel.Toast
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol).foregroundStyle(toast.tint ?? accent)
            Text(toast.text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color(theme.text))
            if let title = toast.actionTitle, let action = toast.action {
                Button(title, action: action).buttonStyle(.ligChip(selected: true))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }
}

// MARK: Focused value for menu commands

struct ProjectKey: FocusedValueKey { typealias Value = ProjectModel }
extension FocusedValues {
    var project: ProjectModel? {
        get { self[ProjectKey.self] }
        set { self[ProjectKey.self] = newValue }
    }
}

/// Reports the NSWindow hosting a view (SwiftUI's dismiss doesn't close WindowGroup windows reliably).
struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    final class Probe: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.onWindow = { w in DispatchQueue.main.async { window = w } }
        return v
    }

    func updateNSView(_ nsView: Probe, context: Context) {}
}

/// Sits in front of a SwiftUI window's own delegate to ask about unsaved edits before the window closes.
/// Everything else is forwarded to the original delegate.
final class CloseGuard: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    var allowClose = false
    let shouldClose: (NSWindow) -> Bool

    init(window: NSWindow, shouldClose: @escaping (NSWindow) -> Bool) {
        self.original = window.delegate
        self.shouldClose = shouldClose
        super.init()
        window.delegate = self
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original?.responds(to: aSelector) == true ? original : nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !allowClose && !MainActor.assumeIsolated({ shouldClose(sender) }) { return false }
        return original?.windowShouldClose?(sender) ?? true
    }
}

extension ProjectModel {
    /// Asks Save / Don't Save / Cancel as a sheet on the window; closes it unless cancelled.
    func confirmClose(window: NSWindow, guard closeGuard: CloseGuard) {
        let names = dirtyPaths.sorted().map { ($0 as NSString).lastPathComponent }
        let alert = NSAlert()
        alert.messageText = names.count == 1 ? "Save changes to “\(names[0])”?" : "Save changes to \(names.count) files?"
        alert.informativeText = "You've edited \(names.joined(separator: ", ")) since the last compile. If you don't save, those edits are lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                switch response {
                case .alertFirstButtonReturn: self.saveAll()
                case .alertSecondButtonReturn: self.discardChanges()
                default: return
                }
                closeGuard.allowClose = true
                window.close()
            }
        }
    }
}
