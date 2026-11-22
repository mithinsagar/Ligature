import SwiftUI

/// Source control: what changed since the last commit, a commit box, push and pull, and recent history.
struct GitPanel: View {
    @Bindable var model: ProjectModel
    @State private var message = ""
    @State private var addingRemote = false
    @State private var remoteURL = ""
    @State private var identityName = ProjectModel.userName
    @State private var identityEmail = ""
    @State private var diffPath: String?
    @State private var diffText = ""

    private var repo: GitRepo { model.git }

    var body: some View {
        VStack(spacing: 0) {
            if !repo.isRepo {
                VStack(spacing: 12) {
                    EmptyState(symbol: "arrow.triangle.branch", title: "Not tracked with Git", message: "Git keeps every version you commit on this Mac, and can sync with GitHub when you want.")
                        .frame(height: 170)
                    Button { Task { await repo.initialize() } } label: { Label("Start Tracking with Git", systemImage: "plus.circle") }
                        .buttonStyle(.ligPrimary)
                        .disabled(repo.busy != nil)
                }
                .padding(.horizontal, 12)
                Spacer()
            } else {
                header
                Rectangle().fill(Color(theme.hairline)).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        commitBox
                        if let e = repo.lastError {
                            Label(e, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(Color(theme.warning)).fixedSize(horizontal: false, vertical: true)
                        }
                        if repo.needsIdentity { identityForm }
                        section("Changes", count: repo.changes.count)
                        if repo.changes.isEmpty {
                            Text("Everything is committed.").font(.system(size: 11.5)).foregroundStyle(Color(theme.secondary)).padding(.leading, 4)
                        }
                        ForEach(repo.changes) { c in changeRow(c) }
                        section("History", count: nil)
                        ForEach(repo.commits) { c in commitRow(c) }
                    }
                    .padding(10)
                }
            }
        }
        .task { await repo.refresh() }
        .onChange(of: model.dirtyPaths) { _, _ in Task { await repo.refresh() } }
        .onChange(of: model.lastCompiled) { _, _ in Task { await repo.refresh() } }
        .alert("Add a remote", isPresented: $addingRemote) {
            TextField("https://github.com/you/paper.git", text: $remoteURL)
            Button("Add") { Task { await repo.addRemote(remoteURL) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Create an empty repository on GitHub (or anywhere), then paste its URL here.") }
        .sheet(item: Binding(get: { diffPath.map { DiffBox(path: $0) } }, set: { diffPath = $0?.path })) { box in
            GitDiffSheet(path: box.path, text: diffText)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
            Text(repo.branch).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(theme.text)).lineLimit(1)
            if repo.ahead > 0 { Text("↑\(repo.ahead)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(accent) }
            if repo.behind > 0 { Text("↓\(repo.behind)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Color(theme.warning)) }
            Spacer()
            if let busy = repo.busy { ProgressView().controlSize(.mini); Text(busy).font(.system(size: 10.5)).foregroundStyle(Color(theme.secondary)) }
            if repo.remote == nil {
                Button { remoteURL = ""; addingRemote = true } label: { Image(systemName: "link.badge.plus") }
                    .buttonStyle(.ligIcon(size: 24)).help("Connect to GitHub or another remote")
            } else {
                Button { Task { await repo.pull() } } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.ligIcon(size: 24)).help("Pull from \(repo.remote ?? "the remote")").disabled(repo.busy != nil)
                Button { Task { await repo.push() } } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.ligIcon(size: 24)).help("Push to \(repo.remote ?? "the remote")").disabled(repo.busy != nil)
            }
            Button { Task { await repo.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.ligIcon(size: 24)).help("Refresh")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("What changed?", text: $message, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12.5)).lineLimit(1...4)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(theme.text).opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(theme.hairline)))
            Button {
                model.saveAll()
                let m = message
                message = ""
                Task { await repo.commitAll(m) }
            } label: {
                Label(repo.changes.isEmpty ? "Nothing to Commit" : "Commit \(repo.changes.count) Change\(repo.changes.count == 1 ? "" : "s")", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.ligPrimary)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(repo.changes.isEmpty && model.dirtyPaths.isEmpty || message.trimmingCharacters(in: .whitespaces).isEmpty || repo.busy != nil)
            if !model.dirtyPaths.isEmpty {
                Text("Unsaved edits are saved first.").font(.system(size: 10.5)).foregroundStyle(Color(theme.secondary))
            }
        }
    }

    private var identityForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Git needs a name and email for commits (kept in this repository only).").font(.system(size: 11.5)).foregroundStyle(Color(theme.text))
            TextField("Name", text: $identityName).textFieldStyle(.roundedBorder)
            TextField("Email", text: $identityEmail).textFieldStyle(.roundedBorder)
            Button("Save and Commit") {
                Task {
                    await repo.setIdentity(name: identityName, email: identityEmail)
                    if !message.isEmpty { await repo.commitAll(message); message = "" }
                }
            }
            .buttonStyle(.ligSecondary)
            .disabled(identityName.isEmpty || !identityEmail.contains("@"))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accent.opacity(0.07)))
    }

    private func section(_ title: String, count: Int?) -> some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(Color(theme.secondary))
            if let count { Text("\(count)").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(Color(theme.secondary)) }
            Spacer()
        }
        .padding(.top, 6)
    }

    private func changeRow(_ c: GitRepo.Change) -> some View {
        let color: Color = c.status == "D" ? Color(theme.error) : (c.status == "?" || c.status == "A" ? .green : Color(theme.warning))
        return HStack(spacing: 8) {
            Text(c.status == "?" ? "U" : c.status)
                .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(color)
                .frame(width: 16, height: 16).background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.14)))
            Text((c.path as NSString).lastPathComponent).font(.system(size: 12)).foregroundStyle(Color(theme.text)).lineLimit(1)
            let dir = (c.path as NSString).deletingLastPathComponent
            if !dir.isEmpty { Text(dir).font(.system(size: 10.5)).foregroundStyle(Color(theme.secondary)).lineLimit(1).truncationMode(.middle) }
            Spacer()
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .hoverRow()
        .onTapGesture { showDiff(c.path) }
        .contextMenu {
            Button("Show Changes") { showDiff(c.path) }
            if c.status != "D" { Button("Open") { model.open(path: c.path) } }
        }
        .help(c.status == "?" ? "New file, not committed yet" : "Click to see what changed")
    }

    private func commitRow(_ c: GitRepo.Commit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(c.subject).font(.system(size: 12, weight: .medium)).foregroundStyle(Color(theme.text)).lineLimit(2)
            HStack(spacing: 5) {
                Text(c.hash).font(.system(size: 10, design: .monospaced)).foregroundStyle(accent)
                Text("· \(c.author) · \(c.when)").font(.system(size: 10.5)).foregroundStyle(Color(theme.secondary)).lineLimit(1)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
    }

    private func showDiff(_ path: String) {
        Task {
            diffText = await repo.diff(path)
            diffPath = path
        }
    }

    private struct DiffBox: Identifiable { let path: String; var id: String { path } }
}

/// A file's uncommitted changes, coloured like a review.
private struct GitDiffSheet: View {
    let path: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: (path as NSString).lastPathComponent, subtitle: "Changes since the last commit", symbol: "arrow.triangle.branch") {
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        let color: Color = line.hasPrefix("+") && !line.hasPrefix("+++") ? .green : (line.hasPrefix("-") && !line.hasPrefix("---") ? Color(theme.error) : (line.hasPrefix("@@") ? accent : Color(theme.text).opacity(0.8)))
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(color)
                            .padding(.horizontal, 10).padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(color == .green ? Color.green.opacity(0.1) : (color == Color(theme.error) ? Color(theme.error).opacity(0.1) : .clear))
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(width: 720, height: 460)
        } footer: {
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(.ligPrimary).keyboardShortcut(.defaultAction)
        }
    }
}
