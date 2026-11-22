import Foundation
import CryptoKit
import AppKit
import LigatureCore

/// Bundled resources. In the built app they're copied to Contents/Resources; under `swift run` they come from
/// SwiftPM's resource bundle.
enum AppResources {
    static func url(_ name: String) -> URL? {
        let fm = FileManager.default
        if let r = Bundle.main.resourceURL {
            for candidate in [r.appendingPathComponent(name), r.appendingPathComponent("Ligature_Ligature.bundle/Resources/\(name)")]
            where fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources")
    }
}

// MARK: Recent projects

struct RecentProject: Codable, Hashable, Identifiable {
    var id: String { path }
    var path: String
    var mainFile: String?
    var opened: Date
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

@Observable @MainActor
final class Recents {
    static let shared = Recents()
    private(set) var items: [RecentProject] = []
    private let key = "recentProjects"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key), let list = try? JSONDecoder().decode([RecentProject].self, from: data) {
            items = list.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    func touch(_ url: URL, main: String?) {
        items.removeAll { $0.path == url.path }
        items.insert(RecentProject(path: url.path, mainFile: main, opened: Date()), at: 0)
        if items.count > 20 { items.removeLast(items.count - 20) }
        save()
        if !Recents.testRun { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
    }

    func remove(_ item: RecentProject) {
        items.removeAll { $0 == item }
        save()
    }

    /// Scripted test runs read the real list but never write to it, so test projects don't show up in it.
    private static let testRun = ProcessInfo.processInfo.environment["LIGATURE_SCRIPT"] != nil

    private func save() {
        guard !Recents.testRun else { return }
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
    }
}

// MARK: Templates

struct ProjectTemplate: Identifiable, Hashable {
    var id: String
    var name: String
    var subtitle: String
    var symbol: String
    var main: String
    var order: Int
    var folder: URL
    var preview: NSImage? { NSImage(contentsOf: folder.appendingPathComponent("preview.png")) }

    static func all() -> [ProjectTemplate] {
        guard let base = AppResources.url("Templates"),
              let dirs = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
        struct Meta: Decodable { var name: String; var subtitle: String; var symbol: String; var main: String; var order: Int }
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("template.json")),
                  let m = try? JSONDecoder().decode(Meta.self, from: data) else { return nil }
            return ProjectTemplate(id: dir.lastPathComponent, name: m.name, subtitle: m.subtitle, symbol: m.symbol, main: m.main, order: m.order, folder: dir)
        }.sorted { $0.order < $1.order }
    }

    /// Copies the template (minus its metadata and preview) into a new folder.
    func instantiate(named name: String, in parent: URL) throws -> URL {
        let fm = FileManager.default
        var dest = parent.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dest.path) { dest = parent.appendingPathComponent("\(name) \(n)", isDirectory: true); n += 1 }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try fm.copyItem(at: folder, to: dest)
        try? fm.removeItem(at: dest.appendingPathComponent("template.json"))
        try? fm.removeItem(at: dest.appendingPathComponent("preview.png"))
        return dest
    }
}

// MARK: Version history

/// Snapshots of a project's text files, taken after successful compiles when something changed.
/// Stored in ~/Library/Application Support/Ligature/History/<project-hash>/<timestamp>.json.
struct Snapshot: Codable, Identifiable, Hashable {
    var id: Double { date.timeIntervalSince1970 }
    var date: Date
    var words: Int
    var files: [String: String]
    var note: String?
    /// Set for compiles the user started: the PDF they produced is kept next to the snapshot.
    var manual: Bool?
    var pdf: String?
    var pages: Int?
    var errors: Int?

    var isCompile: Bool { manual == true && pdf != nil }
}

