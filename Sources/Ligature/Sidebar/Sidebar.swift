import SwiftUI
import PDFKit
import LigatureCore

struct SidebarView: View {
    @Bindable var model: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
            SlidingTabs(items: SidebarTab.allCases, selection: $model.sidebarTab, symbol: \.symbol, title: \.title,
                        badge: { $0 == .issues ? model.errorCount : 0 })
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 6)
            Group {
                switch model.sidebarTab {
                case .files: FilesPanel(model: model)
                case .outline: OutlinePanel(model: model)
                case .issues: IssuesPanel(model: model)
                case .symbols: SymbolsPanel(model: model)
                case .citations: CitationsPanel(model: model)
                case .history: HistoryPanel(model: model)
                }
            }
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .animation(.panel, value: model.sidebarTab)
    }
}

// MARK: Files

struct FilesPanel: View {
    @Bindable var model: ProjectModel
    @State private var expanded: Set<String> = []
    @State private var renaming: String?
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: model.name, trailing: AnyView(
                HStack(spacing: 2) {
                    IconButton(symbol: "pencil", help: "Rename project", size: 22) { model.showRename = true }
                    IconButton(symbol: "doc.badge.plus", help: "New file", shortcut: "⌘N", size: 22) { model.showNewFile = true }
                    IconButton(symbol: "folder", help: "Reveal in Finder", size: 22) { NSWorkspace.shared.activateFileViewerSelecting([model.root]) }
                }
            ))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.tree) { node in row(node, depth: 0) }
                }
                .padding(.horizontal, 6).padding(.bottom, 10)
            }
        }
    }

    func row(_ node: FileNode, depth: Int) -> AnyView {
        let isOpen = expanded.contains(node.path)
        let isActive = model.activeDoc?.relativePath == node.path
        let isMain = model.mainFile == node.path
        return AnyView(VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if node.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(theme.secondary))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 10)
                } else {
                    Spacer().frame(width: 10)
                }
                Image(systemName: node.symbol)
                    .symbolVariant(node.isDirectory && isOpen ? .fill : .none)
                    .font(.system(size: 12))
                    .foregroundStyle(iconColor(node))
                    .frame(width: 16)
                if renaming == node.path {
                    TextField("", text: $newName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .onSubmit { model.rename(node, to: newName); renaming = nil }
                        .onExitCommand { renaming = nil }
                } else {
                    Text(node.name).font(.system(size: 12.5, weight: isActive ? .semibold : .regular)).lineLimit(1)
                        .foregroundStyle(Color(theme.text))
                }
                Spacer(minLength: 4)
                if isMain {
                    Text("MAIN").font(.system(size: 8.5, weight: .bold)).tracking(0.5)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(accent.opacity(0.12)))
                }
                if let doc = model.openDocs.first(where: { $0.relativePath == node.path }), doc.isDirty {
                    Circle().fill(Color(theme.secondary)).frame(width: 5, height: 5)
                }
            }
            .padding(.leading, CGFloat(depth) * 14 + 4).padding(.trailing, 6)
            .frame(height: 26)
            .hoverRow(selected: isActive)
            .onTapGesture {
                if node.isDirectory {
                    withAnimation(.panel) { if isOpen { expanded.remove(node.path) } else { expanded.insert(node.path) } }
                } else {
                    model.open(path: node.path)
                }
            }
            .contextMenu {
                if !node.isDirectory {
                    Button("Open") { model.open(path: node.path) }
                    if node.name.hasSuffix(".tex") && !isMain { Button("Set as Main File") { model.mainFile = node.path } }
                }
                Button("Rename…") { newName = node.name; renaming = node.path }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.root.appendingPathComponent(node.path)]) }
                if node.isDirectory { Button("New File Here…") { model.showNewFile = true } }
                Divider()
                Button("Move to Trash", role: .destructive) { model.trash(node) }
            }
            .draggable(model.root.appendingPathComponent(node.path))
            if node.isDirectory && isOpen {
                ForEach(node.children ?? []) { child in row(child, depth: depth + 1) }
            }
        })
    }

    func iconColor(_ node: FileNode) -> Color {
        if node.isDirectory { return accent.opacity(0.85) }
        switch (node.name as NSString).pathExtension.lowercased() {
        case "tex", "ltx": return Color(theme.command)
        case "bib": return Color(theme.reference)
        case "png", "jpg", "jpeg", "pdf", "svg", "eps": return Color(theme.math)
        default: return Color(theme.secondary)
        }
    }
}

