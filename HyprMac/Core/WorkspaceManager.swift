// Virtual workspace bookkeeping. Workspaces are statically anchored to
// monitors via `(N - 1) % enabledMonitorCount` — with 3 monitors,
// ws 1, 4, 7 → Mon1; ws 2, 5, 8 → Mon2; ws 3, 6, 9 → Mon3 — unless the
// user maps them to monitors by name (`workspaceMonitors`).

import Cocoa

/// Single source of truth for HyprMac's virtual workspaces.
///
/// **Static anchoring**: every workspace has a deterministic home
/// monitor, decided by `WorkspaceHomeResolver` from the enabled screens
/// and `workspaceMonitors`. With no mapping that is
/// `enabledScreens[(N - 1) % enabledScreens.count]`. Switching to ws N
/// always lands on its home monitor. Workspaces cannot move between
/// monitors.
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

    /// Workspace → the window that last had focus while assigned to it.
    /// Fed by `noteFocus`; read by the workspace switch so returning to a
    /// workspace lands on the tile the user left, not the first tile in
    /// enumeration order (in accordion mode that is the front slot, so a
    /// Cmd-Tab away and back used to snap the stack to tile 1). Entries
    /// drop when the window closes or moves to another workspace.
    private var lastFocusedWindow: [Int: CGWindowID] = [:]

    /// The workspace each display last showed, by display name. A screen
    /// that leaves and comes back, on every sleep and wake with an
    /// external monitor, lost its entry with its origin key and came back
    /// on its lowest home workspace, which hid the one the user was on
    /// and parked its windows.
    /// The workspace each display last showed, so a display that leaves and
    /// comes back shows it again. Written under the display's name and
    /// under its name and frame; two displays of one model share the name,
    /// so the read takes the framed key while another live display shares
    /// it, and the plain name otherwise, which also covers a display whose
    /// frame moved while it was the only one (clamshell, then the lid open).
    private var lastVisibleByDisplayName: [String: Int] = [:]

    private func rememberVisible(_ workspace: Int, on screen: NSScreen) {
        lastVisibleByDisplayName[screen.localizedName] = workspace
        lastVisibleByDisplayName[Self.framedDisplayKey(screen)] = workspace
    }

    private func rememberedVisible(on screen: NSScreen, among screens: [NSScreen]) -> Int? {
        let shared = screens.contains { $0 !== screen && $0.localizedName == screen.localizedName }
        return shared ? lastVisibleByDisplayName[Self.framedDisplayKey(screen)]
                      : lastVisibleByDisplayName[screen.localizedName]
    }

    private static func framedDisplayKey(_ screen: NSScreen) -> String {
        "\(screen.localizedName)@\(NSStringFromRect(screen.frame))"
    }

    /// Consecutive park writes that failed, per window. The repair poll is
    /// asked for the first few; a window whose app refuses the write for
    /// good is not worth a walk every 0.3 s, and the ordinary poll cycle
    /// still parks it when it can.
    private var parkFailures: [CGWindowID: Int] = [:]
    static let parkRepairRequests = 3

    /// Called when a park write fails, so the caller can ask for the poll
    /// that repairs it. A window left visible on a hidden workspace is a
    /// ghost over the tiles until then.
    var onParkFailed: (() -> Void)?

    /// Localized names of monitors the user has excluded from tiling.
    /// Disabled monitors host floating windows only.
    var disabledMonitors: Set<String> = []

    /// Monitor name → the workspaces the user put on it, from
    /// monitor-config.json. Empty means the formula decides every home.
    var workspaceMonitors: [String: [Int]] = [:] {
        didSet {
            guard workspaceMonitors != oldValue else { return }
            let duplicates = WorkspaceHomeResolver.owners(workspaceMonitors, workspaceCount: workspaceCount).duplicates
            if !duplicates.isEmpty {
                hyprLog(.notice, .lifecycle, "workspace mapping lists ws\(duplicates) under more than one monitor — the name that sorts first keeps each")
            }
        }
    }

    /// Localized names of monitors a running game has taken over
    /// (`GameScreenController`). Off limits for tiles like a disabled
    /// monitor, but runtime-only: never persisted, never part of
    /// `disabledMonitors`, and windows found on one are admitted to an
    /// enabled screen instead of floating in place.
    var reservedMonitors: Set<String> = []

    /// Linked-monitors mode: every enabled screen shows the SAME
    /// workspace, and the workspace's tiles are partitioned across the
    /// screens (each tile lives wholly on one screen — see
    /// `TilingEngine.tileLinked`). Static anchoring is suspended: every
    /// workspace's home is the leftmost enabled screen, and a switch
    /// flips all screens at once. Set from `UserConfig.linkedMonitors`
    /// by the owner; the owner reconciles visibility after a change.
    var linkedMonitors = false

    /// Total number of virtual workspaces (`Constants.workspaceRange`).
    let workspaceCount = Constants.workspaceCount

    /// True while the scratchpad layer is summoned. Workspace 0 is the
    /// scratchpad pseudo-workspace — never in `monitorWorkspace`, so its
    /// visibility is this flag alone. Routing it through
    /// `isWorkspaceVisible` propagates member behavior to FFM, floater
    /// cycling, raise-behind, dim carve-outs, and discovery for free.
    var scratchpadVisible = false

    /// Workspaces (within `Constants.workspaceRange`) that opt into showing sticky windows. Mirrors
    /// `UserConfig.stickyWorkspaces`; set by the owner.
    var stickyWorkspaces: Set<Int> = []

    /// Owner-supplied predicate: `true` when the window's app carries a
    /// sticky window rule (Hyprland's `pin`). Evaluated live so rule
    /// edits apply on the next switch without re-indexing.
    var isStickyWindow: (CGWindowID) -> Bool = { _ in false }

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
    }

    /// Stable per-screen integer key matching the BSP tree's
    /// `TilingKey` derivation. Two screens at the same origin would
    /// collide; in practice macOS prevents that.
    func screenID(for screen: NSScreen) -> Int {
        Int(screen.frame.origin.x * 10000 + screen.frame.origin.y)
    }

    /// `true` when `screen` hosts no tiles: the user disabled it, or a
    /// running game reserved it.
    func isMonitorDisabled(_ screen: NSScreen) -> Bool {
        disabledMonitors.contains(screen.localizedName) || isMonitorReserved(screen)
    }

    /// `true` when `screen` is in the user's `disabledMonitors` list.
    /// Windows on such a screen float in place.
    func isMonitorUserDisabled(_ screen: NSScreen) -> Bool {
        disabledMonitors.contains(screen.localizedName)
    }

    /// `true` when a running game has reserved `screen`.
    func isMonitorReserved(_ screen: NSScreen) -> Bool {
        reservedMonitors.contains(screen.localizedName)
    }

    /// The screen a window physically on `screen` is admitted to. A
    /// reserved screen hands its windows to the nearest enabled screen,
    /// where tiling moves them; any other screen answers itself.
    func admissionScreen(for screen: NSScreen) -> NSScreen {
        guard isMonitorReserved(screen) else { return screen }
        return Self.nearestScreen(to: screen, among: enabledScreensLeftToRight()) ?? screen
    }

    /// The screen in `candidates` whose center is closest to `screen`'s;
    /// the leftmost wins a tie.
    static func nearestScreen(to screen: NSScreen, among candidates: [NSScreen]) -> NSScreen? {
        func distance(_ other: NSScreen) -> CGFloat {
            hypot(other.frame.midX - screen.frame.midX, other.frame.midY - screen.frame.midY)
        }
        return candidates.min { distance($0) < distance($1) }
    }

    // screens sorted left-to-right by CG x origin. two screens on one x, a
    // stacked desk, keep the order NSScreen.screens lists them in, which
    // puts the primary display first: the homes a stacked desk has today
    // stay its homes, and a sort on y would have swapped them on upgrade
    static func leftToRight(_ screens: [NSScreen]) -> [NSScreen] {
        screens.enumerated().sorted { lhs, rhs in
            lhs.element.frame.origin.x != rhs.element.frame.origin.x
                ? lhs.element.frame.origin.x < rhs.element.frame.origin.x
                : lhs.offset < rhs.offset
        }.map(\.element)
    }

    private func screensLeftToRight() -> [NSScreen] {
        Self.leftToRight(displayManager.screens)
    }

    /// Enabled screens left-to-right. Drives `homeScreenForWorkspace`,
    /// and in linked mode the partition order for `tileLinked`.
    func enabledScreensLeftToRight() -> [NSScreen] {
        screensLeftToRight().filter { !isMonitorDisabled($0) }
    }

    // every anchoring answer comes from here
    private func resolvedHomes() -> (enabled: [NSScreen], resolution: WorkspaceHomeResolver.Resolution) {
        let enabled = enabledScreensLeftToRight()
        let resolution = WorkspaceHomeResolver.resolve(
            enabledNames: enabled.map(\.localizedName), mapping: workspaceMonitors,
            workspaceCount: workspaceCount)
        return (enabled, resolution)
    }

    /// Workspaces whose static home is `screen`, in numeric order. Useful
    /// for choosing a monitor's default visible workspace and for capacity
    /// checks that need to know which workspaces "live here." In linked
    /// mode every workspace anchors to the leftmost enabled screen.
    func workspacesAnchoredTo(_ screen: NSScreen) -> [Int] {
        let (enabled, resolution) = resolvedHomes()
        if linkedMonitors {
            return screen == enabled.first ? Array(1...workspaceCount) : []
        }
        let requestedID = screenID(for: screen)
        guard let idx = enabled.firstIndex(where: { screenID(for: $0) == requestedID }) else { return [] }
        return (1...workspaceCount).filter { resolution.homes[$0 - 1] == idx }
    }

    /// The next empty workspace owned by `screen`, in anchored numeric order.
    /// Every assignment reserves a workspace, including floating windows,
    /// except ids in `ignoring` (the caller's hidden set: closed-but-app-
    /// alive, minimized, or Cmd-H'd windows that keep a stale assignment).
    func nextEmptyWorkspace(after source: Int, on screen: NSScreen,
                            ignoring: Set<CGWindowID> = []) -> Int? {
        let anchored = workspacesAnchoredTo(screen)
        guard workspaceForScreen(screen) == source,
              let sourceIndex = anchored.firstIndex(of: source), anchored.count > 1 else { return nil }
        for offset in 1..<anchored.count {
            let candidate = anchored[(sourceIndex + offset) % anchored.count]
            if !isWorkspaceVisible(candidate),
               windowIDs(onWorkspace: candidate).isSubset(of: ignoring) { return candidate }
        }
        return nil
    }

    /// Establish or refresh the screen→workspace mapping.
    ///
    /// Each enabled monitor's currently-visible workspace must be one
    /// whose static home is that monitor. If the existing mapping
    /// satisfies that invariant it is preserved; otherwise the monitor
    /// falls back to its lowest-numbered home workspace (its
    /// left-to-right index + 1 when nothing is mapped). Disabled and
    /// removed monitors lose their entries.
    func initializeMonitors() {
        let allScreens = screensLeftToRight()
        let enabled = allScreens.filter { !isMonitorDisabled($0) }
        if resolvedHomes().resolution.mappingIgnored {
            hyprLog(.notice, .lifecycle, "init: workspace mapping would leave a monitor with no workspace — using the default homes for this layout")
        }

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
                let homeWorkspaces = workspacesAnchoredTo(screen)
                let valid: Set<Int> = Set(homeWorkspaces)
                if let current = monitorWorkspace[sid], valid.contains(current) {
                    rememberVisible(current, on: screen)
                    continue
                }
                // a display that came back shows what it showed before it left,
                // when that is still one of its own
                if let remembered = rememberedVisible(on: screen, among: enabled), valid.contains(remembered) {
                    monitorWorkspace[sid] = remembered
                    hyprLog(.notice, .lifecycle, "init: \(screen.localizedName) back on ws\(remembered), as it left")
                    continue
                }
                // the fallback is not remembered: a display back on a transient
                // topology that makes its own workspace invalid keeps the memory
                // for the topology that settles
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

    /// Static home screen for `workspace`. Pure function of `workspace`,
    /// the current enabled-screens layout and `workspaceMonitors`, through
    /// `WorkspaceHomeResolver`; with no mapping it is
    /// `enabledScreens[(workspace - 1) % enabledScreens.count]`. Returns
    /// `nil` only when no enabled screens exist. In linked mode every
    /// workspace's home is the leftmost enabled screen (the full set is
    /// `homeScreensForWorkspace`).
    func homeScreenForWorkspace(_ workspace: Int) -> NSScreen? {
        guard Constants.workspaceRange.contains(workspace) else { return nil }
        let (enabled, resolution) = resolvedHomes()
        guard !enabled.isEmpty else { return nil }
        if linkedMonitors { return enabled.first }
        return enabled[resolution.homes[workspace - 1]]
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
            if old != workspace { forgetFocus(windowID, leaving: old) }
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

    /// Remember `windowID` as the last-focused window of its workspace.
    /// No-op for unassigned windows (floaters without a workspace).
    func noteFocus(_ windowID: CGWindowID) {
        guard let ws = windowWorkspaces[windowID] else { return }
        lastFocusedWindow[ws] = windowID
    }

    /// The window that last had focus on `workspace`, or `nil` when none
    /// was recorded or it has since left the workspace.
    func lastFocusedWindow(onWorkspace workspace: Int) -> CGWindowID? {
        guard let wid = lastFocusedWindow[workspace],
              windowWorkspaces[wid] == workspace else { return nil }
        return wid
    }

    /// Drop `windowID` from the per-workspace focus memory when it stops
    /// being `old`'s window. Called on every reassignment and removal.
    private func forgetFocus(_ windowID: CGWindowID, leaving old: Int?) {
        guard let old, lastFocusedWindow[old] == windowID else { return }
        lastFocusedWindow.removeValue(forKey: old)
    }

    /// Snapshot regular workspace membership for deterministic bulk operations.
    func regularWorkspaceWindowIDs() -> [Int: Set<CGWindowID>] {
        Dictionary(uniqueKeysWithValues: Constants.workspaceRange.map {
            ($0, workspaceWindowSets[$0] ?? [])
        })
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
            if old != workspace { forgetFocus(windowID, leaving: old) }
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
        parkFailures.removeValue(forKey: windowID)
        if let old = windowWorkspaces[windowID] {
            workspaceWindowSets[old]?.remove(windowID)
            forgetFocus(windowID, leaving: old)
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
    ///
    /// Screens that share the right edge resolve to the lowest one. A screen
    /// below the corner would catch the window's extension, and macOS then
    /// pulls the window onto it under its menu bar, shrunk to fit (#54).
    func hidePosition() -> CGPoint {
        guard let rightmost = displayManager.screens.max(by: {
            let a = displayManager.cgFullRect(for: $0), b = displayManager.cgFullRect(for: $1)
            return (a.maxX, a.maxY) < (b.maxX, b.maxY)
        }) else {
            return .zero
        }
        let cg = displayManager.cgRect(for: rightmost)
        return CGPoint(x: cg.maxX - 1, y: cg.maxY - 1)
    }

    /// Park `window` at the global hide position via the
    /// EnhancedUI-guarded position write.
    func hideInCorner(_ window: HyprWindow, on screen: NSScreen) {
        let pos = hidePosition()
        let rc = window.setPositionOnly(pos)
        guard rc == .success else {
            // the window is still where it was, visible on a hidden
            // workspace. the repair poll re-parks it, a bounded number of
            // times per run of failures
            let failures = (parkFailures[window.windowID] ?? 0) + 1
            parkFailures[window.windowID] = failures
            let asks = failures <= Self.parkRepairRequests
            hyprLog(.notice, .lifecycle, "hide: '\(window.title ?? "?")' (\(window.windowID)) park write failed rc=\(rc.rawValue)"
                    + (asks ? " — repair poll requested" : " — \(failures) in a row, the ordinary poll retries"))
            if asks { onParkFailed?() }
            return
        }
        parkFailures.removeValue(forKey: window.windowID)
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
            // the saved frame may belong to a screen layout that has since
            // changed, so it is clamped like every other floater write
            window.placeFloating(frame, reason: "workspace reveal, saved frame",
                                 displayManager: displayManager)
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

    /// Sticky windows that should follow the user into `workspace`.
    ///
    /// Hyprland's pinned windows show on every workspace of their
    /// monitor; here a sticky window is a member of exactly one workspace
    /// at a time and is *carried* — reassigned — into the workspace being
    /// shown, provided that workspace opts in. Candidates are sticky
    /// windows sitting on hidden workspaces anchored to `workspace`'s
    /// home screen (any hidden workspace in linked mode). Windows on the
    /// scratchpad (ws 0) and on other monitors' workspaces are never
    /// carried. Call after the monitor→workspace flip so the displaced
    /// workspace already counts as hidden; the caller applies capacity
    /// checks and performs the moves.
    func stickyWindowsToCarry(into workspace: Int) -> Set<CGWindowID> {
        guard (1...workspaceCount).contains(workspace),
              stickyWorkspaces.contains(workspace) else { return [] }
        let targetHomes = Set(homeScreensForWorkspace(workspace).map { screenID(for: $0) })
        guard !targetHomes.isEmpty else { return [] }
        var result: Set<CGWindowID> = []
        for ws in 1...workspaceCount where ws != workspace && !isWorkspaceVisible(ws) {
            if !linkedMonitors {
                // static anchoring: a sticky window stays on its own monitor
                guard let home = homeScreenForWorkspace(ws),
                      targetHomes.contains(screenID(for: home)) else { continue }
            }
            for wid in windowIDs(onWorkspace: ws) where isStickyWindow(wid) {
                result.insert(wid)
            }
        }
        return result
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
        guard Constants.workspaceRange.contains(number) else {
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
        rememberVisible(number, on: targetScreen)

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
