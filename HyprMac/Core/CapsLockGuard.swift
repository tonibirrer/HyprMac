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
    /// Ask the HID system for a lock state. Returns whether it accepted.
    var setLock: (Bool) -> Bool = CapsLockGuard.setSystemLock
    var frontmostApp: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    var now: () -> Date = { Date() }
    var runAfter: (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private var timer: Timer?
    /// Clears logged one by one before the log goes to a summary a minute.
    private static let loggedClearsPerBurst = 3
    private var burstStart: Date?
    private var clearsInBurst = 0
    /// Clears in a row the lock survived.
    private(set) var failedClears = 0

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

    /// Switch the lock off if it is on, and verify it a moment later.
    ///
    /// A plain "off" is what usually works. Seen 2026-10-05: once, "off"
    /// after "off" changed nothing for minutes, while "on", then "off"
    /// 150 ms later cleared it at once; another time it was the other way
    /// round, most likely the Citrix Viewer re-syncing the lock from its
    /// remote session. So a lock that survived a clear gets the other one.
    ///
    /// - Returns: whether it was on.
    @discardableResult
    func check(reason: String) -> Bool {
        guard isActive(), isLockOn() else { return false }
        let firstTry = failedClears == 0
        if firstTry {
            _ = setLock(false)
        } else {
            _ = setLock(true)
            runAfter(0.15) { [weak self] in _ = self?.setLock(false) }
        }
        noteClear(reason: reason)
        // the flag follows the HID system a moment later
        runAfter(0.5) { [weak self] in
            guard let self else { return }
            if self.isLockOn() {
                self.failedClears += 1
                if self.failedClears == 1 || self.failedClears % 60 == 0 {
                    hyprLog(.notice, .hotkey, "caps lock: still on after switching it off (\(self.failedClears) tries, front=\(self.frontmostApp() ?? "?")) — trying on-then-off")
                }
            } else if self.failedClears > 0 {
                hyprLog(.notice, .hotkey, "caps lock: off after \(self.failedClears + 1) tries")
                self.failedClears = 0
            }
        }
        return true
    }

    private func noteClear(reason: String) {
        let t = now()
        if let start = burstStart, t.timeIntervalSince(start) < 60 {
            clearsInBurst += 1
        } else {
            if clearsInBurst > Self.loggedClearsPerBurst, let start = burstStart {
                hyprLog(.notice, .hotkey, "caps lock: switched off \(clearsInBurst) times since \(Self.clock(start))")
            }
            burstStart = t
            clearsInBurst = 1
        }
        // something that keeps re-enabling it would fill the log once a second
        let front = frontmostApp() ?? "?"
        if clearsInBurst <= Self.loggedClearsPerBurst {
            hyprLog(.notice, .hotkey, "caps lock: switched on (front=\(front), \(reason)) — Caps Lock is the Hypr key, switching it off")
        } else if clearsInBurst == Self.loggedClearsPerBurst + 1 {
            hyprLog(.notice, .hotkey, "caps lock: keeps switching on (front=\(front)) — still switching it off, summing up each minute")
        }
    }

    private static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// Ask the HID system for the Caps Lock lock state.
    static func setSystemLock(_ on: Bool) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else {
            return false
        }
        defer { IOServiceClose(connect) }
        return IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), on) == KERN_SUCCESS
    }
}