// MARK: Outline

struct OutlinePanel: View {
    @Bindable var model: ProjectModel
    @State private var showDetails = true

    var visible: [OutlineItem] {
        model.outline.filter { item in
            switch item.kind {
            case .label, .input: return false
            case .figure, .table, .todo: return showDetails
            default: return true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Outline", trailing: AnyView(
                Button(showDetails ? "All" : "Sections") { withAnimation(.panel) { showDetails.toggle() } }
                    .buttonStyle(.ligChip(selected: showDetails))
            ))
            if visible.isEmpty {
                EmptyState(symbol: "list.bullet.indent", title: "No sections yet", message: "Add \\section{…} and it shows up here. Click to jump.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(visible) { item in
                                OutlineRow(item: item, current: model.currentSection?.id == item.id, minDepth: minDepth)
                                    .id(item.id)
                                    .onTapGesture {
                                        model.open(path: item.file, line: item.line)
                                    }
                            }
                        }
                        .padding(.horizontal, 6).padding(.bottom, 10)
                    }
                    .onChange(of: model.currentSection?.id) { _, id in
                        if let id { withAnimation(.panel) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
    }

    var minDepth: Int { visible.filter { $0.kind.isHeading }.map(\.kind.depth).min() ?? 2 }
}

private struct OutlineRow: View {
    let item: OutlineItem
    let current: Bool
    let minDepth: Int

    var body: some View {
        let depth = max(0, (item.kind.isHeading ? item.kind.depth : (minDepth + 2)) - minDepth)
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1).fill(current ? accent : .clear).frame(width: 2.5, height: 14)
            Image(systemName: symbol)
                .font(.system(size: item.kind.isHeading ? 10.5 : 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(item.title)
                .font(.system(size: depth == 0 ? 12.5 : 12, weight: depth == 0 && item.kind.isHeading ? .semibold : .regular))
                .foregroundStyle(Color(theme.text).opacity(item.kind.isHeading ? 1 : 0.8))
                .lineLimit(1)
            Spacer(minLength: 2)
            if let label = item.label, item.kind == .figure || item.kind == .table {
                Text(label).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Color(theme.secondary)).lineLimit(1)
            }
        }
        .padding(.leading, CGFloat(depth) * 12)
        .padding(.trailing, 6)
        .frame(height: 25)
        .hoverRow(selected: current)
        .help("\((item.file as NSString).lastPathComponent):\(item.line)")
    }

    var symbol: String {
        switch item.kind {
        case .part: "books.vertical"
        case .chapter: "book.closed"
        case .section: "number"
        case .subsection, .subsubsection, .paragraph: "text.alignleft"
        case .figure: "photo"
        case .table: "tablecells"
        case .todo: "checklist"
        case .frame: "rectangle.on.rectangle"
        default: "tag"
        }
    }

    var tint: Color {
        switch item.kind {
        case .figure, .table: Color(theme.math)
        case .todo: Color(theme.warning)
        case .frame: Color(theme.environment)
        default: accent
        }
    }
}

// MARK: Issues

struct IssuesPanel: View {
    @Bindable var model: ProjectModel
    @State private var filter: CompileIssue.Severity? = nil
    @State private var expanded: String?

