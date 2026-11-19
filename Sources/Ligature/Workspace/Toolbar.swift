import SwiftUI
import UniformTypeIdentifiers
import LigatureCore

struct WorkspaceToolbar: ToolbarContent {
    @Bindable var model: ProjectModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                LiveSwitch(model: model)
                CompilePill(model: model)
                if !Preferences.shared.liveCompile {
                    CompileButton(model: model)
                        .transition(.move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.panel, value: Preferences.shared.liveCompile)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            InsertMenu(model: model)
            SlidingTabs(items: Preferences.Layout.allCases, selection: $model.layout, symbol: \.symbol, title: \.title, height: 24)
                .frame(width: 104)
                .help("Layout: editor, split, PDF  (⌘1 ⌘2 ⌘3)")
            Button { model.quickDownload() } label: {
                Label("Quick Download", systemImage: "arrow.down.circle")
            }
            .disabled(model.pdfData == nil)
            .help("Save the PDF straight to Downloads as “\(model.exportBaseName).pdf”")
            Button { model.showDownloads = true } label: {
                Label("Downloads", systemImage: "tray.full")
            }
            .help("Previously downloaded PDFs and exports")
            ExportMenu(model: model)
        }
    }
}

// MARK: Live switch and compile button

/// Turns automatic compiling on and off. When it's off, a separate Compile button appears next to the status.
struct LiveSwitch: View {
    let model: ProjectModel
    @State private var hovering = false

