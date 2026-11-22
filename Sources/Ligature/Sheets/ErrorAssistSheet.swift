import SwiftUI
import LigatureCore

/// Suggest Fix: explains a compile error and proposes corrected lines from the on-device model, shown as a
/// diff to apply in one click (and undo with ⌘Z).
struct ErrorAssistSheet: View {
    let model: ProjectModel
    let issue: CompileIssue
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .thinking
    @State private var attempt = 0

    enum Phase: Equatable { case thinking, ready(ErrorAssist.Suggestion), failed(String), unavailable(String) }

    private var advice: Advice? { ErrorAdvisor.advise(issue) }
    private var file: String { issue.file ?? model.mainFile }

    var body: some View {
        SheetScaffold(title: "Suggest a Fix", subtitle: "Apple Intelligence on this Mac · nothing leaves your computer", symbol: "sparkles") {
            VStack(alignment: .leading, spacing: 14) {
                errorCard
                if let fix = advice?.fix, let label = advice?.fixLabel {
                    HStack(spacing: 10) {
                        Image(systemName: "wand.and.sparkles").foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Quick fix").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(theme.text))
                            Text(advice?.explanation ?? "").font(.system(size: 11.5)).foregroundStyle(Color(theme.secondary)).lineLimit(2)
                        }
                        Spacer()
                        Button(label) { model.apply(fix); dismiss() }.buttonStyle(.ligSecondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accent.opacity(0.08)))
                }
                suggestion
            }
            .padding(18)
            .frame(width: 620)
            .frame(minHeight: 300, alignment: .top)
        } footer: {
            if case .ready = phase {
                Button { run() } label: { Label("Try Again", systemImage: "arrow.clockwise") }.buttonStyle(.ligGhost)
            } else if case .failed = phase {
                Button { run() } label: { Label("Try Again", systemImage: "arrow.clockwise") }.buttonStyle(.ligGhost)
            }
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.ligSecondary).keyboardShortcut(.cancelAction)
            Button("Apply Fix") { apply() }
                .buttonStyle(.ligPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled({ if case .ready = phase { return false }; return true }())
        }
        .task { run() }
    }

    private var errorCard: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Color(theme.error)).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(advice?.title ?? issue.message).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(theme.text))
                Text("\(file)\(issue.line.map { ", line \($0)" } ?? "")").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(theme.secondary))
            }
        }
    }

    @ViewBuilder private var suggestion: some View {
        switch phase {
        case .thinking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading the error and the lines around it…").font(.system(size: 12)).foregroundStyle(Color(theme.secondary))
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        case .unavailable(let why), .failed(let why):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(Color(theme.secondary))
                Text(why).font(.system(size: 12)).foregroundStyle(Color(theme.text).opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(theme.text).opacity(0.04)))
        case .ready(let s):
            VStack(alignment: .leading, spacing: 10) {
                Text(s.explanation).font(.system(size: 12.5)).foregroundStyle(Color(theme.text)).fixedSize(horizontal: false, vertical: true)
                DiffBlock(old: s.original, new: s.fixed, firstLine: s.startLine)
                Text("Check the change before applying it: suggestions can be wrong. ⌘Z undoes it.")
                    .font(.system(size: 10.5)).foregroundStyle(Color(theme.secondary))
            }
        }
    }

    private func run() {
        if case .unavailable(let why) = ErrorAssist.availability { phase = .unavailable(why); return }
        attempt += 1
        let mine = attempt
        phase = .thinking
        let text = model.text(of: file) ?? ""
        let packages = Linter.preambleInfo(model.text(of: model.mainFile) ?? "").packages
        Task {
            do {
                let s = try await ErrorAssist.suggest(for: issue, in: text, packages: packages, varied: mine > 1)
                if mine == attempt { withAnimation(.panel) { phase = .ready(s) } }
            } catch {
                if mine == attempt { withAnimation(.panel) { phase = .failed(error.localizedDescription) } }
            }
        }
    }

    private func apply() {
        guard case .ready(let s) = phase, let doc = model.ensureOpen(path: file) else { return }
        var lines = doc.text.components(separatedBy: "\n")
        guard s.startLine >= 1, s.endLine <= lines.count, lines[(s.startLine - 1)...(s.endLine - 1)].joined(separator: "\n") == s.original else {
            phase = .failed("The file changed since the suggestion was made. Try again.")
            return
        }
        var fixed = s.fixed.components(separatedBy: "\n")
        // Keep blank lines the model dropped from the end of the excerpt.
        let trailingBlank = s.original.components(separatedBy: "\n").reversed().prefix { $0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let fixedBlank = fixed.reversed().prefix { $0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if trailingBlank > fixedBlank { fixed += Array(repeating: "", count: trailingBlank - fixedBlank) }
        lines.replaceSubrange((s.startLine - 1)...(s.endLine - 1), with: fixed)
        doc.replaceAll(with: lines.joined(separator: "\n"), actionName: "Apply Suggested Fix")
        model.open(path: file, line: issue.line)
        model.showToast("sparkles", "Applied the suggested fix. ⌘Z undoes it")
        model.compile(manual: true)
        dismiss()
    }
}

/// Old lines in red, new lines in green, unchanged lines plain, with line numbers.
struct DiffBlock: View {
    let old: String
    let new: String
    let firstLine: Int

    var body: some View {
        let lines = LineDiff.diff(old: old, new: new)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { l in
                    HStack(alignment: .top, spacing: 8) {
                        Text(l.kind == .added ? "+" : (l.kind == .removed ? "−" : " "))
                            .frame(width: 10)
                            .foregroundStyle(l.kind == .added ? Color.green : (l.kind == .removed ? Color(theme.error) : Color(theme.secondary)))
                        Text((l.oldNumber ?? l.newNumber).map { "\($0 + firstLine - 1)" } ?? "")
                            .frame(width: 30, alignment: .trailing)
                            .foregroundStyle(Color(theme.secondary))
                        Text(l.text.isEmpty ? " " : l.text)
                            .foregroundStyle(Color(theme.text))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(.vertical, 2).padding(.horizontal, 8)
                    .background(l.kind == .added ? Color.green.opacity(0.14) : (l.kind == .removed ? Color(theme.error).opacity(0.12) : .clear))
                }
            }
        }
        .frame(maxHeight: 260)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(theme.editor)))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(theme.hairline)))
    }
}
