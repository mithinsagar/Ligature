import XCTest
@testable import LigatureCore

final class CoreTests: XCTestCase {
    func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTectonicStderrAndLog() throws {
        let stderr = """
        note: Running TeX ...
        error: bad.tex:3: Undefined control sequence
        error: bad.tex:6: LaTeX Error: \\begin{itemize} on input line 4 ended by \\end{document}.
        warning: main.tex:9: Requested font "[TeXGyreTermesX-Regular.otf]/OT" at 10.00003pt
        """
        let issues = LogParser.parse(stderr: stderr, log: try fixture("bad.log"), mainFile: "bad.tex")
        let errors = issues.filter { $0.severity == .error }
        XCTAssertEqual(errors.count, 2)
        XCTAssertEqual(errors[0].line, 3)
        XCTAssertEqual(errors[0].file, "bad.tex")
        XCTAssertEqual(errors[0].context, "Hi \\foo")
        XCTAssertFalse(issues.contains { $0.message.contains("Requested font") })
        let advice = try XCTUnwrap(ErrorAdvisor.advise(errors[0]))
        XCTAssertTrue(advice.title.contains("\\foo"))
        XCTAssertTrue(ErrorAdvisor.advise(errors[1])!.title.contains("itemize"))
    }

    func testPackageAdvice() {
        let issue = CompileIssue(severity: .error, file: "main.tex", line: 4, message: "Undefined control sequence", context: "$\\mathbb")
        let a = ErrorAdvisor.advise(issue)
        XCTAssertEqual(a?.fix, .addPackage(name: "amssymb", options: nil))
        let text = "\\documentclass{article}\n\\usepackage{amsmath}\n\\begin{document}\nx\n\\end{document}"
        let added = LaTeXText.addingPackage("amssymb", to: text)
        XCTAssertEqual(added?.line, 3)
        XCTAssertTrue(added!.text.contains("\\usepackage{amsmath}\n\\usepackage{amssymb}"))
        XCTAssertNil(LaTeXText.addingPackage("amsmath", to: text))
    }

    func testLogWarnings() {
        let log = """
        (./main.tex
        LaTeX Warning: Reference `eq:b' on page 1 undefined on input line 9.

        Overfull \\hbox (12.3pt too wide) in paragraph at lines 14--16
        (./chapters/intro.tex
        LaTeX Warning: Citation `knuth' on page 2 undefined on input line 3.
        )
        )
        """
        let issues = LogParser.parse(stderr: "", log: log, mainFile: "main.tex")
        XCTAssertEqual(issues.count, 3)
        let cite = issues.first { $0.message.contains("knuth") }
        XCTAssertEqual(cite?.file, "chapters/intro.tex")
        XCTAssertEqual(cite?.line, 3)
        let box = issues.first { $0.severity == .badBox }
        XCTAssertEqual(box?.line, 14)
        XCTAssertEqual(box?.file, "main.tex")
    }

    func testSyncTeXRoundTrip() throws {
        let s = try XCTUnwrap(SyncTeX(text: try fixture("main.synctex")))
        let pageHeight = 792.0
        // Line 5 is the "Hello world" paragraph.
        let fwd = try XCTUnwrap(s.forward(file: "main.tex", line: 5, pageHeight: { _ in pageHeight }))
        XCTAssertEqual(fwd.page, 1)
        let r = try XCTUnwrap(fwd.rects.first)
        // Article body text starts ~1.86in from the left (134pt) near the top of the page.
        XCTAssertEqual(r.minX, 133.8, accuracy: 2)
        XCTAssertGreaterThan(r.minY, 600)
        let back = try XCTUnwrap(s.inverse(page: 1, point: CGPoint(x: r.midX, y: r.midY), pageHeight: pageHeight))
        XCTAssertTrue(back.file.hasSuffix("main.tex"))
        XCTAssertTrue((5...6).contains(back.line), "got \(back.line)")
        // The equation (line 7) maps somewhere below the paragraph.
        let eq = try XCTUnwrap(s.forward(file: "main.tex", line: 7, pageHeight: { _ in pageHeight }))
        XCTAssertLessThan(eq.rects[0].minY, r.minY)
    }

    func testOutline() {
        let text = """
        \\section{Intro}\\label{sec:intro}
        % TODO: tighten this
        \\subsection*[Short]{A \\textbf{long} title}
        \\begin{figure}
        \\caption{A cat}
        \\label{fig:cat}
        \\end{figure}
        \\input{chapters/two}
        """
        let items = Outline.items(in: text, file: "main.tex")
        XCTAssertEqual(items.first?.title, "Intro")
        XCTAssertEqual(items.first?.label, "sec:intro")
        XCTAssertTrue(items.contains { $0.kind == .todo && $0.title == "tighten this" })
        XCTAssertTrue(items.contains { $0.kind == .subsection && $0.title == "Short" })
        XCTAssertTrue(items.contains { $0.kind == .figure && $0.title == "A cat" && $0.label == "fig:cat" })
        let project = Outline.project(main: "main.tex") { $0 == "main.tex" ? text : ($0 == "chapters/two.tex" ? "\\section{Two}" : nil) }
        XCTAssertTrue(project.contains { $0.title == "Two" && $0.file == "chapters/two.tex" })
    }

