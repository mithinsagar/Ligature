import SwiftUI
import AppKit

/// A complete colour scheme for the app chrome and the editor. Light and dark themes are separate entries; "auto"
/// follows the system appearance between Paper and Graphite.
struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let isDark: Bool

    // Chrome
    let canvas: NSColor          // window / behind the PDF pages
    let surface: NSColor         // sidebar cards, popovers
    let editor: NSColor          // editor background
    let gutter: NSColor
    let gutterText: NSColor
    let currentLine: NSColor
    let selection: NSColor
    let text: NSColor
    let secondary: NSColor
    let hairline: NSColor

    // Syntax
    let command: NSColor
    let environment: NSColor
    let math: NSColor
    let comment: NSColor
    let brace: NSColor
    let reference: NSColor
    let heading: NSColor
    let special: NSColor

    let error: NSColor
    let warning: NSColor

    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    static let paper = Theme(
        id: "paper", name: "Paper", isDark: false,
        canvas: hex(0xEEEDEA), surface: hex(0xFFFFFF), editor: hex(0xFCFBF9), gutter: hex(0xFCFBF9), gutterText: hex(0xA8A6A1),
        currentLine: hex(0x1F2328, 0.035), selection: hex(0x2F5BEA, 0.16), text: hex(0x1F2328), secondary: hex(0x6E6C68), hairline: hex(0x1F2328, 0.08),
        command: hex(0x2F5BEA), environment: hex(0x8A3FD1), math: hex(0x0F7B6C), comment: hex(0x9A9893), brace: hex(0x8B8984),
        reference: hex(0xB25E09), heading: hex(0x1F2328), special: hex(0xC2410C),
        error: hex(0xD92D20), warning: hex(0xB54708))

    static let graphite = Theme(
        id: "graphite", name: "Graphite", isDark: true,
        canvas: hex(0x111214), surface: hex(0x1E1F22), editor: hex(0x18191B), gutter: hex(0x18191B), gutterText: hex(0x5B5D63),
        currentLine: hex(0xFFFFFF, 0.04), selection: hex(0x6E8EFB, 0.28), text: hex(0xE6E6E3), secondary: hex(0x9A9CA1), hairline: hex(0xFFFFFF, 0.08),
        command: hex(0x7EA1FF), environment: hex(0xC79BFF), math: hex(0x5CD3B6), comment: hex(0x6B6E75), brace: hex(0x878A91),
        reference: hex(0xF2B263), heading: hex(0xF4F4F2), special: hex(0xFF8F5E),
        error: hex(0xFF6B5E), warning: hex(0xF5B342))

    static let mist = Theme(
        id: "mist", name: "Mist", isDark: false,
        canvas: hex(0xE9EDF2), surface: hex(0xFFFFFF), editor: hex(0xF8FAFC), gutter: hex(0xF8FAFC), gutterText: hex(0x9AA4B2),
        currentLine: hex(0x0F172A, 0.035), selection: hex(0x0E7490, 0.16), text: hex(0x0F172A), secondary: hex(0x64748B), hairline: hex(0x0F172A, 0.08),
        command: hex(0x0E7490), environment: hex(0x7C3AED), math: hex(0x15803D), comment: hex(0x94A3B8), brace: hex(0x94A3B8),
        reference: hex(0xC2410C), heading: hex(0x0F172A), special: hex(0xBE123C),
        error: hex(0xDC2626), warning: hex(0xB45309))

    static let midnight = Theme(
        id: "midnight", name: "Midnight", isDark: true,
        canvas: hex(0x0A0D14), surface: hex(0x151A25), editor: hex(0x0F131C), gutter: hex(0x0F131C), gutterText: hex(0x465066),
        currentLine: hex(0x93B4FF, 0.05), selection: hex(0x5B8CFF, 0.3), text: hex(0xDCE3F0), secondary: hex(0x8A95AB), hairline: hex(0xFFFFFF, 0.07),
        command: hex(0x82AAFF), environment: hex(0xF07178), math: hex(0xC3E88D), comment: hex(0x546178), brace: hex(0x89DDFF),
        reference: hex(0xFFCB6B), heading: hex(0xFFFFFF), special: hex(0xF78C6C),
        error: hex(0xFF5370), warning: hex(0xFFCB6B))

    static let sepia = Theme(
        id: "sepia", name: "Sepia", isDark: false,
        canvas: hex(0xE8E0D0), surface: hex(0xFAF5EA), editor: hex(0xF6F0E2), gutter: hex(0xF6F0E2), gutterText: hex(0xB0A48C),
        currentLine: hex(0x3B2F1E, 0.04), selection: hex(0x9C6B30, 0.2), text: hex(0x3B2F1E), secondary: hex(0x7A6A52), hairline: hex(0x3B2F1E, 0.09),
        command: hex(0x2B5F8A), environment: hex(0x8E3B6E), math: hex(0x4D7A2E), comment: hex(0xA89A80), brace: hex(0x9A8B70),
        reference: hex(0xA4561B), heading: hex(0x2A2015), special: hex(0xB4441B),
        error: hex(0xC0392B), warning: hex(0xA66A00))

    static let solarizedLight = Theme(
        id: "solarized-light", name: "Solarized Light", isDark: false,
        canvas: hex(0xEEE8D5), surface: hex(0xFDF6E3), editor: hex(0xFDF6E3), gutter: hex(0xFDF6E3), gutterText: hex(0x93A1A1),
        currentLine: hex(0x073642, 0.05), selection: hex(0x268BD2, 0.2), text: hex(0x586E75), secondary: hex(0x839496), hairline: hex(0x073642, 0.1),
        command: hex(0x268BD2), environment: hex(0x6C71C4), math: hex(0x859900), comment: hex(0x93A1A1), brace: hex(0x93A1A1),
        reference: hex(0xCB4B16), heading: hex(0x073642), special: hex(0xD33682),
        error: hex(0xDC322F), warning: hex(0xB58900))

    static let solarizedDark = Theme(
        id: "solarized-dark", name: "Solarized Dark", isDark: true,
        canvas: hex(0x00212B), surface: hex(0x073642), editor: hex(0x002B36), gutter: hex(0x002B36), gutterText: hex(0x4F6A72),
        currentLine: hex(0xFDF6E3, 0.04), selection: hex(0x268BD2, 0.3), text: hex(0x93A1A1), secondary: hex(0x657B83), hairline: hex(0xFDF6E3, 0.08),
        command: hex(0x268BD2), environment: hex(0x6C71C4), math: hex(0x859900), comment: hex(0x586E75), brace: hex(0x657B83),
        reference: hex(0xCB4B16), heading: hex(0xEEE8D5), special: hex(0xD33682),
        error: hex(0xDC322F), warning: hex(0xB58900))

    static let nord = Theme(
        id: "nord", name: "Nord", isDark: true,
        canvas: hex(0x242933), surface: hex(0x3B4252), editor: hex(0x2E3440), gutter: hex(0x2E3440), gutterText: hex(0x616E88),
        currentLine: hex(0xECEFF4, 0.04), selection: hex(0x88C0D0, 0.25), text: hex(0xD8DEE9), secondary: hex(0x9AA5B9), hairline: hex(0xECEFF4, 0.08),
        command: hex(0x81A1C1), environment: hex(0xB48EAD), math: hex(0xA3BE8C), comment: hex(0x616E88), brace: hex(0x8FBCBB),
        reference: hex(0xEBCB8B), heading: hex(0xECEFF4), special: hex(0xD08770),
        error: hex(0xBF616A), warning: hex(0xEBCB8B))

    static let dracula = Theme(
        id: "dracula", name: "Dracula", isDark: true,
        canvas: hex(0x1E1F29), surface: hex(0x343746), editor: hex(0x282A36), gutter: hex(0x282A36), gutterText: hex(0x6272A4),
        currentLine: hex(0xF8F8F2, 0.04), selection: hex(0xBD93F9, 0.28), text: hex(0xF8F8F2), secondary: hex(0xA4A9C4), hairline: hex(0xF8F8F2, 0.08),
        command: hex(0x8BE9FD), environment: hex(0xFF79C6), math: hex(0x50FA7B), comment: hex(0x6272A4), brace: hex(0xBD93F9),
        reference: hex(0xF1FA8C), heading: hex(0xFFFFFF), special: hex(0xFFB86C),
        error: hex(0xFF5555), warning: hex(0xF1FA8C))

    static let oneDark = Theme(
        id: "one-dark", name: "One Dark", isDark: true,
        canvas: hex(0x1E2127), surface: hex(0x2C313A), editor: hex(0x282C34), gutter: hex(0x282C34), gutterText: hex(0x5C6370),
        currentLine: hex(0xFFFFFF, 0.04), selection: hex(0x61AFEF, 0.25), text: hex(0xABB2BF), secondary: hex(0x8A919E), hairline: hex(0xFFFFFF, 0.07),
        command: hex(0x61AFEF), environment: hex(0xC678DD), math: hex(0x98C379), comment: hex(0x5C6370), brace: hex(0x56B6C2),
        reference: hex(0xE5C07B), heading: hex(0xE6E6E6), special: hex(0xD19A66),
        error: hex(0xE06C75), warning: hex(0xE5C07B))

    static let github = Theme(
        id: "github", name: "GitHub Light", isDark: false,
        canvas: hex(0xF0F2F4), surface: hex(0xFFFFFF), editor: hex(0xFFFFFF), gutter: hex(0xFFFFFF), gutterText: hex(0x8C959F),
        currentLine: hex(0x0969DA, 0.04), selection: hex(0x0969DA, 0.15), text: hex(0x1F2328), secondary: hex(0x656D76), hairline: hex(0x1F2328, 0.1),
        command: hex(0x0550AE), environment: hex(0x8250DF), math: hex(0x116329), comment: hex(0x6E7781), brace: hex(0x6E7781),
        reference: hex(0x953800), heading: hex(0x1F2328), special: hex(0xCF222E),
        error: hex(0xCF222E), warning: hex(0x9A6700))

    static let gruvbox = Theme(
        id: "gruvbox", name: "Gruvbox", isDark: true,
        canvas: hex(0x1D2021), surface: hex(0x3C3836), editor: hex(0x282828), gutter: hex(0x282828), gutterText: hex(0x7C6F64),
        currentLine: hex(0xEBDBB2, 0.04), selection: hex(0xD79921, 0.25), text: hex(0xEBDBB2), secondary: hex(0xA89984), hairline: hex(0xEBDBB2, 0.08),
        command: hex(0x83A598), environment: hex(0xD3869B), math: hex(0xB8BB26), comment: hex(0x928374), brace: hex(0x8EC07C),
        reference: hex(0xFABD2F), heading: hex(0xFBF1C7), special: hex(0xFE8019),
        error: hex(0xFB4934), warning: hex(0xFABD2F))

    static let all: [Theme] = [paper, mist, sepia, github, solarizedLight, graphite, midnight, solarizedDark, nord, dracula, oneDark, gruvbox]
}

