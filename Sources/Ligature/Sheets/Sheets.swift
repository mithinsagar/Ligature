import SwiftUI
import UniformTypeIdentifiers
import LigatureCore

/// Common chrome for the app's sheets: title, subtitle, content, and a footer with actions.
struct SheetScaffold<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accent.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(theme.text))
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Color(theme.secondary))
                }
                Spacer()
            }
            .padding(18)
            Rectangle().fill(Color(theme.hairline)).frame(height: 0.5)
            content
            Rectangle().fill(Color(theme.hairline)).frame(height: 0.5)
            HStack(spacing: 8) { footer }.padding(14)
        }
        .background(Color(theme.surface))
    }
}

// MARK: Table builder

struct TableBuilderSheet: View {
    let model: ProjectModel
    @State var table: TableModel
    @State private var preview: NSImage?
    @State private var previewError: String?
    @State private var renderTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    init(model: ProjectModel, initial: TableModel) {
        self.model = model
        _table = State(initialValue: initial)
    }

    var body: some View {
        SheetScaffold(title: "Table", subtitle: "Type in the grid or paste from Numbers, Excel or Google Sheets.", symbol: "tablecells") {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    controls
                    ScrollView([.horizontal, .vertical]) { grid.padding(1) }
                        .defaultScrollAnchor(.topLeading)
                        .frame(minHeight: 180)
                        .card(cornerRadius: 10)
                    HStack(spacing: 8) {
                        TextField("Caption", text: $table.caption).textFieldStyle(.roundedBorder)
                        TextField("Label (tab:results)", text: $table.label).textFieldStyle(.roundedBorder).frame(width: 180)
                    }
                    Toggle("Floating table environment (caption, label, placement)", isOn: $table.floating).toggleStyle(.lig).font(.system(size: 12))
                }
                .padding(16)
                .frame(width: 520)
                Rectangle().fill(Color(theme.hairline)).frame(width: 0.5)
                VStack(alignment: .leading, spacing: 10) {
                    Text("PREVIEW").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Color(theme.secondary))
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(.white)
                        if let preview {
                            Image(nsImage: preview).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(14)
                        } else if let previewError {
                            Text(previewError).font(.system(size: 11)).foregroundStyle(.secondary).padding()
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(height: 170)
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                    Text("LATEX").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Color(theme.secondary))
                    ScrollView {
                        Text(table.latex())
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color(theme.text))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(theme.editor)))
                }
                .padding(16)
                .frame(width: 340)
            }
        } footer: {
            Button("Paste from Clipboard") {
                if let s = NSPasteboard.general.string(forType: .string), var t = TableModel.parse(delimited: s) {
                    t.caption = table.caption; t.label = table.label; t.style = table.style; t.floating = table.floating
                    withAnimation(.panel) { table = t }
                }
            }
            .buttonStyle(.ligSecondary)
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.ligSecondary).keyboardShortcut(.cancelAction)
            Button(model.tableReplaceRange == nil ? "Insert Table" : "Update Table") { insert() }.buttonStyle(.ligPrimary).keyboardShortcut(.defaultAction)
        }
        .frame(width: 862)
        .onAppear { render() }
        .onChange(of: table) { _, _ in render() }
    }

    var controls: some View {
        HStack(spacing: 14) {
            Stepper("Rows \(table.rows)", value: Binding(get: { table.rows }, set: { table.resize(rows: $0, columns: table.columns) }), in: 1...60)
            Stepper("Columns \(table.columns)", value: Binding(get: { table.columns }, set: { table.resize(rows: table.rows, columns: $0) }), in: 1...20)
            Spacer()
            Picker("", selection: $table.style) {
                Text("Booktabs").tag(TableModel.Style.booktabs)
                Text("Grid").tag(TableModel.Style.grid)
                Text("Minimal").tag(TableModel.Style.minimal)
            }
            .pickerStyle(.segmented).frame(width: 220)
        }
        .font(.system(size: 12))
    }

    var grid: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<table.columns, id: \.self) { c in
                    Picker("", selection: Binding(get: { table.align[c] }, set: { table.align[c] = $0 })) {
                        Image(systemName: "text.alignleft").tag(TableModel.Align.l)
                        Image(systemName: "text.aligncenter").tag(TableModel.Align.c)
                        Image(systemName: "text.alignright").tag(TableModel.Align.r)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .frame(width: 112).padding(4)
                }
            }
            ForEach(0..<table.rows, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<table.columns, id: \.self) { c in
                        TextField("", text: Binding(get: { table.cells[safe: r]?[safe: c] ?? "" }, set: { if r < table.rows && c < table.columns { table.cells[r][c] = $0 } }))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: r == 0 && table.headerRow ? .semibold : .regular))
                            .multilineTextAlignment(table.align[c] == .r ? .trailing : (table.align[c] == .c ? .center : .leading))
                            .padding(.horizontal, 8).frame(width: 120, height: 28)
                            .background(r == 0 && table.headerRow ? accent.opacity(0.06) : Color.clear)
                            .overlay(Rectangle().strokeBorder(Color(theme.hairline), lineWidth: 0.5))
                    }
                }
            }
        }
    }

    func render() {
        renderTask?.cancel()
        renderTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let engine = model.engine else { return }
            var t = table
            t.floating = false
            let code = "\\begin{minipage}{11cm}\\centering " + t.latex() + "\\end{minipage}"
            let pre = "\\usepackage{booktabs}\n" + LaTeXText.preamble(of: model.text(of: model.mainFile) ?? "").body
            let r = await MathRenderer.shared.render(math: code, display: true, preamble: pre, engine: engine)
            guard !Task.isCancelled else { return }
            switch r {
            case .pdf(let d):
                if let doc = PDFDocumentImage.make(d) { preview = doc; previewError = nil }
            case .failed(let e): previewError = e
            case nil: break
            }
        }
    }

    func insert() {
        let code = table.latex() + "\n"
        if let range = model.tableReplaceRange, let ed = model.editor as? EditorController {
            ed.select(range)
        }
        model.editor?.insertPlain(code)
        model.tableReplaceRange = nil
        dismiss()
    }
}

