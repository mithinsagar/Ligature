import Foundation

/// Plain-English explanations and one-click fixes for the TeX errors people actually hit. No AI: a curated table.
public struct Advice: Sendable, Hashable {
    public enum Fix: Sendable, Hashable {
        case addPackage(name: String, options: String?)
        case replace(line: Int, find: String, with: String)
        case insertAtLineEnd(line: Int, text: String)
    }

    public var title: String
    public var explanation: String
    public var fix: Fix?
    public var fixLabel: String?
}

public enum ErrorAdvisor {
    /// Which package defines a command or environment people commonly forget to load.
    public static let packageFor: [String: String] = [
        "includegraphics": "graphicx", "graphicspath": "graphicx", "rotatebox": "graphicx", "scalebox": "graphicx", "resizebox": "graphicx",
        "url": "url", "href": "hyperref", "hyperref": "hyperref", "autoref": "hyperref", "texorpdfstring": "hyperref",
        "mathbb": "amssymb", "mathfrak": "amssymb", "varnothing": "amssymb", "therefore": "amssymb", "because": "amssymb",
        "leqslant": "amssymb", "geqslant": "amssymb", "checkmark": "amssymb", "square": "amssymb", "blacksquare": "amssymb",
        "eqref": "amsmath", "text": "amsmath", "dfrac": "amsmath", "tfrac": "amsmath", "binom": "amsmath", "operatorname": "amsmath",
        "DeclareMathOperator": "amsmath", "intertext": "amsmath", "boxed": "amsmath", "numberwithin": "amsmath",
        "align": "amsmath", "align*": "amsmath", "gather": "amsmath", "gather*": "amsmath", "multline": "amsmath", "split": "amsmath",
        "pmatrix": "amsmath", "bmatrix": "amsmath", "vmatrix": "amsmath", "cases": "amsmath", "matrix": "amsmath",
        "newtheorem": "amsthm", "theorem": "amsthm", "proof": "amsthm", "qedhere": "amsthm", "theoremstyle": "amsthm",
        "toprule": "booktabs", "midrule": "booktabs", "bottomrule": "booktabs", "cmidrule": "booktabs", "addlinespace": "booktabs",
        "multirow": "multirow", "cellcolor": "xcolor", "rowcolor": "xcolor", "textcolor": "xcolor", "color": "xcolor", "colorbox": "xcolor", "definecolor": "xcolor",
        "SI": "siunitx", "si": "siunitx", "qty": "siunitx", "unit": "siunitx", "num": "siunitx", "ang": "siunitx",
        "lstinline": "listings", "lstset": "listings", "lstlisting": "listings", "lstinputlisting": "listings",
        "tikz": "tikz", "tikzpicture": "tikz", "usetikzlibrary": "tikz", "draw": "tikz", "node": "tikz",
        "subcaption": "subcaption", "subfigure": "subcaption", "captionof": "caption", "captionsetup": "caption",
        "cref": "cleveref", "Cref": "cleveref", "geometry": "geometry", "newgeometry": "geometry",
        "todo": "todonotes", "listoftodos": "todonotes", "lipsum": "lipsum", "blindtext": "blindtext",
        "citep": "natbib", "citet": "natbib", "citeauthor": "natbib", "parencite": "biblatex", "textcite": "biblatex", "printbibliography": "biblatex", "addbibresource": "biblatex",
        "algorithm": "algorithm", "algorithmic": "algpseudocode", "State": "algpseudocode", "Require": "algpseudocode", "Ensure": "algpseudocode",
        "enumerate*": "enumitem", "setlist": "enumitem", "wrapfigure": "wrapfig", "multicols": "multicol",
        "minted": "minted", "mintinline": "minted", "verbatiminput": "verbatim", "comment": "verbatim",
        "tabularx": "tabularx", "longtable": "longtable", "makecell": "makecell", "xspace": "xspace",
        "fancyhead": "fancyhdr", "fancyfoot": "fancyhdr", "pagestyle{fancy}": "fancyhdr", "doublespacing": "setspace", "onehalfspacing": "setspace",
        "bm": "bm", "mathscr": "mathrsfs", "cancel": "cancel", "ce": "mhchem", "qty*": "physics", "dv": "physics", "pdv": "physics", "ket": "braket", "bra": "braket",
        "FloatBarrier": "placeins", "sout": "ulem", "uline": "ulem", "hl": "soul", "euro": "eurosym", "degree": "gensymb", "celsius": "gensymb",
        "faGithub": "fontawesome5", "faEnvelope": "fontawesome5", "faPhone": "fontawesome5", "faLinkedin": "fontawesome5",
    ]