/// Accent colours offered in Settings.
struct Accent: Identifiable, Equatable {
    let id: String
    let name: String
    let light: NSColor
    let dark: NSColor

    static let all: [Accent] = [
        Accent(id: "ink", name: "Ink", light: Theme.hex(0x2F5BEA), dark: Theme.hex(0x6E8EFB)),
        Accent(id: "iris", name: "Iris", light: Theme.hex(0x6E56CF), dark: Theme.hex(0x9E8CFC)),
        Accent(id: "teal", name: "Teal", light: Theme.hex(0x0E7C7B), dark: Theme.hex(0x3DD6C6)),
        Accent(id: "forest", name: "Forest", light: Theme.hex(0x2F7D32), dark: Theme.hex(0x6BCB77)),
        Accent(id: "amber", name: "Amber", light: Theme.hex(0xB45309), dark: Theme.hex(0xF5A524)),
        Accent(id: "crimson", name: "Crimson", light: Theme.hex(0xC0263D), dark: Theme.hex(0xFF6B81)),
        Accent(id: "graphite", name: "Graphite", light: Theme.hex(0x3F4247), dark: Theme.hex(0xC9CCD1)),
    ]
}

/// Resolves the active theme (following the system appearance for "auto") and publishes changes.
@Observable @MainActor
final class ThemeManager {
    static let shared = ThemeManager()
    private(set) var systemIsDark: Bool = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    private var observer: NSKeyValueObservation?

