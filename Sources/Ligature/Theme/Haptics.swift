import AppKit

/// Haptic feedback through the Force Touch trackpad, used for exactly three moments: the editor/PDF divider
/// snapping to a preset, a force click, and the result of a compile you started. Everything uses the system's
/// lightest pattern (alignment), and a cooldown stops taps from stacking up.
@MainActor
enum Haptics {
    enum Event {
        /// The editor/PDF divider settled onto ⅓, ½ or ⅔.
        case snap
        /// A force click opened a peek or jumped between source and PDF.
        case forceClick
        /// A compile you started finished cleanly: one soft tap.
        case success
        /// A compile you started finished with errors: two soft taps.
        case failure
    }

    private static var last: TimeInterval = 0

    static func play(_ event: Event) {
        guard Preferences.shared.haptics else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - last > 0.12 else { return }
        last = now
        let performer = NSHapticFeedbackManager.defaultPerformer
        performer.perform(.alignment, performanceTime: .now)
        if event == .failure {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { performer.perform(.alignment, performanceTime: .now) }
        }
    }
}
