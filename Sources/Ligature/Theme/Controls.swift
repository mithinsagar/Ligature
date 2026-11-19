import SwiftUI

// The app's control vocabulary. Every interactive element responds to hover (a soft fill that fades in, the icon
// brightening), to press (a quick spring-down), and plays the matching haptic.

@MainActor var theme: Theme { ThemeManager.shared.theme }
@MainActor var accent: Color { ThemeManager.shared.accent }

extension Animation {
    @MainActor static var hover: Animation { Preferences.shared.reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.14) }
    @MainActor static var press: Animation { Preferences.shared.reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.22, dampingFraction: 0.62) }
    @MainActor static var panel: Animation { Preferences.shared.reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.36, dampingFraction: 0.86) }
}

// MARK: Buttons

struct LigButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, icon, chip, destructive }
    var kind: Kind = .secondary
    var size: CGFloat = 28
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        LigButtonBody(configuration: configuration, kind: kind, size: size, selected: selected)
    }
}

private struct LigButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: LigButtonStyle.Kind
    let size: CGFloat
    let selected: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(font)
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: kind == .icon ? size : nil, minHeight: size)
            .background(background, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: kind == .secondary || kind == .chip ? 0.75 : 0))
            .contentShape(shape)
            .scaleEffect(pressed ? 0.95 : (hovering && kind == .primary ? 1.015 : 1))
            .shadow(color: kind == .primary && hovering ? accent.opacity(0.35) : .clear, radius: hovering ? 8 : 0, y: 2)
            .opacity(enabled ? 1 : 0.4)
            .animation(.press, value: pressed)
            .animation(.hover, value: hovering)
            .onHover { h in
                guard enabled else { return }
                hovering = h
            }
    }

    var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: kind == .chip ? size / 2 : (kind == .icon ? 7 : 8), style: .continuous)
    }

    var font: Font {
        switch kind {
        case .icon: .system(size: 13.5, weight: .medium)
        case .chip: .system(size: 11.5, weight: .medium)
        default: .system(size: 12.5, weight: .semibold)
        }
    }

    var horizontalPadding: CGFloat {
        switch kind {
        case .icon: 0
        case .chip: 10
        default: 12
        }
    }

    var foreground: Color {
        switch kind {
        case .primary: .white
        case .destructive: Color(theme.error)
        case .icon, .ghost: selected ? accent : (hovering ? Color(theme.text) : Color(theme.secondary))
        case .chip: selected ? accent : Color(theme.text).opacity(hovering ? 1 : 0.85)
        case .secondary: Color(theme.text)
        }
    }

    var background: Color {
        let p = configuration.isPressed
        switch kind {
        case .primary: return accent.opacity(p ? 0.85 : 1).mix(with: .white, by: hovering && !p ? 0.08 : 0)
        case .secondary: return Color(theme.text).opacity(p ? 0.1 : (hovering ? 0.07 : 0.04))
        case .destructive: return Color(theme.error).opacity(p ? 0.16 : (hovering ? 0.12 : 0.07))
        case .ghost, .icon:
            if selected { return accent.opacity(hovering ? 0.18 : 0.13) }
            return Color(theme.text).opacity(p ? 0.11 : (hovering ? 0.065 : 0))
        case .chip:
            if selected { return accent.opacity(0.14) }
            return Color(theme.text).opacity(p ? 0.1 : (hovering ? 0.07 : 0.035))
        }
    }

    var border: Color {
        switch kind {
        case .secondary: Color(theme.hairline).opacity(hovering ? 1.6 : 1)
        case .chip: selected ? accent.opacity(0.35) : Color(theme.hairline)
        default: .clear
        }
    }
}

extension ButtonStyle where Self == LigButtonStyle {
    static var ligPrimary: LigButtonStyle { LigButtonStyle(kind: .primary) }
    static var ligSecondary: LigButtonStyle { LigButtonStyle(kind: .secondary) }
    static var ligGhost: LigButtonStyle { LigButtonStyle(kind: .ghost) }
    static func ligIcon(size: CGFloat = 28, selected: Bool = false) -> LigButtonStyle { LigButtonStyle(kind: .icon, size: size, selected: selected) }
    static func ligChip(selected: Bool = false) -> LigButtonStyle { LigButtonStyle(kind: .chip, size: 24, selected: selected) }
}

/// An icon button with a tooltip that includes its keyboard shortcut.
struct IconButton: View {
    let symbol: String
    let help: String
    var shortcut: String? = nil
    var size: CGFloat = 28
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .frame(width: size, height: size)
        }
        .buttonStyle(.ligIcon(size: size, selected: selected))
        .help(shortcut.map { "\(help)  \($0)" } ?? help)
        .accessibilityLabel(help)
    }
}

// MARK: Rows

/// A list row that highlights on hover and when selected, with a hover tick.
struct HoverRow: ViewModifier {
    var selected = false
    var cornerRadius: CGFloat = 7
    var tint: Color? = nil
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(selected ? (tint ?? accent).opacity(0.14) : Color(theme.text).opacity(hovering ? 0.055 : 0))
            )
            .animation(.hover, value: hovering)
            .animation(.hover, value: selected)
            .onHover { h in
                hovering = h
            }
    }
}