enum HistoryStore {
    static func directory(for root: URL) -> URL {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ligature/History/\(digest)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func list(root: URL) -> [Snapshot] {
        let dir = directory(for: root)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    /// Saves a snapshot unless it is identical to the latest one. Keeps the newest 300.
    @discardableResult
    static func pdfURL(_ snap: Snapshot, root: URL) -> URL? { snap.pdf.map { directory(for: root).appendingPathComponent($0) } }

    /// Saves a snapshot unless nothing changed. A manual compile is always kept (with its PDF) unless the
    /// previous entry is already the same compile.
    static func save(root: URL, files: [String: String], words: Int, note: String? = nil, latest: Snapshot?,
                     pdf: Data? = nil, pages: Int? = nil, errors: Int? = nil) -> Snapshot? {
        let manual = pdf != nil
        if let latest, latest.files == files, !manual || latest.isCompile { return nil }
        let date = Date()
        let stamp = String(format: "%.3f", date.timeIntervalSince1970)
        let dir = directory(for: root)
        var snap = Snapshot(date: date, words: words, files: files, note: note)
        if let pdf {
            snap.manual = true
            snap.pdf = stamp + ".pdf"
            snap.pages = pages
            snap.errors = errors
            try? pdf.write(to: dir.appendingPathComponent(stamp + ".pdf"), options: .atomic)
        }
        guard let data = try? JSONEncoder().encode(snap) else { return nil }
        try? data.write(to: dir.appendingPathComponent(stamp + ".json"), options: .atomic)
        let all = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if all.count > 300 {
            // Labelled versions are kept forever; the oldest unlabelled ones go.
            let unlabelled = all.filter { ((try? JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: $0)))?.note ?? "").isEmpty }
            for old in unlabelled.prefix(max(0, all.count - 300)) {
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.removeItem(at: old.deletingPathExtension().appendingPathExtension("pdf"))
            }
        }
        return snap
    }

    /// Names a version (or clears its name with nil).
    static func setLabel(_ label: String?, on snap: Snapshot, root: URL) -> Snapshot? {
        let url = directory(for: root).appendingPathComponent(String(format: "%.3f", snap.date.timeIntervalSince1970) + ".json")
        var s = snap
        s.note = label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? label : nil
        guard let data = try? JSONEncoder().encode(s), (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return s
    }
}

// MARK: Downloads

/// Every PDF or zip the user downloads from a project, with a private copy so it can be opened or saved
/// again later even if the original was moved or deleted. Kept per project, newest 60.
struct DownloadRecord: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case pdf, source, arxiv, word, markdown, html }
    var id = UUID()
    var date: Date
    var kind: Kind
    var fileName: String
    var destination: String
    var copyName: String
    var bytes: Int
    var pages: Int?
    var words: Int?

    var destinationURL: URL { URL(fileURLWithPath: destination) }
    var stillThere: Bool { FileManager.default.fileExists(atPath: destination) }
}

enum DownloadStore {
    static func directory(for root: URL) -> URL {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ligature/Downloads/\(digest)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func list(root: URL) -> [DownloadRecord] {
        guard let data = try? Data(contentsOf: directory(for: root).appendingPathComponent("index.json")),
              let list = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return [] }
        return list.sorted { $0.date > $1.date }
    }

    static func copyURL(_ r: DownloadRecord, root: URL) -> URL { directory(for: root).appendingPathComponent(r.copyName) }

    /// Records a download and stores a copy of the file that was written to `destination`.
    static func record(root: URL, kind: DownloadRecord.Kind, destination: URL, pages: Int?, words: Int?) -> [DownloadRecord] {
        let dir = directory(for: root)
        let copyName = "\(Int(Date().timeIntervalSince1970 * 1000))-\(destination.lastPathComponent)"
        try? FileManager.default.copyItem(at: destination, to: dir.appendingPathComponent(copyName))
        let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var all = list(root: root)
        all.insert(DownloadRecord(date: Date(), kind: kind, fileName: destination.lastPathComponent, destination: destination.path,
                                  copyName: copyName, bytes: bytes, pages: pages, words: words), at: 0)
        for old in all.dropFirst(60) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old.copyName)) }
        all = Array(all.prefix(60))
        save(all, root: root)
        return all
    }

    static func remove(_ r: DownloadRecord, root: URL) -> [DownloadRecord] {
        try? FileManager.default.removeItem(at: copyURL(r, root: root))
        let all = list(root: root).filter { $0.id != r.id }
        save(all, root: root)
        return all
    }

    static func save(_ all: [DownloadRecord], root: URL) {
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: directory(for: root).appendingPathComponent("index.json"), options: .atomic) }
    }
}

// MARK: Word export

