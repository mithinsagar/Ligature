import Foundation

/// Turns a .zip of a project, a Word document or a Markdown file into a new Ligature project folder in
/// ~/Documents/Ligature. Word and Markdown go through pandoc on this Mac (no upload).
enum ProjectImporter {
    static var defaultParent: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Ligature", isDirectory: true)
    }

    static func uniqueFolder(named name: String, in parent: URL = defaultParent) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        var dest = parent.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dest.path) { dest = parent.appendingPathComponent("\(name) \(n)", isDirectory: true); n += 1 }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        return dest
    }

    /// Picks the right importer from the file's extension.
    static func importFile(_ url: URL, into parent: URL = defaultParent) throws -> URL {
        switch url.pathExtension.lowercased() {
        case "zip": return try importZip(url, into: parent)
        case "docx", "odt", "rtf", "html", "htm", "epub", "md", "markdown", "txt": return try importDocument(url, into: parent)
        default: throw failure("Ligature can import a .zip project, a Word document (.docx) or a Markdown file (.md).")
        }
    }

    /// Unzips a project (an Overleaf download, say). A single folder inside the zip becomes the project itself.
    static func importZip(_ url: URL, into parent: URL = defaultParent) throws -> URL {
        let dest = try uniqueFolder(named: url.deletingPathExtension().lastPathComponent, in: parent)
        try run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", url.path, dest.path], cwd: dest)
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: [.isDirectoryKey]).filter { $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" }
        try? fm.removeItem(at: dest.appendingPathComponent("__MACOSX"))
        if items.count == 1, (try? items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            for child in try fm.contentsOfDirectory(at: items[0], includingPropertiesForKeys: nil) {
                try fm.moveItem(at: child, to: dest.appendingPathComponent(child.lastPathComponent))
            }
            try fm.removeItem(at: items[0])
        }
        guard (fm.enumerator(at: dest, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).contains(where: { $0.pathExtension == "tex" }) else {
            throw failure("That zip doesn't contain any .tex files.")
        }
        return dest
    }

    /// Converts a document to LaTeX with pandoc: main.tex plus any images in media/.
    static func importDocument(_ url: URL, into parent: URL = defaultParent) throws -> URL {
        guard let pandoc = WordExporter.pandoc() else { throw failure("Importing Word and Markdown needs pandoc. Install it with: brew install pandoc") }
        let dest = try uniqueFolder(named: url.deletingPathExtension().lastPathComponent, in: parent)
        do {
            var args = [url.path, "--standalone", "--to=latex", "--output=main.tex", "--extract-media=."]
            if ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) {
                args += ["--from=markdown", "--resource-path=\(url.deletingLastPathComponent().path)"]
                // Local images the Markdown points at come along.
                let fm = FileManager.default
                for f in (try? fm.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
                where ["png", "jpg", "jpeg", "pdf", "gif"].contains(f.pathExtension.lowercased()) {
                    try? fm.copyItem(at: f, to: dest.appendingPathComponent(f.lastPathComponent))
                }
            }
            try run(pandoc, args, cwd: dest)
            guard FileManager.default.fileExists(atPath: dest.appendingPathComponent("main.tex").path) else { throw failure("pandoc didn't produce a LaTeX file.") }
            return dest
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }

    private static func run(_ exe: URL, _ args: [String], cwd: URL) throws {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = cwd
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw failure(String(data: data, encoding: .utf8)?.components(separatedBy: "\n").first { !$0.isEmpty } ?? "The conversion failed.")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Ligature", code: 20, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
