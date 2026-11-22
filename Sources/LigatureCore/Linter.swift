import Foundation

/// Checks LaTeX as you type, without compiling: unbalanced braces, environments that don't match or never close,
/// unclosed maths, \left without \right, references to labels and citations that don't exist, and commands
/// used without their package. Fast enough to run on every pause in typing.
public enum Linter {
    public struct Context: Sendable {
        /// Every \label in the project (nil: don't check references).
        public var labels: Set<String>?
        /// Every citation key in the project's .bib files (nil: don't check citations).
        public var citations: Set<String>?
        /// Packages loaded by the main file's preamble, and its document class (nil: don't check packages).
        public var packages: Set<String>?
        public var documentClass: String?
        /// The file being checked is the main file (it should end with \end{document}).
        public var isMain: Bool

        public init(labels: Set<String>? = nil, citations: Set<String>? = nil, packages: Set<String>? = nil, documentClass: String? = nil, isMain: Bool = true) {
            self.labels = labels; self.citations = citations; self.packages = packages; self.documentClass = documentClass; self.isMain = isMain
        }
    }

    static let verbatimEnvs: Set<String> = ["verbatim", "verbatim*", "lstlisting", "minted", "comment", "Verbatim", "filecontents", "filecontents*", "alltt"]
    static let mathEnvs: Set<String> = ["equation", "equation*", "align", "align*", "gather", "gather*", "multline", "multline*", "flalign", "flalign*", "alignat", "alignat*", "eqnarray", "eqnarray*", "displaymath", "math"]
    /// Classes that load nothing extra, where "needs \usepackage{…}" is reliable.
    static let plainClasses: Set<String> = ["article", "report", "book", "letter", "scrartcl", "scrreprt", "scrbook", "extarticle", "extreport"]
    /// Commands worth warning about when their package is missing (unambiguous ones only).
    static let packageChecks: [String: String] = [
        "includegraphics": "graphicx", "href": "hyperref", "toprule": "booktabs", "midrule": "booktabs", "bottomrule": "booktabs",
        "mathbb": "amssymb", "eqref": "amsmath", "dfrac": "amsmath", "tfrac": "amsmath", "operatorname": "amsmath", "text": "amsmath",
        "SI": "siunitx", "cref": "cleveref", "Cref": "cleveref", "multirow": "multirow", "textcolor": "xcolor", "lstinline": "listings",
        "citep": "natbib", "citet": "natbib", "url": "url",
    ]
    static let packageAlternatives: [String: Set<String>] = [
        "amssymb": ["amssymb", "amsfonts", "mathtools"], "amsmath": ["amsmath", "mathtools"], "xcolor": ["xcolor", "color"],
        "url": ["url", "hyperref", "xurl"], "natbib": ["natbib"], "graphicx": ["graphicx", "graphics"],
    ]
    static let envPackages: [String: String] = ["align": "amsmath", "align*": "amsmath", "gather": "amsmath", "gather*": "amsmath", "multline": "amsmath",
                                                "pmatrix": "amsmath", "bmatrix": "amsmath", "cases": "amsmath", "tikzpicture": "tikz", "lstlisting": "listings"]

