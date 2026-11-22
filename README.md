# Ligature

A native macOS LaTeX editor: write on the left, see the typeset PDF update on the right.

![Ligature: LaTeX, typeset as you write](docs/screenshots/01-hero.jpg)

<table>
<tr><td><img src="docs/screenshots/02-visual-mode.jpg" alt="Visual mode"></td><td><img src="docs/screenshots/03-equation-preview.jpg" alt="Live equation preview"></td></tr>
<tr><td><img src="docs/screenshots/04-checks-as-you-type.jpg" alt="Checks as you type"></td><td><img src="docs/screenshots/05-errors-explained.jpg" alt="Errors explained in plain English"></td></tr>
<tr><td><img src="docs/screenshots/06-project-search.jpg" alt="Project search"></td><td><img src="docs/screenshots/07-comments.jpg" alt="Comments and replies"></td></tr>
<tr><td><img src="docs/screenshots/08-history.jpg" alt="Version history"></td><td><img src="docs/screenshots/09-git.jpg" alt="Git panel"></td></tr>
<tr><td><img src="docs/screenshots/10-themes.jpg" alt="Twelve themes"></td><td><img src="docs/screenshots/11-command-palette.jpg" alt="Command palette"></td></tr>
<tr><td><img src="docs/screenshots/12-focus-mode.jpg" alt="Focus mode"></td><td><img src="docs/screenshots/13-templates.jpg" alt="Templates"></td></tr>
</table>

## Install

