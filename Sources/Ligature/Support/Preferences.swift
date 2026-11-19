import SwiftUI

/// Every user setting, persisted in UserDefaults. One shared instance, observed by views and AppKit code alike.
@Observable @MainActor
final class Preferences {
    static let shared = Preferences()

    enum Layout: String, CaseIterable, Identifiable {
        case editor, split, preview
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .editor: "doc.plaintext"
            case .split: "rectangle.split.2x1"
            case .preview: "doc.richtext"
            }
        }
        var title: String {
            switch self {
            case .editor: "Editor"
            case .split: "Split"
            case .preview: "PDF"
            }
        }
    }

    enum Engine: String, CaseIterable, Identifiable {
        case tectonic, latexmk
        var id: String { rawValue }
        var title: String { self == .tectonic ? "Tectonic (XeTeX)" : "latexmk (TeX Live)" }
    }

    private let d = UserDefaults.standard

    var themeID: String { didSet { d.set(themeID, forKey: "themeID") } }
    var accentID: String { didSet { d.set(accentID, forKey: "accentID") } }
    var editorFontSize: Double { didSet { d.set(editorFontSize, forKey: "editorFontSize") } }
    var lineSpacing: Double { didSet { d.set(lineSpacing, forKey: "lineSpacing") } }
    var liveCompile: Bool { didSet { d.set(liveCompile, forKey: "liveCompile") } }
    var compileDelay: Double { didSet { d.set(compileDelay, forKey: "compileDelay") } }
    var haptics: Bool { didSet { d.set(haptics, forKey: "hapticsEnabled") } }
    var spellCheck: Bool { didSet { d.set(spellCheck, forKey: "spellCheck") } }
    var autoPair: Bool { didSet { d.set(autoPair, forKey: "autoPair") } }
    var wrapLines: Bool { didSet { d.set(wrapLines, forKey: "wrapLines") } }
    var inlineIssues: Bool { didSet { d.set(inlineIssues, forKey: "inlineIssues") } }
    var lineNumbers: Bool { didSet { d.set(lineNumbers, forKey: "lineNumbers") } }
    var mathPreview: Bool { didSet { d.set(mathPreview, forKey: "mathPreview") } }
    var hoverPeeks: Bool { didSet { d.set(hoverPeeks, forKey: "hoverPeeks") } }
    var pdfDarkPaper: Bool { didSet { d.set(pdfDarkPaper, forKey: "pdfDarkPaper") } }
    var followCaret: Bool { didSet { d.set(followCaret, forKey: "followCaret") } }
    var engine: Engine { didSet { d.set(engine.rawValue, forKey: "engine") } }
    var enginePath: String { didSet { d.set(enginePath, forKey: "enginePath") } }
    var reduceMotion: Bool { didSet { d.set(reduceMotion, forKey: "reduceMotion") } }
    /// Visual editing: the source shown as formatted prose with LaTeX markup hidden (like Overleaf's Visual mode).
    var visualMode: Bool { didSet { d.set(visualMode, forKey: "visualMode") } }

    private init() {
        d.register(defaults: [
            "themeID": "auto", "accentID": "ink", "editorFontSize": 13.5, "lineSpacing": 1.45, "liveCompile": false,
            "compileDelay": 0.12, "hapticsEnabled": true, "spellCheck": true, "autoPair": true,
            "wrapLines": true, "inlineIssues": true, "lineNumbers": true, "mathPreview": true, "hoverPeeks": true,
            "pdfDarkPaper": false, "followCaret": false, "engine": Engine.tectonic.rawValue, "enginePath": "", "reduceMotion": false, "visualMode": false,
        ])
        themeID = d.string(forKey: "themeID")!
        accentID = d.string(forKey: "accentID")!
        editorFontSize = d.double(forKey: "editorFontSize")
        lineSpacing = d.double(forKey: "lineSpacing")
        liveCompile = d.bool(forKey: "liveCompile")
        compileDelay = d.double(forKey: "compileDelay")
        haptics = d.bool(forKey: "hapticsEnabled")
        spellCheck = d.bool(forKey: "spellCheck")
        autoPair = d.bool(forKey: "autoPair")
        wrapLines = d.bool(forKey: "wrapLines")
        inlineIssues = d.bool(forKey: "inlineIssues")
        lineNumbers = d.bool(forKey: "lineNumbers")
        mathPreview = d.bool(forKey: "mathPreview")
        hoverPeeks = d.bool(forKey: "hoverPeeks")
        pdfDarkPaper = d.bool(forKey: "pdfDarkPaper")
        followCaret = d.bool(forKey: "followCaret")
        engine = Engine(rawValue: d.string(forKey: "engine")!) ?? .tectonic
        enginePath = d.string(forKey: "enginePath")!
        reduceMotion = d.bool(forKey: "reduceMotion")
        visualMode = d.bool(forKey: "visualMode")
    }
}
