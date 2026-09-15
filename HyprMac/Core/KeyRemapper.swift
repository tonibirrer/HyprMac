// HID-level key remap shim. Drives `hidutil` to map Caps Lock → F18 so
// the Hypr key produces clean keyDown/keyUp events that
// `HotkeyManager`'s CGEventTap can intercept; Caps Lock alone is a
// driver-level toggle and never reaches the tap.

import Foundation

/// Static helpers for applying and clearing the Caps Lock → F18 remap.
///
/// Uses `hidutil property --set` under the hood.
///
/// This only works while Caps Lock stays set to "⇪ Caps Lock" in System
/// Settings → Keyboard → Keyboard Shortcuts… → Modifier Keys. That pane
/// applies first, per keyboard, so "No Action" (or any other choice)
/// swallows the key before our mapping or the event tap ever sees it.
/// macOS exposes no supported way to read or change that setting, so
/// HyprMac asks the user to check it — see `HyprKeySystemGuidance`.
class KeyRemapper {
    private static let capsLockHID: UInt = 0x700000039
    private static let f18HID: UInt = 0x70000006D

    /// Apply or restore the remap based on the configured Hypr key.
    /// `hyprKey.usesCapsLockRemap` controls which path runs.
    static func applyHyprKey(_ key: HyprKey) {
        if key.usesCapsLockRemap {
            remapCapsLockToF18()
        } else {
            restoreCapsLock()
        }
    }

    static func remapCapsLockToF18() {
        // assumes Modifier Keys still has Caps Lock on "⇪ Caps Lock";
        // we can't read that, so the UI asks the user instead
        let mapping: [[String: UInt]] = [
            [
                "HIDKeyboardModifierMappingSrc": capsLockHID,
                "HIDKeyboardModifierMappingDst": f18HID
            ]
        ]
        applyMapping(mapping)
        hyprLog(.debug, .lifecycle, "remapped Caps Lock → F18")
    }

    static func restoreCapsLock() {
        applyMapping([])
        hyprLog(.debug, .lifecycle, "restored Caps Lock to default")
    }

    private static func applyMapping(_ mapping: [[String: UInt]]) {
        // use hidutil CLI — reliable and doesn't need special entitlements
        let json: [String: Any] = ["UserKeyMapping": mapping]
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let jsonString = String(data: data, encoding: .utf8) else { return }

        let task = Process()
        task.launchPath = "/usr/bin/hidutil"
        task.arguments = ["property", "--set", jsonString]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try? task.run()
        task.waitUntilExit()
    }
}