/// Renders a PDF page as a normal (non-template) image for previews on white.
enum PDFDocumentImage {
    static func make(_ data: Data) -> NSImage? {
        guard let img = MathImage.make(from: data, scale: 2) else { return nil }
        img.isTemplate = false
        return img
    }
}

// MARK: Figure

struct FigureSheet: View {
    let model: ProjectModel
    @State private var imageURL: URL?
    @State private var caption = ""
    @State private var label = ""
    @State private var width: Double = 0.8
    @State private var targeted = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: "Figure", subtitle: "Images are copied into the project's figures folder.", symbol: "photo") {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .foregroundStyle(targeted ? accent : Color(theme.hairline).opacity(2))
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(targeted ? accent.opacity(0.06) : Color(theme.text).opacity(0.02)))
                    if let imageURL, let img = NSImage(contentsOf: imageURL) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(12)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.plus").font(.system(size: 28, weight: .light)).foregroundStyle(accent)
                            Text("Drop an image here").font(.system(size: 13, weight: .medium)).foregroundStyle(Color(theme.text))
                            Button("Choose…") { choose() }.buttonStyle(.ligSecondary)
                        }
                    }
                }
                .frame(height: 220)
                .animation(.hover, value: targeted)
                .dropDestination(for: URL.self) { urls, _ in
                    guard let u = urls.first else { return false }
                    set(u)
                    return true
                } isTargeted: { t in
                    targeted = t
                }
                TextField("Caption", text: $caption).textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Label", text: $label).textFieldStyle(.roundedBorder)
                    Text("Width").font(.system(size: 12)).foregroundStyle(Color(theme.secondary))
                    Slider(value: $width, in: 0.2...1, step: 0.05).frame(width: 160)
                    Text("\(Int(width * 100))%").font(.system(size: 12).monospacedDigit()).frame(width: 38)
                }
            }
            .padding(18)
        } footer: {
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.ligSecondary).keyboardShortcut(.cancelAction)
            Button("Insert Figure") { insert() }.buttonStyle(.ligPrimary).keyboardShortcut(.defaultAction).disabled(imageURL == nil)
        }
        .frame(width: 560)
    }

    func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .jpeg, .pdf, .tiff, .heic, .gif]
        if p.runModal() == .OK, let u = p.url { set(u) }
    }

    func set(_ u: URL) {
        imageURL = u
        if label.isEmpty { label = "fig:" + u.deletingPathExtension().lastPathComponent.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression) }
    }

    func insert() {
        guard let u = imageURL, let path = model.importImage(u) else { return }
        let w = width >= 0.999 ? "\\linewidth" : String(format: "%.2g\\linewidth", width)
        model.editor?.insertSnippet("\\begin{figure}[htbp]\n\t\\centering\n\t\\includegraphics[width=\(w)]{\(path)}\n\t\\caption{\(caption.isEmpty ? "${1:Caption}" : caption)}\n\t\\label{\(label)}\n\\end{figure}\n$0")
        dismiss()
    }
}

