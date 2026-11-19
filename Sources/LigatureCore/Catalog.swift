import Foundation

/// A math or text symbol shown in the Symbols panel.
public struct LaTeXSymbol: Identifiable, Hashable, Sendable {
    public var id: String { command }
    public var command: String
    public var glyph: String
    public var name: String
    public var package: String?
    public var category: String
}

/// An autocompletion candidate. `snippet` uses `$1`, `$2`… for tab stops and `$0` for the final caret.
public struct CompletionItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case command, environment, label, citation, file, symbol, package, snippet }
    public var id: String { "\(kind.rawValue):\(label)" }
    public var kind: Kind
    public var label: String
    public var detail: String
    public var snippet: String
    public var glyph: String?

    public init(kind: Kind, label: String, detail: String, snippet: String, glyph: String? = nil) {
        self.kind = kind; self.label = label; self.detail = detail; self.snippet = snippet; self.glyph = glyph
    }
}

public enum Catalog {
    // MARK: Symbols

    public static let symbolCategories = ["Greek", "Operators", "Relations", "Arrows", "Sets & Logic", "Delimiters", "Accents", "Misc", "Text"]

    public static let symbols: [LaTeXSymbol] = {
        var out: [LaTeXSymbol] = []
        func add(_ cat: String, _ list: [(String, String, String)], package: String? = nil) {
            for (cmd, g, n) in list { out.append(LaTeXSymbol(command: cmd, glyph: g, name: n, package: package, category: cat)) }
        }
        add("Greek", [
            ("\\alpha", "α", "alpha"), ("\\beta", "β", "beta"), ("\\gamma", "γ", "gamma"), ("\\delta", "δ", "delta"),
            ("\\epsilon", "ϵ", "epsilon"), ("\\varepsilon", "ε", "varepsilon"), ("\\zeta", "ζ", "zeta"), ("\\eta", "η", "eta"),
            ("\\theta", "θ", "theta"), ("\\vartheta", "ϑ", "vartheta"), ("\\iota", "ι", "iota"), ("\\kappa", "κ", "kappa"),
            ("\\lambda", "λ", "lambda"), ("\\mu", "μ", "mu"), ("\\nu", "ν", "nu"), ("\\xi", "ξ", "xi"), ("\\pi", "π", "pi"),
            ("\\varpi", "ϖ", "varpi"), ("\\rho", "ρ", "rho"), ("\\varrho", "ϱ", "varrho"), ("\\sigma", "σ", "sigma"),
            ("\\varsigma", "ς", "varsigma"), ("\\tau", "τ", "tau"), ("\\upsilon", "υ", "upsilon"), ("\\phi", "ϕ", "phi"),
            ("\\varphi", "φ", "varphi"), ("\\chi", "χ", "chi"), ("\\psi", "ψ", "psi"), ("\\omega", "ω", "omega"),
            ("\\Gamma", "Γ", "Gamma"), ("\\Delta", "Δ", "Delta"), ("\\Theta", "Θ", "Theta"), ("\\Lambda", "Λ", "Lambda"),
            ("\\Xi", "Ξ", "Xi"), ("\\Pi", "Π", "Pi"), ("\\Sigma", "Σ", "Sigma"), ("\\Upsilon", "Υ", "Upsilon"),
            ("\\Phi", "Φ", "Phi"), ("\\Psi", "Ψ", "Psi"), ("\\Omega", "Ω", "Omega"),
        ])
        add("Operators", [
            ("\\sum", "∑", "sum"), ("\\prod", "∏", "product"), ("\\coprod", "∐", "coproduct"), ("\\int", "∫", "integral"),
            ("\\iint", "∬", "double integral"), ("\\iiint", "∭", "triple integral"), ("\\oint", "∮", "contour integral"),
            ("\\bigcup", "⋃", "big union"), ("\\bigcap", "⋂", "big intersection"), ("\\bigoplus", "⨁", "big direct sum"),
            ("\\bigotimes", "⨂", "big tensor"), ("\\times", "×", "times"), ("\\div", "÷", "divide"), ("\\cdot", "⋅", "dot"),
            ("\\pm", "±", "plus-minus"), ("\\mp", "∓", "minus-plus"), ("\\ast", "∗", "asterisk"), ("\\star", "⋆", "star"),
            ("\\circ", "∘", "compose"), ("\\bullet", "∙", "bullet"), ("\\oplus", "⊕", "direct sum"), ("\\otimes", "⊗", "tensor"),
            ("\\odot", "⊙", "circled dot"), ("\\wedge", "∧", "wedge"), ("\\vee", "∨", "vee"), ("\\nabla", "∇", "nabla"),
            ("\\partial", "∂", "partial"), ("\\sqrt{x}", "√", "square root"), ("\\frac{a}{b}", "⁄", "fraction"),
            ("\\lim", "lim", "limit"), ("\\max", "max", "max"), ("\\min", "min", "min"), ("\\log", "log", "log"), ("\\exp", "exp", "exp"),
        ])
        add("Relations", [
            ("\\leq", "≤", "less or equal"), ("\\geq", "≥", "greater or equal"), ("\\neq", "≠", "not equal"),
            ("\\approx", "≈", "approximately"), ("\\equiv", "≡", "equivalent"), ("\\sim", "∼", "similar"),
            ("\\simeq", "≃", "similar equal"), ("\\cong", "≅", "congruent"), ("\\propto", "∝", "proportional"),
            ("\\ll", "≪", "much less"), ("\\gg", "≫", "much greater"), ("\\prec", "≺", "precedes"), ("\\succ", "≻", "succeeds"),
            ("\\perp", "⊥", "perpendicular"), ("\\parallel", "∥", "parallel"), ("\\mid", "∣", "divides"),
            ("\\models", "⊨", "models"), ("\\vdash", "⊢", "proves"), ("\\doteq", "≐", "dot equal"), ("\\asymp", "≍", "asymptotic"),
        ])
        add("Arrows", [
            ("\\to", "→", "to"), ("\\gets", "←", "gets"), ("\\leftrightarrow", "↔", "left-right"), ("\\Rightarrow", "⇒", "implies"),
            ("\\Leftarrow", "⇐", "implied by"), ("\\Leftrightarrow", "⇔", "iff"), ("\\mapsto", "↦", "maps to"),
            ("\\longrightarrow", "⟶", "long right"), ("\\Longrightarrow", "⟹", "long implies"), ("\\iff", "⟺", "iff (long)"),
            ("\\uparrow", "↑", "up"), ("\\downarrow", "↓", "down"), ("\\updownarrow", "↕", "up-down"), ("\\nearrow", "↗", "north-east"),
            ("\\searrow", "↘", "south-east"), ("\\hookrightarrow", "↪", "hook right"), ("\\rightharpoonup", "⇀", "harpoon"),
            ("\\rightleftharpoons", "⇌", "equilibrium"), ("\\leadsto", "⇝", "leads to"),
        ])
        add("Sets & Logic", [
            ("\\in", "∈", "element of"), ("\\notin", "∉", "not element of"), ("\\ni", "∋", "contains"), ("\\subset", "⊂", "subset"),
            ("\\subseteq", "⊆", "subset or equal"), ("\\supset", "⊃", "superset"), ("\\supseteq", "⊇", "superset or equal"),
            ("\\cup", "∪", "union"), ("\\cap", "∩", "intersection"), ("\\setminus", "∖", "set minus"), ("\\emptyset", "∅", "empty set"),
            ("\\forall", "∀", "for all"), ("\\exists", "∃", "exists"), ("\\nexists", "∄", "not exists"), ("\\neg", "¬", "not"),
            ("\\land", "∧", "and"), ("\\lor", "∨", "or"), ("\\top", "⊤", "top"), ("\\bot", "⊥", "bottom"),
        ])
        add("Sets & Logic", [
            ("\\mathbb{R}", "ℝ", "reals"), ("\\mathbb{N}", "ℕ", "naturals"), ("\\mathbb{Z}", "ℤ", "integers"),
            ("\\mathbb{Q}", "ℚ", "rationals"), ("\\mathbb{C}", "ℂ", "complex"), ("\\varnothing", "∅", "empty set (var)"),
            ("\\therefore", "∴", "therefore"), ("\\because", "∵", "because"),
        ], package: "amssymb")
        add("Delimiters", [
            ("\\langle", "⟨", "left angle"), ("\\rangle", "⟩", "right angle"), ("\\lfloor", "⌊", "left floor"), ("\\rfloor", "⌋", "right floor"),
            ("\\lceil", "⌈", "left ceiling"), ("\\rceil", "⌉", "right ceiling"), ("\\{", "{", "left brace"), ("\\}", "}", "right brace"),
            ("\\|", "‖", "norm"), ("\\left( \\right)", "( )", "auto-size parens"),
        ])
        add("Accents", [
            ("\\hat{x}", "x̂", "hat"), ("\\bar{x}", "x̄", "bar"), ("\\vec{x}", "x⃗", "vector"), ("\\dot{x}", "ẋ", "dot"),
            ("\\ddot{x}", "ẍ", "double dot"), ("\\tilde{x}", "x̃", "tilde"), ("\\overline{xy}", "x̅y̅", "overline"),
            ("\\widehat{xy}", "x̂y", "wide hat"), ("\\underbrace{x}_{n}", "⏟", "underbrace"), ("\\overbrace{x}^{n}", "⏞", "overbrace"),
        ])
        add("Misc", [
            ("\\infty", "∞", "infinity"), ("\\hbar", "ℏ", "h-bar"), ("\\ell", "ℓ", "ell"), ("\\Re", "ℜ", "real part"),
            ("\\Im", "ℑ", "imaginary part"), ("\\aleph", "ℵ", "aleph"), ("\\angle", "∠", "angle"), ("\\triangle", "△", "triangle"),
            ("\\cdots", "⋯", "centred dots"), ("\\ldots", "…", "dots"), ("\\vdots", "⋮", "vertical dots"), ("\\ddots", "⋱", "diagonal dots"),
            ("\\prime", "′", "prime"), ("\\dagger", "†", "dagger"), ("\\clubsuit", "♣", "club"), ("\\heartsuit", "♡", "heart"),
            ("\\checkmark", "✓", "check"), ("\\square", "□", "square"), ("\\blacksquare", "■", "QED"),
        ])
        add("Text", [
            ("\\textbf{}", "B", "bold"), ("\\textit{}", "I", "italic"), ("\\underline{}", "U̲", "underline"), ("\\texttt{}", "T", "monospace"),
            ("\\textsc{}", "Sᴄ", "small caps"), ("\\emph{}", "E", "emphasis"), ("\\S", "§", "section sign"), ("\\P", "¶", "pilcrow"),
            ("\\copyright", "©", "copyright"), ("\\textregistered", "®", "registered"), ("\\texttrademark", "™", "trademark"),
            ("\\pounds", "£", "pound"), ("\\euro", "€", "euro"), ("---", "\u{2014}", "em dash"), ("--", "–", "en dash"), ("``''", "“”", "quotes"),
            ("\\&", "&", "ampersand"), ("\\%", "%", "percent"), ("\\$", "$", "dollar"), ("\\#", "#", "hash"), ("\\_", "_", "underscore"),
        ])
        return out
    }()

