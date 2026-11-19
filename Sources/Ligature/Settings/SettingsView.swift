import SwiftUI

struct SettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case appearance, editor, compile, haptics
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .appearance: "paintpalette"
            case .editor: "character.cursor.ibeam"
            case .compile: "hammer"
            case .haptics: "hand.tap"
            }
        }
    }

    @State private var page: Page = .appearance

    var body: some View {
        VStack(spacing: 0) {
            SlidingTabs(items: Page.allCases, selection: $page, symbol: \.symbol, title: \.title, iconOnly: false, height: 30)
                .padding(.top, 14).padding(.bottom, 12)
            Rectangle().fill(Color(theme.hairline)).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch page {
                    case .appearance: AppearancePage()
                    case .editor: EditorPage()
                    case .compile: CompilePage()
                    case .haptics: HapticsPage()
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 620, height: 560)
        .background(Color(theme.surface))
        .preferredColorScheme(Preferences.shared.themeID == "auto" ? nil : (theme.isDark ? .dark : .light))
        .tint(accent)
        .animation(.panel, value: page)
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    var footnote: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(theme.text))
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(cornerRadius: 12)
            if let footnote { Text(footnote).font(.system(size: 11)).foregroundStyle(Color(theme.secondary)) }
        }
    }
}

// MARK: Appearance

private struct AppearancePage: View {
    @Bindable var prefs = Preferences.shared

    var body: some View {
        SettingsGroup(title: "Theme") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                ThemeSwatch(id: "auto", name: "Automatic", swatchTheme: ThemeManager.shared.systemIsDark ? .graphite : .paper, split: true, selected: prefs.themeID == "auto") { prefs.themeID = "auto" }
                ForEach(Theme.all) { t in
                    ThemeSwatch(id: t.id, name: t.name, swatchTheme: t, split: false, selected: prefs.themeID == t.id) { prefs.themeID = t.id }
                }
            }
        }
        SettingsGroup(title: "Accent colour") {
            HStack(spacing: 12) {
                ForEach(Accent.all) { a in
                    AccentDot(accent: a, selected: prefs.accentID == a.id) { prefs.accentID = a.id }
                }
            }
        }
        SettingsGroup(title: "Text") {
            DetentSlider(title: "Editor font size", value: $prefs.editorFontSize, range: 11...20, step: 0.5, format: { String(format: "%.1f pt", $0) })
            DetentSlider(title: "Line spacing", value: $prefs.lineSpacing, range: 1.1...2.0, step: 0.05, format: { String(format: "%.2f×", $0) })
        }
        SettingsGroup(title: "Motion") {
            Toggle("Reduce motion", isOn: $prefs.reduceMotion).toggleStyle(.lig)
        }
    }
}

private struct ThemeSwatch: View {
    let id: String
    let name: String
    let swatchTheme: Theme
    let split: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button { action() } label: {
            VStack(spacing: 7) {
                ZStack(alignment: .topLeading) {
                    if split {
                        HStack(spacing: 0) { mini(Theme.paper); mini(Theme.graphite) }
                    } else {
                        mini(swatchTheme)
                    }
                }
                .frame(height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? accent : Color(theme.hairline), lineWidth: selected ? 2.5 : 0.75))
                .scaleEffect(hovering ? 1.04 : 1)
                .shadow(color: .black.opacity(hovering ? 0.15 : 0), radius: 8, y: 4)
                Text(name).font(.system(size: 11.5, weight: selected ? .semibold : .regular)).foregroundStyle(Color(theme.text))
            }
        }
        .buttonStyle(.plain)
        .animation(.press, value: hovering)
        .onHover { h in hovering = h }
    }

    func mini(_ t: Theme) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 1).fill(Color(t.command)).frame(width: 18, height: 4)
                RoundedRectangle(cornerRadius: 1).fill(Color(t.environment)).frame(width: 22, height: 4)
            }
            RoundedRectangle(cornerRadius: 1).fill(Color(t.text).opacity(0.7)).frame(width: 44, height: 4)
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 1).fill(Color(t.math)).frame(width: 26, height: 4)
                RoundedRectangle(cornerRadius: 1).fill(Color(t.reference)).frame(width: 12, height: 4)
            }
            RoundedRectangle(cornerRadius: 1).fill(Color(t.comment)).frame(width: 34, height: 4)
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(t.editor))
    }
}

private struct AccentDot: View {
    let accent: Accent
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button { action() } label: {
            ZStack {
                Circle().fill(Color(theme.isDark ? accent.dark : accent.light)).frame(width: 24, height: 24)
                if selected { Circle().strokeBorder(.white, lineWidth: 2).frame(width: 14, height: 14) }
            }
            .padding(3)
            .overlay(Circle().strokeBorder(selected ? Color(theme.isDark ? accent.dark : accent.light).opacity(0.5) : .clear, lineWidth: 2))
            .scaleEffect(hovering ? 1.15 : 1)
        }
        .buttonStyle(.plain)
        .help(accent.name)
        .animation(.press, value: hovering)
        .animation(.press, value: selected)
        .onHover { h in hovering = h }
    }
}

