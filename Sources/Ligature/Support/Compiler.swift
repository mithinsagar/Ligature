import Foundation
import CryptoKit
import LigatureCore

/// Finds a TeX engine on this Mac.
enum EngineLocator {
    struct Found: Equatable {
        var engine: Preferences.Engine
        var url: URL
        var version: String
    }

    static func tectonicCandidates() -> [String] {
        var c: [String] = []
        if let helper = Bundle.main.url(forAuxiliaryExecutable: "tectonic") { c.append(helper.path) }
        c += ["/opt/homebrew/bin/tectonic", "/usr/local/bin/tectonic", NSHomeDirectory() + "/.cargo/bin/tectonic", "/opt/local/bin/tectonic"]
        return c
    }

    static func latexmkCandidates() -> [String] { ["/Library/TeX/texbin/latexmk", "/opt/homebrew/bin/latexmk", "/usr/local/bin/latexmk"] }

    @MainActor static func locate() -> Found? {
        let prefs = Preferences.shared
        let fm = FileManager.default
        if !prefs.enginePath.isEmpty, fm.isExecutableFile(atPath: prefs.enginePath) {
            let isLatexmk = prefs.enginePath.hasSuffix("latexmk")
            return Found(engine: isLatexmk ? .latexmk : .tectonic, url: URL(fileURLWithPath: prefs.enginePath), version: version(prefs.enginePath))
        }
        let order: [Preferences.Engine] = prefs.engine == .tectonic ? [.tectonic, .latexmk] : [.latexmk, .tectonic]
        for e in order {
            let list = e == .tectonic ? tectonicCandidates() : latexmkCandidates()
            if let p = list.first(where: { fm.isExecutableFile(atPath: $0) }) {
                return Found(engine: e, url: URL(fileURLWithPath: p), version: version(p))
            }
        }
        return nil
    }

    static func version(_ path: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}

/// Where a project's build products live: ~/Library/Caches/Ligature/Builds/<hash>/ (never inside the project).
enum BuildPaths {
    static func directory(for root: URL) -> URL {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ligature/Builds/\(root.lastPathComponent)-\(digest)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

struct CompileResult {
    var pdf: Data?
    var synctex: SyncTeX?
    var issues: [CompileIssue]
    var duration: TimeInterval
    var exitCode: Int32
    var cancelled: Bool
    var log: String
    var stderr: String
}

/// Runs one compile at a time. Starting a new compile terminates the one in flight, so typing never queues up
/// stale builds.
@MainActor
final class CompileService {
    private var process: Process?
    private var generation = 0

    func cancel() {
        generation += 1
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    func compile(engine: EngineLocator.Found, main: URL, root: URL) async -> CompileResult {
        cancel()
        generation += 1
        let myGeneration = generation
        let outDir = BuildPaths.directory(for: root)
        let p = Process()
        p.executableURL = engine.url
        p.currentDirectoryURL = main.deletingLastPathComponent()
        let jobName = main.deletingPathExtension().lastPathComponent
        switch engine.engine {
        case .tectonic:
            p.arguments = ["-X", "compile", main.lastPathComponent, "--synctex", "--keep-logs", "--keep-intermediates",
                           "--outdir", outDir.path, "-Z", "continue-on-errors", "--untrusted"]
        case .latexmk:
            p.arguments = ["-pdf", "-synctex=1", "-interaction=nonstopmode", "-file-line-error", "-halt-on-error-", "-outdir=\(outDir.path)", main.lastPathComponent]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/Library/TeX/texbin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            p.environment = env
        }
        let errPipe = Pipe(), outPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = outPipe
        process = p
        let start = Date()

        let (status, stderrText): (Int32, String) = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try p.run() } catch {
                    cont.resume(returning: (-1, "error: could not start the engine: \(error.localizedDescription)"))
                    return
                }
                // Drain both pipes so a chatty engine can't block on a full pipe buffer.
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                var text = String(data: errData, encoding: .utf8) ?? ""
                if engine.engine == .latexmk { text += "\n" + (String(data: outData, encoding: .utf8) ?? "") }
                cont.resume(returning: (p.terminationStatus, text))
            }
        }
        let duration = Date().timeIntervalSince(start)
        if myGeneration != generation || p.terminationReason == .uncaughtSignal {
            return CompileResult(pdf: nil, synctex: nil, issues: [], duration: duration, exitCode: status, cancelled: true, log: "", stderr: stderrText)
        }
        process = nil

        let pdfURL = outDir.appendingPathComponent("\(jobName).pdf")
        let logURL = outDir.appendingPathComponent("\(jobName).log")
        let pdf = try? Data(contentsOf: pdfURL)
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? (try? String(contentsOf: logURL, encoding: .isoLatin1)) ?? ""
        let synctex = await Task.detached { SyncTeX.load(url: outDir.appendingPathComponent("\(jobName).synctex.gz")) }.value
        let mainRel = main.path.hasPrefix(root.path + "/") ? String(main.path.dropFirst(root.path.count + 1)) : main.lastPathComponent
        var issues = LogParser.parse(stderr: stderrText, log: log, mainFile: mainRel)
        // Paths in messages are relative to the main file's folder; make them project-relative.
        let mainDir = main.deletingLastPathComponent()
        issues = issues.map { i in
            var i = i
            if let f = i.file {
                let abs = f.hasPrefix("/") ? URL(fileURLWithPath: f) : mainDir.appendingPathComponent(f)
                let std = abs.standardizedFileURL.path
                if std.hasPrefix(root.standardizedFileURL.path + "/") { i.file = String(std.dropFirst(root.standardizedFileURL.path.count + 1)) }
            }
            return i
        }
        if status != 0 && issues.filter({ $0.severity == .error }).isEmpty {
            let firstError = stderrText.components(separatedBy: "\n").first { $0.hasPrefix("error:") }?.replacingOccurrences(of: "error: ", with: "")
            issues.insert(CompileIssue(severity: .error, file: nil, line: nil, message: firstError ?? "The engine stopped without producing a PDF"), at: 0)
        }
        return CompileResult(pdf: pdf, synctex: synctex, issues: issues, duration: duration, exitCode: status, cancelled: false, log: log, stderr: stderrText)
    }
}

/// Renders small math snippets to PDF with the document's own preamble, for the live equation preview and
/// hover peeks. Results are cached by content.
@MainActor
final class MathRenderer {
    static let shared = MathRenderer()
    private var cache: [String: Data] = [:]
    private var order: [String] = []
    private var running: Process?
    private var latestKey: String?