    var shown: [CompileIssue] { model.issues.filter { filter == nil || $0.severity == filter } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                chip("All", count: model.issues.count, value: nil, color: Color(theme.secondary))
                chip("Errors", count: model.errorCount, value: .error, color: Color(theme.error))
                chip("Warnings", count: model.issues.filter { $0.severity == .warning }.count, value: .warning, color: Color(theme.warning))
                chip("Layout", count: model.issues.filter { $0.severity == .badBox }.count, value: .badBox, color: Color(theme.secondary))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            if model.issues.isEmpty {
                if model.compileState == .success {
                    EmptyState(symbol: "checkmark.seal", title: "Clean compile", message: "No errors or warnings. Nice.")
                } else {
                    EmptyState(symbol: "exclamationmark.triangle", title: "No issues", message: "Problems from the last compile appear here, explained in plain English.")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(shown) { issue in
                            IssueRow(issue: issue, expanded: expanded == issue.id, model: model)
                                .onTapGesture {
                                    withAnimation(.panel) { expanded = expanded == issue.id ? nil : issue.id }
                                    if let line = issue.line { model.open(path: issue.file ?? model.mainFile, line: line) }
                                }
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                }
            }
        }
    }

    func chip(_ title: String, count: Int, value: CompileIssue.Severity?, color: Color) -> some View {
        Button {
            withAnimation(.panel) { filter = value }
        } label: {
            HStack(spacing: 4) {
                if let value {
                    Image(systemName: value == .error ? "xmark.octagon.fill" : (value == .warning ? "exclamationmark.triangle.fill" : "rectangle.badge.xmark"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(color)
                } else {
                    Text("All")
                }
                Text("\(count)").monospacedDigit()
            }
            .fixedSize()
        }
        .buttonStyle(.ligChip(selected: filter == value))
        .help(title)
    }
}

private struct IssueRow: View {
    let issue: CompileIssue
    let expanded: Bool
    let model: ProjectModel
    @State private var hovering = false

    var advice: Advice? { ErrorAdvisor.advise(issue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(color).frame(width: 14).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(advice?.title ?? issue.message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(theme.text))
                        .lineLimit(expanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let file = issue.file ?? (issue.line != nil ? model.mainFile : nil) {
                        Text("\((file as NSString).lastPathComponent)\(issue.line.map { ":\($0)" } ?? "")")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color(theme.secondary))
                    }
                }
                Spacer(minLength: 0)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let advice { Text(advice.explanation).font(.system(size: 11.5)).foregroundStyle(Color(theme.secondary)).fixedSize(horizontal: false, vertical: true) }
                    if advice != nil && advice?.title != issue.message {
                        Text(issue.message).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(theme.secondary).opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                    }
                    if let ctx = issue.context {
                        Text(ctx).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(theme.text).opacity(0.8))
                            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color(theme.text).opacity(0.04)))
                    }
                    if let fix = advice?.fix, let label = advice?.fixLabel {
                        Button { model.apply(fix) } label: { Label(label, systemImage: "wand.and.sparkles") }
                            .buttonStyle(.ligPrimary)
                    }
                }
                .padding(.leading, 22)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color.opacity(hovering || expanded ? 0.09 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(color.opacity(expanded ? 0.3 : 0.12), lineWidth: 0.75))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.hover) { hovering = h } }
    }

    var icon: String {
        switch issue.severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .badBox: "rectangle.badge.xmark"
        }
    }

    var color: Color {
        switch issue.severity {
        case .error: Color(theme.error)
        case .warning: Color(theme.warning)
        case .badBox: Color(theme.secondary)
        }
    }
}

// MARK: Symbols

struct SymbolsPanel: View {
    let model: ProjectModel
    @State private var query = ""
    @State private var category = "Greek"
    @State private var recent: [String] = UserDefaults.standard.stringArray(forKey: "recentSymbols") ?? []

