import SwiftUI
import LigatureCore

/// Lets other UI open the palette pre-filled (e.g. ":" for go-to-line).
@MainActor final class PaletteSeed { static let shared = PaletteSeed(); var text = "" }

/// ⌘K: one box for commands, files, sections, labels, citations and go-to-line (":42").
struct CommandPalette: View {
    @Bindable var model: ProjectModel
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    struct Entry: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
        var shortcut: String? = nil
        let group: String
        let run: () -> Void
    }

    var entries: [Entry] {
        if query.hasPrefix(":") {
            let n = Int(query.dropFirst()) ?? 0
            return [Entry(id: "goto", symbol: "arrow.right.to.line", title: n > 0 ? "Go to line \(n)" : "Type a line number", detail: model.activeDoc?.name ?? "", group: "Navigate") {
                if n > 0 { model.editor?.reveal(line: n, column: nil, flash: true) }
            }]
        }
        var all: [Entry] = actions
        for f in FileNode.flatten(model.tree) where !f.isDirectory {
            all.append(Entry(id: "file:\(f.path)", symbol: f.symbol, title: f.name, detail: f.path, group: "Files") { model.open(path: f.path) })
        }
        for item in model.outline where item.kind.isHeading || item.kind == .figure || item.kind == .table {
            all.append(Entry(id: "outline:\(item.id)", symbol: item.kind == .figure ? "photo" : (item.kind == .table ? "tablecells" : "number"), title: item.title,
                             detail: "\((item.file as NSString).lastPathComponent):\(item.line)", group: "Sections") { model.open(path: item.file, line: item.line) })
        }
        for l in model.labels {
            all.append(Entry(id: "label:\(l.id)", symbol: "tag", title: l.title, detail: "Insert \\ref", group: "Labels") { model.editor?.insertSnippet("\\ref{\(l.title)}") })
        }
        for e in model.bibEntries {
            all.append(Entry(id: "cite:\(e.key)", symbol: "quote.opening", title: e.title.isEmpty ? e.key : e.title, detail: "\\cite{\(e.key)}", group: "Citations") { model.editor?.insertSnippet("\\cite{\(e.key)}") })
        }
        guard !query.isEmpty else { return Array(actions.prefix(9)) + Array(all.filter { $0.group == "Files" }.prefix(6)) }
        return all.compactMap { e -> (Entry, Int)? in
            // Titles match fuzzily; details only as a plain substring, to keep results relevant.
            let detailHit = e.detail.localizedCaseInsensitiveContains(query) ? (Fuzzy.score(query, e.detail) ?? 0) - 10 : nil
            let scores = [Fuzzy.score(query, e.title), detailHit].compactMap { $0 }
            guard let s = scores.max() else { return nil }
            return (e, s + (e.group == "Commands" ? 6 : 0))
        }
        .sorted { $0.1 > $1.1 }
        .prefix(40)
        .map(\.0)
    }

    var actions: [Entry] {
        [
            Entry(id: "compile", symbol: "play.fill", title: "Compile", detail: "Typeset the document", shortcut: "⌘R", group: "Commands") { model.compile(manual: true) },
            Entry(id: "sync", symbol: "text.viewfinder", title: "Show Caret in PDF", detail: "SyncTeX forward search", shortcut: "⌘⇧J", group: "Commands") { model.syncToPDF() },
            Entry(id: "table", symbol: "tablecells", title: "Insert Table…", detail: "Visual table builder", shortcut: "⌥⌘T", group: "Commands") { model.tableReplaceRange = nil; model.tableDraft = TableModel(rows: 3, columns: 3) },
            Entry(id: "figure", symbol: "photo", title: "Insert Figure…", detail: "Add an image", group: "Commands") { model.showFigureSheet = true },
            Entry(id: "cite", symbol: "quote.opening", title: "Add Citation…", detail: "DOI, arXiv or title", group: "Commands") { model.showCitationSheet = true },
            Entry(id: "newfile", symbol: "doc.badge.plus", title: "New File…", detail: "Add a .tex or .bib file", shortcut: "⌘N", group: "Commands") { model.showNewFile = true },
            Entry(id: "layout-split", symbol: "rectangle.split.2x1", title: "Layout: Split", detail: "Editor and PDF", shortcut: "⌘2", group: "Commands") { model.layout = .split },
            Entry(id: "layout-editor", symbol: "doc.plaintext", title: "Layout: Editor Only", detail: "Focus on writing", shortcut: "⌘1", group: "Commands") { model.layout = .editor },
            Entry(id: "layout-pdf", symbol: "doc.richtext", title: "Layout: PDF Only", detail: "Read the output", shortcut: "⌘3", group: "Commands") { model.layout = .preview },
            Entry(id: "live", symbol: "bolt", title: Preferences.shared.liveCompile ? "Turn Off Live Compile" : "Turn On Live Compile", detail: "Recompile as you type", group: "Commands") { model.setLiveCompile(!Preferences.shared.liveCompile) },
            Entry(id: "dark", symbol: "moon", title: "Toggle Dark Paper", detail: "Invert the PDF preview", group: "Commands") { Preferences.shared.pdfDarkPaper.toggle() },
            Entry(id: "sidebar", symbol: "sidebar.left", title: "Toggle Sidebar", detail: "", shortcut: "⌃⌘S", group: "Commands") { model.showSidebar.toggle() },
            Entry(id: "issues", symbol: "exclamationmark.triangle", title: "Show Issues", detail: "\(model.errorCount) errors, \(model.warningCount) warnings", group: "Commands") { model.sidebarTab = .issues; model.showSidebar = true },
            Entry(id: "history", symbol: "clock.arrow.circlepath", title: "Show Version History", detail: "\(model.snapshots.count) versions", group: "Commands") { model.sidebarTab = .history; model.showSidebar = true },
            Entry(id: "export", symbol: "arrow.down.doc", title: "Download PDF…", detail: "Save a copy", shortcut: "⇧⌘E", group: "Commands") { ExportMenu(model: model).exportPDF() },
            Entry(id: "arxiv", symbol: "paperplane", title: "Export for arXiv…", detail: "Sources with .bbl, comments removed", group: "Commands") { ExportMenu(model: model).exportZip(arxiv: true) },
            Entry(id: "quickdl", symbol: "arrow.down.circle", title: "Quick Download PDF", detail: "Save to Downloads as \(model.exportBaseName).pdf", shortcut: "⌥⌘D", group: "Commands") { model.quickDownload() },
            Entry(id: "word", symbol: "doc.text", title: "Download as Word…", detail: ".docx via pandoc", group: "Commands") { ExportMenu(model: model).exportWord() },
            Entry(id: "downloads", symbol: "tray.full", title: "Previous Downloads…", detail: "\(model.downloads.count) saved", group: "Commands") { model.showDownloads = true },
            Entry(id: "rename", symbol: "pencil", title: "Rename Project…", detail: model.name, group: "Commands") { model.showRename = true },
            Entry(id: "finder", symbol: "folder", title: "Reveal Project in Finder", detail: model.root.path, group: "Commands") { NSWorkspace.shared.activateFileViewerSelecting([model.root]) },
        ]
    }

    var body: some View {
        let list = entries
        ZStack(alignment: .top) {
            Color.black.opacity(theme.isDark ? 0.3 : 0.12)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: query.hasPrefix(":") ? "arrow.right.to.line" : "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(theme.secondary))
                    TextField("Search commands, files, sections, labels…   “:” go to line", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($focused)
                        .onSubmit { run(list[safe: selected]) }
                    KeyCap(text: "esc")
                }
                .padding(.horizontal, 16).frame(height: 52)
                Rectangle().fill(Color(theme.hairline)).frame(height: 0.5)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                                if i == 0 || list[i - 1].group != e.group {
                                    Text(e.group.uppercased())
                                        .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                                        .foregroundStyle(Color(theme.secondary).opacity(0.8))
                                        .padding(.horizontal, 12).padding(.top, i == 0 ? 6 : 10).padding(.bottom, 3)
                                }
                                PaletteRow(entry: e, query: query, selected: i == selected)
                                    .id(e.id)
                                    .onTapGesture { run(e) }
                                    .onHover { if $0 { selected = i } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: min(380, CGFloat(list.count) * 35 + CGFloat(Set(list.map(\.group)).count) * 26 + 12))
                    .onChange(of: selected) { _, i in if let e = list[safe: i] { proxy.scrollTo(e.id, anchor: .center) } }
                }
                if list.isEmpty {
                    Text("No matches").font(.system(size: 12.5)).foregroundStyle(Color(theme.secondary)).padding(24)
                }
            }
            .frame(width: 600)
            .background(Color(theme.surface).opacity(0.94), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .glassEdge(cornerRadius: 16)
            .shadow(color: accent.opacity(theme.isDark ? 0.08 : 0.08), radius: 40)
            .shadow(color: .black.opacity(0.25), radius: 40, y: 18)
            .padding(.top, 70)
        }
        .onAppear {
            query = PaletteSeed.shared.text
            PaletteSeed.shared.text = ""
            selected = 0
            focused = true
        }
        .onChange(of: query) { _, _ in selected = 0 }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(0, list.count - 1)); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    func run(_ e: Entry?) {
        guard let e else { return }
        close()
        DispatchQueue.main.async { e.run() }
    }

    func close() {
        model.showPalette = false
        DispatchQueue.main.async { model.editor?.focus() }
    }
}

private struct PaletteRow: View {
    let entry: CommandPalette.Entry
    let query: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? accent : Color(theme.secondary))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? accent.opacity(0.14) : Color(theme.text).opacity(0.05)))
            HighlightedText(text: entry.title, query: query.hasPrefix(":") ? "" : query, font: .system(size: 13))
                .foregroundStyle(Color(theme.text))
                .lineLimit(1)
            Text(entry.detail).font(.system(size: 11.5)).foregroundStyle(Color(theme.secondary)).lineLimit(1)
            Spacer(minLength: 8)
            if let s = entry.shortcut { KeyCap(text: s) }
            if selected { Image(systemName: "return").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(theme.secondary)) }
        }
        .padding(.horizontal, 8).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? accent.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .animation(.hover, value: selected)
    }
}