extension View {
    func hoverRow(selected: Bool = false, cornerRadius: CGFloat = 7, tint: Color? = nil) -> some View {
        modifier(HoverRow(selected: selected, cornerRadius: cornerRadius, tint: tint))
    }

    /// Lift on hover: a slight scale and a deeper shadow, for cards.
    func hoverLift(cornerRadius: CGFloat = 12) -> some View { modifier(HoverLift(cornerRadius: cornerRadius)) }
}

struct HoverLift: ViewModifier {
    var cornerRadius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.025 : 1)
            .shadow(color: .black.opacity(hovering ? 0.18 : 0.06), radius: hovering ? 18 : 6, y: hovering ? 10 : 3)
            .animation(.press, value: hovering)
            .onHover { h in
                hovering = h
            }
    }
}

// MARK: Segmented tabs with a sliding selection pill

struct SlidingTabs<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let symbol: (Item) -> String
    let title: (Item) -> String
    var badge: (Item) -> Int = { _ in 0 }
    var iconOnly = true
    var height: CGFloat = 28
    @Namespace private var ns
    @State private var hovered: Item?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let isOn = item == selection
                Button {
                    guard item != selection else { return }
                    withAnimation(.panel) { selection = item }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: symbol(item))
                            .font(.system(size: 12.5, weight: .medium))
                            .symbolVariant(isOn ? .fill : .none)
                        if !iconOnly { Text(title(item)).font(.system(size: 12, weight: .medium)) }
                    }
                    .foregroundStyle(isOn ? Color(theme.text) : Color(theme.secondary).opacity(hovered == item ? 1 : 0.85))
                    .frame(maxWidth: iconOnly ? .infinity : nil, minHeight: height)
                    .padding(.horizontal, iconOnly ? 0 : 10)
                    .background {
                        if isOn {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color(theme.surface).opacity(theme.isDark ? 0.9 : 1))
                                .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.1), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "pill", in: ns)
                        } else if hovered == item {
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(theme.text).opacity(0.05))
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        let n = badge(item)
                        if n > 0 {
                            Text(n > 99 ? "99+" : "\(n)")
                                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4).frame(minWidth: 14, minHeight: 14)
                                .background(Capsule().fill(Color(theme.error)))
                                .offset(x: -2, y: 1)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(title(item))
                .onHover { h in
                    withAnimation(.hover) { hovered = h ? item : (hovered == item ? nil : hovered) }
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(theme.text).opacity(0.05)))
    }
}

// MARK: Switch

struct LigToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        LigToggleBody(configuration: configuration)
    }
}

private struct LigToggleBody: View {
    let configuration: ToggleStyleConfiguration
    @State private var hovering = false

    var body: some View {
        HStack {
            configuration.label
            Spacer(minLength: 12)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? accent : Color(theme.text).opacity(hovering ? 0.2 : 0.14))
                    .frame(width: 34, height: 20)
                Circle().fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                    .frame(width: 16, height: 16)
                    .padding(2)
                    .scaleEffect(hovering ? 1.06 : 1)
            }
            .animation(.press, value: configuration.isOn)
            .animation(.hover, value: hovering)
            .onTapGesture {
                configuration.isOn.toggle()
            }
            .onHover { h in hovering = h }
        }
    }
}

extension ToggleStyle where Self == LigToggleStyle { static var lig: LigToggleStyle { LigToggleStyle() } }

// MARK: Small pieces

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(Color(theme.secondary))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(theme.text).opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color(theme.hairline), lineWidth: 0.5))
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color(theme.secondary).opacity(0.85))
            Spacer()
            trailing
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color(theme.secondary).opacity(0.6))
                .padding(.bottom, 2)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(theme.text))
            Text(message).font(.system(size: 11.5)).foregroundStyle(Color(theme.secondary))
                .multilineTextAlignment(.center).frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// A floating glass surface used by popovers, the command palette and the PDF controls.
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 14) -> some View { modifier(GlassPanel(cornerRadius: cornerRadius)) }

    /// A solid card surface with a hairline, for content that must stay legible (lists, previews).
    func card(cornerRadius: CGFloat = 12) -> some View {
        self.background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color(theme.surface)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color(theme.hairline), lineWidth: 0.75))
    }
}

/// Renders text with matched characters emphasised (used by the palette and completion lists).
struct HighlightedText: View {
    let text: String
    let query: String
    var font: Font = .system(size: 12.5)
    var body: some View {
        let idx = Set(Fuzzy.matchedIndices(query, text))
        var out = AttributedString()
        for (i, ch) in text.enumerated() {
            var a = AttributedString(String(ch))
            if idx.contains(i) { a.foregroundColor = accent; a.font = font.weight(.bold) }
            out += a
        }
        return Text(out).font(font)
    }
}

import LigatureCore
