import SwiftUI
import UniformTypeIdentifiers
import PDFKit

struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var mode: Mode = .home
    @State private var engine: EngineLocator.Found?
    @State private var checkedEngine = false
    /// The recent project being peeked at, and where its row sits in the window.
    @State private var peek: RecentPeekTarget?
    private var recents: Recents { Recents.shared }

    enum Mode { case home, templates }

    var body: some View {
        HStack(spacing: 0) {
            leftColumn
                .frame(width: 300)
                .background(Color(theme.canvas).opacity(theme.isDark ? 0.6 : 0.7))
            Rectangle().fill(Color(theme.hairline)).frame(width: 0.5)
            ZStack {
                if mode == .home {
                    RecentList(open: open, peek: $peek)
                        .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                } else {
                    TemplateGallery(back: { withAnimation(.panel) { mode = .home } }, created: { url in open(url) })
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .trailing).combined(with: .opacity)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(theme.surface))
            .clipped()
        }
        .frame(width: 940, height: 600)
        .coordinateSpace(name: RecentPeekTarget.space)
        .overlay(alignment: .topLeading) { peekCard }
        .onChange(of: mode) { _, _ in peek = nil }
        .preferredColorScheme(Preferences.shared.themeID == "auto" ? nil : (theme.isDark ? .dark : .light))
        .tint(accent)
        .onAppear {
            OpenProjectBridge.shared.open = { open($0) }
            OpenProjectBridge.shared.showWelcome = { openWindow(id: "welcome") }
            engine = EngineLocator.locate()
            checkedEngine = true
        }
        .background(WindowConfigurator())
        .onReceive(NotificationCenter.default.publisher(for: .init("LigatureShowTemplates"))) { _ in withAnimation(.panel) { mode = .templates } }
    }

    var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppMark(size: 64)
                .padding(.top, 54)
            Text("Ligature")
                .font(.system(size: 34, weight: .semibold, design: .serif))
                .foregroundStyle(Color(theme.text))
                .padding(.top, 18)
            Text("LaTeX, beautifully typeset as you write.")
                .font(.system(size: 13))
                .foregroundStyle(Color(theme.secondary))
                .padding(.top, 4)

            VStack(spacing: 6) {
                WelcomeAction(symbol: "plus", title: "New Project", detail: "Start from a template", shortcut: "⌘N", primary: true) {
                    withAnimation(.panel) { mode = .templates }
                }
                WelcomeAction(symbol: "folder", title: "Open…", detail: "A project folder or .tex file", shortcut: "⌘O") { openPanel() }
                WelcomeAction(symbol: "square.and.arrow.down.on.square", title: "Import…", detail: "A .zip, Word or Markdown file", shortcut: "⇧⌘I") { importPanel() }
            }
            .padding(.top, 34)

            Spacer()

            HStack(spacing: 7) {
                Circle().fill(engine != nil ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(engine.map { $0.version.isEmpty ? $0.engine.title : $0.version } ?? (checkedEngine ? "No TeX engine found" : "Checking engine…"))
                    .font(.system(size: 11)).foregroundStyle(Color(theme.secondary)).lineLimit(1)
                Spacer()
                if engine == nil && checkedEngine {
                    Button("How to install") { NSWorkspace.shared.open(URL(string: "https://tectonic-typesetting.github.io/en-US/install.html")!) }
                        .buttonStyle(.ligChip())
                }
            }
            .padding(.bottom, 22)
        }
        .padding(.horizontal, 30)
    }

    /// The peek floats over the left column, level with the hovered row, inside this window (a popover is a
    /// separate window and could take the hover away from the row). It never takes clicks or hover itself.
    @ViewBuilder var peekCard: some View {
        if let peek {
            let size = CGSize(width: 248, height: 372)
            let y = min(max(peek.rowFrame.midY - size.height / 2, 14), 600 - size.height - 14)
            RecentPeek(item: peek.item)
                .id(peek.item.id)
                .frame(width: size.width, height: size.height, alignment: .top)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.16), radius: 24, y: 10)
                .offset(x: 300 - size.width - 18, y: y)
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
        }
    }

    func open(_ url: URL) {
        peek = nil
        openWindow(id: "project", value: url)
        dismissWindow(id: "welcome")
    }

    func importPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["zip", "docx", "md", "markdown", "odt", "rtf", "html"].compactMap { UTType(filenameExtension: $0) }
        p.prompt = "Import"
        p.message = "Choose a .zip project (e.g. from Overleaf), a Word document or a Markdown file"
        guard p.runModal() == .OK, let u = p.url else { return }
        do { open(try ProjectImporter.importFile(u)) } catch {
            let a = NSAlert(); a.messageText = "Couldn't import \(u.lastPathComponent)"; a.informativeText = error.localizedDescription; a.runModal()
        }
    }

    func openPanel() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowedContentTypes = [UTType(filenameExtension: "tex") ?? .plainText, .folder]
        p.prompt = "Open"
        p.message = "Choose a project folder or a .tex file"
        if p.runModal() == .OK, let u = p.url { open(u) }
    }
}

