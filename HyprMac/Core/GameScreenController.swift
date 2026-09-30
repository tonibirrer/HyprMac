import Cocoa

/// Which running apps count as games.
enum GameDetection {
    /// `true` when the app's Info.plist declares Game Mode support or an
    /// App Store game category (`public.app-category.games` and every
    /// `…-games` subcategory), or when its bundle id is in
    /// `extraBundleIDs` — for games that declare neither.
    static func isGame(info: [String: Any]?, bundleID: String?, extraBundleIDs: Set<String>) -> Bool {
        if let bundleID, extraBundleIDs.contains(bundleID) { return true }
        guard let info else { return false }
        if (info["LSSupportsGameMode"] as? Bool) == true { return true }
        guard let category = info["LSApplicationCategoryType"] as? String else { return false }
        return category == "public.app-category.games"
            || (category.hasPrefix("public.app-category.") && category.hasSuffix("-games"))
    }
}

/// When the game screen is reserved.
enum GameScreenPolicy {
    /// The monitor to reserve, or `nil`. A running game reserves the
    /// configured game monitor only while it is connected, not disabled
    /// by the user, and another enabled screen is left to take the tiles.
    static func reservedMonitor(gameMonitor: String?, gameRunning: Bool,
                                connected: [String], userDisabled: Set<String>) -> String? {
        guard gameRunning, let gameMonitor,
              connected.contains(gameMonitor),
              !userDisabled.contains(gameMonitor) else { return nil }
        let remaining = connected.filter { $0 != gameMonitor && !userDisabled.contains($0) }
        return remaining.isEmpty ? nil : gameMonitor
    }
}

/// Tracks running games and moves their windows onto the game screen.
///
/// The owner (`WindowManager`) turns `gamePIDs` into the reserved monitor
/// and the ignored processes; this class only knows which processes are
/// games and how to carry a game window over. Moving a native-fullscreen
/// window takes three steps — leave fullscreen, move, fullscreen again —
/// because macOS never moves a fullscreen Space between displays.
///
/// Threading: main thread only.
final class GameScreenController {
    /// Running processes detected as games.
    private(set) var gamePIDs: Set<pid_t> = []

    /// Windows already carried over (or found on the game screen). Each
    /// window is moved once, so a game the user drags back stays put.
    private var settledWindowIDs: Set<CGWindowID> = []

    /// Bumped on every schedule so older relocation passes stand down.
    private var passGeneration = 0

    /// Re-detect games among the running apps. Returns `true` when the
    /// set changed.
    @discardableResult
    func refresh(extraBundleIDs: Set<String>, terminatedPID: pid_t? = nil) -> Bool {
        let games = Set(NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular && !app.isTerminated
                && app.processIdentifier != terminatedPID
                && GameDetection.isGame(info: app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary },
                                        bundleID: app.bundleIdentifier, extraBundleIDs: extraBundleIDs)
        }.map(\.processIdentifier))
        guard games != gamePIDs else { return false }
        for pid in games.subtracting(gamePIDs) {
            let name = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
            hyprLog(.notice, .lifecycle, "game running: \(name)")
        }
        if !gamePIDs.subtracting(games).isEmpty {
            hyprLog(.notice, .lifecycle, "game quit — \(games.count) game(s) still running")
        }
        gamePIDs = games
        if games.isEmpty { settledWindowIDs.removeAll() }
        return true
    }

    /// Carry game windows to `screen` now and over the next seconds — a
    /// game shows its window a while after launch, sometimes a splash
    /// first.
    func scheduleRelocation(to screen: @escaping () -> NSScreen?, displayManager: DisplayManager) {
        passGeneration += 1
        let generation = passGeneration
        for delay in [0.5, 1.5, 3.0, 6.0, 12.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, generation == self.passGeneration, let target = screen() else { return }
                self.relocateWindows(to: target, displayManager: displayManager)
            }
        }
    }

    /// One pass: every standard game window not yet on `screen` moves
    /// there.
    func relocateWindows(to screen: NSScreen, displayManager: DisplayManager) {
        for pid in gamePIDs {
            for (element, windowID) in Self.standardWindows(of: pid) where !settledWindowIDs.contains(windowID) {
                let window = HyprWindow(element: element, windowID: windowID, ownerPID: pid)
                guard let current = displayManager.screen(for: window) else { continue }
                settledWindowIDs.insert(windowID)
                guard current != screen else { continue }
                let usable = displayManager.cgRect(for: screen)
                if window.isFullscreen {
                    hyprLog(.notice, .lifecycle, "game window \(windowID) is fullscreen on '\(current.localizedName)' — leaving fullscreen to move it to '\(screen.localizedName)'")
                    Self.setFullscreen(window, false)
                    moveOnceWindowed(window, to: usable, screenName: screen.localizedName, attempt: 0)
                } else {
                    hyprLog(.notice, .lifecycle, "game window \(windowID) moved from '\(current.localizedName)' to '\(screen.localizedName)'")
                    window.setFrame(usable)
                }
            }
        }
    }

    // wait for the fullscreen exit animation, then move and re-enter
    private func moveOnceWindowed(_ window: HyprWindow, to rect: CGRect, screenName: String, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.gamePIDs.contains(window.ownerPID) else { return }
            if window.isFullscreen {
                // 3 s covers the exit animation; a game that never leaves
                // fullscreen stays where it is
                if attempt < 12 {
                    self.moveOnceWindowed(window, to: rect, screenName: screenName, attempt: attempt + 1)
                } else {
                    hyprLog(.notice, .lifecycle, "game window \(window.windowID) did not leave fullscreen — left in place")
                }
                return
            }
            window.setFrame(rect)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                Self.setFullscreen(window, true)
                hyprLog(.notice, .lifecycle, "game window \(window.windowID) moved to '\(screenName)' and back to fullscreen")
            }
        }
    }

    private static func setFullscreen(_ window: HyprWindow, _ on: Bool) {
        let rc = AXUIElementSetAttributeValue(window.element, "AXFullScreen" as CFString,
                                              on ? kCFBooleanTrue : kCFBooleanFalse)
        if rc != .success {
            hyprLog(.notice, .lifecycle, "game window \(window.windowID): AXFullScreen=\(on) failed (err \(rc.rawValue))")
        }
    }

    /// Standard, unminimized AX windows of `pid` with their window ids.
    private static func standardWindows(of pid: pid_t) -> [(AXUIElement, CGWindowID)] {
        var value: AnyObject?
        let appRef = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap { element in
            var subrole: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            guard (subrole as? String) == (kAXStandardWindowSubrole as String) else { return nil }
            var minimized: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized)
            guard (minimized as? Bool) != true else { return nil }
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { return nil }
            return (element, wid)
        }
    }
}