    var shown: [LaTeXSymbol] {
        if !query.isEmpty {
            return Catalog.symbols.compactMap { s -> (LaTeXSymbol, Int)? in
                guard let score = [Fuzzy.score(query, s.name), Fuzzy.score(query, s.command)].compactMap({ $0 }).max() else { return nil }
                return (s, score)
            }.sorted { $0.1 > $1.1 }.map(\.0)
        }
        if category == "Recent" { return recent.compactMap { c in Catalog.symbols.first { $0.command == c } } }
        return Catalog.symbols.filter { $0.category == category }
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $query, prompt: "Search symbols: “arrow”, “alpha”…")
                .padding(.horizontal, 10).padding(.top, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach((recent.isEmpty ? [] : ["Recent"]) + Catalog.symbolCategories, id: \.self) { c in
                        Button(c) { withAnimation(.panel) { category = c; query = "" } }
                            .buttonStyle(.ligChip(selected: category == c && query.isEmpty))
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 42, maximum: 56), spacing: 5)], spacing: 5) {
                    ForEach(shown) { s in
                        SymbolTile(symbol: s) { insert(s) }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
            }
        }
    }

    func insert(_ s: LaTeXSymbol) {
        let mathy = s.category != "Text"
        let snippet = s.command.replacingOccurrences(of: "{x}", with: "{$1}").replacingOccurrences(of: "{xy}", with: "{$1}")
            .replacingOccurrences(of: "{}", with: "{$1}").replacingOccurrences(of: "{a}{b}", with: "{$1}{$2}")
        if mathy, !(model.editor?.caretInMath() ?? true) { model.editor?.insertSnippet("$" + snippet + "$0$") }
        else { model.editor?.insertSnippet(snippet) }
        if let pkg = s.package, let main = model.text(of: model.mainFile), LaTeXText.addingPackage(pkg, to: main) != nil {
            model.showToast("shippingbox", "\(s.command) needs \\usepackage{\(pkg)}")
        }
        recent.removeAll { $0 == s.command }
        recent.insert(s.command, at: 0)
        recent = Array(recent.prefix(24))
        UserDefaults.standard.set(recent, forKey: "recentSymbols")
    }
}

private struct SymbolTile: View {
    let symbol: LaTeXSymbol
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(symbol.glyph)
                .font(.system(size: symbol.glyph.count > 2 ? 12 : 19, design: .serif))
                .foregroundStyle(hovering ? accent : Color(theme.text))
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? accent.opacity(0.12) : Color(theme.text).opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(hovering ? accent.opacity(0.35) : .clear, lineWidth: 1))
                .scaleEffect(hovering ? 1.08 : 1)
                .zIndex(hovering ? 1 : 0)
        }
        .buttonStyle(.plain)
        .help("\(symbol.command): \(symbol.name)\(symbol.package.map { " (\($0))" } ?? "")")
        .onHover { h in withAnimation(.press) { hovering = h } }
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11.5)).foregroundStyle(Color(theme.secondary))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(Color(theme.secondary))
            }
        }
        .padding(.horizontal, 9).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(theme.text).opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(focused ? accent.opacity(0.6) : Color(theme.hairline), lineWidth: focused ? 1.5 : 0.75))
        .animation(.hover, value: focused)
    }
}

// MARK: Citations

struct CitationsPanel: View {
    @Bindable var model: ProjectModel
    @State private var query = ""

    var shown: [BibEntry] {
        guard !query.isEmpty else { return model.bibEntries }
        return model.bibEntries.compactMap { e -> (BibEntry, Int)? in
            let s = [Fuzzy.score(query, e.key), Fuzzy.score(query, e.title), Fuzzy.score(query, e.authorsShort)].compactMap { $0 }.max()
            return s.map { (e, $0) }
        }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SearchField(text: $query, prompt: "Filter references")
                Button { model.showCitationSheet = true } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.ligPrimary)
                    .help("Add a reference from a DOI, an arXiv ID or a title search")
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
            if model.bibEntries.isEmpty {
                EmptyState(symbol: "books.vertical", title: "No references", message: "Add papers by DOI, arXiv ID or title. They go into references.bib and are suggested when you type \\cite{.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(shown) { e in
                            CitationRow(entry: e)
                                .onTapGesture {
                                    model.editor?.insertSnippet("\\cite{\(e.key)}")
                                }
                                .contextMenu {
                                    Button("Insert \\cite{\(e.key)}") { model.editor?.insertSnippet("\\cite{\(e.key)}") }
                                    Button("Copy Key") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(e.key, forType: .string) }
                                    Button("Show in \((e.file as NSString).lastPathComponent)") { model.open(path: e.file, line: e.line) }
                                    if let doi = e.fields["doi"], let url = URL(string: "https://doi.org/\(doi)") { Button("Open DOI") { NSWorkspace.shared.open(url) } }
                                }
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 10)
                }
            }
        }
    }
}

