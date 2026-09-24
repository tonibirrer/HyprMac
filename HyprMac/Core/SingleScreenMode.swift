import Foundation

/// Pure helpers for `Action.toggleSingleScreen`: collapse tiling onto one
/// screen by disabling every other monitor, and back.
///
/// Made for screen sharing. With linked monitors the shared screen shows
/// a third of every workspace; one press parks the rest of the desktop
/// on the shared screen — and, when accordion mode is on, stacks it.
enum SingleScreenMode {
    struct Screen: Equatable {
        let name: String
        let isBuiltIn: Bool
        /// The display that owns the menu bar (AppKit origin 0,0).
        let isPrimary: Bool
    }

    /// The screen that stays enabled: the accordion monitor when it is
    /// connected, else the built-in display, else the primary, else the
    /// first one. `nil` when nothing is connected.
    static func screenToKeep(_ screens: [Screen], accordionMonitor: String?) -> Screen? {
        if let name = accordionMonitor, let match = screens.first(where: { $0.name == name }) { return match }
        return screens.first(where: \.isBuiltIn)
            ?? screens.first(where: \.isPrimary)
            ?? screens.first
    }

    /// Every connected screen except `keep`, as the disabled-monitor set.
    static func disabledMonitors(keeping keep: Screen, screens: [Screen]) -> Set<String> {
        Set(screens.filter { $0.name != keep.name }.map(\.name))
    }
}
