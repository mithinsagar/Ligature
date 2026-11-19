import Foundation
import CoreGraphics

/// A minimal SyncTeX reader: enough for "show this line in the PDF" and "which line made this spot in the PDF".
///
/// Coordinates in the file are TeX scaled points measured from the top-left corner of the page (the 1in TeX
/// origin is already included). `pdfRect` converts them to PDF points with the origin at the bottom-left.
public struct SyncTeX: Sendable {
    public struct Box: Sendable, Hashable {
        public enum Kind: Character, Sendable { case vbox = "[", hbox = "(", voidHbox = "h", kern = "k", glue = "g", math = "$", char = "x", voidVbox = "v" }
        public var kind: Kind
        public var input: Int
        public var line: Int
        /// TeX sp, top-left origin. `y` is the baseline.
        public var x: Int, y: Int, width: Int, height: Int, depth: Int
    }

    public struct Location: Sendable, Hashable {
        public var file: String
        public var line: Int
    }

    public private(set) var inputs: [Int: String] = [:]
    /// Page number (1-based) → boxes on that page, in file order.
    public private(set) var pages: [Int: [Box]] = [:]
    var unit: Double = 1, magnification: Double = 1000, xOffset: Double = 0, yOffset: Double = 0

    public init?(text: String) {
        var page = 0
        var sawContent = false
        for rawSub in text.split(separator: "\n") {
            let raw = String(rawSub)
            guard let first = raw.first else { continue }
            if !sawContent {
                if raw.hasPrefix("Input:") {
                    let rest = raw.dropFirst(6)
                    if let colon = rest.firstIndex(of: ":"), let tag = Int(rest[..<colon]) {
                        let path = String(rest[rest.index(after: colon)...])
                        if !path.isEmpty { self.inputs[tag] = path }
                    }
                } else if raw.hasPrefix("Unit:") { self.unit = Double(raw.dropFirst(5)) ?? 1 }
                else if raw.hasPrefix("Magnification:") { self.magnification = Double(raw.dropFirst(14)) ?? 1000 }
                else if raw.hasPrefix("X Offset:") { self.xOffset = Double(raw.dropFirst(9)) ?? 0 }
                else if raw.hasPrefix("Y Offset:") { self.yOffset = Double(raw.dropFirst(9)) ?? 0 }
                else if raw.hasPrefix("Content:") { sawContent = true }
                continue
            }
            switch first {
            case "{": page = Int(raw.dropFirst()) ?? page
            case "}": break
            case "[", "(", "h", "k", "g", "$", "x", "v":
                if let b = SyncTeX.box(raw, kind: first) { self.pages[page, default: []].append(b) }
            case "I":
                // Inputs may also appear after Content: (files opened mid-run).
                if raw.hasPrefix("Input:") {
                    let rest = raw.dropFirst(6)
                    if let colon = rest.firstIndex(of: ":"), let tag = Int(rest[..<colon]) {
                        let path = String(rest[rest.index(after: colon)...])
                        if !path.isEmpty { self.inputs[tag] = path }
                    }
                }
            default: break
            }
        }
        if inputs.isEmpty && pages.isEmpty { return nil }
    }

    /// Reads a `.synctex.gz` (via the system gunzip) or a plain `.synctex` file.
    public static func load(url: URL) -> SyncTeX? {
        if url.pathExtension == "gz" {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
            p.arguments = ["-c", url.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8).flatMap(SyncTeX.init(text:))
        }
        return (try? String(contentsOf: url, encoding: .utf8)).flatMap(SyncTeX.init(text:))
    }

    // "(1,4:8799519,8865055:22609920,647391,5661"  or  "x1,8:19314067,11087577"
    static func box(_ line: String, kind: Character) -> Box? {
        guard let k = Box.Kind(rawValue: kind) else { return nil }
        let body = line.dropFirst()
        let groups = body.split(separator: ":", omittingEmptySubsequences: false)
        guard groups.count >= 2 else { return nil }
        let tl = groups[0].split(separator: ","), xy = groups[1].split(separator: ",")
        guard tl.count >= 2, xy.count >= 2, let tag = Int(tl[0]), let ln = Int(tl[1]),
              let x = Int(xy[0]), let y = Int(xy[1]) else { return nil }
        var w = 0, h = 0, d = 0
        if groups.count >= 3 {
            let whd = groups[2].split(separator: ",")
            if whd.count >= 1 { w = Int(whd[0]) ?? 0 }
            if whd.count >= 2 { h = Int(whd[1]) ?? 0 }
            if whd.count >= 3 { d = Int(whd[2]) ?? 0 }
        }
        return Box(kind: k, input: tag, line: ln, x: x, y: y, width: w, height: h, depth: d)
    }

    // MARK: Coordinates

    /// sp → big points (PDF units).
    func bp(_ sp: Int) -> Double { Double(sp) * unit * (magnification / 1000) / 65536 * 72 / 72.27 }
    func sp(_ bp: Double) -> Double { bp / (72 / 72.27) * 65536 / (magnification / 1000) / unit }

    /// The box as a PDF rect (bottom-left origin) on a page of the given height in points.
    public func pdfRect(_ b: Box, pageHeight: Double) -> CGRect {
        let top = bp(b.y - b.height) + yOffset
        let height = max(bp(b.height + b.depth), 1)
        let width = b.width > 0 ? bp(b.width) : 1
        return CGRect(x: bp(b.x) + xOffset, y: pageHeight - top - height, width: abs(width), height: height)
    }

    // MARK: Forward search: source line → PDF