/// LaTeX → .docx through pandoc (headings, lists, tables, equations as native Word equations, citations from
/// the project's .bib files). Pandoc is a free install: `brew install pandoc`.
enum WordExporter {
    static func pandoc() -> URL? {
        ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc", "/opt/local/bin/pandoc"].map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// What pandoc writes: Word, Markdown, or a self-contained web page (images embedded, maths as MathML so
    /// it shows offline).
    enum Format: String { case docx, markdown, html
        var title: String { ["docx": "Word", "markdown": "Markdown", "html": "Web page"][rawValue]! }
    }

    static func export(root: URL, main: String, bibFiles: [String], to dest: URL, format: Format = .docx) throws {
        guard let pandoc = pandoc() else {
            throw NSError(domain: "Ligature", code: 10, userInfo: [NSLocalizedDescriptionKey: "\(format.title) export needs pandoc. Install it with: brew install pandoc"])
        }
        let mainURL = root.appendingPathComponent(main)
        let p = Process()
        p.executableURL = pandoc
        p.currentDirectoryURL = mainURL.deletingLastPathComponent()
        var args = [mainURL.lastPathComponent, "--from=latex", "--to=\(format == .markdown ? "markdown" : format.rawValue)", "--output=\(dest.path)",
                    "--resource-path=\(mainURL.deletingLastPathComponent().path):\(root.path)"]
        switch format {
        case .html: args += ["--standalone", "--embed-resources", "--mathml", "--metadata=pagetitle:\(mainURL.deletingPathExtension().lastPathComponent)"]
        case .markdown: args += ["--wrap=none", "--standalone"]
        case .docx: break
        }
        if !bibFiles.isEmpty {
            args.append("--citeproc")
            args += bibFiles.map { "--bibliography=\(root.appendingPathComponent($0).path)" }
        }
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: dest.path) else {
            let msg = String(data: errData, encoding: .utf8)?.components(separatedBy: "\n").first { !$0.isEmpty } ?? "pandoc failed"
            throw NSError(domain: "Ligature", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
}

// MARK: Export

enum Exporter {
    /// Zips a folder's contents with the system zip tool, leaving out build junk and version control.
    static func zip(folder: URL, to dest: URL) throws {
        try? FileManager.default.removeItem(at: dest)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = folder
        p.arguments = ["-r", "-q", dest.path, ".", "-x", "*.DS_Store", ".git/*", "*.aux", "*.log", "*.synctex.gz", "*.fdb_latexmk", "*.fls", "*.out"]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw NSError(domain: "Ligature", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "zip failed"]) }
    }

    /// arXiv-ready source: comments stripped from .tex files, the compiled .bbl included next to the main file,
    /// and only text sources plus images.
    static func arxiv(root: URL, main: String, buildDir: URL, to dest: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ligature-arxiv-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let keep: Set<String> = ["tex", "bib", "bbl", "sty", "cls", "bst", "png", "jpg", "jpeg", "pdf", "eps", "svg", "tikz", "pgf", "csv", "dat", "txt"]
        let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        while let url = e?.nextObject() as? URL {
            let rel = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            guard keep.contains(url.pathExtension.lowercased()) else { continue }
            let out = tmp.appendingPathComponent(rel)
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            if url.pathExtension.lowercased() == "tex", let text = try? String(contentsOf: url, encoding: .utf8) {
                try LaTeXText.stripComments(text).write(to: out, atomically: true, encoding: .utf8)
            } else {
                try fm.copyItem(at: url, to: out)
            }
        }
        let job = (main as NSString).deletingPathExtension
        let bbl = buildDir.appendingPathComponent((job as NSString).lastPathComponent + ".bbl")
        if fm.fileExists(atPath: bbl.path) {
            let target = tmp.appendingPathComponent(job + ".bbl")
            try? fm.removeItem(at: target)
            try fm.copyItem(at: bbl, to: target)
        }
        try zip(folder: tmp, to: dest)
    }
}

// MARK: Citations from the web

/// Fetches BibTeX for a DOI (via doi.org content negotiation), an arXiv ID (arXiv API), or searches Crossref by
/// title. Network is only used when the user asks for it.
enum CitationFetcher {
    enum Query {
        case doi(String)
        case arxiv(String)
        case search(String)

        static func parse(_ raw: String) -> Query {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let r = s.range(of: #"10\.\d{4,9}/\S+"#, options: .regularExpression) { return .doi(String(s[r])) }
            if let r = s.range(of: #"(\d{4}\.\d{4,5})(v\d+)?"#, options: .regularExpression), s.lowercased().contains("arxiv") || s.range(of: #"^\d{4}\.\d{4,5}(v\d+)?$"#, options: .regularExpression) != nil {
                return .arxiv(String(s[r]))
            }
            return .search(s)
        }
    }

