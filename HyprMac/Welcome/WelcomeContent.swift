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
            icon: "rectangle.split.2x2",
            title: "Steadier Tiling",
            description: "Windows keep their tile when an app is slow to answer, splits survive a minimize, and saved layouts restore to the same shape.",
            credit: "@Amin-El-Sayed"
        ),
        WhatsNewFeature(
            icon: "display.2",
            title: "Displays After Sleep",
            description: "Workspaces come back on the right monitor after sleep or a reconnect, and Caps Lock stays your Hypr key.",
            credit: "@Amin-El-Sayed"
        ),
        WhatsNewFeature(
            icon: "hourglass",
            title: "Frozen Apps Don't Stall Tiling",
            description: "An app that stops answering no longer holds up switches, moves and layouts for everything else.",
            credit: "@Amin-El-Sayed"
        ),
        WhatsNewFeature(
            icon: "square.grid.3x3",
            title: "Live Overview",
            description: "The Hypr+O overview updates while it's open."
        ),
        WhatsNewFeature(
            icon: "paintpalette",
            title: "Your Floating Color Everywhere",
            description: "Overlays mark floating windows in the floating color you picked in Settings.",
            tint: .magenta
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