    public static func advise(_ issue: CompileIssue) -> Advice? {
        let m = issue.message
        let ctx = issue.context ?? ""

        if m.hasPrefix("Undefined control sequence") {
            let cmd = lastCommand(in: ctx)
            if let cmd, let pkg = packageFor[cmd] {
                return Advice(title: "\\\(cmd) needs the \(pkg) package",
                              explanation: "LaTeX doesn't know \\\(cmd) until \\usepackage{\(pkg)} is in the preamble.",
                              fix: .addPackage(name: pkg, options: nil), fixLabel: "Add \\usepackage{\(pkg)}")
            }
            return Advice(title: cmd.map { "Unknown command \\\($0)" } ?? "Unknown command",
                          explanation: "LaTeX doesn't recognise \(cmd.map { "\\\($0)" } ?? "a command") on this line. Check the spelling, or load the package that defines it.",
                          fix: nil, fixLabel: nil)
        }
        if let env = capture(#"Environment (\S+) undefined"#, m) {
            if let pkg = packageFor[env] {
                return Advice(title: "The \(env) environment needs \(pkg)", explanation: "Add \\usepackage{\(pkg)} to use \\begin{\(env)}.",
                              fix: .addPackage(name: pkg, options: nil), fixLabel: "Add \\usepackage{\(pkg)}")
            }
            return Advice(title: "Unknown environment \(env)", explanation: "No package defines \\begin{\(env)}. Check the spelling or define it with \\newenvironment.", fix: nil, fixLabel: nil)
        }
        if let file = capture(#"File [`']([^']+)' not found"#, m) {
            if file.hasSuffix(".sty") || file.hasSuffix(".cls") {
                return Advice(title: "Package \(file) isn't available",
                              explanation: "The engine couldn't download \(file). Check the name, and that you're online for the first compile that uses it.",
                              fix: nil, fixLabel: nil)
            }
            return Advice(title: "Missing file \(file)", explanation: "The file isn't in the project folder at that path. Paths are relative to the main file.", fix: nil, fixLabel: nil)
        }
        if m.hasPrefix("Missing $ inserted") {
            return Advice(title: "Math symbol outside math mode",
                          explanation: "Symbols like _, ^, \\alpha or \\frac only work inside $…$. Wrap the expression in $ $, or escape a literal underscore as \\_.",
                          fix: nil, fixLabel: nil)
        }
        if m.hasPrefix("Missing } inserted") || m.hasPrefix("Extra }") || m.hasPrefix("Too many }'s") || m.hasPrefix("Missing { inserted") {
            return Advice(title: "Unbalanced braces", explanation: "A { has no matching } (or the other way round) near this line. Matching braces are highlighted when the caret is next to one.", fix: nil, fixLabel: nil)
        }
        if let pair = captures(#"\\begin\{([^}]+)\} on input line (\d+) ended by \\end\{([^}]+)\}"#, m), pair.count == 3 {
            return Advice(title: "\\begin{\(pair[0])} is never closed",
                          explanation: "The environment opened on line \(pair[1]) needs \\end{\(pair[0])} before \\end{\(pair[2])}.",
                          fix: nil, fixLabel: nil)
        }
        if m.hasPrefix("Misplaced alignment tab character &") {
            return Advice(title: "Stray &", explanation: "& separates columns only inside tabular, align or matrix. Use \\& for an ampersand in text.", fix: nil, fixLabel: nil)
        }
        if m.hasPrefix("Double subscript") || m.hasPrefix("Double superscript") {
            return Advice(title: "Two subscripts in a row", explanation: "Write x_{ij} instead of x_i_j (group with braces).", fix: nil, fixLabel: nil)
        }
        if m.hasPrefix("Paragraph ended before") {
            return Advice(title: "An argument runs into a blank line", explanation: "A command's {…} argument isn't closed before the paragraph break.", fix: nil, fixLabel: nil)
        }
        if m.hasPrefix("There's no line here to end") {
            return Advice(title: "\\\\ with nothing before it", explanation: "Use a blank line to start a new paragraph instead of \\\\ at the start of one.", fix: nil, fixLabel: nil)
        }
        if m.contains("Missing \\begin{document}") {
            return Advice(title: "Text before \\begin{document}", explanation: "Only setup commands may appear in the preamble. Move this text below \\begin{document}.", fix: nil, fixLabel: nil)
        }
        if m.hasPrefix("Option clash for package") {
            return Advice(title: "Package loaded twice with different options", explanation: "Load the package once, with all options, or pass options via \\PassOptionsToPackage before \\documentclass.", fix: nil, fixLabel: nil)
        }
        if m.hasPrefix("Missing number") || m.hasPrefix("Illegal unit") {
            return Advice(title: "A length or number is expected", explanation: "Lengths need units (e.g. 2cm, 0.5\\textwidth).", fix: nil, fixLabel: nil)
        }
        if m.hasPrefix("Runaway argument") {
            return Advice(title: "Unclosed argument", explanation: "A { … } argument is never closed.", fix: nil, fixLabel: nil)
        }
        if m.hasPrefix("Can be used only in preamble") {
            return Advice(title: "Preamble-only command", explanation: "Move this command above \\begin{document}.", fix: nil, fixLabel: nil)
        }
        if let key = capture(#"Citation [`']([^']+)' (on page \d+ )?undefined"#, m) {
            return Advice(title: "No bibliography entry \(key)", explanation: "Add an entry with this key to a .bib file (Citations panel → Add from DOI or arXiv), and make sure the document has \\bibliography{…} or \\printbibliography.", fix: nil, fixLabel: nil)
        }
        if let key = capture(#"Reference [`']([^']+)' (on page \d+ )?undefined"#, m) {
            return Advice(title: "No \\label{\(key)}", explanation: "Nothing in the project has \\label{\(key)}. Check the spelling. Labels are suggested as you type \\ref{.", fix: nil, fixLabel: nil)
        }
        if m.hasPrefix("There were undefined references") {
            return Advice(title: "Some \\ref or \\cite targets are missing", explanation: "They show as ?? in the PDF. Each one is listed separately below.", fix: nil, fixLabel: nil)
        }
        if m.hasPrefix("Overfull \\hbox") {
            return Advice(title: "A line sticks into the margin", explanation: "Usually a long word, URL or wide table/figure. Allow a break with \\- or \\allowbreak, use \\url{…}, or scale the figure to \\linewidth.", fix: nil, fixLabel: nil)
        }
        if m.hasPrefix("Underfull \\hbox") {
            return Advice(title: "A line is stretched", explanation: "Often caused by \\\\ after a paragraph or a forced break. Usually harmless.", fix: nil, fixLabel: nil)
        }
        if m.contains("Float too large") {
            return Advice(title: "Figure or table taller than the page", explanation: "Scale it down, e.g. \\includegraphics[width=\\linewidth]{…}.", fix: nil, fixLabel: nil)
        }
        if m.contains("Font") && m.contains("not") && m.contains("found") {
            return Advice(title: "Font not installed", explanation: "fontspec can only use fonts installed on this Mac (Font Book) or shipped with TeX.", fix: nil, fixLabel: nil)
        }
        return nil
    }

    /// The last `\command` in TeX's error context ("l.3 Hi \foo" → "foo").
    static func lastCommand(in context: String) -> String? {
        let re = try! NSRegularExpression(pattern: #"\\([A-Za-z@]+)"#)
        let ns = context as NSString
        guard let m = re.matches(in: context, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    static func capture(_ p: String, _ s: String) -> String? { captures(p, s)?.first }

    static func captures(_ p: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: p),
              let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { m.range(at: $0).location == NSNotFound ? nil : (s as NSString).substring(with: m.range(at: $0)) }
    }
}