// MARK: Add citation

struct AddCitationSheet: View {
    let model: ProjectModel
    @State private var input = ""
    @State private var results: [CitationFetcher.SearchHit] = []
    @State private var bibtex = ""
    @State private var loading = false
    @State private var error: String?
    @State private var insertCite = true
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var kindHint: String {
        switch CitationFetcher.Query.parse(input) {
        case .doi: "DOI"
        case .arxiv: "arXiv"
        case .search: input.isEmpty ? "" : "Title search"
        }
    }

    var body: some View {
        SheetScaffold(title: "Add Citation", subtitle: "Paste a DOI or arXiv ID, or search by title. Uses Crossref and arXiv.", symbol: "quote.opening") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    SearchField(text: $input, prompt: "10.1038/nature14539  ·  1706.03762  ·  attention is all you need")
                        .focused($focused)
                        .onSubmit { lookUp() }
                    if !kindHint.isEmpty { Text(kindHint).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(accent).padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(accent.opacity(0.12))) }
                    Button("Look Up") { lookUp() }.buttonStyle(.ligPrimary).disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || loading)
                }
                if loading { HStack { ProgressView().controlSize(.small); Text("Looking up…").font(.system(size: 12)).foregroundStyle(Color(theme.secondary)) } }
                if let error { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Color(theme.warning)) }
                if !results.isEmpty && bibtex.isEmpty {
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(results) { hit in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(hit.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color(theme.text)).lineLimit(2)
                                    Text([hit.authors, hit.year, hit.venue].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Color(theme.secondary)).lineLimit(1)
                                }
                                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                .hoverRow()
                                .onTapGesture { fetch(doi: hit.doi) }
                            }
                        }
                    }
                    .frame(height: 230)
                }
                if !bibtex.isEmpty {
                    TextEditor(text: $bibtex)
                        .font(.system(size: 11.5, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(theme.editor)))
                        .frame(height: 210)
                    Toggle("Insert \\cite{…} at the caret", isOn: $insertCite).toggleStyle(.lig).font(.system(size: 12))
                }
            }
            .padding(18)
        } footer: {
            if !bibtex.isEmpty { Button("Back") { bibtex = "" }.buttonStyle(.ligSecondary) }
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.ligSecondary).keyboardShortcut(.cancelAction)
            Button("Add to Bibliography") { add() }.buttonStyle(.ligPrimary).keyboardShortcut(.defaultAction).disabled(bibtex.isEmpty)
        }
        .frame(width: 600)
        .onAppear { focused = true }
    }

    func lookUp() {
        error = nil; bibtex = ""; results = []
        let q = CitationFetcher.Query.parse(input)
        loading = true
        Task { @MainActor in
            defer { loading = false }
            do {
                switch q {
                case .doi(let d): bibtex = try await CitationFetcher.bibtex(doi: d)
                case .arxiv(let a): bibtex = try await CitationFetcher.bibtex(arxiv: a)
                case .search(let s):
                    results = try await CitationFetcher.search(s)
                    if results.isEmpty { error = "No papers found." }
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func fetch(doi: String) {
        loading = true
        Task { @MainActor in
            defer { loading = false }
            do { bibtex = try await CitationFetcher.bibtex(doi: doi) } catch { self.error = error.localizedDescription }
        }
    }

    func add() {
        guard let key = model.addBibTeX(bibtex.hasSuffix("\n") ? bibtex : bibtex + "\n") else { return }
        if insertCite { model.editor?.insertSnippet("\\cite{\(key)}") }
        model.showToast("books.vertical.fill", "Added \(key)")
        let main = model.text(of: model.mainFile) ?? ""
        if !main.contains("\\bibliography{") && !main.contains("\\addbibresource") && !main.contains("\\printbibliography") {
            model.showToast("info.circle", "Add \\bibliography{references} before \\end{document} to print it")
        }
        dismiss()
    }
}

// MARK: New file

struct NewFileSheet: View {
    let model: ProjectModel
    @State private var name = ""
    @State private var kind = "tex"
    @State private var addInput = true
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: "New File", subtitle: "Add a chapter, section file or bibliography.", symbol: "doc.badge.plus") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $kind) {
                    Text("TeX (.tex)").tag("tex")
                    Text("Bibliography (.bib)").tag("bib")
                }
                .pickerStyle(.segmented).labelsHidden()
                TextField(kind == "tex" ? "chapters/introduction" : "references", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { create() }
                if kind == "tex" {
                    Toggle("Add \\input{…} to the main file at the caret", isOn: $addInput).toggleStyle(.lig).font(.system(size: 12))
                }
            }
            .padding(18)
        } footer: {
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.ligSecondary).keyboardShortcut(.cancelAction)
            Button("Create") { create() }.buttonStyle(.ligPrimary).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .frame(width: 440)
        .onAppear { focused = true }
    }

    func create() {
        var n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if (n as NSString).pathExtension.isEmpty { n += "." + kind }
        if kind == "tex", addInput, model.activeDoc?.relativePath == model.mainFile {
            model.editor?.insertSnippet("\\input{\((n as NSString).deletingPathExtension)}\n")
        }
        let title = ((n as NSString).deletingPathExtension as NSString).lastPathComponent.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
        model.createFile(named: n, contents: kind == "tex" ? "\\section{\(title)}\n\\label{sec:\(title.lowercased().replacingOccurrences(of: " ", with: "-"))}\n\n" : "")
        dismiss()
    }
}

