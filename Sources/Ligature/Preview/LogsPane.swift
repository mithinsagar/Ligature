import SwiftUI
import AppKit
import LigatureCore

/// The last compile's problems in plain English, the raw log, and the files the engine produced. Shown over the
/// PDF from its controls, the compile menu, or the error badge.
struct LogsPane: View {
    @Bindable var model: ProjectModel
    @State private var filter: Filter = .all
    @State private var expanded: String?
    @State private var showRaw = false

    enum Filter: String, CaseIterable, Hashable {
        case all, errors, warnings, info
        var title: String { ["all": "All", "errors": "Errors", "warnings": "Warnings", "info": "Info"][rawValue]! }
        var symbol: String { ["all": "list.bullet", "errors": "xmark.octagon", "warnings": "exclamationmark.triangle", "info": "info.circle"][rawValue]! }
    }

    private func matches(_ i: CompileIssue, _ f: Filter) -> Bool {
        switch f {
        case .all: true
        case .errors: i.severity == .error
        case .warnings: i.severity == .warning
        case .info: i.severity == .badBox
        }
    }

    var shown: [CompileIssue] { model.issues.filter { matches($0, filter) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color(theme.hairline)).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if model.issues.isEmpty {
                        EmptyState(symbol: model.compileState == .success ? "checkmark.seal" : "doc.text.magnifyingglass",
                                   title: model.compileState == .success ? "Clean compile" : "No log yet",
                                   message: model.compileState == .success ? "No errors, warnings or layout notes." : "Compile to see what TeX has to say.")
                            .frame(height: 220)
                    }
                    ForEach(shown) { issue in
                        LogEntry(issue: issue, model: model, expanded: expanded == issue.id) {
                            withAnimation(.panel) { expanded = expanded == issue.id ? nil : issue.id }
                        }
                    }
                    rawLog
                }
                .padding(14)
            }
            Rectangle().fill(Color(theme.hairline)).frame(height: 1)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(theme.surface))
        .clipped()
    }

    var header: some View {
        HStack(spacing: 8) {
            Text("Logs").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(theme.text))
                .layoutPriority(1)
            ViewThatFits(in: .horizontal) {
                filters(titles: true)
                filters(titles: false)
            }
            Spacer(minLength: 4)
            Button { withAnimation(.panel) { model.showLogs = false } } label: { Image(systemName: "xmark") }
                .buttonStyle(.ligIcon(size: 26))
                .help("Back to the PDF")
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    func filters(titles: Bool) -> some View {
            HStack(spacing: 4) {
                ForEach(Filter.allCases, id: \.self) { f in
                    let count = model.issues.filter { matches($0, f) }.count
                    Button { withAnimation(.panel) { filter = f } } label: {
                        HStack(spacing: 4) {
                            if titles { Text(f.title) } else { Image(systemName: f.symbol).font(.system(size: 10, weight: .semibold)) }
                            Text("\(count)").monospacedDigit().foregroundStyle(count > 0 && f == .errors ? Color(theme.error) : Color(theme.secondary))
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.ligChip(selected: filter == f))
                    .help(f.title)
                }
            }
    }

    @ViewBuilder var rawLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.panel) { showRaw.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(showRaw ? 90 : 0))
                    Text("Raw log").font(.system(size: 12, weight: .semibold))
                    Text("\(model.lastLog.components(separatedBy: "\n").count) lines").font(.system(size: 11)).foregroundStyle(Color(theme.secondary))
                    Spacer()
                }
                .foregroundStyle(Color(theme.text))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            if showRaw {
                RawLogView(text: model.lastLog.isEmpty ? model.lastStderr : model.lastLog + (model.lastStderr.isEmpty ? "" : "\n\n── Engine output ──\n" + model.lastStderr))
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(theme.hairline)))
            }
        }
    }

    var footer: some View {
        HStack(spacing: 8) {
            Button { model.recompileFromScratch() } label: { Label("Clear Cache", systemImage: "trash") }
                .buttonStyle(.ligSecondary)
                .help("Delete everything the engine cached for this project and compile from scratch")
            Spacer()
            Menu {
                let files = model.outputFiles
                if files.isEmpty { Text("Nothing yet") }
                ForEach(files, id: \.self) { url in
                    Button(url.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Divider()
                Button("Download All…") { downloadAll() }.disabled(files.isEmpty)
                Button("Reveal Build Folder") { NSWorkspace.shared.activateFileViewerSelecting([BuildPaths.directory(for: model.root)]) }
            } label: {
                Label("Output Files", systemImage: "folder")
            }
            .menuStyle(.button)
            .fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func downloadAll() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.exportBaseName) build files.zip"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", BuildPaths.directory(for: model.root).path, dest.path]
        try? p.run()
        p.waitUntilExit()
        model.showToast("archivebox.fill", "Saved \(dest.lastPathComponent)", actionTitle: "Show") { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
    }
}

/// One problem: what it means, where it is, the raw TeX context, and what to do about it.
private struct LogEntry: View {
    let issue: CompileIssue
    let model: ProjectModel
    let expanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var advice: Advice? { ErrorAdvisor.advise(issue) }
    var color: Color { issue.severity == .error ? Color(theme.error) : (issue.severity == .warning ? Color(theme.warning) : Color(theme.secondary)) }
    var icon: String { issue.severity == .error ? "xmark.octagon.fill" : (issue.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(color).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(advice?.title ?? issue.message)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(issue.severity == .error ? color : Color(theme.text))
                        .fixedSize(horizontal: false, vertical: true)
                    if let file = issue.file ?? (issue.line != nil ? model.mainFile : nil) {
                        Text("\(file)\(issue.line.map { ", line \($0)" } ?? "")")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(theme.secondary))
                    }
                }
                Spacer(minLength: 4)
                if issue.line != nil {
                    Button { model.open(path: issue.file ?? model.mainFile, line: issue.line) } label: { Image(systemName: "location.fill") }
                        .buttonStyle(.ligIcon(size: 24))
                        .help("Go to this line")
                }
                Image(systemName: "chevron.down").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Color(theme.secondary))
                    .rotationEffect(.degrees(expanded ? 180 : 0)).padding(.top, 5)
            }
            if expanded {
                if let advice { Text(advice.explanation).font(.system(size: 12)).foregroundStyle(Color(theme.text).opacity(0.85)).fixedSize(horizontal: false, vertical: true) }
                if let ctx = issue.context ?? (advice != nil && advice?.title != issue.message ? issue.message : nil) {
                    Text(ctx).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(theme.text).opacity(0.8))
                        .textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(theme.text).opacity(0.05)))
                }
                HStack(spacing: 8) {
                    if let fix = advice?.fix, let label = advice?.fixLabel {
                        Button { model.apply(fix) } label: { Label(label, systemImage: "wand.and.sparkles") }.buttonStyle(.ligPrimary)
                    }
                    if issue.severity == .error, issue.line != nil {
                        Button { model.suggestFix(for: issue) } label: { Label("Suggest Fix", systemImage: "sparkles") }
                            .buttonStyle(.ligSecondary)
                            .help("Ask the on-device model for a fix (nothing leaves your Mac)")
                    }
                    Spacer()
                    if let url = LogEntry.learnMore(issue.message) {
                        Button("Learn more") { NSWorkspace.shared.open(url) }.buttonStyle(.ligGhost)
                    }
                }
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(theme.text).opacity(hovering || expanded ? 0.05 : 0.025)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(expanded ? color.opacity(0.35) : Color(theme.hairline)))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { h in withAnimation(.hover) { hovering = h } }
    }

    /// Overleaf's error guides are named after the message, e.g. "Undefined control sequence".
    static func learnMore(_ message: String) -> URL? {
        let known = ["Undefined control sequence", "Missing $ inserted", "Extra alignment tab has been changed to \\cr", "Missing } inserted",
                     "Paragraph ended before", "File not found", "Extra }, or forgotten $", "Misplaced alignment tab character &",
                     "There's no line here to end", "Undefined citation", "Reference undefined", "Overfull hbox", "Underfull hbox"]
        guard let hit = known.first(where: { message.localizedCaseInsensitiveContains($0.replacingOccurrences(of: " not found", with: "")) }) else { return nil }
        let slug = hit.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "$", with: "%24")
        return URL(string: "https://www.overleaf.com/learn/latex/Errors/\(slug)")
    }
}

/// A read-only, searchable (⌘F) monospaced view of the raw log.
private struct RawLogView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.usesFindBar = true
            tv.isIncrementalSearchingEnabled = true
            tv.textContainerInset = NSSize(width: 8, height: 8)
            tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        }
        scroll.drawsBackground = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        let t = ThemeManager.shared.theme
        tv.backgroundColor = t.editor
        tv.textColor = t.text
        tv.string = text
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.scrollToEndOfDocument(nil)
    }
}