    enum Outcome { case pdf(Data), failed(String) }

    func render(math: String, display: Bool, preamble: String, engine: EngineLocator.Found) async -> Outcome? {
        let body = display && !math.contains("\\begin{") ? "$\\displaystyle \(math)$" : (display ? math : "$\(math)$")
        let key = "\(preamble.hashValue)|\(body)"
        if let d = cache[key] { return .pdf(d) }
        latestKey = key
        guard engine.engine == .tectonic else { return .failed("Equation preview needs Tectonic") }
        if let r = running, r.isRunning { r.terminate() }

        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Ligature/Math", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tex = """
        \\documentclass{article}
        \(Self.safePreamble(preamble))
        \\usepackage[active,tightpage]{preview}
        \\setlength\\PreviewBorder{1pt}
        \\pagestyle{empty}
        \\begin{document}
        \\begin{preview}\(display && math.contains("\\begin{") ? "\\begin{minipage}{12cm}\(body)\\end{minipage}" : body)\\end{preview}
        \\end{document}
        """
        let file = dir.appendingPathComponent("snippet.tex")
        try? tex.write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = engine.url
        p.currentDirectoryURL = dir
        p.arguments = ["-X", "compile", "snippet.tex", "--outdir", dir.path, "--untrusted"]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        running = p
        let status: Int32 = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard (try? p.run()) != nil else { cont.resume(returning: -1); return }
                _ = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus)
            }
        }
        guard latestKey == key else { return nil }  // superseded
        if status == 0, let data = try? Data(contentsOf: dir.appendingPathComponent("snippet.pdf")) {
            cache[key] = data
            order.append(key)
            if order.count > 200 { cache[order.removeFirst()] = nil }
            return .pdf(data)
        }
        return .failed("This equation doesn't compile yet")
    }

    /// Keeps packages and macro definitions, drops things that break a tiny standalone page (geometry, fancyhdr,
    /// title data, bibliography setup).
    static func safePreamble(_ p: String) -> String {
        p.components(separatedBy: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            for bad in ["\\title", "\\author", "\\date", "\\pagestyle", "\\geometry", "\\addbibresource", "\\bibliographystyle", "\\setbeamer", "\\usetheme", "\\usecolortheme", "\\institute", "\\subtitle", "\\signature", "\\address", "\\onehalfspacing", "\\doublespacing", "\\fancy", "\\titleformat", "\\titlespacing"] where t.hasPrefix(bad) { return false }
            for bad in ["fancyhdr", "geometry", "biblatex", "hyperref", "titlesec", "IEEEtran"] where t.hasPrefix("\\usepackage") && t.contains(bad) { return false }
            return true
        }.joined(separator: "\n")
    }
}