    var body: some View {
        let on = Preferences.shared.liveCompile
        Button { model.setLiveCompile(!on) } label: {
            HStack(spacing: 7) {
                Image(systemName: on ? "bolt.fill" : "bolt.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(on ? accent : Color(theme.secondary))
                    .contentTransition(.symbolEffect(.replace))
                Text("Live").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(theme.text).opacity(on ? 1 : 0.6))
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(on ? accent : Color(theme.text).opacity(0.18)).frame(width: 26, height: 15)
                    Circle().fill(.white).frame(width: 11, height: 11).padding(2)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(Color(theme.text).opacity(hovering ? 0.07 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .animation(.press, value: on)
        .onHover { h in withAnimation(.hover) { hovering = h } }
        .help(on ? "Live compile is on: the PDF updates as you type. Click to turn off." : "Live compile is off. Click to compile automatically as you type.")
    }
}

/// The explicit Compile button shown while live compile is off. Glows softly when there are edits to compile.
struct CompileButton: View {
    let model: ProjectModel
    @State private var hovering = false
    @State private var breathe = false

    var body: some View {
        let pending = model.hasUncompiledChanges && model.compileState != .running
        Button { model.compile(manual: true) } label: {
            HStack(spacing: 6) {
                Image(systemName: model.compileState == .running ? "hourglass" : "play.fill").font(.system(size: 10.5, weight: .bold))
                Text("Compile").font(.system(size: 12, weight: .semibold))
                Text("⌘R").font(.system(size: 10.5, weight: .medium)).opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(accent.mix(with: .white, by: hovering ? 0.1 : 0)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.75))
            .shadow(color: accent.opacity(pending ? (breathe ? (theme.isDark ? 0.4 : 0.6) : 0.2) : (hovering ? 0.3 : 0)), radius: pending ? (breathe ? 8 : 4) : 5)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .help(pending ? "You have edits that aren't in the PDF yet. Compile  ⌘R" : "Compile  ⌘R")
        .onHover { h in withAnimation(.hover) { hovering = h } }
        .onAppear {
            guard !Preferences.shared.reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

// MARK: Compile pill

struct CompilePill: View {
    let model: ProjectModel
    @State private var hovering = false
    @State private var pressed = false
    @State private var flash: Color?

    var body: some View {
        HStack(spacing: 0) {
            Button {
                model.compile(manual: true)
            } label: {
                HStack(spacing: 7) {
                    icon.frame(width: 14, height: 14)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .contentTransition(.numericText())
                        .lineLimit(1)
                    if let d = model.lastDuration, model.compileState == .success {
                        Text(String(format: "%.2fs", d))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(Color(theme.secondary))
                            .contentTransition(.numericText())
                    }
                }
                .foregroundStyle(foreground)
                .padding(.leading, 12).padding(.trailing, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(PillPressStyle())
            .help(model.compileState == .noEngine ? "Install a TeX engine" : "Compile  ⌘R")

            Rectangle().fill(Color(theme.hairline)).frame(width: 1, height: 14)

            Menu {
                Toggle("Live Compile", isOn: Binding(get: { Preferences.shared.liveCompile }, set: { model.setLiveCompile($0) }))
                Toggle("PDF Follows Caret", isOn: Binding(get: { Preferences.shared.followCaret }, set: { Preferences.shared.followCaret = $0 }))
                Divider()
                Menu("Main File") {
                    ForEach(model.texFiles, id: \.self) { f in
                        Button { model.mainFile = f } label: {
                            if f == model.mainFile { Label(f, systemImage: "checkmark") } else { Text(f) }
                        }
                    }
                }
                Divider()
                if let e = model.engine { Text(e.version.isEmpty ? e.engine.title : e.version) }
                Button("Reveal Build Folder") { NSWorkspace.shared.activateFileViewerSelecting([BuildPaths.directory(for: model.root)]) }
                Button("Clean Build and Compile") {
                    try? FileManager.default.removeItem(at: BuildPaths.directory(for: model.root))
                    model.compile(manual: true)
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(theme.secondary))
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
        }
        .frame(minWidth: 176)
        .background(Capsule().fill(background))
        .overlay {
            if model.compileState == .running && !Preferences.shared.reduceMotion {
                // A light that travels around the rim while typesetting.
                TimelineView(.animation) { ctx in
                    let angle = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6 * 360
                    Capsule().strokeBorder(
                        AngularGradient(colors: [accent.opacity(0.05), accent, accent.opacity(0.05)], center: .center, angle: .degrees(angle)),
                        lineWidth: 1.5)
                }
                .transition(.opacity)
            } else {
                Capsule().strokeBorder(border, lineWidth: 1)
            }
        }
        .shadow(color: glowColor, radius: flash != nil ? 12 : 7)
        .onChange(of: model.compileState) { _, s in
            guard s == .success || s == .failed else { return }
            withAnimation(.easeOut(duration: 0.2)) { flash = s == .success ? .green : Color(theme.error) }
            withAnimation(.easeInOut(duration: 1.2).delay(0.35)) { flash = nil }
        }
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.press, value: hovering)
        .animation(.panel, value: model.compileState)
        .onHover { h in hovering = h }
    }

    var title: String {
        if !Preferences.shared.liveCompile && model.hasUncompiledChanges && model.compileState != .running { return "Edited" }
        return switch model.compileState {
        case .idle: "Compile"
        case .running: "Typesetting"
        case .success: model.warningCount > 0 ? "\(model.warningCount) warning\(model.warningCount == 1 ? "" : "s")" : "Up to date"
        case .failed: model.errorCount > 0 ? "\(model.errorCount) error\(model.errorCount == 1 ? "" : "s")" : "Failed"
        case .noEngine: "Install engine"
        }
    }

    @ViewBuilder var icon: some View {
        if !Preferences.shared.liveCompile && model.hasUncompiledChanges && model.compileState != .running {
            Circle().fill(Color(theme.warning)).frame(width: 7, height: 7).transition(.scale.combined(with: .opacity))
        } else {
            statusIcon
        }
    }

    @ViewBuilder var statusIcon: some View {
        switch model.compileState {
        case .running: ProgressView().controlSize(.mini).scaleEffect(0.8)
        case .success: Image(systemName: model.warningCount > 0 ? "checkmark.circle" : "checkmark.circle.fill").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(model.warningCount > 0 ? Color(theme.warning) : Color.green).transition(.scale.combined(with: .opacity))
        case .failed: Image(systemName: "xmark.octagon.fill").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(theme.error)).transition(.scale.combined(with: .opacity))
        case .noEngine: Image(systemName: "shippingbox").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(theme.warning))
        case .idle: Image(systemName: "play.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
        }
    }

    var foreground: Color { Color(theme.text) }

    var glowColor: Color {
        if let flash { return flash.opacity(theme.isDark ? 0.3 : 0.45) }
        switch model.compileState {
        case .failed: return Color(theme.error).opacity(theme.isDark ? 0.15 : 0.25)
        case .running: return accent.opacity(theme.isDark ? 0.12 : 0.2)
        default: return .clear
        }
    }

    // The toolbar already draws a glass capsule; only tint it for states that need attention.
    var background: Color {
        switch model.compileState {
        case .failed: Color(theme.error).opacity(hovering ? 0.16 : 0.11)
        default: Color(theme.text).opacity(hovering ? 0.06 : 0)
        }
    }

    var border: Color {
        switch model.compileState {
        case .running: accent.opacity(0.45)
        default: .clear
        }
    }
}

private struct PillPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.press, value: configuration.isPressed)
    }
}

// MARK: Insert menu

struct InsertMenu: View {
    let model: ProjectModel

    var body: some View {
        Menu {
            Button { model.tableReplaceRange = nil; model.tableDraft = TableModel(rows: 3, columns: 3) } label: { Label("Table…", systemImage: "tablecells") }
            Button { model.showFigureSheet = true } label: { Label("Figure…", systemImage: "photo") }
            Button { model.showCitationSheet = true } label: { Label("Citation…", systemImage: "quote.opening") }
            Divider()
            Button { model.editor?.insertSnippet("\\begin{equation}\n\t$1\n\t\\label{eq:$2}\n\\end{equation}\n$0") } label: { Label("Equation", systemImage: "function") }
            Button { model.editor?.insertSnippet("\\begin{align}\n\t$1 &= $2 \\\\\n\t$3 &= $4\n\\end{align}\n$0") } label: { Label("Aligned Equations", systemImage: "equal") }
            Button { model.editor?.insertSnippet("\\section{$1}\n\\label{sec:$2}\n$0") } label: { Label("Section", systemImage: "number") }
            Button { model.editor?.insertSnippet("\\begin{itemize}\n\t\\item $1\n\\end{itemize}\n$0") } label: { Label("Bulleted List", systemImage: "list.bullet") }
            Button { model.editor?.insertSnippet("\\begin{enumerate}\n\t\\item $1\n\\end{enumerate}\n$0") } label: { Label("Numbered List", systemImage: "list.number") }
            Button { model.editor?.insertSnippet("\\footnote{$1}$0") } label: { Label("Footnote", systemImage: "text.append") }
            Button { model.editor?.insertSnippet("\\href{$1}{$2}$0") } label: { Label("Link", systemImage: "link") }
            Divider()
            Button { model.sidebarTab = .symbols; model.showSidebar = true } label: { Label("Symbols…", systemImage: "sum") }
        } label: {
            Label("Insert", systemImage: "plus.square.on.square")
        }
        .help("Insert a table, figure, citation, equation…")
    }
}

// MARK: Export menu

struct ExportMenu: View {
    let model: ProjectModel

    var body: some View {
        Menu {
            Button { model.quickDownload() } label: { Label("Quick Download to Downloads", systemImage: "arrow.down.circle") }
            Button { exportPDF() } label: { Label("Download PDF…", systemImage: "arrow.down.doc") }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button { exportWord() } label: { Label("Download as Word (.docx)…", systemImage: "doc.text") }
            if let url = sharedPDFURL() {
                ShareLink(item: url) { Label("Share PDF…", systemImage: "square.and.arrow.up") }
            }
            Button { model.pdf?.print() } label: { Label("Print…", systemImage: "printer") }
            Button { if let url = sharedPDFURL() { NSWorkspace.shared.open(url) } } label: { Label("Open in Preview", systemImage: "eye") }
            Divider()
            Button { exportZip(arxiv: false) } label: { Label("Export Source (.zip)…", systemImage: "doc.zipper") }
            Button { exportZip(arxiv: true) } label: { Label("Export for arXiv…", systemImage: "paperplane") }
            Divider()
            Button { model.showDownloads = true } label: { Label("Previous Downloads (\(model.downloads.count))…", systemImage: "tray.full") }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(model.pdfData == nil)
        .help("Download, share or print the PDF; export sources")
    }

    /// A copy of the PDF named after the project, for sharing and opening elsewhere.
    func sharedPDFURL() -> URL? {
        guard let data = model.pdfData else { return nil }
        let dir = BuildPaths.directory(for: model.root).appendingPathComponent("share", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(model.exportBaseName).pdf")
        try? data.write(to: url)
        return url
    }

    func exportPDF() {
        guard let data = model.pdfData else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(model.exportBaseName).pdf"
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            model.recordDownload(.pdf, to: url)
            model.showToast("arrow.down.doc.fill", "Saved \(url.lastPathComponent)")
        } catch {
            model.showToast("exclamationmark.triangle.fill", "Couldn't save: \(error.localizedDescription)", tint: Color(theme.error))
        }
    }

    func exportWord() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        panel.nameFieldStringValue = "\(model.exportBaseName).docx"
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.saveAll()
        let bibs = FileNode.flatten(model.tree).filter { $0.name.hasSuffix(".bib") }.map(\.path)
        do {
            try? FileManager.default.removeItem(at: url)
            try WordExporter.export(root: model.root, main: model.mainFile, bibFiles: bibs, to: url)
            model.recordDownload(.word, to: url)
            model.showToast("doc.text.fill", "Saved \(url.lastPathComponent)", actionTitle: "Open") { NSWorkspace.shared.open(url) }
        } catch {
            model.showToast("exclamationmark.triangle.fill", error.localizedDescription, tint: Color(theme.error))
        }
    }

    func exportZip(arxiv: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(model.exportBaseName)\(arxiv ? "-arxiv" : "").zip"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.saveAll()
        do {
            if arxiv { try Exporter.arxiv(root: model.root, main: model.mainFile, buildDir: BuildPaths.directory(for: model.root), to: url) }
            else { try Exporter.zip(folder: model.root, to: url) }
            model.recordDownload(arxiv ? .arxiv : .source, to: url)
            model.showToast("doc.zipper", "Exported \(url.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            model.showToast("exclamationmark.triangle.fill", "Export failed: \(error.localizedDescription)", tint: Color(theme.error))
        }
    }
}