    struct SearchHit: Identifiable, Hashable {
        var id: String { doi }
        var doi: String
        var title: String
        var authors: String
        var year: String
        var venue: String
    }

    static func bibtex(doi: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://doi.org/\(doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi)")!)
        req.setValue("application/x-bibtex; charset=utf-8", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8), text.contains("@") else {
            throw NSError(domain: "Ligature", code: 1, userInfo: [NSLocalizedDescriptionKey: "No BibTeX found for that DOI."])
        }
        return prettify(text)
    }

    static func bibtex(arxiv id: String) async throws -> String {
        let url = URL(string: "https://export.arxiv.org/api/query?id_list=\(id)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let parser = ArxivParser(data: data)
        guard let e = parser.parse(), !e.title.isEmpty else {
            throw NSError(domain: "Ligature", code: 2, userInfo: [NSLocalizedDescriptionKey: "arXiv didn't return a paper for \(id)."])
        }
        let year = String(e.published.prefix(4))
        let key = BibTeX.suggestKey(author: e.authors.first ?? "", year: year, title: e.title)
        var fields: [(String, String)] = [
            ("title", e.title), ("author", e.authors.joined(separator: " and ")), ("year", year),
            ("eprint", id.replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression)), ("archivePrefix", "arXiv"),
        ]
        if !e.category.isEmpty { fields.append(("primaryClass", e.category)) }
        if !e.doi.isEmpty { fields.append(("doi", e.doi)) }
        fields.append(("url", "https://arxiv.org/abs/\(id)"))
        return BibTeX.format(type: "misc", key: key, fields: fields)
    }

    static func search(_ query: String) async throws -> [SearchHit] {
        var c = URLComponents(string: "https://api.crossref.org/works")!
        c.queryItems = [URLQueryItem(name: "query.bibliographic", value: query), URLQueryItem(name: "rows", value: "8"),
                        URLQueryItem(name: "select", value: "DOI,title,author,issued,container-title")]
        var req = URLRequest(url: c.url!)
        req.setValue("Ligature/1.0 (LaTeX editor for macOS)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any], let items = message["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let doi = item["DOI"] as? String else { return nil }
            let title = (item["title"] as? [String])?.first ?? "Untitled"
            let authors = (item["author"] as? [[String: Any]] ?? []).compactMap { $0["family"] as? String }
            let year = ((item["issued"] as? [String: Any])?["date-parts"] as? [[Int]])?.first?.first.map(String.init) ?? ""
            let venue = (item["container-title"] as? [String])?.first ?? ""
            let a = authors.count > 2 ? "\(authors[0]) et al." : authors.joined(separator: " & ")
            return SearchHit(doi: doi, title: title, authors: a, year: year, venue: venue)
        }
    }

    /// doi.org returns BibTeX on one line; reflow it one field per line with a readable key.
    static func prettify(_ raw: String) -> String {
        let entries = BibTeX.parse(raw, file: "")
        guard let e = entries.first else { return raw }
        let key = BibTeX.suggestKey(author: e.fields["author"] ?? "", year: e.year, title: e.fields["title"] ?? "")
        let order = ["title", "author", "journal", "booktitle", "volume", "number", "pages", "year", "publisher", "doi", "url"]
        var fields = order.compactMap { k in e.fields[k].map { (k, $0) } }
        for (k, v) in e.fields.sorted(by: { $0.key < $1.key }) where !order.contains(k) && k != "month" { fields.append((k, v)) }
        return BibTeX.format(type: e.type, key: key, fields: fields)
    }

    final class ArxivParser: NSObject, XMLParserDelegate {
        struct Entry { var title = "", authors: [String] = [], published = "", category = "", doi = "" }
        let data: Data
        var entry: Entry?
        var text = ""
        var inAuthor = false
        init(data: Data) { self.data = data }

        func parse() -> Entry? {
            let p = XMLParser(data: data)
            p.delegate = self
            p.parse()
            return entry
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "entry" { entry = Entry() }
            if name == "author" { inAuthor = true }
            if name == "arxiv:primary_category" || name == "primary_category", let t = attributes["term"] { entry?.category = t }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard entry != nil else { return }
            switch name {
            case "title": entry?.title = t
            case "name" where inAuthor: entry?.authors.append(t)
            case "author": inAuthor = false
            case "published": entry?.published = t
            case "arxiv:doi", "doi": entry?.doi = t
            default: break
            }
        }
    }
}