    /// Rects (PDF points) for a source line, on the first page where it appears. Falls back to the closest
    /// following line that produced output (blank lines and comments produce nothing).
    public func forward(file: String, line: Int, pageHeight: (Int) -> Double) -> (page: Int, rects: [CGRect])? {
        let tags = inputs.filter { Self.samePath($0.value, file) }.map(\.key)
        guard !tags.isEmpty else { return nil }
        let tagSet = Set(tags)
        // Collect the nearest line ≥ requested that has any record; else nearest below.
        var best: Int?
        for (_, boxes) in pages {
            for b in boxes where tagSet.contains(b.input) && b.line >= line {
                if best == nil || b.line < best! { best = b.line }
            }
        }
        if best == nil {
            for (_, boxes) in pages {
                for b in boxes where tagSet.contains(b.input) && b.line < line {
                    if best == nil || b.line > best! { best = b.line }
                }
            }
        }
        guard let target = best else { return nil }
        for p in pages.keys.sorted() {
            let hits = pages[p]!.filter { tagSet.contains($0.input) && $0.line == target }
            guard !hits.isEmpty else { continue }
            let h = pageHeight(p)
            // Prefer horizontal boxes (whole text lines); otherwise build a band from the point records.
            let lineBoxes = hits.filter { ($0.kind == .hbox || $0.kind == .voidHbox) && $0.width > 0 }
            var rects: [CGRect]
            let pageBoxes = pages[p]!
            if !lineBoxes.isEmpty {
                rects = lineBoxes.map { pdfRect($0, pageHeight: h) }
            } else if case let enclosing = Set(hits.compactMap({ enclosingLine($0, in: pageBoxes) })), !enclosing.isEmpty {
                // A paragraph's line box is tagged with the paragraph's last line, so a middle line only has glyph
                // and glue records: highlight the text lines that contain them.
                rects = enclosing.map { pdfRect($0, pageHeight: h) }.sorted { $0.minY > $1.minY }
            } else {
                let xs: [Double] = hits.map { bp($0.x) }
                let ys: [Double] = hits.map { bp($0.y) }
                let minX: Double = xs.min() ?? 0
                let maxX: Double = Swift.max(xs.max() ?? 0, minX + 40)
                let base: Double = ys.max() ?? 0
                let y: Double = h - base - 3 - yOffset
                rects = [CGRect(x: minX + xOffset, y: y, width: maxX - minX, height: 12)]
            }
            // Drop rects fully contained in another to keep the highlight clean.
            rects = rects.filter { r in !rects.contains { $0 != r && $0.contains(r) } }
            return (p, rects)
        }
        return nil
    }

    /// The smallest horizontal box (a typeset line) containing a point record.
    func enclosingLine(_ b: Box, in boxes: [Box]) -> Box? {
        var best: Box?
        for c in boxes where (c.kind == .hbox || c.kind == .voidHbox) && c.width > 0 {
            guard b.x >= c.x, b.x <= c.x + c.width, b.y >= c.y - c.height, b.y <= c.y + c.depth else { continue }
            if best == nil || c.width * max(c.height + c.depth, 1) < best!.width * max(best!.height + best!.depth, 1) { best = c }
        }
        return best
    }

    // MARK: Inverse search: PDF point → source line

    /// `point` is in PDF points with a bottom-left origin.
    public func inverse(page: Int, point: CGPoint, pageHeight: Double) -> Location? {
        guard let boxes = pages[page], !boxes.isEmpty else { return nil }
        let x = sp(Double(point.x) - xOffset), yTop = sp(pageHeight - Double(point.y) - yOffset)
        // Smallest enclosing horizontal box first: that's the text line under the pointer.
        var bestBox: Box?
        var bestArea = Double.infinity
        for b in boxes where b.kind == .hbox || b.kind == .voidHbox || b.kind == .vbox {
            let left = Double(b.x), right = Double(b.x + b.width)
            let top = Double(b.y - b.height), bottom = Double(b.y + b.depth)
            if x >= left && x <= right && yTop >= top - 2 * 65536 && yTop <= bottom + 2 * 65536 {
                let area = Double(max(b.width, 1)) * Double(max(b.height + b.depth, 1))
                if area < bestArea { bestArea = area; bestBox = b }
            }
        }
        // Within that line, the nearest glyph/glue record carries a more precise source line.
        var nearest: Box?
        var nearestDistance = Double.infinity
        for b in boxes where b.kind != .vbox {
            if let line = bestBox, !(Double(b.y) >= Double(line.y - line.height) && Double(b.y) <= Double(line.y + line.depth) + 65536) { continue }
            let dx = Double(b.x) - x, dy = (Double(b.y) - yTop) * 2
            let d = dx * dx + dy * dy
            if d < nearestDistance { nearestDistance = d; nearest = b }
        }
        guard let hit = nearest ?? bestBox, let file = inputs[hit.input] else { return nil }
        return Location(file: file, line: hit.line)
    }

    /// SyncTeX paths are absolute or "./relative"; compare by standardised path and fall back to suffix.
    public static func samePath(_ a: String, _ b: String) -> Bool {
        let na = (a as NSString).standardizingPath, nb = (b as NSString).standardizingPath
        if na == nb { return true }
        let ta = na.hasPrefix("./") ? String(na.dropFirst(2)) : na
        let tb = nb.hasPrefix("./") ? String(nb.dropFirst(2)) : nb
        return ta.hasSuffix("/" + tb) || tb.hasSuffix("/" + ta) || ta == tb
    }
}
