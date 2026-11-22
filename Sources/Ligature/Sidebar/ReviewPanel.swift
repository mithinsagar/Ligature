import SwiftUI

/// Comments: threads attached to text, with replies, resolve and reopen. "This file" or every file; resolved
/// threads fold away at the bottom.
struct ReviewPanel: View {
    @Bindable var model: ProjectModel
    @State private var scope: Scope = .file
    @State private var draft = ""
    @State private var showResolved = false
    @FocusState private var composing: Bool

    enum Scope: Hashable { case file, all }

    private var visible: [Comment] {
        let current = model.activeDoc?.relativePath
        return model.comments.filter { scope == .all || $0.file == current }
            .sorted { ($0.file, $0.location) < ($1.file, $1.location) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button("This File") { withAnimation(.panel) { scope = .file } }.buttonStyle(.ligChip(selected: scope == .file))
                Button("All Files") { withAnimation(.panel) { scope = .all } }.buttonStyle(.ligChip(selected: scope == .all))
                Spacer()
                Button { model.beginComment() } label: { Image(systemName: "plus.bubble") }
                    .buttonStyle(.ligIcon(size: 24))
                    .help("Comment on the selected text (⌥⌘M)")
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let d = model.commentDraft { composer(quote: d.quote, file: d.file) }
                    let open = visible.filter { !$0.resolved }
                    let resolved = visible.filter(\.resolved)
                    if open.isEmpty && model.commentDraft == nil {
                        EmptyState(symbol: "text.bubble", title: "No comments", message: "Select text and press ⌥⌘M to leave a note for yourself or a co-author.")
                            .frame(height: 200)
                    }
                    ForEach(open) { c in CommentCard(model: model, comment: c, showFile: scope == .all) }
                    if !resolved.isEmpty {
                        Button { withAnimation(.panel) { showResolved.toggle() } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(showResolved ? 90 : 0))
                                Text("Resolved (\(resolved.count))").font(.system(size: 11.5, weight: .semibold))
                                Spacer()
                            }
                            .foregroundStyle(Color(theme.secondary))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                        if showResolved { ForEach(resolved) { c in CommentCard(model: model, comment: c, showFile: scope == .all) } }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
            }
        }
    }

    private func composer(quote: String, file: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("“\(quote.prefix(160))\(quote.count > 160 ? "…" : "")”")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(theme.secondary)).lineLimit(3)
            TextField("Add a comment…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12.5)).lineLimit(2...6)
                .focused($composing)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(theme.text).opacity(0.05)))
                .onSubmit(post)
            HStack {
                Spacer()
                Button("Cancel") { model.commentDraft = nil; draft = "" }.buttonStyle(.ligGhost)
                Button("Comment", action: post).buttonStyle(.ligPrimary).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(accent.opacity(0.35)))
        .onAppear { composing = true }
    }

    private func post() {
        model.addComment(draft)
        draft = ""
    }
}

private struct CommentCard: View {
    let model: ProjectModel
    let comment: Comment
    let showFile: Bool
    @State private var hovering = false
    @State private var reply = ""
    @State private var editing = false
    @State private var editText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Avatar(name: comment.author)
                VStack(alignment: .leading, spacing: 0) {
                    Text(comment.author).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(theme.text))
                    Text(comment.date, format: .relative(presentation: .named)).font(.system(size: 10.5)).foregroundStyle(Color(theme.secondary))
                }
                Spacer()
                Button { model.setResolved(comment.id, !comment.resolved) } label: { Image(systemName: comment.resolved ? "arrow.uturn.backward" : "checkmark") }
                    .buttonStyle(.ligIcon(size: 22))
                    .help(comment.resolved ? "Reopen" : "Resolve")
                Menu {
                    Button("Edit") { editText = comment.text; editing = true }
                    Button("Delete", role: .destructive) { model.deleteComment(comment.id) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.ligIcon(size: 22)).fixedSize()
            }
            HStack(spacing: 6) {
                Rectangle().fill(comment.orphaned ? Color(theme.secondary) : Color(theme.warning)).frame(width: 2.5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(comment.orphaned ? "The text this was on was deleted" : "“\(comment.quote.prefix(120))\(comment.quote.count > 120 ? "…" : "")”")
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(theme.secondary)).lineLimit(2)
                    if showFile { Text(comment.file).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(theme.secondary).opacity(0.8)) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if editing {
                TextField("Comment", text: $editText, axis: .vertical).textFieldStyle(.roundedBorder).font(.system(size: 12.5))
                HStack { Spacer(); Button("Cancel") { editing = false }.buttonStyle(.ligGhost); Button("Save") { model.editComment(comment.id, text: editText); editing = false }.buttonStyle(.ligPrimary) }
            } else {
                Text(comment.text).font(.system(size: 12.5)).foregroundStyle(Color(theme.text)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            ForEach(comment.replies) { r in
                HStack(alignment: .top, spacing: 7) {
                    Avatar(name: r.author, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(r.author).font(.system(size: 11, weight: .semibold))
                            Text(r.date, format: .relative(presentation: .named)).font(.system(size: 10)).foregroundStyle(Color(theme.secondary))
                        }
                        Text(r.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    .foregroundStyle(Color(theme.text))
                }
                .padding(.leading, 6)
            }
            if !comment.resolved {
                TextField("Reply", text: $reply)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(theme.text).opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(theme.hairline)))
                    .onSubmit { model.reply(to: comment.id, reply); reply = "" }
            }
        }
        .padding(10)
        .opacity(comment.resolved ? 0.7 : 1)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(theme.text).opacity(hovering || model.focusedComment == comment.id ? 0.06 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(model.focusedComment == comment.id ? Color(theme.warning).opacity(0.6) : Color(theme.hairline)))
        .contentShape(Rectangle())
        .onTapGesture { model.reveal(comment) }
        .onHover { h in
            withAnimation(.hover) { hovering = h }
            model.focusedComment = h ? comment.id : (model.focusedComment == comment.id ? nil : model.focusedComment)
            (model.editor as? EditorController)?.textView.needsDisplay = true
        }
    }
}

/// A round initial badge in a colour derived from the name.
private struct Avatar: View {
    let name: String
    var size: CGFloat = 24
    var body: some View {
        let hue = Double(name.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }) / 360
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(hue: hue, saturation: 0.45, brightness: 0.75)))
    }
}
