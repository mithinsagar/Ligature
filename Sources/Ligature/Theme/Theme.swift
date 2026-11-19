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

    static let all: [Theme] = [paper, mist, sepia, graphite, midnight]
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
    static func editorFont(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    static func editorBold(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .semibold) }
    static let serifTitle = Font.system(size: 30, weight: .semibold, design: .serif)
}