    // MARK: Commands and environments

    public static let environments: [(name: String, detail: String, body: String)] = [
        ("equation", "Numbered equation", "$1"), ("equation*", "Unnumbered equation", "$1"),
        ("align", "Aligned equations", "$1 &= $2 \\\\\n\t$3 &= $4"), ("align*", "Aligned, unnumbered", "$1 &= $2"),
        ("gather", "Centred equations", "$1"), ("cases", "Piecewise", "$1 & \\text{if } $2 \\\\\n\t$3 & \\text{otherwise}"),
        ("itemize", "Bulleted list", "\\item $1"), ("enumerate", "Numbered list", "\\item $1"),
        ("description", "Description list", "\\item[$1] $2"),
        ("figure", "Figure", "\\centering\n\t\\includegraphics[width=0.8\\linewidth]{$1}\n\t\\caption{$2}\n\t\\label{fig:$3}"),
        ("table", "Table", "\\centering\n\t\\caption{$1}\n\t\\label{tab:$2}\n\t\\begin{tabular}{$3}\n\t\t$0\n\t\\end{tabular}"),
        ("tabular", "Table body", "$1"), ("center", "Centred block", "$1"), ("minipage", "Mini page", "$1"),
        ("theorem", "Theorem", "$1"), ("lemma", "Lemma", "$1"), ("proof", "Proof", "$1"), ("definition", "Definition", "$1"),
        ("abstract", "Abstract", "$1"), ("quote", "Quotation", "$1"), ("verbatim", "Verbatim text", "$1"),
        ("frame", "Beamer slide", "\\frametitle{$1}\n\t$0"), ("columns", "Beamer columns", "\\column{0.5\\textwidth}\n\t$1"),
        ("tikzpicture", "TikZ drawing", "$1"), ("lstlisting", "Code listing", "$1"), ("pmatrix", "Matrix ( )", "$1 & $2 \\\\ $3 & $4"),
        ("bmatrix", "Matrix [ ]", "$1 & $2 \\\\ $3 & $4"), ("subfigure", "Sub-figure", "$1"), ("thebibliography", "Manual bibliography", "\\bibitem{$1} $2"),
    ]

