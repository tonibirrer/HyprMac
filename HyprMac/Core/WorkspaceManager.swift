// Virtual workspace bookkeeping. Workspaces are statically anchored to
// monitors via `(N - 1) % enabledMonitorCount` — with 3 monitors,
// ws 1, 4, 7 → Mon1; ws 2, 5, 8 → Mon2; ws 3, 6, 9 → Mon3.

import Cocoa

/// Single source of truth for HyprMac's nine virtual workspaces.
///
/// **Static anchoring**: every workspace has a deterministic home
/// monitor computed as `enabledScreens[(N - 1) % enabledScreens.count]`.
/// Switching to ws N always lands on its home monitor. Workspaces
/// cannot move between monitors.
///
/// Owns:
/// - `monitorWorkspace`: which workspace is currently visible on each
///   screen (keyed by `screenID`). Invariant: any value here must have
///   the keyed screen as its static home.
/// - `windowWorkspaces` (private): window → workspace assignment.
/// - `savedFloatingFrames` (private): per-window floating frames
///   captured before a hide, restored on show.
///
/// Threading: main-thread only.
class WorkspaceManager {
    let displayManager: DisplayManager

    /// Screen → workspace currently shown on that screen.
    private(set) var monitorWorkspace: [Int: Int] = [:]

    /// Window → workspace assignment.
    private var windowWorkspaces: [CGWindowID: Int] = [:]

    /// Reverse index of `windowWorkspaces`. Kept in sync by every
    /// `assignWindow` / `removeWindow` / `moveWindow` call.
    private var workspaceWindowSets: [Int: Set<CGWindowID>] = [:]

    /// Pre-hide frames for floating windows. Restored on the next
    /// reveal so floaters return to their last user-chosen position.
    private var savedFloatingFrames: [CGWindowID: CGRect] = [:]

    /// Localized names of monitors the user has excluded from tiling.
    /// Disabled monitors host floating windows only.
    var disabledMonitors: Set<String> = []

    /// Linked-monitors mode: every enabled screen shows the SAME
    /// workspace, and the workspace's tiles are partitioned across the
    /// screens (each tile lives wholly on one screen — see
    /// `TilingEngine.tileLinked`). Static anchoring is suspended: every
    /// workspace's home is the leftmost enabled screen, and a switch
    /// flips all screens at once. Set from `UserConfig.linkedMonitors`
    /// by the owner; the owner reconciles visibility after a change.
    var linkedMonitors = false

    /// Total number of virtual workspaces (1...9).
    let workspaceCount = 9