// MARK: Rename project

struct RenameProjectSheet: View {
    let model: ProjectModel
    @State private var name = ""
    @State private var error: String?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: "Rename Project", subtitle: "Renames the project folder. Files, history and settings come along.", symbol: "pencil") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Project name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { rename() }
                Text((model.root.deletingLastPathComponent().appendingPathComponent(name.isEmpty ? model.name : name).path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(theme.secondary))
                    .lineLimit(1).truncationMode(.middle)
                if let error { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Color(theme.warning)) }
            }
            .padding(18)
        } footer: {
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.ligSecondary).keyboardShortcut(.cancelAction)
            Button("Rename") { rename() }.buttonStyle(.ligPrimary).keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == model.name)
        }
        .frame(width: 460)
        .onAppear { name = model.name; focused = true }
    }

    func rename() {
        switch model.renameProject(to: name) {
        case .success:
            dismiss()
        case .failure(let e):
            error = e.localizedDescription
        }
    }
}

// MARK: Previous downloads

struct DownloadsSheet: View {
    let model: ProjectModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: "Previous Downloads", subtitle: "Every PDF and export you've saved from \(model.name). Ligature keeps its own copy of each one.", symbol: "tray.full") {
            if model.downloads.isEmpty {
                EmptyState(symbol: "tray", title: "Nothing downloaded yet", message: "Use Export → Download PDF (⇧⌘E). Each download appears here with a copy you can always get back.")
                    .frame(height: 280)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(groups, id: \.0) { day, records in
                            Text(day).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color(theme.secondary))
                                .padding(.horizontal, 6).padding(.top, 8)
                            ForEach(records) { r in DownloadRow(record: r, model: model) }
                        }
                    }
                    .padding(12)
                }
                .frame(height: 380)
            }
        } footer: {
            if !model.downloads.isEmpty {
                Text("\(model.downloads.count) saved · newest 60 kept").font(.system(size: 11)).foregroundStyle(Color(theme.secondary))
            }
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(.ligPrimary).keyboardShortcut(.defaultAction)
        }
        .frame(width: 620)
    }

    var groups: [(String, [DownloadRecord])] {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        var out: [(String, [DownloadRecord])] = []
        for r in model.downloads {
            let k = f.string(from: r.date)
            if let i = out.firstIndex(where: { $0.0 == k }) { out[i].1.append(r) } else { out.append((k, [r])) }
        }
        return out
    }
}