1. Download `Ligature-1.1.0.dmg` from [Releases](https://github.com/mithinsagar/Ligature/releases) and drag Ligature into Applications.
2. The app isn't notarised, so the first time macOS blocks it: open System Settings > Privacy & Security and click "Open Anyway".
3. Install a TeX engine once: `brew install tectonic` (it fetches only the packages your documents need). For Word export, also `brew install pandoc`.

## Features

- **Compile on demand or live.** Live compile is off by default: press Compile (⌘R) in the toolbar. Flip the Live switch to recompile as you type: compiles run back to back, so the PDF keeps updating while you type rather than waiting for a pause. While Live is off, the status shows "Edited" and the Compile button glows softly when the PDF is out of date. New PDFs crossfade in at the same scroll position.
- **Two-way SyncTeX.** Click any word in the PDF (single click, double-click, ⌘-click or force click) to jump to its source line, with that exact word marked strongly. ⌘⇧J shows the caret's line in the PDF with a highlight.
- **Editor.** LaTeX syntax colouring, a line gutter with issue markers, auto-closing braces and `$`, and `\begin{env}` + Return to close the environment. `\item` lines continue. Includes snippets with tab stops, ⌘/ to comment, and ⌘B / ⌘I / ⌘U.
- **Autocomplete** for commands, your own `\newcommand` macros, environments, `\ref` labels, `\cite` keys, `\input` files, images and packages.
- **Live equation preview** while the caret is inside math, rendered by the TeX engine with your own preamble and macros.
- **Hover and force-click peeks** for references (rendered equations), citations, images, included files and symbols.
- **Errors in plain English**, shown inline at the end of the line, with one-click fixes such as adding a missing package.
- **Outline** of sections, figures, tables and TODOs, following `\input` and `\include` across files.
- **Table builder** with a live rendered preview. Pasting spreadsheet data opens it pre-filled.
- **Figures:** drag or paste an image into the editor. It is copied into `figures/` and wrapped in a figure environment.
- **Citations:** add references by DOI, arXiv ID or a title search (Crossref).
- **Symbols palette** with search and recents.
- **Version history:** automatic snapshots after successful compiles, with a diff view and restore.
- **Undo and redo** buttons in the tab bar. Hover Undo (or click the clock) for the edit-history card: drag a scrubber through every edit since you opened the file, or jump back to the last compile or to when you opened it. All of these are undoable.
- **Code | Visual:** Visual mode shows the source as a formatted document in a centred reading column: equations typeset by TeX (inline and display), numbered and bulleted lists, figures with their images and captions, tables drawn with their rules, the title block, and the preamble folded into one bar. The construct with the caret shows its raw LaTeX so you can edit it, and clicking a table opens it in the table editor. It's the same text underneath, so switching is instant. Equation images are cached, so a project reopens with its maths already rendered.
- **Paste from Word, Pages, Google Docs or the web:** formatted text arrives as LaTeX (headings, bold, italic, links, superscripts, lists, tables). A toast offers "Paste as plain text" to undo the conversion.
- **Checks as you type:** unbalanced braces, environments that don't match or never close, unclosed maths, `\left` without `\right`, references to labels or citations that don't exist, and commands used without their package. Problems get a wavy underline and a gutter dot before you compile.
- **Code folding:** fold sections, environments and the preamble from the gutter, or with ⌥⌘← / ⌥⌘→ (and ⇧ for all).
- **Logs pane:** All / Errors / Warnings / Info with counts, each problem explained in plain English with its TeX context and a jump to the line, the raw log (searchable), every build file (aux, bbl, log, synctex…), Clear Cache and Download All.
- **Compile options:** draft mode (skip images), stop on the first error, and recompile from scratch. Compiles use packages already downloaded first, so they work offline; a missing package is fetched once when you're online.
- **Search the whole project** (⇧⌘F) with match case, regular expressions and whole word, results grouped by file, and replace one or all (undoable per file).
- **Suggest Fix with Apple Intelligence:** for a compile error, the on-device model explains the problem and proposes a change, shown as a red and green diff to apply in one click. It runs on your Mac and nothing is sent anywhere.
- **Comments:** select text and press ⌥⌘M (or use the Comment button beside the selection) to leave a note. Threads have replies, resolve and reopen, and stay attached to their text as you edit. They're stored in Application Support, so the project stays plain LaTeX.
- **Labelled versions:** name any version in History ("Sent to supervisor"), filter by labels, and download any version as a zip. Labelled versions are never cleaned up. Comparing a version shows which files were added, edited or deleted since.
- **Presenting:** play the PDF full screen (⌥⌘P), one page at a time, with the arrow keys. Fit the whole page, open the PDF in its own window for a second display, or switch to Focus mode (⌥⌘↩) to hide everything but the writing and the PDF.
- **Import and export:** import a .zip project (an Overleaf download, for example), a Word document or a Markdown file as a new project (⇧⌘I). Export as Markdown or as a self-contained web page with MathML maths, besides PDF, Word, zip and arXiv.
- **Git:** start tracking a project, see what changed with a diff, commit, push and pull, and browse history from the Git panel. Commits work offline; push and pull use your existing Git setup.
- **Zotero:** search your Zotero library from Add Citation and add items as BibTeX, through the Better BibTeX add-on running on your Mac (new and not yet tested against a live Zotero install; please report problems).
- **Vim keybindings** (normal, insert, visual and visual-line modes, with counts, operators and motions), twelve themes including Solarized, Nord, Dracula, One Dark, GitHub and Gruvbox, any installed monospaced font (including OpenDyslexic), a spell-check language and grammar checking, a personal dictionary, and a searchable list of every keyboard shortcut (⌥⌘/).
- **⌘K command palette:** commands, files, sections, labels, citations, and `:42` to go to a line.
- **Export:** Quick Download (⌥⌘D) saves the PDF straight into Downloads with no dialog. You can also download with a dialog, download as Word (.docx, via pandoc, with native Word equations and resolved citations), share, print, export a source .zip, or export for arXiv (comments stripped, `.bbl` included). Files are named after the main file (`report.tex` → `report.pdf`), or after the project when the main file is `main.tex`.
- **Saving:** files are written when you compile or press ⌘S, so what's on disk is what you last compiled. Unsaved tabs show a dot. Closing a tab or window, or quitting, with newer edits asks Save / Don't Save / Cancel.
- **Compile history:** every compile you start keeps its PDF. History → Compiles shows each one with a page thumbnail, word and page counts, and errors; open its PDF or go back to that version (your current state is saved first).
- **Previous downloads:** every PDF and zip you download is remembered with its own copy. The Downloads button lists them, so you can open, reveal or save any of them again, even if the original was moved or deleted.
- **Rename the project** from the window title menu, the Files panel or File → Rename Project. The folder, history and downloads move together.
- **Nine templates:** blank, article, IEEE-style paper, thesis, Beamer slides, résumé, letter, assignment and lecture notes.
- **Look and feel:** a softly lit backdrop under Liquid Glass chrome, a floating editor card, PDF pages that float with a soft glow, a light that travels around the compile pill while it works, twelve themes plus Automatic, seven accent colours, and a dark-paper PDF mode.
- **PDF zoom:** 100% means the page fits the pane's width with equal margins, and it keeps fitting as you resize. Pinch or use the buttons to zoom; the percentage follows. Click the percentage to return to 100%.
- **Compile ripple:** when a compile you started finishes, a circular ripple spreads from the centre of the page and reveals the new PDF as it goes, with a frosted glass edge, a soft bloom and trailing rings. It's drawn with Core Animation and stays on the page.
- **Haptics,** soft and only for three moments: the editor/PDF divider snapping to ⅓, ½ or ⅔, a force click, and the result of a compile you started. They can be turned off in Settings → Haptics.

## Requirements

- macOS 26 or later, Apple silicon or Intel.
- A TeX engine. Tectonic is recommended: `brew install tectonic`. It downloads only the packages a document needs, once; after that compiling works offline. MacTeX's `latexmk` can be chosen instead (Settings → Compile), though it has had far less testing than Tectonic.
- Optional: `brew install pandoc` for Word, Markdown and HTML export and for importing Word or Markdown files.
- Optional: Apple Intelligence turned on (System Settings) for Suggest Fix. Zotero with the Better BibTeX add-on for the Zotero search.

Everything runs on your Mac. The only things that use the internet are downloading a TeX package the first time a document needs it, the DOI/arXiv citation lookup, and Git push and pull.

## Build

```sh
swift test                 # core parser tests
./scripts/build_app.sh     # → build/Ligature.app
```

`LigatureCore` (log, SyncTeX, outline, BibTeX, tables, symbols) has no UI and no third-party dependencies. The app uses SwiftUI with AppKit for the editor (TextKit 1) and PDFKit for the preview.

For scripted UI checks, set `LIGATURE_OPEN=/path/to/project` and `LIGATURE_SCRIPT="goto:12 ;; type:\frac ;; wait:1"` (see `Sources/Ligature/Support/TestScript.swift`).

Made by Mithin Sagar.
