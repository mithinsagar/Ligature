import Foundation

/// A table as a grid of cells, convertible to and from LaTeX `tabular` code and spreadsheet clipboard text.
public struct TableModel: Equatable, Sendable {
    public enum Style: String, CaseIterable, Sendable { case booktabs, grid, minimal }
    public enum Align: String, CaseIterable, Sendable { case l, c, r }

    public var cells: [[String]]
    public var align: [Align]
    public var headerRow: Bool
    public var style: Style
    public var caption: String
    public var label: String
    public var floating: Bool

    public init(rows: Int = 3, columns: Int = 3) {
        cells = Array(repeating: Array(repeating: "", count: columns), count: rows)
        align = Array(repeating: .l, count: columns)
        headerRow = true; style = .booktabs; caption = ""; label = ""; floating = true
    }

    public var rows: Int { cells.count }
    public var columns: Int { cells.first?.count ?? 0 }

    public mutating func resize(rows r: Int, columns c: Int) {
        let r = max(1, r), c = max(1, c)
        if cells.count > r { cells.removeLast(cells.count - r) }
        while cells.count < r { cells.append(Array(repeating: "", count: columns)) }
        for i in cells.indices {
            if cells[i].count > c { cells[i].removeLast(cells[i].count - c) }
            while cells[i].count < c { cells[i].append("") }
        }
        if align.count > c { align.removeLast(align.count - c) }
        while align.count < c { align.append(.l) }
    }

    // MARK: To LaTeX

    public func latex() -> String {
        let spec: String
        switch style {
        case .grid: spec = "|" + align.map(\.rawValue).joined(separator: "|") + "|"
        default: spec = align.map(\.rawValue).joined()
        }
        var lines: [String] = []
        let indent = floating ? "  " : ""
        lines.append("\(indent)\\begin{tabular}{\(spec)}")
        let (top, mid, bottom) = rules
        if let top { lines.append("\(indent)  \(top)") }
        // Pad columns so the source lines up.
        let widths = (0..<columns).map { c in cells.map { TableModel.escape($0[c]).count }.max() ?? 0 }
        for (r, row) in cells.enumerated() {
            let parts = row.enumerated().map { c, v -> String in
                let e = TableModel.escape(v)
                return c == row.count - 1 ? e : e.padding(toLength: widths[c], withPad: " ", startingAt: 0)
            }
            lines.append("\(indent)  " + parts.joined(separator: " & ") + " \\\\")
            if r == 0 && headerRow, let mid { lines.append("\(indent)  \(mid)") }
            else if style == .grid && r < cells.count - 1 { lines.append("\(indent)  \\hline") }
        }
        if let bottom { lines.append("\(indent)  \(bottom)") }
        lines.append("\(indent)\\end{tabular}")
        guard floating else { return lines.joined(separator: "\n") }
        var out = ["\\begin{table}[htbp]", "  \\centering"]
        if !caption.isEmpty { out.append("  \\caption{\(caption)}") }
        if !label.isEmpty { out.append("  \\label{\(label)}") }
        out += lines
        out.append("\\end{table}")
        return out.joined(separator: "\n")
    }

    var rules: (String?, String?, String?) {
        switch style {
        case .booktabs: ("\\toprule", "\\midrule", "\\bottomrule")
        case .grid: ("\\hline", "\\hline", "\\hline")
        case .minimal: (nil, headerRow ? "\\hline" : nil, nil)
        }
    }

    /// Escapes characters that are special in text, but leaves cells that already look like LaTeX alone.
    public static func escape(_ s: String) -> String {
        if s.contains("\\") || s.contains("$") { return s }
        var t = s
        for (a, b) in [("&", "\\&"), ("%", "\\%"), ("#", "\\#"), ("_", "\\_")] { t = t.replacingOccurrences(of: a, with: b) }
        return t
    }

    // MARK: From LaTeX

