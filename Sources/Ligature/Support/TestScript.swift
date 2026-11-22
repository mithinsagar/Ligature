import AppKit
import LigatureCore

/// Drives a project window from the LIGATURE_SCRIPT environment variable, for screenshots and smoke tests.
/// Steps are separated by " ;; ", e.g. `goto:12 ;; type:\fra ;; wait:1 ;; key:return ;; theme:paper`.
/// Each step is logged to stderr with a timestamp so an outside capture can be lined up with it.
@MainActor
enum TestScript {
    private static var started = false

    static func runIfRequested(model: ProjectModel) {
        guard !started, let script = ProcessInfo.processInfo.environment["LIGATURE_SCRIPT"] else { return }
        started = true
        let steps = script.components(separatedBy: " ;; ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            for step in steps {
                FileHandle.standardError.write("[script \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime))] \(step)\n".data(using: .utf8)!)
                await run(step, model: model)
            }
            FileHandle.standardError.write("[script] done\n".data(using: .utf8)!)
        }
    }

    private static func run(_ step: String, model: ProjectModel) async {
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let cmd = parts[0], arg = parts.count > 1 ? parts[1] : ""
        let editor = model.editor as? EditorController
        let tv = editor?.textView
        switch cmd {
        case "wait":
            try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
        case "type":
            for ch in arg.replacingOccurrences(of: "\\n", with: "\n") {
                if ch == "\n" { tv?.insertNewline(nil) } else { tv?.insertText(String(ch), replacementRange: tv?.selectedRange() ?? NSRange()) }
                try? await Task.sleep(for: .milliseconds(45))
            }
        case "key":
            switch arg {
            case "return": tv?.insertNewline(nil)
            case "tab": tv?.insertTab(nil)
            case "down": tv?.moveDown(nil)
            case "up": tv?.moveUp(nil)
            case "esc": tv?.cancelOperation(nil)
            case "end": tv?.moveToEndOfLine(nil)
            default: break
            }
        case "goto":
            let nums = arg.split(separator: ":").compactMap { Int($0) }
            if let l = nums.first { editor?.reveal(line: l, column: nums.count > 1 ? nums[1] : nil, flash: false) }
        case "select":
            // select:LINE: whole line
            if let l = Int(arg), let tv, let r = LaTeXText.range(ofLine: l, in: tv.string as NSString) { tv.setSelectedRange(r) }
        case "hover":
            // hover:LINE:COL: show the peek for that position as a force click would
            let nums = arg.split(separator: ":").compactMap { Int($0) }
            if nums.count == 2, let tv, let r = LaTeXText.range(ofLine: nums[0], in: tv.string as NSString) {
                editor?.textViewHover(tv, at: r.location + nums[1] - 1, pointInView: .zero, force: true)
            }
        case "theme": Preferences.shared.themeID = arg
        case "accent": Preferences.shared.accentID = arg
        case "tab": if let t = SidebarTab(rawValue: arg) { model.sidebarTab = t }
        case "layout": if let l = Preferences.Layout(rawValue: arg) { model.layout = l }
        case "palette":
            PaletteSeed.shared.text = arg
            model.showPalette = true
        case "closepalette": model.showPalette = false
        case "compile": model.compile(manual: true)
        case "sync": model.syncToPDF()
        case "table": model.tableDraft = TableModel.parse(delimited: "Method\tAccuracy\tTime (s)\nBaseline\t81.2\t12.4\nOurs\t87.9\t9.1")
        case "citation": model.showCitationSheet = true
        case "figure": model.showFigureSheet = true
        case "pinch":
            // Simulates a trackpad pinch that magnifies PDFKit's scroll view, then reads the zoom back.
            if let c = model.pdf as? PDFRepresentable.Coordinator, let st = c.state, let sv = st.scrollView {
                sv.magnification = CGFloat(Double(arg) ?? 1.5)
                st.fitMode = false
                st.syncScale()
            }
        case "dump":
            if let e = editor {
                let sv = e.scrollView
                FileHandle.standardError.write("[dump] scroll=\(sv.frame) clip=\(sv.contentView.frame) clipBounds=\(sv.contentView.bounds) text=\(e.textView.frame) ruler=\(sv.verticalRulerView?.frame ?? .zero) thickness=\(sv.verticalRulerView?.ruleThickness ?? 0) inset=\(e.textView.textContainerInset) origin=\(e.textView.textContainerOrigin) container=\(e.textView.textContainer?.size ?? .zero) textInWin=\(e.textView.convert(e.textView.bounds, to: nil)) rulerInWin=\(sv.verticalRulerView.map { $0.convert($0.bounds, to: nil) } ?? .zero) clipInWin=\(sv.contentView.convert(sv.contentView.bounds, to: nil)) insets=\(sv.contentInsets.left) auto=\(sv.automaticallyAdjustsContentInsets)\n".data(using: .utf8)!)
            }
        case "scan":
            // scan:SLOWDOWN: compile manually with the reveal stretched for capture.
            PDFRepresentable.Coordinator.slowdown = Double(arg) ?? 1
            model.compile(manual: true)
        case "clickword":
            // clickword:WORD: finds WORD in the PDF and clicks it as a single click would.
            if let c = model.pdf as? PDFRepresentable.Coordinator, let v = c.view, let doc = v.document,
               let sel = doc.findString(arg, withOptions: []).first, let page = sel.pages.first {
                let b = sel.bounds(for: page)
                v.onSyncClick?(page, CGPoint(x: b.midX, y: b.midY))
            }
        case "quickdl": model.quickDownload()
        case "visual": Preferences.shared.visualMode = arg != "off"
        case "undo": model.activeDoc?.undoManager.undo()
        case "history": (model.editor as? EditorController).map { _ in () }
        case "closewindow": NSApp.windows.first { $0.title == model.name }?.performClose(nil)
        case "widget":
            // widget:KIND activates the first widget of that kind (table, preamble, fold), as a click would.
            if let tv, let ts = tv.textStorage, let editor {
                var found: (WidgetRef, NSRange)?
                ts.enumerateAttribute(Highlighter.widgetKey, in: NSRange(location: 0, length: ts.length)) { v, r, stop in
                    if let w = v as? WidgetRef, "\(w.kind)".lowercased().hasPrefix(arg) { found = (w, r); stop.pointee = true }
                }
                if let (w, r) = found { editor.textViewActivateWidget(tv, w, range: r) }
            }
        case "pastehtml":
            // pastehtml:<html> pastes HTML through a private pasteboard (never the user's clipboard).
            if let tv {
                let pb = NSPasteboard(name: NSPasteboard.Name("ligature-test"))
                pb.clearContents()
                pb.setData(arg.data(using: .utf8), forType: .html)
                let plain = (try? NSAttributedString(data: arg.data(using: .utf8)!, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil))?.string ?? ""
                pb.setString(plain, forType: .string)
                tv.paste(from: pb)
            }
        case "sel":
            if let tv { FileHandle.standardError.write("[sel] \(tv.selectedRange()) len=\((tv.string as NSString).length)\n".data(using: .utf8)!) }
        case "dumptext":
            if let tv { FileHandle.standardError.write("[text]\n\(tv.string)\n[/text]\n".data(using: .utf8)!) }
        case "insert":
            // insert:TEXT inserts as one paste-like edit (no auto-pairing).
            tv?.insertText(arg.replacingOccurrences(of: "\\n", with: "\n"), replacementRange: tv?.selectedRange() ?? NSRange())
        case "logs": model.showLogs = arg != "off"
        case "opt":
            // opt:draft|stop|normal
            Preferences.shared.draftMode = arg == "draft"
            Preferences.shared.stopOnFirstError = arg == "stop"
        case "search":
            // search:QUERY opens project search with that query
            model.searchQuery = arg; model.sidebarTab = .search; model.showSidebar = true
        case "replaceall":
            // replaceall:FIND=>WITH across the project (as the panel's All button does)
            let parts = arg.components(separatedBy: "=>")
            if parts.count == 2 {
                for file in model.searchableFiles {
                    guard let doc = model.ensureOpen(path: file) else { continue }
                    let r = ProjectSearch.replace(parts[0], with: parts[1], in: doc.text, options: model.searchOptions)
                    if r.count > 0 { doc.replaceAll(with: r.text, actionName: "Replace All") }
                }
            }
        case "assist":
            // assist: opens Suggest Fix for the first compile error
            model.errorAssistIssue = model.issues.first { $0.severity == .error && $0.line != nil }
        case "comment":
            // comment:LINE:TEXT comments on the whole of LINE
            let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let l = Int(parts[0]), let tv, let r = LaTeXText.range(ofLine: l, in: tv.string as NSString) {
                tv.setSelectedRange(r)
                model.beginComment()
                model.addComment(parts[1])
            }
        case "label": model.labelCurrentVersion(arg)
        case "exportdoc":
            // exportdoc:FORMAT:PATH writes Word/Markdown/HTML (no dialog)
            let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let f = WordExporter.Format(rawValue: parts[0]) {
                model.saveAll()
                do {
                    try WordExporter.export(root: model.root, main: model.mainFile, bibFiles: [], to: URL(fileURLWithPath: parts[1]), format: f)
                    FileHandle.standardError.write("[export] ok \(parts[1])\n".data(using: .utf8)!)
                } catch { FileHandle.standardError.write("[export] failed \(error.localizedDescription)\n".data(using: .utf8)!) }
            }
        case "importfile":
            // importfile:SRC=>PARENT imports into PARENT (not ~/Documents) and logs the new folder
            let parts = arg.components(separatedBy: "=>")
            if parts.count == 2 {
                do {
                    let u = try ProjectImporter.importFile(URL(fileURLWithPath: parts[0]), into: URL(fileURLWithPath: parts[1]))
                    FileHandle.standardError.write("[import] ok \(u.path)\n".data(using: .utf8)!)
                } catch { FileHandle.standardError.write("[import] failed \(error.localizedDescription)\n".data(using: .utf8)!) }
            }
        case "gitinit": await model.git.initialize()
        case "gitcommit": await model.git.commitAll(arg)
        case "vim": Preferences.shared.keybindings = arg == "off" ? "standard" : "vim"
        case "vimkeys":
            // vimkeys:KEYS sends key presses to the editor; "<esc>" is Escape
            guard let tv else { break }
            var keys = arg
            while !keys.isEmpty {
                let esc = keys.hasPrefix("<esc>")
                let ch = esc ? "\u{1b}" : String(keys.removeFirst())
                if esc { keys.removeFirst(5) }
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: tv.window?.windowNumber ?? 0,
                                            context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: esc ? 53 : 0) {
                    tv.keyDown(with: e)
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        case "focus": model.focusMode = arg != "off"
        case "fitheight": (model.pdf as? PDFRepresentable.Coordinator)?.state?.fitHeight(animated: false)
        case "present":
            if let d = model.pdfData { PresentationController.start(data: d, page: Int(arg) ?? 1, screen: nil) }
        case "detach": NotificationCenter.default.post(name: .init("LigatureTestDetach"), object: model.root)
        case "reply":
            if let c = model.comments.last { model.reply(to: c.id, arg) }
        case "fold":
            // fold:here|unfold|all|none
            let map: [String: EditorController.FoldAction] = ["here": .foldHere, "unfold": .unfoldHere, "all": .foldAll, "none": .unfoldAll]
            if let a = map[arg] { editor?.fold(a) }
        case "frags":
            // Logs the first N line fragments (y, height, characters) of the editor.
            if let tv, let lm = tv.layoutManager {
                var g = 0, n = 0
                let ns = tv.string as NSString
                while g < lm.numberOfGlyphs && n < (Int(arg) ?? 20) {
                    var eff = NSRange()
                    let r = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: &eff)
                    let cr = lm.characterRange(forGlyphRange: eff, actualGlyphRange: nil)
                    FileHandle.standardError.write("[frag] y=\(Int(r.minY)) h=\(Int(r.height)) chars=\(cr.location)+\(cr.length) \(ns.substring(with: NSRange(location: cr.location, length: min(cr.length, 40))).debugDescription)\n".data(using: .utf8)!)
                    g = NSMaxRange(eff); n += 1
                }
            }
        case "zoomin": (model.pdf as? PDFRepresentable.Coordinator)?.state?.zoom(by: 1)
        case "zoomout": (model.pdf as? PDFRepresentable.Coordinator)?.state?.zoom(by: -1)
        case "refit": (model.pdf as? PDFRepresentable.Coordinator)?.state?.fitWidth(animated: true)
        case "resize":
            // resize:WxH resizes the project window (or "max" zooms it), as maximising would.
            if let c = model.pdf as? PDFRepresentable.Coordinator, let w = c.view?.window {
                if arg == "max" { w.zoom(nil) } else if arg == "full" { w.toggleFullScreen(nil) } else {
                    let p = arg.split(separator: "x").compactMap { Double($0) }
                    if p.count == 2 { w.setFrame(NSRect(x: w.frame.minX, y: w.frame.minY, width: p[0], height: p[1]), display: true) }
                }
            }
        case "zoomlog":
            if let st = (model.pdf as? PDFRepresentable.Coordinator)?.state {
                FileHandle.standardError.write("[zoom] percent=\(st.displayPercent) scale=\(st.scale) real=\(st.effectiveScale) doc=\(st.view?.documentView?.frame ?? .zero) clipB=\(st.scrollView?.contentView.bounds ?? .zero) mag=\(st.scrollView?.magnification ?? 0) fitBase=\(st.fitBase) fitMode=\(st.fitMode) clip=\(st.scrollView?.contentView.frame.width ?? 0)\n".data(using: .utf8)!)
            }
        case "rename": model.showRename = true
        case "downloads": model.showDownloads = true
        case "fakedownload":
            // Writes the current PDF to the scratch path given and records it, as Download PDF would.
            if let data = model.pdfData { let u = URL(fileURLWithPath: arg); try? data.write(to: u); model.recordDownload(.pdf, to: u) }
        case "renameto":
            _ = model.renameProject(to: arg)
        case "live": model.setLiveCompile(arg == "on")
        case "dismiss":
            model.tableDraft = nil; model.showCitationSheet = false; model.showFigureSheet = false; model.showNewFile = false
        case "settings": OpenProjectBridge.shared.showSettings?()
        case "welcome": OpenProjectBridge.shared.showWelcome?()
        case "peek": NotificationCenter.default.post(name: .init("LigaturePeekRecent"), object: Int(arg) ?? 0)
        case "newproject":
            OpenProjectBridge.shared.showWelcome?()
            NotificationCenter.default.post(name: .init("LigatureShowTemplates"), object: nil)
        case "open": model.open(path: arg)
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }
}