private struct CitationRow: View {
    let entry: BibEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title.isEmpty ? entry.key : entry.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(theme.text))
                .lineLimit(2)
            HStack(spacing: 6) {
                Text([entry.authorsShort, entry.year].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(Color(theme.secondary)).lineLimit(1)
                Spacer(minLength: 4)
                Text(entry.key).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(theme.reference)).lineLimit(1)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .hoverRow()
        .help("Click to insert \\cite{\(entry.key)}")
    }
}

// MARK: History

struct HistoryPanel: View {
    @Bindable var model: ProjectModel
    @State private var selected: Snapshot?
    @State private var compilesOnly = true
    @State private var confirmRestore: Snapshot?

    var shown: [Snapshot] { compilesOnly ? model.snapshots.filter(\.isCompile) : model.snapshots }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button("Compiles") { withAnimation(.panel) { compilesOnly = true } }.buttonStyle(.ligChip(selected: compilesOnly))
                Button("All versions") { withAnimation(.panel) { compilesOnly = false } }.buttonStyle(.ligChip(selected: !compilesOnly))
                Spacer()
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            if shown.isEmpty {
                EmptyState(symbol: compilesOnly ? "play.circle" : "clock.arrow.circlepath",
                           title: compilesOnly ? "No compiles yet" : "No versions yet",
                           message: compilesOnly ? "Each time you press Compile, the PDF and your sources are kept here so you can go back to them."
                                                 : "A version is saved after each successful compile that changed something.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.0) { day, snaps in
                            Section {
                                ForEach(snaps) { s in
                                    HistoryRow(snap: s, previous: previous(of: s), root: model.root,
                                               open: { selected = s },
                                               viewPDF: { if let u = HistoryStore.pdfURL(s, root: model.root) { NSWorkspace.shared.open(u) } },
                                               restore: { confirmRestore = s })
                                }
                            } header: {
                                Text(day).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color(theme.secondary))
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.bar)
                            }
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 10)
                }
            }
        }
        .sheet(item: $selected) { snap in HistoryDiffSheet(model: model, snapshot: snap) }
        .alert("Go back to this version?", isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }), presenting: confirmRestore) { snap in
            Button("Restore") { model.restoreProject(to: snap) }
            Button("Cancel", role: .cancel) {}
        } message: { snap in
            Text("Every file goes back to how it was at \(snap.date.formatted(date: .abbreviated, time: .shortened)), then the document compiles. Your current version is saved in History first, so you can come back to it.")
        }
    }

    var groups: [(String, [Snapshot])] {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .none
        var out: [(String, [Snapshot])] = []
        for s in shown {
            let k = f.string(from: s.date)
            if let i = out.firstIndex(where: { $0.0 == k }) { out[i].1.append(s) } else { out.append((k, [s])) }
        }
        return out
    }

    func previous(of s: Snapshot) -> Snapshot? {
        guard let i = shown.firstIndex(of: s), i + 1 < shown.count else { return nil }
        return shown[i + 1]
    }
}

private struct HistoryRow: View {
    let snap: Snapshot
    let previous: Snapshot?
    let root: URL
    let open: () -> Void
    let viewPDF: () -> Void
    let restore: () -> Void
    @State private var hovering = false
    @State private var thumb: NSImage?

