import SwiftUI
import LigatureCore

/// Find and replace across every text file in the project, with case, regex and whole-word options. Results
/// are grouped by file; clicking one opens it with the match selected.
struct SearchPanel: View {
    @Bindable var model: ProjectModel
    @State private var results: [ProjectSearch.Match] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var showReplace = false
    @State private var collapsed: Set<String> = []
    @State private var regexError: String?
    @FocusState private var focused: Bool

    private var options: ProjectSearch.Options { model.searchOptions }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Button { withAnimation(.panel) { showReplace.toggle() } } label: {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(showReplace ? 90 : 0))
                    }
                    .buttonStyle(.ligIcon(size: 22))
                    .help(showReplace ? "Hide replace" : "Replace")
                    field("Search project", text: $model.searchQuery, symbol: "magnifyingglass")
                        .focused($focused)
                        .onSubmit { run() }
                }
                if showReplace {
                    HStack(spacing: 6) {
                        Color.clear.frame(width: 22, height: 1)
                        field("Replace with", text: $model.replaceText, symbol: "arrow.2.squarepath")
                        Button("All") { replaceAll() }
                            .buttonStyle(.ligChip())
                            .disabled(results.isEmpty)
                            .help("Replace every match in every file")
                    }
                    .transition(.opacity)
                }
                HStack(spacing: 4) {
                    Color.clear.frame(width: 22, height: 1)
                    toggle("Aa", help: "Match case", on: options.caseSensitive) { model.searchOptions.caseSensitive.toggle() }
                    toggle(".*", help: "Regular expression", on: options.regex) { model.searchOptions.regex.toggle() }
                    toggle("W", help: "Whole word", on: options.wholeWord) { model.searchOptions.wholeWord.toggle() }
                    Spacer()
                    if !model.searchQuery.isEmpty {
                        Text(summary).font(.system(size: 10.5)).foregroundStyle(regexError == nil ? Color(theme.secondary) : Color(theme.error)).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Rectangle().fill(Color(theme.hairline)).frame(height: 1)
            if model.searchQuery.isEmpty {
                EmptyState(symbol: "text.magnifyingglass", title: "Search the project", message: "Every .tex, .bib and style file, including ones you haven't opened.")
            } else if results.isEmpty && regexError == nil {
                EmptyState(symbol: "magnifyingglass", title: "No matches", message: "Try fewer words, or turn off Match case or Whole word.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                        ForEach(grouped, id: \.file) { group in
                            Section {
                                if !collapsed.contains(group.file) {
                                    ForEach(group.matches) { m in row(m) }
                                }
                            } header: { header(group.file, count: group.matches.count) }
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 10)
                }
            }
        }
        .onAppear { focused = true; run() }
        .onChange(of: model.searchQuery) { _, _ in schedule() }
        .onChange(of: model.searchOptions) { _, _ in run() }
        .onChange(of: model.undoTick) { _, _ in schedule() }
    }

    private var grouped: [(file: String, matches: [ProjectSearch.Match])] {
        var order: [String] = []
        var by: [String: [ProjectSearch.Match]] = [:]
        for m in results { if by[m.file] == nil { order.append(m.file) }; by[m.file, default: []].append(m) }
        return order.map { ($0, by[$0]!) }
    }

    private var summary: String {
        if let regexError { return regexError }
        let files = Set(results.map(\.file)).count
        return "\(results.count) result\(results.count == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")"
    }

    // MARK: Pieces

    private func field(_ placeholder: String, text: Binding<String>, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Color(theme.secondary))
            TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 12.5))
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color(theme.secondary)) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(theme.text).opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(theme.hairline)))
    }

    private func toggle(_ label: String, help: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label).font(.system(size: 11, weight: .semibold, design: label == ".*" ? .monospaced : .default)).frame(minWidth: 18) }
            .buttonStyle(.ligChip(selected: on))
            .help(help)
    }

    private func header(_ file: String, count: Int) -> some View {
        Button {
            withAnimation(.panel) { if collapsed.contains(file) { collapsed.remove(file) } else { collapsed.insert(file) } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).rotationEffect(.degrees(collapsed.contains(file) ? 0 : 90))
                Image(systemName: FileNode(name: (file as NSString).lastPathComponent, path: file, isDirectory: false).symbol).font(.system(size: 11))
                Text((file as NSString).lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                let dir = (file as NSString).deletingLastPathComponent
                if !dir.isEmpty { Text(dir).font(.system(size: 10.5)).foregroundStyle(Color(theme.secondary)).lineLimit(1).truncationMode(.middle) }
                Spacer()
                Text("\(count)").font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(Color(theme.secondary))
                    .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color(theme.text).opacity(0.07)))
            }
            .foregroundStyle(Color(theme.text))
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(Color(theme.canvas).opacity(0.96))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ m: ProjectSearch.Match) -> some View {
        SearchRow(match: m, showReplace: showReplace, open: { open(m) }, replace: { replace(m) })
    }

    // MARK: Actions

    private func schedule() {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            run()
        }
    }

    private func run() {
        let q = model.searchQuery
        guard !q.isEmpty else { results = []; regexError = nil; return }
        if case .failure = ProjectSearch.expression(q, options) { regexError = "Invalid pattern"; results = []; return }
        regexError = nil
        let files = model.searchableFiles.map { ($0, model.text(of: $0) ?? "") }
        let o = options
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                files.flatMap { ProjectSearch.find(q, in: $0.1, file: $0.0, options: o, limit: 500) }
            }.value
            if q == model.searchQuery { withAnimation(.panel) { results = found } }
        }
    }

    private func open(_ m: ProjectSearch.Match) {
        model.open(path: m.file, line: m.line)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            (model.editor as? EditorController)?.select(m.range)
        }
    }

    private func replace(_ m: ProjectSearch.Match) {
        guard let doc = model.ensureOpen(path: m.file) else { return }
        let r = ProjectSearch.replace(model.searchQuery, with: model.replaceText, in: doc.text, options: options, only: [m.range])
        if r.count > 0 { doc.replaceAll(with: r.text, actionName: "Replace") }
        run()
    }

    private func replaceAll() {
        var total = 0, files = 0
        for file in Set(results.map(\.file)).sorted() {
            guard let doc = model.ensureOpen(path: file) else { continue }
            let r = ProjectSearch.replace(model.searchQuery, with: model.replaceText, in: doc.text, options: options)
            if r.count > 0 { doc.replaceAll(with: r.text, actionName: "Replace All"); total += r.count; files += 1 }
        }
        model.refreshDirty()
        model.showToast("arrow.2.squarepath", "Replaced \(total) match\(total == 1 ? "" : "es") in \(files) file\(files == 1 ? "" : "s"). ⌘Z undoes it per file")
        run()
    }
}

