// Data tables for the Welcome / Tour window.

import SwiftUI

// MARK: - what's new feature list
// Update this array before each release with features from git log;
// see docs/release.md for the workflow.

/// Accent used for a changelog row's icon tile.
enum WhatsNewTint {
    case cyan   // default
    case magenta // floating / scratchpad features
}

/// One row in the "What's New" page: icon, title, description, tint.
struct WhatsNewFeature {
    let icon: String
    let title: String
    let description: String
    var tint: WhatsNewTint = .cyan
    /// github handle of an outside contributor, shown under the description
    var credit: String? = nil
}

enum WhatsNewFeatures {
    // update this before each release — see docs/release.md
    static let current: [WhatsNewFeature] = [
        WhatsNewFeature(
            icon: "display.2",
            title: "Workspaces on Your Monitors",
            description: "Pick which workspaces live on which monitor in Settings → Layout. The rest keep their usual home."
        ),
        WhatsNewFeature(
            icon: "rectangle.inset.filled",
            title: "Padding per Monitor",
            description: "Give each side of a monitor its own padding, to make room for a custom bar or a side Dock.",
            credit: "@zalewskigrzegorz"
        ),
        WhatsNewFeature(
            icon: "character.cursor.ibeam",
            title: "Workspace Names",
            description: "Name a workspace, and the HUD, menu bar and overview show \"term\" instead of 4.",
            credit: "@zalewskigrzegorz"
        ),
        WhatsNewFeature(
            icon: "arrow.up.and.down.square",
            title: "Move Windows Up and Down",
            description: "Hypr+Ctrl+Up and Down move a window to the monitor above or below.",
            credit: "@BruceChanJianLe"
        ),
        WhatsNewFeature(
            icon: "keyboard",
            title: "Steadier Switches and Moves",
            description: "Typing follows a workspace switch, Hypr+F works on more desks, and windows moved to another monitor fit their tile.",
            credit: "@zalewskigrzegorz"
        ),
    ]
}

enum WelcomeContent {
    static let productURL = URL(string: "https://hyprmac.app/")!

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static func chord(
        in keybinds: [Keybind],
        hyprKey: HyprKey,
        matching predicate: (Action) -> Bool
    ) -> String? {
        guard let bind = keybinds.first(where: { predicate($0.action) }) else { return nil }
        var parts: [String] = []
        if bind.modifiers.contains(.hypr) { parts.append("HYPR") }
        if bind.modifiers.contains(.control) { parts.append("⌃") }
        if bind.modifiers.contains(.option) { parts.append("⌥") }
        if bind.modifiers.contains(.shift) { parts.append("⇧") }
        if bind.modifiers.contains(.command) { parts.append("⌘") }
        parts.append(bind.keyCodeName)
        return parts.joined(separator: " ")
    }
}