/// A slider that plays a level haptic at each step.
private struct DetentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12.5)).foregroundStyle(Color(theme.text))
            Spacer()
            Slider(value: $value, in: range, step: step).frame(width: 220)
            Text(format(value)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color(theme.secondary)).frame(width: 56, alignment: .trailing)
        }
    }
}

// MARK: Editor

private struct EditorPage: View {
    @Bindable var prefs = Preferences.shared

    var body: some View {
        SettingsGroup(title: "Typing") {
            Toggle("Close brackets, braces and $ automatically", isOn: $prefs.autoPair).toggleStyle(.lig)
            Toggle("Wrap long lines", isOn: $prefs.wrapLines).toggleStyle(.lig)
            Toggle("Check spelling in prose (not in commands or math)", isOn: $prefs.spellCheck).toggleStyle(.lig)
            Toggle("Show line numbers", isOn: $prefs.lineNumbers).toggleStyle(.lig)
        }
        SettingsGroup(title: "Previews", footnote: "Equation previews are rendered by the TeX engine with your document's own packages and macros.") {
            Toggle("Live equation preview while the caret is in math", isOn: $prefs.mathPreview).toggleStyle(.lig)
            Toggle("Peek on hover: references, citations, images, symbols", isOn: $prefs.hoverPeeks).toggleStyle(.lig)
            Toggle("Show errors and warnings inline at the end of the line", isOn: $prefs.inlineIssues).toggleStyle(.lig)
        }
    }
}

// MARK: Compile

private struct CompilePage: View {
    @Bindable var prefs = Preferences.shared
    @State private var found: EngineLocator.Found?

    var body: some View {
        SettingsGroup(title: "Live compile") {
            Toggle("Recompile automatically as you type", isOn: $prefs.liveCompile).toggleStyle(.lig)
            DetentSlider(title: "Pause before compiling", value: $prefs.compileDelay, range: 0.0...1.5, step: 0.05, format: { String(format: "%.2f s", $0) })
            Toggle("PDF follows the caret (SyncTeX)", isOn: $prefs.followCaret).toggleStyle(.lig)
        }
        SettingsGroup(title: "Engine", footnote: "Tectonic is recommended: it fetches packages on demand, so there's no 5 GB TeX distribution to install. latexmk uses an existing MacTeX install (needed for shell-escape packages such as minted).") {
            Picker("Preferred engine", selection: $prefs.engine) {
                ForEach(Preferences.Engine.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: prefs.engine) { _, _ in found = EngineLocator.locate() }
            HStack {
                TextField("Custom engine path (optional)", text: $prefs.enginePath).textFieldStyle(.roundedBorder)
                Button("Browse…") {
                    let p = NSOpenPanel()
                    p.canChooseFiles = true
                    if p.runModal() == .OK, let u = p.url { prefs.enginePath = u.path; found = EngineLocator.locate() }
                }
                .buttonStyle(.ligSecondary)
            }
            HStack(spacing: 8) {
                Circle().fill(found != nil ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(found.map { "\($0.version.isEmpty ? $0.engine.title : $0.version) at \($0.url.path)" } ?? "No engine found. Install with: brew install tectonic")
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color(theme.secondary)).lineLimit(2)
                Spacer()
                Button("Check Again") { found = EngineLocator.locate() }.buttonStyle(.ligSecondary)
            }
        }
        .onAppear { found = EngineLocator.locate() }
    }
}

// MARK: Haptics

private struct HapticsPage: View {
    @Bindable var prefs = Preferences.shared

    var body: some View {
        SettingsGroup(title: "Haptic feedback", footnote: "Haptics play through a Force Touch trackpad while your finger rests on it. Mice and older trackpads have no haptic engine.") {
            Toggle("Soft haptics for important moments", isOn: $prefs.haptics).toggleStyle(.lig)
            VStack(alignment: .leading, spacing: 8) {
                moment("rectangle.split.2x1", "Dragging the editor/PDF divider onto ⅓, ½ or ⅔")
                moment("hand.point.up.left", "Force click to peek, or to jump between source and PDF")
                moment("checkmark.circle", "A compile you started finishes: one tap, or two if there are errors")
            }
            .opacity(prefs.haptics ? 1 : 0.45)
        }
        SettingsGroup(title: "Try it", footnote: "Only these three moments use haptics, always with the lightest system tap. Typing, hovering, clicking, scrolling and live compiles never do.") {
            HStack(spacing: 8) {
                TryButton(title: "Snap", detail: "One soft tap", event: .snap)
                TryButton(title: "Compile errors", detail: "Two soft taps", event: .failure)
            }
        }
    }

    func moment(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(accent).frame(width: 18)
            Text(text).font(.system(size: 12)).foregroundStyle(Color(theme.text))
        }
    }
}

private struct TryButton: View {
    let title: String
    let detail: String
    let event: Haptics.Event
    @State private var hovering = false
    @State private var pulses = 0

    var body: some View {
        Button {
            Haptics.play(event)
            pulses += 1
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(theme.text))
                    Spacer()
                    Image(systemName: "waveform").font(.system(size: 11)).foregroundStyle(accent).symbolEffect(.bounce, value: pulses)
                }
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Color(theme.secondary))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(theme.text).opacity(hovering ? 0.07 : 0.035)))
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.hover) { hovering = h } }
    }
}