    /// Parses the first tabular in `code` (simple tables: no multicolumn spans are merged).
    public static func parse(latex code: String) -> TableModel? {
        guard let begin = code.range(of: #"\\begin\{tabular\*?\}(\{[^}]*\})?\{((?:[^{}]|\{[^{}]*\})*)\}"#, options: .regularExpression),
              let end = code.range(of: "\\end{tabular", range: begin.upperBound..<code.endIndex) else { return nil }
        let head = String(code[begin])
        let specRaw = head.replacingOccurrences(of: #"^\\begin\{tabular\*?\}(\{[^}]*\})?\{"#, with: "", options: .regularExpression).dropLast()
        let spec = specRaw.replacingOccurrences(of: #"[pmb]\{[^}]*\}"#, with: "l", options: .regularExpression)
        let aligns = spec.compactMap { Align(rawValue: String($0)) }
        let body = String(code[begin.upperBound..<end.lowerBound])
        var model = TableModel(rows: 1, columns: max(1, aligns.count))
        model.style = body.contains("\\toprule") ? .booktabs : (spec.contains("|") ? .grid : .minimal)
        let rows = body.components(separatedBy: "\\\\")
            .map { $0.replacingOccurrences(of: #"\\(toprule|midrule|bottomrule|hline|cmidrule(\([^)]*\))?\{[^}]*\})"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !rows.isEmpty else { return nil }
        var grid = rows.map { splitCells($0).map { unescape($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
        let cols = max(aligns.count, grid.map(\.count).max() ?? 1)
        grid = grid.map { $0 + Array(repeating: "", count: cols - $0.count) }
        model.cells = grid
        model.align = aligns + Array(repeating: .l, count: max(0, cols - aligns.count))
        model.headerRow = body.contains("\\midrule") || model.style == .grid
        if let c = code.range(of: #"\\caption\{([^}]*)\}"#, options: .regularExpression) {
            model.caption = String(code[c]).replacingOccurrences(of: #"^\\caption\{|\}$"#, with: "", options: .regularExpression)
        }
        if let l = code.range(of: #"\\label\{([^}]*)\}"#, options: .regularExpression) {
            model.label = String(code[l]).replacingOccurrences(of: #"^\\label\{|\}$"#, with: "", options: .regularExpression)
        }
        model.floating = code.contains("\\begin{table")
        return model
    }

    /// Splits on unescaped & that is not inside braces.
    static func splitCells(_ row: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var depth = 0
        var prev: Character = " "
        for ch in row {
            if ch == "{" { depth += 1 } else if ch == "}" { depth -= 1 }
            if ch == "&" && depth == 0 && prev != "\\" { out.append(cur); cur = "" } else { cur.append(ch) }
            prev = ch
        }
        out.append(cur)
        return out
    }

    static func unescape(_ s: String) -> String {
        if s.contains("$") { return s }
        var t = s
        for (a, b) in [("\\&", "&"), ("\\%", "%"), ("\\#", "#"), ("\\_", "_")] { t = t.replacingOccurrences(of: a, with: b) }
        return t
    }

    // MARK: From the clipboard

    /// Numbers, Excel and Google Sheets copy as tab-separated text; CSV is accepted too.
    public static func parse(delimited text: String) -> TableModel? {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return nil }
        let delimiter: Character = trimmed.contains("\t") ? "\t" : (trimmed.contains(";") && !trimmed.contains(",") ? ";" : ",")
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let chars = Array(trimmed)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == delimiter {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r" {
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                row.append(field); field = ""; rows.append(row); row = []
            } else { field.append(c) }
            i += 1
        }
        row.append(field); rows.append(row)
        let cols = rows.map(\.count).max() ?? 1
        guard cols > 1 || rows.count > 1 else { return nil }
        var model = TableModel(rows: rows.count, columns: cols)
        model.cells = rows.map { $0 + Array(repeating: "", count: cols - $0.count) }
        // Right-align columns that are numeric below the header.
        for c in 0..<cols {
            let values = rows.dropFirst().map { $0.count > c ? $0[c] : "" }.filter { !$0.isEmpty }
            if !values.isEmpty, values.allSatisfy({ Double($0.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "%", with: "")) != nil }) {
                model.align[c] = .r
            }
        }
        return model
    }
}
