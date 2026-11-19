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
        case "zoomin": (model.pdf as? PDFRepresentable.Coordinator)?.state?.zoom(by: 1)
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
        case "newproject":
            OpenProjectBridge.shared.showWelcome?()
            NotificationCenter.default.post(name: .init("LigatureShowTemplates"), object: nil)
        case "open": model.open(path: arg)
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }
}