    var body: some View {
        HStack(spacing: 9) {
            if snap.isCompile {
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(.white)
                    if let thumb { Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit) }
                }
                .frame(width: 26, height: 34)
                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
            } else {
                Circle().fill(accent.opacity(0.7)).frame(width: 6, height: 6).frame(width: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(snap.date, style: .time).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Color(theme.text))
                    if let e = snap.errors, e > 0 {
                        Text("\(e) error\(e == 1 ? "" : "s")").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Color(theme.error))
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color(theme.error).opacity(0.12)))
                    }
                }
                HStack(spacing: 5) {
                    Text("\(snap.words) words").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Color(theme.secondary))
                    if let p = previous {
                        let d = snap.words - p.words
                        if d != 0 { Text(d > 0 ? "+\(d)" : "\(d)").font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(d > 0 ? Color.green : Color(theme.error)) }
                    }
                    if let pages = snap.pages { Text("· \(pages) p").font(.system(size: 10.5)).foregroundStyle(Color(theme.secondary)) }
                }
            }
            Spacer(minLength: 2)
            if hovering {
                HStack(spacing: 0) {
                    if snap.isCompile { IconButton(symbol: "eye", help: "Open this PDF", size: 22, action: viewPDF) }
                    IconButton(symbol: "arrow.uturn.backward", help: "Go back to this version", size: 22, action: restore)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .hoverRow()
        .onHover { h in withAnimation(.hover) { hovering = h } }
        .onTapGesture(perform: open)
        .help("Click to compare with now")
        .task(id: snap.id) {
            guard snap.isCompile, thumb == nil, let url = HistoryStore.pdfURL(snap, root: root) else { return }
            thumb = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
                return page.thumbnail(of: NSSize(width: 52, height: 68), for: .cropBox)
            }.value
        }
    }
}

struct HistoryDiffSheet: View {
    let model: ProjectModel
    let snapshot: Snapshot
    @State private var file = ""
    @Environment(\.dismiss) private var dismiss

    var files: [String] { snapshot.files.keys.sorted { a, b in a == model.mainFile ? true : (b == model.mainFile ? false : a < b) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version from \(snapshot.date.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 14, weight: .semibold))
                    Text("Red lines are only in this version; green lines are only in the current file.").font(.system(size: 11)).foregroundStyle(Color(theme.secondary))
                }
                Spacer()
                Picker("", selection: $file) { ForEach(files, id: \.self) { Text($0).tag($0) } }.frame(width: 220)
            }
            .padding(16)
            Divider()
            let lines = LineDiff.hunks(LineDiff.diff(old: snapshot.files[file] ?? "", new: model.text(of: file) ?? ""))
            if lines.isEmpty {
                EmptyState(symbol: "equal.circle", title: "Identical", message: "\(file) hasn't changed since this version.")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            if let line {
                                HStack(spacing: 8) {
                                    Text(line.kind == .added ? "+" : (line.kind == .removed ? "−" : " ")).frame(width: 10)
                                    Text(line.text.isEmpty ? " " : line.text)
                                }
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(line.kind == .same ? Color(theme.secondary) : Color(theme.text))
                                .padding(.horizontal, 12).padding(.vertical, 1.5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(line.kind == .added ? Color.green.opacity(0.12) : (line.kind == .removed ? Color(theme.error).opacity(0.12) : .clear))
                            } else {
                                Text("⋯").font(.system(size: 11)).foregroundStyle(Color(theme.secondary)).padding(.horizontal, 12).padding(.vertical, 4)
                            }
                        }
                    }
                }
                .background(Color(theme.editor))
            }
            Divider()
            HStack {
                Button("Close") { dismiss() }.buttonStyle(.ligSecondary).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Restore \((file as NSString).lastPathComponent)") {
                    model.restore(file: file, from: snapshot)
                    dismiss()
                }
                .buttonStyle(.ligPrimary)
                .disabled(lines.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 760, height: 560)
        .background(Color(theme.surface))
        .onAppear { file = files.first ?? "" }
    }
}