    func testBibTeX() {
        let bib = """
        @article{lecun2015deep,
          title = {Deep {L}earning},
          author = "LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey",
          year = 2015,
          journal = {Nature}
        }
        @comment{ignored}
        @misc{x, title={T}}
        """
        let e = BibTeX.parse(bib, file: "r.bib")
        XCTAssertEqual(e.map(\.key), ["lecun2015deep", "x"])
        XCTAssertEqual(e[0].title, "Deep Learning")
        XCTAssertEqual(e[0].year, "2015")
        XCTAssertEqual(e[0].authorsShort, "LeCun et al.")
        XCTAssertEqual(e[1].line, 8)
        XCTAssertEqual(BibTeX.suggestKey(author: "Vaswani, Ashish and Shazeer, Noam", year: "2017", title: "Attention Is All You Need"), "vaswani2017attention")
    }

    func testTables() throws {
        var t = try XCTUnwrap(TableModel.parse(delimited: "Name\tScore\nAda\t92.5\nAlan\t88"))
        XCTAssertEqual(t.rows, 3)
        XCTAssertEqual(t.align, [.l, .r])
        t.caption = "Scores"; t.label = "tab:s"
        let code = t.latex()
        XCTAssertTrue(code.contains("\\toprule"))
        XCTAssertTrue(code.contains("Name & Score \\\\"))
        let back = try XCTUnwrap(TableModel.parse(latex: code))
        XCTAssertEqual(back.cells, t.cells)
        XCTAssertEqual(back.caption, "Scores")
        XCTAssertEqual(back.style, .booktabs)
        XCTAssertEqual(TableModel.parse(delimited: "a,\"b, c\"\n1,2")?.cells[0], ["a", "b, c"])
    }

    func testTextHelpers() {
        let doc = "\\documentclass{article}\n\\begin{document}\nHello \\textbf{bold} world $x^2$ % comment\n\\cite{a} done.\n\\end{document}"
        XCTAssertEqual(LaTeXText.wordCount(doc), 4)
        let ns = "See \\cite{alpha, beta} and \\ref{eq:1}." as NSString
        XCTAssertEqual(LaTeXText.token(at: 18, in: ns), .argument(command: "cite", value: "beta", range: NSRange(location: 16, length: 5)))
        if case .argument(let c, let v, _) = LaTeXText.token(at: 34, in: ns) { XCTAssertEqual(c, "ref"); XCTAssertEqual(v, "eq:1") } else { XCTFail() }
        let math = "Inline $a+b$ and \\begin{align}x &= 1\\label{e}\\end{align}" as NSString
        XCTAssertEqual(LaTeXText.math(at: 9, in: math)?.content, "a+b")
        let m2 = LaTeXText.math(at: 33, in: math)
        XCTAssertEqual(m2?.display, true)
        XCTAssertEqual(m2?.content, "\\begin{align}x &= 1\\end{align}")
        XCTAssertNil(LaTeXText.math(at: 2, in: math))
        let eq = "\\begin{equation}\n  x = 1\n  \\label{eq:a}\n\\end{equation}" as NSString
        XCTAssertFalse(LaTeXText.math(at: 20, in: eq)!.content.contains("\n\n"))
        XCTAssertEqual(LaTeXText.stripComments("a % x\n% whole\nb \\% c"), "a %\nb \\% c")
        XCTAssertEqual(LaTeXText.openEnvironments(before: 30, in: "\\begin{itemize}\\begin{enumerate}\\end{enumerate}x" as NSString), ["itemize"])
        XCTAssertEqual(LaTeXText.range(ofLine: 2, in: "ab\ncd\nef" as NSString), NSRange(location: 3, length: 2))
        XCTAssertEqual(LaTeXText.lineNumber(at: 4, in: "ab\ncd\nef" as NSString), 2)
    }

    func testFuzzyAndDiff() {
        XCTAssertNotNil(Fuzzy.score("intr", "Introduction"))
        XCTAssertNil(Fuzzy.score("xyz", "Introduction"))
        XCTAssertGreaterThan(Fuzzy.score("sec", "Section")!, Fuzzy.score("sec", "Subsection: else")!)
        let d = LineDiff.diff(old: "a\nb\nc", new: "a\nB\nc\nd")
        XCTAssertEqual(d.filter { $0.kind == .added }.map(\.text), ["B", "d"])
        XCTAssertEqual(d.filter { $0.kind == .removed }.map(\.text), ["b"])
    }

    func testCatalogSnippets() {
        XCTAssertTrue(Catalog.commands.contains { $0.label == "\\frac" && $0.snippet == "\\frac{$1}{$2}" })
        XCTAssertTrue(Catalog.environments.contains { $0.name == "align" && $0.body.contains("\\\\\n") })
        XCTAssertGreaterThan(Catalog.symbols.count, 150)
    }
}
