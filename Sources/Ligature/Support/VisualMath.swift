import AppKit
import PDFKit
import CryptoKit

extension Notification.Name {
    /// New equation renders are ready for Visual mode.
    static let visualMathReady = Notification.Name("LigatureVisualMathReady")
}

/// Typesets the equations Visual mode shows, many at a time: every pending formula goes into one document with
/// one tight page each, so a whole paper's maths costs a single compile. Results are kept on disk, so reopening
/// a project shows its equations instantly (and offline).
@MainActor
final class VisualMath {
    static let shared = VisualMath()

    private var pdfs: [String: Data] = [:]
    private var images: [String: NSImage] = [:]
    private var tinted: [String: NSImage] = [:]
    private var failed: Set<String> = []
    private var queue: [(key: String, snippet: String, preamble: String)] = []
    private var queued: Set<String> = []
    private var running = false
    private let dir: URL

    private init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Ligature/VisualMath", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("work", isDirectory: true), withIntermediateDirectories: true)
    }

    static func key(_ snippet: String, preamble: String) -> String {
        SHA256.hash(data: Data((preamble + "\u{1}" + snippet).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    enum State { case ready(NSImage), pending, failed }

    /// The rendered formula at `scale` (points per TeX point), tinted, or whether it's still on its way.
    func image(_ snippet: String, preamble: String, scale: CGFloat, color: NSColor) -> State {
        let k = Self.key(snippet, preamble: preamble)
        if failed.contains(k) { return .failed }
        let ck = "\(k)|\(scale)|\(color.hexString)"
        if let t = tinted[ck] { return .ready(t) }
        let ik = "\(k)|\(scale)"
        var base = images[ik]
        if base == nil, let data = pdfs[k] ?? loadDisk(k) {
            pdfs[k] = data
            base = MathImage.make(from: data, scale: scale, trim: true)
            images[ik] = base
        }
        guard let base else { return .pending }
        let t = Self.tint(base, color)
        tinted[ck] = t
        return .ready(t)
    }

    /// Asks for these formulas to be typeset (those not already done or underway).
    func request(_ snippets: [String], preamble: String, engine: EngineLocator.Found?) {
        guard let engine, engine.engine == .tectonic else { return }
        for s in snippets {
            let k = Self.key(s, preamble: preamble)
            guard pdfs[k] == nil, !failed.contains(k), !queued.contains(k) else { continue }
            if let d = loadDisk(k) { pdfs[k] = d; continue }
            queue.append((k, s, preamble))
            queued.insert(k)
        }
        pump(engine)
    }

    private func pump(_ engine: EngineLocator.Found) {
        guard !running, let first = queue.first else { return }
        // One preamble per batch (they only differ across projects).
        let batch = Array(queue.filter { $0.preamble == first.preamble }.prefix(120))
        let keys = Set(batch.map(\.key))
        queue.removeAll { keys.contains($0.key) }
        running = true
        let dir = dir
        Task {
            let results = await Self.typeset(batch.map { ($0.key, $0.snippet) }, preamble: first.preamble, engine: engine, dir: dir)
            for item in batch {
                queued.remove(item.key)
                if let d = results[item.key] {
                    pdfs[item.key] = d
                    try? d.write(to: dir.appendingPathComponent(item.key + ".pdf"))
                } else {
                    failed.insert(item.key)
                }
            }
            running = false
            NotificationCenter.default.post(name: .visualMathReady, object: nil)
            pump(engine)
        }
    }

    private func loadDisk(_ k: String) -> Data? { try? Data(contentsOf: dir.appendingPathComponent(k + ".pdf")) }

    /// Compiles the batch; when it fails, splits it in half until the formulas that don't compile are isolated.
    nonisolated private static func typeset(_ items: [(String, String)], preamble: String, engine: EngineLocator.Found, dir: URL) async -> [String: Data] {
        guard !items.isEmpty else { return [:] }
        if let pages = await compile(items.map(\.1), preamble: preamble, engine: engine, dir: dir), pages.count == items.count {
            return Dictionary(uniqueKeysWithValues: zip(items.map(\.0), pages))
        }
        guard items.count > 1 else { return [:] }
        let mid = items.count / 2
        let a = await typeset(Array(items[..<mid]), preamble: preamble, engine: engine, dir: dir)
        let b = await typeset(Array(items[mid...]), preamble: preamble, engine: engine, dir: dir)
        return a.merging(b) { x, _ in x }
    }

    /// One compile; returns each page as its own single-page PDF, or nil if TeX reported an error.
    nonisolated private static func compile(_ snippets: [String], preamble: String, engine: EngineLocator.Found, dir: URL) async -> [Data]? {
        let work = dir.appendingPathComponent("work", isDirectory: true)
        let name = "batch-\(UUID().uuidString.prefix(8))"
        let body = snippets.map { "\\begin{preview}\($0)\\end{preview}\n" }.joined()
        let tex = """
        \\documentclass{article}
        \(preamble)
        \\usepackage[active,tightpage]{preview}
        \\setlength\\PreviewBorder{0.5pt}
        \\pagestyle{empty}
        \\begin{document}
        \(body)\\end{document}
        """
        let file = work.appendingPathComponent(name + ".tex")
        guard (try? tex.write(to: file, atomically: true, encoding: .utf8)) != nil else { return nil }
        defer {
            for ext in ["tex", "pdf", "log"] { try? FileManager.default.removeItem(at: work.appendingPathComponent("\(name).\(ext)")) }
        }
        let status = await run(engine.url, ["-X", "compile", file.lastPathComponent, "--outdir", work.path, "--untrusted"], cwd: work)
        guard status == 0, let doc = PDFDocument(url: work.appendingPathComponent(name + ".pdf")) else { return nil }
        var out: [Data] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { return nil }
            let single = PDFDocument()
            single.insert(page, at: 0)
            guard let d = single.dataRepresentation() else { return nil }
            out.append(d)
        }
        return out
    }

    nonisolated static func run(_ exe: URL, _ args: [String], cwd: URL) async -> Int32 {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = exe
                p.arguments = args
                p.currentDirectoryURL = cwd
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { cont.resume(returning: -1); return }
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus)
            }
        }
    }

    /// A copy of a template image (alpha = ink) filled with `color`.
    static func tint(_ image: NSImage, _ color: NSColor) -> NSImage {
        let out = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return out
    }

    // MARK: Turning source into something the batch can typeset

    /// The snippet to typeset for a math match from the source (`$…$`, `\[…\]`, `equation`, `align`, …), and
    /// whether it's display math. Labels and numbering are dropped: Visual mode shows the maths itself.
    static func snippet(for source: String) -> (snippet: String, display: Bool)? {
        var s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        func clean(_ t: String) -> String {
            t.replacingOccurrences(of: #"\\label\{[^}]*\}|\\nonumber|\\notag"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\n\s*\n"#, with: "\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.hasPrefix("$$") && s.hasSuffix("$$") && s.count > 4 {
            return ("$\\displaystyle " + clean(String(s.dropFirst(2).dropLast(2))) + "$", true)
        }
        if s.hasPrefix("$") && s.hasSuffix("$") && s.count > 2 { return ("$" + clean(String(s.dropFirst().dropLast())) + "$", false) }
        if s.hasPrefix("\\(") && s.hasSuffix("\\)") { return ("$" + clean(String(s.dropFirst(2).dropLast(2))) + "$", false) }
        if s.hasPrefix("\\[") && s.hasSuffix("\\]") { return ("$\\displaystyle " + clean(String(s.dropFirst(2).dropLast(2))) + "$", true) }
        guard let m = s.range(of: #"^\\begin\{([a-zA-Z]+)(\*?)\}"#, options: .regularExpression) else { return nil }
        let env = String(s[m]).replacingOccurrences(of: #"^\\begin\{|\*?\}$"#, with: "", options: .regularExpression)
        guard let end = s.range(of: "\\end{", options: .backwards) else { return nil }
        let inner = clean(String(s[m.upperBound..<end.lowerBound]))
        switch env {
        case "equation", "displaymath", "math":
            return env == "math" ? ("$" + inner + "$", false) : ("$\\displaystyle " + inner + "$", true)
        default:
            // Multi-line environments keep their alignment; the starred form drops equation numbers.
            s = "\\begin{\(env)*}\(inner)\\end{\(env)*}"
            return ("\\begin{minipage}{12cm}\(s)\\end{minipage}", true)
        }
    }
}

extension NSColor {
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return description }
        return String(format: "%02x%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255), Int(c.alphaComponent * 255))
    }
}
