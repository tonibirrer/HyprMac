// Keeps the Caps Lock lock off while Caps Lock is the Hypr key.
//
// The Hypr key remaps Caps Lock to F18 (`KeyRemapper`), so the key can no
// longer toggle the lock. Anything else that switches the lock on leaves
// every keystroke capitalised with no key to undo it. Seen 2026-10-05,
// most likely the Citrix Viewer syncing the lock from its remote session
// when it got focus.

import Cocoa
import IOKit
import IOKit.hid

/// Switches the Caps Lock lock back off whenever it turns on while Caps
/// Lock is the Hypr key, and logs which app was in front when it did.
///
/// Checked every second and right after an app activates. Reading the lock
/// is one window-server call; only switching it off opens IOKit.
///
/// Threading: main thread only.
final class CapsLockGuard {
    /// Whether the guard applies: Caps Lock is the Hypr key.
    var isActive: () -> Bool = { false }
    var isLockOn: () -> Bool = { CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift) }
    var switchLockOff: () -> Bool = CapsLockGuard.switchSystemLockOff
    var frontmostApp: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    var now: () -> Date = { Date() }

    private var timer: Timer?
    /// When the lock was last switched off, for the log's rate limit.
    private var recentClears: [Date] = []

    func start(interval: TimeInterval = 1.0) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.check(reason: "watch")
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Switch the lock off if it is on.
    ///
    /// - Returns: whether it was on.
    @discardableResult
    func check(reason: String) -> Bool {
        guard isActive(), isLockOn() else { return false }
        let cleared = switchLockOff()
        let t = now()
        recentClears = recentClears.filter { t.timeIntervalSince($0) < 60 } + [t]
        let front = frontmostApp() ?? "?"
        // something that keeps re-enabling it would fill the log once a second
        if recentClears.count <= 3 {
            hyprLog(.notice, .hotkey, "caps lock: switched on (front=\(front), \(reason)) — Caps Lock is the Hypr key, "
                    + (cleared ? "switched it off" : "switching it off FAILED"))
        } else if recentClears.count == 4 {
            hyprLog(.notice, .hotkey, "caps lock: keeps switching on (front=\(front)) — still switching it off, not logging it again this minute")
        }
        return true
    }

    /// Switch the system Caps Lock lock off through the HID system.
    static func switchSystemLockOff() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else {
            return false
        }
        defer { IOServiceClose(connect) }
        return IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false) == KERN_SUCCESS
    }
}
