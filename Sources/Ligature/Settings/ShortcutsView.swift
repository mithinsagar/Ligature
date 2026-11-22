import SwiftUI

/// Every keyboard shortcut in one searchable list (Help › Keyboard Shortcuts).
struct ShortcutsView: View {
    @State private var query = ""

    struct Group: Identifiable { let id: String; let items: [(String, String)] }

    static let groups: [Group] = [
        Group(id: "Compile and preview", items: [("Compile", "⌘R"), ("Show caret in PDF", "⇧⌘J"), ("Present PDF full screen", "⌥⌘P"), ("Quick download PDF", "⌥⌘D"), ("Download PDF…", "⇧⌘E"), ("Print PDF", "⇧⌘P")]),
        Group(id: "Writing", items: [("Bold", "⌘B"), ("Italic", "⌘I"), ("Underline", "⌘U"), ("Inline maths", "⇧⌘M"), ("Toggle % comment", "⌘/"), ("Add review comment", "⌥⌘M"), ("Indent / outdent lines", "⇥ / ⇧⇥"), ("Next snippet field", "⇥")]),
        Group(id: "Insert", items: [("Table…", "⌥⌘T"), ("Figure…", "⌥⌘G"), ("Citation…", "⇧⌥⌘C")]),
        Group(id: "Find and navigate", items: [("Find in file", "⌘F"), ("Find in project", "⇧⌘F"), ("Command palette", "⌘K"), ("Quick open", "⌘P"), ("Go to line", "⌘L"), ("Jump to definition (\\ref, \\cite, \\input)", "⌘-click"), ("Peek", "Force click")]),
        Group(id: "Folding", items: [("Fold", "⌥⌘←"), ("Unfold", "⌥⌘→"), ("Fold all", "⇧⌥⌘←"), ("Unfold all", "⇧⌥⌘→")]),
        Group(id: "View", items: [("Editor only", "⌘1"), ("Editor and PDF", "⌘2"), ("PDF only", "⌘3"), ("Focus mode", "⌥⌘↩"), ("Bigger text", "⌘="), ("Smaller text", "⌘−")]),
        Group(id: "Files and projects", items: [("New project", "⌘N"), ("Open", "⌘O"), ("Import .zip, Word or Markdown", "⇧⌘I"), ("Save", "⌘S"), ("Undo / redo", "⌘Z / ⇧⌘Z")]),
        Group(id: "Vim (when turned on)", items: [("Normal mode", "Esc"), ("Insert / append", "i  a  I  A  o  O"), ("Move", "h j k l  w b e  0 ^ $  gg G  { }"), ("Delete / change / yank", "d c y + motion, dd cc yy"), ("Delete char, join, replace", "x  J  r"), ("Paste", "p  P"), ("Undo / redo", "u  ⌃R"), ("Visual / line", "v  V"), ("Search", "/  n  N"), ("Go to line", ":")]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Color(theme.secondary))
                TextField("Search shortcuts", text: $query).textFieldStyle(.plain)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(theme.text).opacity(0.05)))
            .padding(14)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Self.groups) { g in
                        let items = g.items.filter { query.isEmpty || $0.0.localizedCaseInsensitiveContains(query) || $0.1.localizedCaseInsensitiveContains(query) }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(g.id.uppercased()).font(.system(size: 10.5, weight: .semibold)).kerning(0.6).foregroundStyle(Color(theme.secondary))
                                ForEach(items, id: \.0) { item in
                                    HStack {
                                        Text(item.0).font(.system(size: 12.5)).foregroundStyle(Color(theme.text))
                                        Spacer()
                                        Text(item.1).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Color(theme.text))
                                            .padding(.horizontal, 7).padding(.vertical, 2)
                                            .background(RoundedRectangle(cornerRadius: 5).fill(Color(theme.text).opacity(0.07)))
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 18)
            }
        }
        .frame(width: 520, height: 600)
        .background(Color(theme.surface))
    }
}
