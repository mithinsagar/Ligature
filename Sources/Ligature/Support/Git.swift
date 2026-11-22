import Foundation
import Observation

/// The project's Git repository, driven through the git on this Mac: status, commit, push and pull, history.
/// Commits are local and work offline; push and pull use your existing Git setup (keychain or SSH keys).
@Observable @MainActor
final class GitRepo {
    struct Change: Identifiable, Hashable {
        var id: String { path }
        let path: String
        /// Short status: M modified, A added, D deleted, R renamed, ? new (untracked).
        let status: String
    }

    struct Commit: Identifiable, Hashable {
        var id: String { hash }
        let hash: String
        let author: String
        let when: String
        let subject: String
    }

    let root: URL
    var isRepo = false
    var branch = ""
    var upstream: String?
    var ahead = 0
    var behind = 0
    var changes: [Change] = []
    var commits: [Commit] = []
    var remote: String?
    /// What's running right now ("Pushing…"), and the last problem.
    var busy: String?
    var lastError: String?
    var needsIdentity = false

    init(root: URL) { self.root = root }

    static let gitURL = URL(fileURLWithPath: "/usr/bin/git")

    @discardableResult
    private func git(_ args: [String], timeout: Double = 30) async -> (status: Int32, out: String, err: String) {
        let root = root
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = Self.gitURL
                p.arguments = args
                p.currentDirectoryURL = root
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"          // never hang waiting for a password
                env["GIT_OPTIONAL_LOCKS"] = "0"
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                guard (try? p.run()) != nil else { cont.resume(returning: (-1, "", "git isn't available on this Mac.")); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                var errData = Data()
                let g = DispatchGroup()
                g.enter()
                DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                g.wait()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: (p.terminationStatus, String(data: outData, encoding: .utf8) ?? "", String(data: errData, encoding: .utf8) ?? ""))
            }
        }
    }

    func refresh() async {
        let top = await git(["rev-parse", "--show-toplevel"])
        isRepo = top.status == 0
        guard isRepo else { changes = []; commits = []; branch = ""; return }
        let st = await git(["status", "--porcelain=v1", "-b", "-uall"])
        var list: [Change] = []
        for line in st.out.components(separatedBy: "\n") where !line.isEmpty {
            if line.hasPrefix("## ") { parseBranch(String(line.dropFirst(3))); continue }
            let code = String(line.prefix(2)).trimmingCharacters(in: .whitespaces)
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            list.append(Change(path: path, status: code == "??" ? "?" : String(code.prefix(1))))
        }
        changes = list
        let log = await git(["log", "-25", "--pretty=format:%h%x09%an%x09%ar%x09%s"])
        commits = log.out.components(separatedBy: "\n").compactMap { l in
            let p = l.components(separatedBy: "\t")
            return p.count >= 4 ? Commit(hash: p[0], author: p[1], when: p[2], subject: p[3...].joined(separator: "\t")) : nil
        }
        let r = await git(["remote", "get-url", "origin"])
        remote = r.status == 0 ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    private func parseBranch(_ s: String) {
        // "main...origin/main [ahead 1, behind 2]" or "No commits yet on main"
        ahead = 0; behind = 0; upstream = nil
        if s.hasPrefix("No commits yet on ") { branch = String(s.dropFirst(18)); return }
        let parts = s.components(separatedBy: " [")
        let names = parts[0].components(separatedBy: "...")
        branch = names[0]
        upstream = names.count > 1 ? names[1] : nil
        if parts.count > 1 {
            let info = parts[1].replacingOccurrences(of: "]", with: "")
            for item in info.components(separatedBy: ", ") {
                let kv = item.components(separatedBy: " ")
                if kv.count == 2, let n = Int(kv[1]) { if kv[0] == "ahead" { ahead = n } else if kv[0] == "behind" { behind = n } }
            }
        }
    }

    /// Starts tracking the project: git init, a .gitignore for TeX's by-products, and a first commit.
    func initialize() async {
        busy = "Setting up…"
        defer { busy = nil }
        let r = await git(["init", "-b", "main"])
        guard r.status == 0 else { lastError = r.err; return }
        let ignore = root.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try? "# TeX by-products (Ligature builds outside the project, but other editors may not)\n*.aux\n*.log\n*.out\n*.toc\n*.lof\n*.lot\n*.fls\n*.fdb_latexmk\n*.synctex.gz\n*.bbl\n*.blg\n*.bcf\n*.run.xml\n*.nav\n*.snm\n.DS_Store\n".write(to: ignore, atomically: true, encoding: .utf8)
        }
        await commitAll("Start tracking with Git")
    }

    func commitAll(_ message: String) async {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }
        busy = "Committing…"
        defer { busy = nil }
        lastError = nil
        await git(["add", "-A"])
        let r = await git(["commit", "-m", msg])
        if r.status != 0 {
            let text = r.err + r.out
            if text.contains("Please tell me who you are") || text.contains("user.email") { needsIdentity = true }
            else if !text.contains("nothing to commit") { lastError = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        await refresh()
    }

    /// Sets the name and email commits are made with, for this repository only.
    func setIdentity(name: String, email: String) async {
        await git(["config", "user.name", name])
        await git(["config", "user.email", email])
        needsIdentity = false
    }

    func push() async {
        busy = "Pushing…"
        defer { busy = nil }
        lastError = nil
        let r = await git(upstream == nil ? ["push", "-u", "origin", branch] : ["push"], timeout: 90)
        if r.status != 0 { lastError = Self.friendly(r.err) }
        await refresh()
    }

    func pull() async {
        busy = "Pulling…"
        defer { busy = nil }
        lastError = nil
        let r = await git(["pull", "--ff-only"], timeout: 90)
        if r.status != 0 { lastError = Self.friendly(r.err) }
        await refresh()
    }

    func addRemote(_ url: String) async {
        let r = await git(["remote", "add", "origin", url.trimmingCharacters(in: .whitespaces)])
        if r.status != 0 { lastError = r.err.trimmingCharacters(in: .whitespacesAndNewlines) }
        await refresh()
    }

    func diff(_ path: String) async -> String {
        let tracked = await git(["diff", "HEAD", "--", path])
        if !tracked.out.isEmpty { return tracked.out }
        return (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)).map { "New file\n\n" + $0 } ?? ""
    }

    static func friendly(_ err: String) -> String {
        let e = err.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.contains("Could not resolve host") || e.contains("unable to access") { return "Couldn't reach the remote. Pushing and pulling need the internet; your commits are safe locally." }
        if e.contains("terminal prompts disabled") || e.contains("Authentication failed") { return "The remote wants a login. Set up GitHub access once in Terminal (e.g. `gh auth login`), then try again." }
        if e.contains("non-fast-forward") || e.contains("rejected") { return "The remote has commits you don't have yet. Pull first, then push." }
        if e.contains("Not possible to fast-forward") { return "Your branch and the remote have both changed. Merge them in Terminal (`git pull`), then come back." }
        return e
    }
}
