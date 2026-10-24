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
            icon: "square.grid.2x2",
            title: "Fewer Floating Windows at Launch",
            description: "When a workspace can't fit every window, HyprMac tiles the ones that fit and floats only the rest, instead of floating them all.",
            tint: .magenta
        ),
        WhatsNewFeature(
            icon: "keyboard",
            title: "No Duplicate Shortcuts",
            description: "The Keys tab won't save a shortcut another keybind already uses, and tells you which one has it."
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