    public static func check(_ text: String, file: String? = nil, context ctx: Context = Context()) -> [CompileIssue] {
        let ns = text as NSString
        let len = ns.length
        var issues: [CompileIssue] = []
        // Line starts for offset → (line, column).
        var lineStarts = [0]
        for i in 0..<len where ns.character(at: i) == 10 { lineStarts.append(i + 1) }
        func pos(_ o: Int) -> (Int, Int) {
            var lo = 0, hi = lineStarts.count - 1
            while lo < hi { let mid = (lo + hi + 1) / 2; if lineStarts[mid] <= o { lo = mid } else { hi = mid - 1 } }
            return (lo + 1, o - lineStarts[lo] + 1)
        }
        func add(_ sev: CompileIssue.Severity, _ offset: Int, _ length: Int, _ message: String) {
            let (l, c) = pos(offset)
            issues.append(CompileIssue(severity: sev, file: file, line: l, message: message, column: c, length: max(1, length), isLive: true))
        }

        var braces: [Int] = []                                  // offsets of open {
        var envs: [(name: String, offset: Int, length: Int)] = []
        var inlineMath: Int?                                     // offset of an open $
        var displayMath: (offset: Int, close: String)?           // \[ … \] or $$ … $$ or \( … \)
        var lefts: [Int] = []                                    // open \left in the current maths
        var mathEnvDepth = 0
        var usedCommands: [(name: String, offset: Int)] = []
        var refs: [(key: String, offset: Int, cite: Bool)] = []
        var i = 0

        func inMath() -> Bool { inlineMath != nil || displayMath != nil || mathEnvDepth > 0 }
        func readName(at j: Int) -> (String, Int) {
            var k = j
            while k < len, let u = UnicodeScalar(ns.character(at: k)), CharacterSet.letters.contains(u) || u == "@" { k += 1 }
            if k < len, ns.character(at: k) == 42 { k += 1 }   // *
            return (ns.substring(with: NSRange(location: j, length: k - j)), k)
        }
        func readGroup(at j: Int) -> (String, Int)? {
            guard j < len, ns.character(at: j) == 123 else { return nil }
            var k = j + 1, depth = 1
            while k < len {
                let c = ns.character(at: k)
                if c == 92 { k += 2; continue }
                if c == 123 { depth += 1 } else if c == 125 { depth -= 1; if depth == 0 { break } }
                if c == 10 && k > j + 400 { return nil }
                k += 1
            }
            guard k < len else { return nil }
            return (ns.substring(with: NSRange(location: j + 1, length: k - j - 1)), k + 1)
        }
        func skipOptional(_ j: Int) -> Int {
            var k = j
            while k < len, ns.character(at: k) == 91 {       // [ … ]
                guard let close = ns.range(of: "]", range: NSRange(location: k, length: min(400, len - k))).location as Int?, close != NSNotFound else { return k }
                k = close + 1
            }
            return k
        }
        func displayMessage(_ close: String) -> String {
            close == "\\]" ? "\\[ without a matching \\]" : (close == "$$" ? "Unclosed $$" : "\\( without a matching \\)")
        }
        func closeParagraphMath() {
            // A blank line ends the paragraph, and maths can't run across one.
            if let m = inlineMath { add(.error, m, 1, "Unclosed $: the maths starting here never ends"); inlineMath = nil; lefts = [] }
            if let d = displayMath { add(.error, d.offset, 2, displayMessage(d.close)); displayMath = nil; lefts = [] }
        }

        while i < len {
            let c = ns.character(at: i)
            switch c {
            case 37: // % comment: skip to end of line
                while i < len, ns.character(at: i) != 10 { i += 1 }
                continue
            case 10: // newline: blank line ends paragraph-level maths
                var k = i + 1
                while k < len, ns.character(at: k) == 32 || ns.character(at: k) == 9 { k += 1 }
                if k < len, ns.character(at: k) == 10 { closeParagraphMath() }
            case 123: braces.append(i)
            case 125:
                if braces.popLast() == nil { add(.error, i, 1, "Extra } with no matching {") }
            case 36: // $
                if i + 1 < len, ns.character(at: i + 1) == 36 {
                    if let d = displayMath, d.close == "$$" {
                        if !lefts.isEmpty { add(.error, lefts[0], 5, "\\left without a matching \\right") }
                        displayMath = nil; lefts = []
                    } else if displayMath == nil && inlineMath == nil { displayMath = (i, "$$"); lefts = [] }
                    i += 2; continue
                }
                if let m = inlineMath {
                    if !lefts.isEmpty { add(.error, lefts[0], 5, "\\left without a matching \\right") }
                    _ = m; inlineMath = nil; lefts = []
                } else if displayMath == nil && mathEnvDepth == 0 { inlineMath = i; lefts = [] }
            case 92: // backslash
                guard i + 1 < len else { break }
                let n = ns.character(at: i + 1)
                if n == 91 { // \[
                    if displayMath == nil && inlineMath == nil { displayMath = (i, "\\]"); lefts = [] }
                    else { add(.error, i, 2, "\\[ inside maths that's already open") }
                    i += 2; continue
                }
                if n == 93 { // \]
                    if let d = displayMath, d.close == "\\]" {
                        if !lefts.isEmpty { add(.error, lefts[0], 5, "\\left without a matching \\right") }
                        displayMath = nil; lefts = []
                    } else { add(.error, i, 2, "\\] with no matching \\[") }
                    i += 2; continue
                }
                if n == 40 { if displayMath == nil && inlineMath == nil { displayMath = (i, "\\)"); lefts = [] }; i += 2; continue }
                if n == 41 {
                    if let d = displayMath, d.close == "\\)" { displayMath = nil; lefts = [] } else { add(.error, i, 2, "\\) with no matching \\(") }
                    i += 2; continue
                }
                guard let u = UnicodeScalar(n), CharacterSet.letters.contains(u) || u == "@" else { i += 2; continue }
                let (name, end) = readName(at: i + 1)
                if name == "begin" || name == "end" {
                    let gStart = end
                    guard let (env, after) = readGroup(at: gStart) else { i = end; continue }
                    if name == "begin" {
                        envs.append((env, i, after - i))
                        if mathEnvs.contains(env) { mathEnvDepth += 1; lefts = [] }
                        if verbatimEnvs.contains(env) {
                            // Skip to the matching \end{env} without checking anything inside.
                            let close = ns.range(of: "\\end{\(env)}", range: NSRange(location: after, length: len - after))
                            if close.location == NSNotFound { i = len; continue }
                            envs.removeLast()
                            i = NSMaxRange(close); continue
                        }
                        if let pkg = envPackages[env] { usedCommands.append((name: "env:" + env + ":" + pkg, offset: i)) }
                    } else {
                        if let top = envs.last {
                            if top.name == env {
                                envs.removeLast()
                                if mathEnvs.contains(env) {
                                    if !lefts.isEmpty { add(.error, lefts[0], 5, "\\left without a matching \\right") }
                                    mathEnvDepth = max(0, mathEnvDepth - 1); lefts = []
                                }
                            } else if let idx = envs.lastIndex(where: { $0.name == env }) {
                                // Something opened in between was never closed.
                                for open in envs[(idx + 1)...] { add(.error, open.offset, open.length, "\\begin{\(open.name)} is closed by \\end{\(env)} instead of \\end{\(open.name)}") }
                                envs.removeSubrange(idx...)
                                if mathEnvs.contains(env) { mathEnvDepth = max(0, mathEnvDepth - 1) }
                            } else {
                                add(.error, i, after - i, "\\end{\(env)} doesn't match \\begin{\(top.name)} (line \(pos(top.offset).0))")
                            }
                        } else {
                            add(.error, i, after - i, "\\end{\(env)} with no matching \\begin{\(env)}")
                        }
                    }
                    i = after; continue
                }
                if name == "left" && inMath() { lefts.append(i) }
                if name == "right" && inMath() { if lefts.popLast() == nil { add(.error, i, 6, "\\right without a matching \\left") } }
                if ["ref", "eqref", "cref", "Cref", "autoref", "pageref", "nameref", "vref"].contains(name) || name.hasPrefix("cite") || ["parencite", "textcite", "autocite", "footcite", "nocite"].contains(name) {
                    let isCite = name.hasPrefix("cite") || name.hasSuffix("cite")
                    let g = skipOptional(end)
                    if let (arg, after) = readGroup(at: g) {
                        var o = g + 1
                        for part in arg.components(separatedBy: ",") {
                            let key = part.trimmingCharacters(in: .whitespaces)
                            let lead = part.prefix { $0 == " " }.count
                            if !key.isEmpty && key != "*" { refs.append((key, o + lead, isCite)) }
                            o += (part as NSString).length + 1
                        }
                        i = after; continue
                    }
                }
                usedCommands.append((name, i))
                i = end; continue
            default:
                break
            }
            i += 1
        }

        for b in braces.suffix(3) { add(.error, b, 1, "This { is never closed") }
        for e in envs where !(e.name == "document" && !ctx.isMain) { add(.error, e.offset, e.length, "\\begin{\(e.name)} is never closed") }
        if let m = inlineMath { add(.error, m, 1, "Unclosed $: the maths starting here never ends") }
        if let d = displayMath { add(.error, d.offset, 2, displayMessage(d.close)) }

        // References and citations that point nowhere.
        if let labels = ctx.labels {
            for r in refs where !r.cite && !labels.contains(r.key) { add(.warning, r.offset, (r.key as NSString).length, "No \\label{\(r.key)} anywhere in the project") }
        }
        if let cites = ctx.citations, !cites.isEmpty {
            for r in refs where r.cite && !cites.contains(r.key) { add(.warning, r.offset, (r.key as NSString).length, "\(r.key) isn't in your bibliography") }
        }
        // Commands used without the package that defines them (plain document classes only).
        if let pkgs = ctx.packages, let cls = ctx.documentClass, plainClasses.contains(cls) {
            var warned = Set<String>()
            for u in usedCommands {
                var cmd = u.name, pkg: String?
                if cmd.hasPrefix("env:") {
                    let parts = cmd.split(separator: ":")
                    cmd = "\\begin{\(parts[1])}"; pkg = String(parts[2])
                } else { pkg = packageChecks[cmd]; cmd = "\\" + cmd }
                guard let pkg, !warned.contains(pkg) else { continue }
                let ok = packageAlternatives[pkg] ?? [pkg]
                if pkgs.isDisjoint(with: ok) {
                    warned.insert(pkg)
                    add(.warning, u.offset, (cmd as NSString).length, "\(cmd) needs \\usepackage{\(pkg)}")
                }
            }
        }
        return issues.sorted { ($0.line ?? 0, $0.column ?? 0) < ($1.line ?? 0, $1.column ?? 0) }
    }

    /// Packages loaded and the document class, read from a preamble.
    public static func preambleInfo(_ text: String) -> (packages: Set<String>, documentClass: String?) {
        let ns = text as NSString
        let end = ns.range(of: "\\begin{document}").location
        let pre = end == NSNotFound ? text : ns.substring(to: end)
        var pkgs = Set<String>()
        let re = try! NSRegularExpression(pattern: #"\\(?:usepackage|RequirePackage)(?:\[[^\]]*\])?\{([^}]*)\}"#)
        let pns = pre as NSString
        for m in re.matches(in: pre, range: NSRange(location: 0, length: pns.length)) {
            for p in pns.substring(with: m.range(at: 1)).split(separator: ",") { pkgs.insert(p.trimmingCharacters(in: .whitespaces)) }
        }
        let cls = pre.range(of: #"\\documentclass(\[[^\]]*\])?\{([^}]*)\}"#, options: .regularExpression)
            .map { String(pre[$0]).replacingOccurrences(of: #"^.*\{|\}$"#, with: "", options: .regularExpression) }
        return (pkgs, cls)
    }
}