/// The app mark: a ligature "fi" set in the serif face on an ink tile.
struct AppMark: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [Color(Theme.hex(0x22252B)), Color(Theme.hex(0x111215))], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            Text("fi")
                .font(.system(size: size * 0.52, weight: .regular, design: .serif))
                .italic()
                .foregroundStyle(.white)
                .offset(y: -size * 0.02)
            Circle().fill(accent).frame(width: size * 0.12, height: size * 0.12)
                .offset(x: size * 0.25, y: size * 0.24)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
    }
}

private struct WelcomeAction: View {
    let symbol: String
    let title: String
    let detail: String
    let shortcut: String
    var primary = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primary ? .white : accent)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(primary ? accent : accent.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(theme.text))
                    Text(detail).font(.system(size: 11)).foregroundStyle(Color(theme.secondary))
                }
                Spacer()
                KeyCap(text: shortcut).opacity(hovering ? 1 : 0.6)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(theme.text).opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
            .scaleEffect(hovering ? 1.01 : 1)
        }
        .buttonStyle(PressableStyle())
        .keyboardShortcut(shortcut == "⌘N" ? "n" : (shortcut == "⌘O" ? "o" : "i"), modifiers: shortcut == "⇧⌘I" ? [.command, .shift] : .command)
        .onHover { h in withAnimation(.hover) { hovering = h } }
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.press, value: configuration.isPressed)
    }
}

struct RecentPeekTarget: Equatable {
    static let space = "welcome"
    var item: RecentProject
    var rowFrame: CGRect
}

private struct RecentList: View {
    let open: (URL) -> Void
    @Binding var peek: RecentPeekTarget?
    private var recents: Recents { Recents.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(theme.text))
                .padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 10)
            if recents.items.isEmpty {
                EmptyState(symbol: "clock", title: "Nothing here yet", message: "Projects you open appear here. Start with a template on the left.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(recents.items.enumerated()), id: \.element.id) { index, item in
                            RecentRow(item: item, index: index, peek: $peek, open: { open(item.url) }, remove: { withAnimation(.panel) { peek = nil; recents.remove(item) } })
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 16)
                }
            }
        }
    }
}

private struct RecentRow: View {
    let item: RecentProject
    let index: Int
    @Binding var peek: RecentPeekTarget?
    let open: () -> Void
    let remove: () -> Void
    @State private var hovering = false
    @State private var peekTask: Task<Void, Never>?
    @State private var frame: CGRect = .zero

    func showPeek() {
        withAnimation(.spring(duration: 0.28, bounce: 0.12)) { peek = RecentPeekTarget(item: item, rowFrame: frame) }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 15))
                .foregroundStyle(accent)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent.opacity(0.1)))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(theme.text)).lineLimit(1)
                Text((item.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11)).foregroundStyle(Color(theme.secondary)).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if hovering {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.ligIcon(size: 22))
                    .help("Remove from list")
                    .transition(.opacity)
            } else {
                Text(item.opened, format: .relative(presentation: .named)).font(.system(size: 11)).foregroundStyle(Color(theme.secondary))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .hoverRow(cornerRadius: 10)
        .onHover { h in
            withAnimation(.hover) { hovering = h }
            // Resting on a row for a moment peeks at its last compiled page; leaving it hides the peek at once.
            peekTask?.cancel()
            if h {
                peekTask = Task {
                    try? await Task.sleep(for: .milliseconds(650))
                    if !Task.isCancelled { showPeek() }
                }
            } else if peek?.item == item {
                withAnimation(.easeOut(duration: 0.12)) { peek = nil }
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(RecentPeekTarget.space)) } action: { f in
            frame = f
            if peek?.item == item { peek?.rowFrame = f }  // follow scrolling
        }
        .onTapGesture { peekTask?.cancel(); peek = nil; open() }
        .onReceive(NotificationCenter.default.publisher(for: .init("LigaturePeekRecent"))) { n in
            if n.object as? Int == index { showPeek() }  // test hook
        }
        .contextMenu {
            Button("Open") { open() }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Remove from List", action: remove)
        }
    }
}

/// The hover peek for a recent project: the first page of its last compiled PDF, with when it was built.
private struct RecentPeek: View {
    let item: RecentProject
    @State private var info: RecentPreview.Info?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                if let info {
                    Image(nsImage: info.image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .shadow(color: .black.opacity(theme.isDark ? 0.5 : 0.18), radius: 8, y: 3)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else if loaded {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 26, weight: .light))
                        Text("Not compiled yet").font(.system(size: 12, weight: .medium))
                        Text("Open it and press Compile to see a preview here.").font(.system(size: 11)).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(Color(theme.secondary))
                    .padding(.horizontal, 18)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 220, height: 285)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(theme.text)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.mainFile ?? "main.tex").lineLimit(1).truncationMode(.middle)
                    if let info {
                        Text("·")
                        Text(info.pages == 1 ? "1 page" : "\(info.pages) pages")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(Color(theme.secondary))
                if let info {
                    Text("Compiled \(info.compiled, format: .relative(presentation: .named))")
                        .font(.system(size: 11)).foregroundStyle(Color(theme.secondary))
                }
            }
            .frame(width: 220, alignment: .leading)
        }
        .padding(14)
        .task {
            let found = await RecentPreview.load(item)
            withAnimation(.easeOut(duration: 0.18)) { info = found; loaded = true }
        }
    }
}

