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
            icon: "square.and.arrow.down.on.square",
            title: "Saved Layouts",
            description: "Hypr+Ctrl+S saves which workspace every window is on and how each one is split, across all your monitors. Hypr+Ctrl+R puts it back, and plugging a saved display setup back in restores it on its own.",
            credit: "@joops"
        ),
        WhatsNewFeature(
            icon: "keyboard",
            title: "A Balanced Keybind List",
            description: "Hypr+K now spreads its shortcuts evenly: window management on the left, apps and system in the middle, workspaces and focus on the right."
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
