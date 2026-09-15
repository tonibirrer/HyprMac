// macOS remaps modifier keys in System Settings → Keyboard → Keyboard
// Shortcuts… → Modifier Keys, before hidutil and before any CGEvent
// exists. If the Hypr key is remapped there, HyprMac never sees it.
// This is the copy that tells the user to leave it alone.

import AppKit
import Foundation

/// What the user must keep set in Modifier Keys for the chosen Hypr key
/// to reach HyprMac. `nil` when that pane cannot remap the key.
struct HyprKeySystemGuidance: Equatable {
    let keyName: String
    let requiredAction: String

    // the pane only lists Caps Lock, Control, Option, Command (and Function
    // and Globe). shift, tab, backtick, backslash and F13–F20 are safe.
    static func forKey(_ key: HyprKey) -> HyprKeySystemGuidance? {
        switch key {
        case .capsLock:
            return HyprKeySystemGuidance(keyName: "Caps Lock", requiredAction: "⇪ Caps Lock")
        case .leftControl, .rightControl:
            return HyprKeySystemGuidance(keyName: "Control", requiredAction: "⌃ Control")
        case .leftOption, .rightOption:
            return HyprKeySystemGuidance(keyName: "Option", requiredAction: "⌥ Option")
        case .leftCommand, .rightCommand:
            return HyprKeySystemGuidance(keyName: "Command", requiredAction: "⌘ Command")
        case .tab, .grave, .backslash,
             .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
             .leftShift, .rightShift:
            return nil
        }
    }

    static let settingsPath = "System Settings → Keyboard → Keyboard Shortcuts… → Modifier Keys"

    static let keyboardSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?CustomizeModifierKeys")!

    static let openButtonTitle = "Open Keyboard Settings"

    var title: String {
        "Keep \(keyName) set to \"\(requiredAction)\" in macOS Modifier Keys."
    }

    var detail: String {
        "Check \(Self.settingsPath) for each keyboard you use. \"No Action\" or any other choice hides \(keyName) from HyprMac. HyprMac can't check it for you."
    }

    /// Opens the Keyboard pane. Returns false when macOS refused the URL,
    /// so callers keep showing the path in words either way.
    @discardableResult
    static func openKeyboardSettings(
        using open: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Bool {
        open(keyboardSettingsURL)
    }
}