    public static let commands: [CompletionItem] = {
        let list: [(String, String, String)] = [
            ("section", "Section", "\\section{$1}"), ("subsection", "Subsection", "\\subsection{$1}"),
            ("subsubsection", "Subsubsection", "\\subsubsection{$1}"), ("chapter", "Chapter", "\\chapter{$1}"),
            ("paragraph", "Paragraph heading", "\\paragraph{$1}"), ("section*", "Unnumbered section", "\\section*{$1}"),
            ("textbf", "Bold", "\\textbf{$1}"), ("textit", "Italic", "\\textit{$1}"), ("emph", "Emphasis", "\\emph{$1}"),
            ("underline", "Underline", "\\underline{$1}"), ("texttt", "Monospace", "\\texttt{$1}"), ("textsc", "Small caps", "\\textsc{$1}"),
            ("frac", "Fraction", "\\frac{$1}{$2}"), ("dfrac", "Display fraction", "\\dfrac{$1}{$2}"), ("sqrt", "Square root", "\\sqrt{$1}"),
            ("sum", "Sum", "\\sum_{$1}^{$2}"), ("int", "Integral", "\\int_{$1}^{$2}"), ("prod", "Product", "\\prod_{$1}^{$2}"),
            ("lim", "Limit", "\\lim_{$1 \\to $2}"), ("left(", "Auto-size parentheses", "\\left( $1 \\right)"),
            ("mathbb", "Blackboard bold", "\\mathbb{$1}"), ("mathcal", "Calligraphic", "\\mathcal{$1}"), ("mathrm", "Upright", "\\mathrm{$1}"),
            ("mathbf", "Bold math", "\\mathbf{$1}"), ("text", "Text in math", "\\text{$1}"), ("operatorname", "Operator", "\\operatorname{$1}"),
            ("label", "Label", "\\label{$1}"), ("ref", "Reference", "\\ref{$1}"), ("eqref", "Equation reference", "\\eqref{$1}"),
            ("cite", "Citation", "\\cite{$1}"), ("citep", "Parenthetical citation", "\\citep{$1}"), ("citet", "Textual citation", "\\citet{$1}"),
            ("footnote", "Footnote", "\\footnote{$1}"), ("url", "URL", "\\url{$1}"), ("href", "Link", "\\href{$1}{$2}"),
            ("includegraphics", "Image", "\\includegraphics[width=\\linewidth]{$1}"), ("caption", "Caption", "\\caption{$1}"),
            ("input", "Include file", "\\input{$1}"), ("include", "Include chapter", "\\include{$1}"),
            ("usepackage", "Load package", "\\usepackage{$1}"), ("documentclass", "Document class", "\\documentclass{$1}"),
            ("newcommand", "Define command", "\\newcommand{\\$1}{$2}"), ("renewcommand", "Redefine command", "\\renewcommand{\\$1}{$2}"),
            ("item", "List item", "\\item $1"), ("maketitle", "Title block", "\\maketitle"), ("tableofcontents", "Table of contents", "\\tableofcontents"),
            ("title", "Title", "\\title{$1}"), ("author", "Author", "\\author{$1}"), ("date", "Date", "\\date{$1}"),
            ("bibliography", "Bibliography file", "\\bibliography{$1}"), ("bibliographystyle", "Bibliography style", "\\bibliographystyle{${1:plain}}"),
            ("printbibliography", "Print bibliography (biblatex)", "\\printbibliography"), ("addbibresource", "Bib file (biblatex)", "\\addbibresource{$1}"),
            ("hspace", "Horizontal space", "\\hspace{$1}"), ("vspace", "Vertical space", "\\vspace{$1}"), ("newpage", "New page", "\\newpage"),
            ("clearpage", "Clear page", "\\clearpage"), ("noindent", "No indent", "\\noindent"), ("centering", "Centre", "\\centering"),
            ("toprule", "Top rule", "\\toprule"), ("midrule", "Middle rule", "\\midrule"), ("bottomrule", "Bottom rule", "\\bottomrule"),
            ("hline", "Horizontal line", "\\hline"), ("multicolumn", "Span columns", "\\multicolumn{$1}{c}{$2}"),
            ("textcolor", "Coloured text", "\\textcolor{$1}{$2}"), ("todo", "Todo note", "\\todo{$1}"), ("frametitle", "Slide title", "\\frametitle{$1}"),
            ("overline", "Overline", "\\overline{$1}"), ("hat", "Hat", "\\hat{$1}"), ("vec", "Vector", "\\vec{$1}"), ("bar", "Bar", "\\bar{$1}"),
            ("cdot", "Dot", "\\cdot"), ("ldots", "Dots", "\\ldots"), ("cdots", "Centred dots", "\\cdots"), ("quad", "Space", "\\quad"),
            ("SI", "Quantity", "\\SI{$1}{$2}"), ("binom", "Binomial", "\\binom{$1}{$2}"), ("boxed", "Boxed", "\\boxed{$1}"),
        ]
        var items = list.map { CompletionItem(kind: .command, label: "\\" + $0.0, detail: $0.1, snippet: $0.2) }
        items.append(CompletionItem(kind: .environment, label: "\\begin", detail: "Environment", snippet: "\\begin{$1}\n\t$0\n\\end{$1}"))
        for s in symbols where s.command.hasPrefix("\\") && !list.contains(where: { "\\" + $0.0 == s.command }) {
            let name = s.command.split(separator: "{").first.map(String.init) ?? s.command
            if items.contains(where: { $0.label == name }) { continue }
            let snippet = s.command.replacingOccurrences(of: "{x}", with: "{$1}").replacingOccurrences(of: "{xy}", with: "{$1}")
                .replacingOccurrences(of: "{}", with: "{$1}").replacingOccurrences(of: "{a}{b}", with: "{$1}{$2}")
            items.append(CompletionItem(kind: .symbol, label: name, detail: s.name, snippet: snippet, glyph: s.glyph))
        }
        return items
    }()

    public static let packages: [(String, String)] = [
        ("amsmath", "Advanced math"), ("amssymb", "Math symbols"), ("amsthm", "Theorems"), ("graphicx", "Images"),
        ("hyperref", "Links"), ("booktabs", "Nice tables"), ("geometry", "Page margins"), ("xcolor", "Colours"),
        ("tikz", "Drawings"), ("siunitx", "Units"), ("cleveref", "Smart references"), ("natbib", "Citations"),
        ("biblatex", "Modern bibliography"), ("listings", "Code"), ("enumitem", "List layout"), ("caption", "Captions"),
        ("subcaption", "Sub-figures"), ("float", "Float placement"), ("multirow", "Merged rows"), ("fontspec", "System fonts"),
        ("microtype", "Better typography"), ("lipsum", "Placeholder text"), ("fancyhdr", "Headers/footers"), ("setspace", "Line spacing"),
        ("algorithm", "Algorithms"), ("algpseudocode", "Pseudocode"), ("todonotes", "Todo notes"), ("tabularx", "Flexible tables"),
        ("physics", "Physics notation"), ("mhchem", "Chemistry"), ("babel", "Languages"), ("csquotes", "Quotes"), ("pgfplots", "Plots"),
    ]
}