    private init() {
        observer = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { app, _ in
            Task { @MainActor in
                ThemeManager.shared.systemIsDark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            }
        }
    }

    var theme: Theme {
        let id = Preferences.shared.themeID
        if id == "auto" { return systemIsDark ? .graphite : .paper }
        return Theme.all.first { $0.id == id } ?? .paper
    }

    var accentNS: NSColor {
        let a = Accent.all.first { $0.id == Preferences.shared.accentID } ?? Accent.all[0]
        return theme.isDark ? a.dark : a.light
    }

    var accent: Color { Color(nsColor: accentNS) }

    /// The appearance the window should force so system controls match a themed light/dark choice.
    var appearance: NSAppearance? {
        Preferences.shared.themeID == "auto" ? nil : NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
    }
}

extension Color {
    init(_ ns: NSColor) { self.init(nsColor: ns) }
}

/// Typography in one place.
enum Typo {
    /// The chosen editor font family ("" = system monospaced). Set from Preferences.
    nonisolated(unsafe) static var fontName = ""

    static func editorFont(size: CGFloat) -> NSFont {
        if !fontName.isEmpty, let f = NSFontManager.shared.font(withFamily: fontName, traits: [], weight: 5, size: size) { return f }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
    static func editorBold(size: CGFloat) -> NSFont {
        if !fontName.isEmpty, let f = NSFontManager.shared.font(withFamily: fontName, traits: .boldFontMask, weight: 9, size: size) { return f }
        return .monospacedSystemFont(ofSize: size, weight: .semibold)
    }
    /// Monospaced families installed on this Mac that read well as an editor font.
    static func availableFamilies() -> [String] {
        let preferred = ["SF Mono", "Menlo", "Monaco", "JetBrains Mono", "Fira Code", "Source Code Pro", "IBM Plex Mono", "Cascadia Code", "Hack", "Iosevka", "Courier New", "OpenDyslexic Mono", "OpenDyslexicMono", "OpenDyslexic"]
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return preferred.filter { installed.contains($0) }
    }
    static let serifTitle = Font.system(size: 30, weight: .semibold, design: .serif)
}