private struct SearchRow: View {
    let match: ProjectSearch.Match
    let showReplace: Bool
    let open: () -> Void
    let replace: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(match.line)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(theme.secondary)).frame(minWidth: 26, alignment: .trailing)
            snippet.lineLimit(2)
            Spacer(minLength: 0)
            if showReplace && hovering {
                Button(action: replace) { Image(systemName: "arrow.2.squarepath").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.ligIcon(size: 20))
                    .help("Replace this one")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(theme.text).opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { h in withAnimation(.hover) { hovering = h } }
    }

    /// The line, trimmed to a window around the match, with the match highlighted.
    private var snippet: Text {
        let ns = match.lineText as NSString
        let r = match.rangeInLine
        let start = max(0, r.location - 28)
        let lead = ns.substring(with: NSRange(location: start, length: r.location - start)).replacingOccurrences(of: "\t", with: " ")
        let hit = ns.substring(with: r)
        let tailStart = NSMaxRange(r)
        let tail = ns.substring(with: NSRange(location: tailStart, length: min(120, ns.length - tailStart)))
        var a = AttributedString((start > 0 ? "…" : "") + lead.drop { $0 == " " && start == 0 })
        a.foregroundColor = Color(theme.text).opacity(0.75)
        var h = AttributedString(hit)
        h.foregroundColor = Color(theme.text)
        h.backgroundColor = accent.opacity(0.28)
        h.font = .system(size: 12, weight: .semibold)
        var tl = AttributedString(tail)
        tl.foregroundColor = Color(theme.text).opacity(0.75)
        return Text(a + h + tl).font(.system(size: 12))
    }
}