    /// True while the scratchpad layer is summoned. Workspace 0 is the
    /// scratchpad pseudo-workspace — never in `monitorWorkspace`, so its
    /// visibility is this flag alone. Routing it through
    /// `isWorkspaceVisible` propagates member behavior to FFM, floater
    /// cycling, raise-behind, dim carve-outs, and discovery for free.
    var scratchpadVisible = false

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
    }

    /// Stable per-screen integer key matching the BSP tree's
    /// `TilingKey` derivation. Two screens at the same origin would
    /// collide; in practice macOS prevents that.
    func screenID(for screen: NSScreen) -> Int {
        Int(screen.frame.origin.x * 10000 + screen.frame.origin.y)
    }

    /// `true` when `screen` is in the user's `disabledMonitors` list.
    func isMonitorDisabled(_ screen: NSScreen) -> Bool {
        disabledMonitors.contains(screen.localizedName)
    }

    // screens sorted left-to-right by CG x origin
    private func screensLeftToRight() -> [NSScreen] {
        displayManager.screens.sorted { $0.frame.origin.x < $1.frame.origin.x }
    }

    /// Enabled screens left-to-right. Drives `homeScreenForWorkspace`,
    /// and in linked mode the partition order for `tileLinked`.
    func enabledScreensLeftToRight() -> [NSScreen] {
        screensLeftToRight().filter { !isMonitorDisabled($0) }
    }

    /// Workspaces whose static home is `screen`. Useful for choosing a
    /// monitor's default visible workspace and for capacity checks that
    /// need to know which workspaces "live here." In linked mode every
    /// workspace anchors to the leftmost enabled screen.
    func workspacesAnchoredTo(_ screen: NSScreen) -> [Int] {
        let enabled = enabledScreensLeftToRight()
        if linkedMonitors {
            return screen == enabled.first ? Array(1...workspaceCount) : []
        }
        return staticWorkspacesAnchoredTo(screen, enabled: enabled)
    }

    // the pure static-anchoring computation, independent of `linkedMonitors`.
    private func staticWorkspacesAnchoredTo(_ screen: NSScreen, enabled: [NSScreen]) -> [Int] {
        guard let idx = enabled.firstIndex(of: screen) else { return [] }
        let count = enabled.count
        return Array(stride(from: idx + 1, through: workspaceCount, by: count))
    }

    /// Establish or refresh the screen→workspace mapping.
    ///
    /// Each enabled monitor's currently-visible workspace must be one
    /// whose static home is that monitor. If the existing mapping
    /// satisfies that invariant it is preserved; otherwise the monitor
    /// falls back to its lowest-numbered home workspace (its
    /// left-to-right index + 1). Disabled and removed monitors lose
    /// their entries.
    func initializeMonitors() {
        let allScreens = screensLeftToRight()
        let enabled = allScreens.filter { !isMonitorDisabled($0) }

        // remove workspace assignments for disabled monitors
        for screen in allScreens where isMonitorDisabled(screen) {
            let sid = screenID(for: screen)
            if let ws = monitorWorkspace.removeValue(forKey: sid) {
                hyprLog(.debug, .lifecycle, "init: removed ws\(ws) from disabled monitor \(screen.localizedName)")
            }
        }

        if linkedMonitors {
            // linked mode: one global workspace on every enabled screen.
            // the leftmost screen's current workspace wins (deterministic,
            // and it's the screen a fresh link most likely keeps).
            let global = enabled.first.flatMap { monitorWorkspace[screenID(for: $0)] } ?? 1
            for screen in enabled {
                monitorWorkspace[screenID(for: screen)] = global
            }
        } else {
            // for each enabled screen, ensure its current visible workspace
            // is one whose static home is this screen — otherwise default
            // to that screen's lowest-numbered home workspace.
            for screen in enabled {
                let sid = screenID(for: screen)
                let homeWorkspaces = staticWorkspacesAnchoredTo(screen, enabled: enabled)
                let valid: Set<Int> = Set(homeWorkspaces)
                if let current = monitorWorkspace[sid], valid.contains(current) {
                    continue
                }
                monitorWorkspace[sid] = homeWorkspaces.first ?? 1
            }
        }

        // clean up stale entries for screens that no longer exist
        let currentSIDs = Set(allScreens.map { screenID(for: $0) })
        for sid in monitorWorkspace.keys where !currentSIDs.contains(sid) {
            monitorWorkspace.removeValue(forKey: sid)
        }

        hyprLog(.debug, .lifecycle, "init: monitors=\(monitorWorkspace) enabled=\(enabled.count)")
    }

    /// Workspace currently visible on `screen`. Self-heals by calling
    /// `initializeMonitors` and retrying when the screen has no
    /// mapping — that path should not normally fire and logs a warning
    /// when it does.
    func workspaceForScreen(_ screen: NSScreen) -> Int {
        let sid = screenID(for: screen)
        if let ws = monitorWorkspace[sid] {
            return ws
        }
        hyprLog(.debug, .lifecycle, "WARNING: screen \(sid) had no workspace, reinitializing")
        initializeMonitors()
        return monitorWorkspace[sid] ?? 1
    }

    /// Screen currently showing `workspace`, or `nil` when the
    /// workspace is hidden. In linked mode several screens show the
    /// same workspace — the leftmost wins so the answer is
    /// deterministic (dictionary iteration order is not).
    func screenForWorkspace(_ workspace: Int) -> NSScreen? {
        screensLeftToRight().first { monitorWorkspace[screenID(for: $0)] == workspace }
    }

    /// Static home screen for `workspace`. Pure function of `workspace`
    /// and the current enabled-screens layout. Indexed by
    /// `(workspace - 1) % enabledScreens.count`. In linked mode every
    /// workspace's home is the leftmost enabled screen (the full set is
    /// `homeScreensForWorkspace`). Returns `nil` only when no enabled
    /// screens exist.
    func homeScreenForWorkspace(_ workspace: Int) -> NSScreen? {
        guard workspace >= 1 && workspace <= workspaceCount else { return nil }
        let enabled = enabledScreensLeftToRight()
        guard !enabled.isEmpty else { return nil }
        if linkedMonitors { return enabled.first }
        return enabled[(workspace - 1) % enabled.count]
    }

    /// Every screen `workspace` may legitimately occupy trees on. One
    /// static home normally; all enabled screens in linked mode. Drives
    /// `TilingEngine.handleDisplayChange` tree validity.
    func homeScreensForWorkspace(_ workspace: Int) -> [NSScreen] {
        if linkedMonitors {
            guard workspace >= 1 && workspace <= workspaceCount else { return [] }
            return enabledScreensLeftToRight()
        }
        return homeScreenForWorkspace(workspace).map { [$0] } ?? []
    }

    /// `true` when `workspace` is currently shown on any screen.
    /// Workspace 0 (scratchpad) is visible only while summoned.
    func isWorkspaceVisible(_ workspace: Int) -> Bool {
        if workspace == 0 { return scratchpadVisible }
        return monitorWorkspace.values.contains(workspace)
    }

    /// Assign `windowID` to `workspace`, removing it from any prior
    /// workspace assignment in the same call.
    func assignWindow(_ windowID: CGWindowID, toWorkspace workspace: Int) {
        let oldDesc: String
        if let old = windowWorkspaces[windowID] {
            workspaceWindowSets[old]?.remove(windowID)
            oldDesc = "ws\(old)"
        } else {
            oldDesc = "none"
        }
        windowWorkspaces[windowID] = workspace
        workspaceWindowSets[workspace, default: []].insert(windowID)
        if oldDesc != "ws\(workspace)" {
            hyprLog(.notice, .lifecycle, "assignWindow: wid=\(windowID) \(oldDesc) → ws\(workspace)")
        }
    }

    /// Workspace a window is assigned to, or `nil` when no
    /// assignment exists.
    func workspaceFor(_ windowID: CGWindowID) -> Int? {
        windowWorkspaces[windowID]
    }

    /// `true` when `windowID`'s workspace is currently visible (or
    /// when the window has no assignment — floating windows take this
    /// branch).
    func isWindowVisible(_ windowID: CGWindowID) -> Bool {
        guard let ws = windowWorkspaces[windowID] else { return true }
        return isWorkspaceVisible(ws)
    }

    /// Every window assigned to `workspace`. Includes hidden windows.
    func windowIDs(onWorkspace workspace: Int) -> Set<CGWindowID> {
        workspaceWindowSets[workspace] ?? []
    }

    /// Snapshot of the live window→workspace map.
    func allWindowWorkspaces() -> [CGWindowID: Int] {
        windowWorkspaces
    }

    /// Move `windowID` to `workspace`. Identical effect to
    /// `assignWindow`; the alias clarifies caller intent at the use
    /// site.
    func moveWindow(_ windowID: CGWindowID, toWorkspace workspace: Int) {
        let oldDesc: String
        if let old = windowWorkspaces[windowID] {
            workspaceWindowSets[old]?.remove(windowID)
            oldDesc = "ws\(old)"
        } else {
            oldDesc = "none"
        }
        windowWorkspaces[windowID] = workspace
        workspaceWindowSets[workspace, default: []].insert(windowID)
        if oldDesc != "ws\(workspace)" {
            hyprLog(.notice, .lifecycle, "moveWindow: wid=\(windowID) \(oldDesc) → ws\(workspace)")
        }
    }

    /// Drop `windowID` from workspace tracking entirely. Used when the
    /// window closes or its app terminates.
    func removeWindow(_ windowID: CGWindowID) {
        if let old = windowWorkspaces[windowID] {
            workspaceWindowSets[old]?.remove(windowID)
        }
        windowWorkspaces.removeValue(forKey: windowID)
        savedFloatingFrames.removeValue(forKey: windowID)
    }

    /// Single global park position: 1px inside the bottom-right corner
    /// of the rightmost monitor. Because nothing lives to the right of
    /// the rightmost monitor (and typically nothing below it either),
    /// the window's off-screen extension area never overlaps another
    /// monitor — so macOS WindowServer doesn't trigger the
    /// rescale-to-neighbor bug that breaks per-monitor corner-park on
    /// middle monitors in horizontal multi-monitor layouts.
    func hidePosition() -> CGPoint {
        guard let rightmost = displayManager.screens.max(by: { $0.frame.maxX < $1.frame.maxX }) else {
            return .zero
        }
        let cg = displayManager.cgRect(for: rightmost)
        return CGPoint(x: cg.maxX - 1, y: cg.maxY - 1)
    }

    /// Park `window` at the global hide position via the
    /// EnhancedUI-guarded position write.
    func hideInCorner(_ window: HyprWindow, on screen: NSScreen) {
        let pos = hidePosition()
        window.setPositionOnly(pos)
        hyprLog(.debug, .lifecycle, "hide: '\(window.title ?? "?")' (\(window.windowID)) parked at (\(Int(pos.x)),\(Int(pos.y)))")
    }

    /// Capture `window`'s current frame so it can be restored after a
    /// workspace switch. No-op when the window has no readable frame or
    /// when the frame is off-screen — saving a hide-corner park position
    /// would strand the floater in the corner sliver on the next
    /// restore. Keeps any previously-saved on-screen frame instead.
    func saveFloatingFrame(_ window: HyprWindow) {
        guard let frame = window.frame else { return }
        let onScreen = displayManager.screens.contains { screen in
            frame.isSubstantiallyVisible(on: displayManager.cgRect(for: screen))
        }
        guard onScreen else {
            hyprLog(.debug, .lifecycle, "saveFloatingFrame: skipped off-screen frame for \(window.windowID)")
            return
        }
        savedFloatingFrames[window.windowID] = frame
    }

    /// Apply the saved floating frame to `window` and clear the saved
    /// entry. No-op when no frame was captured.
    func restoreFloatingFrame(_ window: HyprWindow) {
        if let frame = savedFloatingFrames[window.windowID] {
            window.setFrame(frame)
            savedFloatingFrames.removeValue(forKey: window.windowID)
        }
    }

    /// Peek without consuming — the scratchpad computes carry geometry
    /// from the intended frame instead of a laggy AX read.
    func savedFloatingFrame(for id: CGWindowID) -> CGRect? {
        savedFloatingFrames[id]
    }

    func clearSavedFloatingFrame(for id: CGWindowID) {
        savedFloatingFrames.removeValue(forKey: id)
    }

    /// Explicit unconditional save — used when a live AX read was stale
    /// and `saveFloatingFrame`'s off-screen guard rejected it, so the
    /// caller substitutes the frame it knows it placed.
    func setSavedFloatingFrame(_ frame: CGRect, for id: CGWindowID) {
        savedFloatingFrames[id] = frame
    }

    /// Result of `switchWorkspace`. `toHide` and `toShow` are window
    /// id sets the caller drives through hide-corner and tile.
    /// `alreadyVisible` skips the hide/show pass entirely.
    struct SwitchResult {
        let toHide: Set<CGWindowID>
        let toShow: Set<CGWindowID>
        let screen: NSScreen
        let alreadyVisible: Bool
    }

    /// Switch to workspace `number`. Always lands on the workspace's
    /// static home monitor — except in linked mode, where every enabled
    /// screen switches to `number` together.
    ///
    /// - Parameter cursorScreen: kept for signature compatibility;
    ///   only used as the empty-result fallback when no enabled screens
    ///   exist or `number` is out of range, and as the linked-mode
    ///   result screen (the warp target for an empty workspace).
    func switchWorkspace(_ number: Int, cursorScreen: NSScreen) -> SwitchResult {
        guard number >= 1 && number <= workspaceCount else {
            return SwitchResult(toHide: [], toShow: [], screen: cursorScreen, alreadyVisible: false)
        }

        if linkedMonitors {
            return switchAllLinked(to: number, cursorScreen: cursorScreen)
        }

        guard let targetScreen = homeScreenForWorkspace(number) else {
            return SwitchResult(toHide: [], toShow: [], screen: cursorScreen, alreadyVisible: false)
        }

        let targetSID = screenID(for: targetScreen)

        if monitorWorkspace[targetSID] == number {
            hyprLog(.notice, .lifecycle, "switch: ws\(number) already visible on \(targetScreen.localizedName)")
            return SwitchResult(toHide: [], toShow: windowIDs(onWorkspace: number),
                                screen: targetScreen, alreadyVisible: true)
        }

        let oldWorkspace = monitorWorkspace[targetSID] ?? (workspacesAnchoredTo(targetScreen).first ?? 1)
        let toHide = windowIDs(onWorkspace: oldWorkspace)
        let toShow = windowIDs(onWorkspace: number)

        monitorWorkspace[targetSID] = number

        hyprLog(.notice, .lifecycle, "switch: \(targetScreen.localizedName) ws\(oldWorkspace)→ws\(number) (hide \(toHide.count), show \(toShow.count))")
        return SwitchResult(toHide: toHide, toShow: toShow, screen: targetScreen, alreadyVisible: false)
    }

    /// Linked-mode switch: every enabled screen flips to `number` at
    /// once. `toHide` is the union of all previously-visible workspaces'
    /// windows (a fresh link can leave different workspaces on different
    /// screens); already-visible means every enabled screen shows
    /// `number`. The result screen is the cursor's, so the
    /// empty-workspace warp stays where the user is looking.
    private func switchAllLinked(to number: Int, cursorScreen: NSScreen) -> SwitchResult {
        let enabled = enabledScreensLeftToRight()
        guard !enabled.isEmpty else {
            return SwitchResult(toHide: [], toShow: [], screen: cursorScreen, alreadyVisible: false)
        }

        let oldWorkspaces = Set(enabled.compactMap { monitorWorkspace[screenID(for: $0)] })
        if oldWorkspaces == [number] {
            hyprLog(.notice, .lifecycle, "switch(linked): ws\(number) already visible on all screens")
            return SwitchResult(toHide: [], toShow: windowIDs(onWorkspace: number),
                                screen: cursorScreen, alreadyVisible: true)
        }

        var toHide: Set<CGWindowID> = []
        for ws in oldWorkspaces where ws != number {
            toHide.formUnion(windowIDs(onWorkspace: ws))
        }
        let toShow = windowIDs(onWorkspace: number)

        for screen in enabled {
            monitorWorkspace[screenID(for: screen)] = number
        }

        hyprLog(.notice, .lifecycle, "switch(linked): ws\(oldWorkspaces.sorted())→ws\(number) on \(enabled.count) screens (hide \(toHide.count), show \(toShow.count))")
        return SwitchResult(toHide: toHide, toShow: toShow, screen: cursorScreen, alreadyVisible: false)
    }
}