private struct DownloadRow: View {
    let record: DownloadRecord
    let model: ProjectModel
    @State private var hovering = false

    var copy: URL { DownloadStore.copyURL(record, root: model.root) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.kind == .pdf ? "doc.richtext.fill" : (record.kind == .word ? "doc.text.fill" : "doc.zipper"))
                .font(.system(size: 15))
                .foregroundStyle(record.kind == .pdf ? Color(theme.error).opacity(0.85) : (record.kind == .word ? Color(Theme.hex(0x2B579A)) : accent))
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(theme.text).opacity(0.05)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.fileName).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(theme.text)).lineLimit(1)
                    if record.kind == .arxiv { Text("arXiv").font(.system(size: 9.5, weight: .bold)).foregroundStyle(accent).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(accent.opacity(0.12))) }
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(Color(theme.secondary)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                IconButton(symbol: "eye", help: "Open this version", size: 26) { NSWorkspace.shared.open(copy) }
                IconButton(symbol: "folder", help: record.stillThere ? "Show in Finder" : "The original was moved or deleted", size: 26) {
                    NSWorkspace.shared.activateFileViewerSelecting([record.destinationURL])
                }
                .disabled(!record.stillThere)
                IconButton(symbol: "square.and.arrow.down", help: "Save a copy again…", size: 26) { saveAgain() }
                IconButton(symbol: "trash", help: "Forget this download", size: 26) { withAnimation(.panel) { model.removeDownload(record) } }
            }
            .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .hoverRow(cornerRadius: 10)
        .onHover { h in withAnimation(.hover) { hovering = h } }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(copy) }
        .contextMenu {
            Button("Open This Version") { NSWorkspace.shared.open(copy) }
            Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([record.destinationURL]) }.disabled(!record.stillThere)
            Button("Save a Copy Again…") { saveAgain() }
            Divider()
            Button("Forget This Download", role: .destructive) { model.removeDownload(record) }
        }
    }

    var detail: String {
        var parts = [record.date.formatted(date: .omitted, time: .shortened)]
        if let p = record.pages { parts.append("\(p) page\(p == 1 ? "" : "s")") }
        if let w = record.words { parts.append("\(w.formatted()) words") }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(record.bytes), countStyle: .file))
        parts.append(record.stillThere ? (record.destination as NSString).abbreviatingWithTildeInPath : "original moved or deleted")
        return parts.joined(separator: " · ")
    }

    func saveAgain() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = record.fileName
        panel.directoryURL = record.destinationURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? FileManager.default.removeItem(at: url)
        if (try? FileManager.default.copyItem(at: copy, to: url)) != nil {
            model.showToast("arrow.down.doc.fill", "Saved \(url.lastPathComponent)")
        }
    }
}