/// Finds and renders the last PDF a recent project compiled to, cached by file date so repeat peeks are instant.
@MainActor
enum RecentPreview {
    struct Info { let image: NSImage; let pages: Int; let compiled: Date }
    private static var cache: [String: (date: Date, info: Info)] = [:]

    static func pdfURL(for item: RecentProject) -> URL? {
        let dir = BuildPaths.location(for: item.url)
        let job = ((item.mainFile ?? "main.tex") as NSString).lastPathComponent
        let named = dir.appendingPathComponent((job as NSString).deletingPathExtension + ".pdf")
        if FileManager.default.fileExists(atPath: named.path) { return named }
        // The main file may have been renamed since; fall back to the newest PDF in the build folder.
        let pdfs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "pdf" } ?? []
        return pdfs.max { modified($0) < modified($1) }
    }

    static func load(_ item: RecentProject) async -> Info? {
        guard let url = pdfURL(for: item) else { return nil }
        let date = modified(url)
        if let hit = cache[url.path], hit.date == date { return hit.info }
        let rendered: (Data, Int)? = await Task.detached(priority: .userInitiated) {
            guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
            let thumb = page.thumbnail(of: NSSize(width: 440, height: 570), for: .cropBox)
            guard let tiff = thumb.tiffRepresentation else { return nil }
            return (tiff, doc.pageCount)
        }.value
        guard let (tiff, pages) = rendered, let image = NSImage(data: tiff) else { return nil }
        let info = Info(image: image, pages: pages, compiled: date)
        cache[url.path] = (date, info)
        return info
    }

    private nonisolated static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

// MARK: Template gallery

private struct TemplateGallery: View {
    let back: () -> Void
    let created: (URL) -> Void
    @State private var templates = ProjectTemplate.all()
    @State private var selected: ProjectTemplate?
    @State private var name = ""
    @State private var location = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Ligature", isDirectory: true)
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                IconButton(symbol: "chevron.left", help: "Back", size: 26, action: back)
                Text("Choose a template").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(theme.text))
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 6)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 210), spacing: 16)], spacing: 18) {
                    ForEach(templates) { t in
                        TemplateCard(template: t, selected: selected == t)
                            .onTapGesture {
                                withAnimation(.panel) { selected = t }
                                if name.isEmpty || templates.contains(where: { $0.name == name }) { name = t.name }
                            }
                            .onTapGesture(count: 2) { selected = t; create() }
                    }
                }
                .padding(18)
            }
            if selected != nil {
                Rectangle().fill(Color(theme.hairline)).frame(height: 0.5)
                HStack(spacing: 10) {
                    TextField("Project name", text: $name).textFieldStyle(.roundedBorder).frame(width: 200)
                    Button {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                        p.directoryURL = location
                        if p.runModal() == .OK, let u = p.url { location = u }
                    } label: {
                        Label((location.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.ligSecondary)
                    .frame(maxWidth: 260)
                    if let error { Text(error).font(.system(size: 11)).foregroundStyle(Color(theme.error)).lineLimit(1) }
                    Spacer()
                    Button("Create") { create() }.buttonStyle(.ligPrimary).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    func create() {
        guard let t = selected else { return }
        do {
            let url = try t.instantiate(named: name.trimmingCharacters(in: .whitespaces).isEmpty ? t.name : name.trimmingCharacters(in: .whitespaces), in: location)
            created(url)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct TemplateCard: View {
    let template: ProjectTemplate
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Rectangle()
                .fill(Color.white)
                .frame(height: 200)
                .overlay(alignment: .top) {
                    if let img = template.preview {
                        if img.size.width > img.size.height {
                            // Slides: show the whole landscape page centred on a soft backdrop.
                            ZStack {
                                Color(white: 0.93)
                                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                                    .padding(12)
                            }
                        } else {
                            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                        }
                    }
                }
                .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(selected ? accent : Color(theme.hairline), lineWidth: selected ? 2.5 : 0.75))
            .shadow(color: .black.opacity(hovering ? 0.2 : 0.07), radius: hovering ? 16 : 5, y: hovering ? 9 : 2)
            .scaleEffect(hovering ? 1.03 : 1)
            HStack(spacing: 6) {
                Image(systemName: template.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(selected ? accent : Color(theme.secondary))
                Text(template.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(theme.text))
            }
            Text(template.subtitle).font(.system(size: 11)).foregroundStyle(Color(theme.secondary)).lineLimit(2).frame(height: 28, alignment: .top)
        }
        .contentShape(Rectangle())
        .animation(.press, value: hovering)
        .animation(.panel, value: selected)
        .onHover { h in hovering = h }
    }
}

/// Makes the welcome window's title bar transparent and the background draggable.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
