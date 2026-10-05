import Cocoa

/// Makes a native-fullscreen window behave like any other window of its
/// workspace: it belongs to one workspace (`FullscreenMembers`), takes its
/// display while that workspace is up, shows when the workspace is switched
/// to, and gets out of the way when another workspace is.
///
/// macOS gives a fullscreen window a Space of its own, and every tile and
/// parked window of the virtual workspaces sits on the display's desktop
/// Space behind it. Three facts, verified live, carry the design:
/// - activating the window's app shows its Space;
/// - focusing a window on the display's desktop Space shows the desktop
///   again, even when the app has windows on other displays (hiding the
///   fullscreen app does not: its Space stays up, empty);
/// - a window behind the fullscreen Space drops out of the on-screen list
///   and out of AX's window list, but an AX element read before still
///   reads and writes it, so the snapshot keeps such a window present
///   (`windowsBehindFullscreen`) instead of letting discovery file it as
///   hidden and the tiler lose it.
///
/// Games are left alone: their processes are ignored, as the game screen
/// owns them.
///
/// Threading: main thread only.
final class FullscreenSpaceController {

    let members = FullscreenMembers()
    private let reader = FullscreenSpaceReader()

    /// Processes whose fullscreen windows are not workspace members.
    var ignoredPIDs: () -> Set<pid_t> = { [] }
    /// Workspace for a fullscreen window seen for the first time.
    var workspaceForNewMember: (FullscreenWindowObservation) -> Int = { _ in 1 }
    /// A window joined; a tracked tile that went fullscreen must leave tiling.
    var memberJoined: (FullscreenMember) -> Void = { _ in }
    var memberLeft: (FullscreenMember) -> Void = { _ in }
    /// Runs `work` on the main queue after `delay`.
    var runAfter: (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - state

    /// What a `refresh` found.
    struct Refresh {
        /// A member joined or left: the screens a workspace tiles on changed.
        var membershipChanged = false
        /// Members whose Space came up since the last refresh.
        var newlyShown: [FullscreenMember] = []
    }

    /// Re-read the Spaces and bring the members in line. Cheap when no
    /// display has a fullscreen Space: one window-server call.
    @discardableResult
    func refresh() -> Refresh {
        let displays = reader.displays()
        let observed = displays.contains { !$0.fullscreenSpaces.isEmpty }
            ? reader.fullscreenWindows(in: displays, ignoring: ignoredPIDs())
            : []
        let wasShowing = Set(members.byWindow.values.filter(\.isShowing).map(\.windowID))
        let (added, removed) = members.reconcile(observed, assign: workspaceForNewMember)
        for member in added {
            let app = NSRunningApplication(processIdentifier: member.pid)?.bundleIdentifier ?? "pid \(member.pid)"
            hyprLog(.notice, .lifecycle, "fullscreen: \(app) window \(member.windowID) joins ws\(member.workspace) — takes \(screenName(member.displayUUID)) while ws\(member.workspace) is up")
            memberJoined(member)
        }
        for member in removed {
            hyprLog(.notice, .lifecycle, "fullscreen: window \(member.windowID) left fullscreen or closed — ws\(member.workspace) gets \(screenName(member.displayUUID)) back")
            memberLeft(member)
        }
        let newlyShown = members.byWindow.values
            .filter { $0.isShowing && !wasShowing.contains($0.windowID) }
            .sorted { $0.windowID < $1.windowID }
        return Refresh(membershipChanged: !added.isEmpty || !removed.isEmpty, newlyShown: newlyShown)
    }

    /// The screens among `screens` that `workspace`'s fullscreen members take.
    func screensTaken(onWorkspace workspace: Int, among screens: [NSScreen]) -> [NSScreen] {
        let taken = members.occupiedDisplays(onWorkspace: workspace)
        guard !taken.isEmpty else { return [] }
        return screens.filter { FullscreenSpaceReader.displayUUID(for: $0).map(taken.contains) ?? false }
    }

    /// The workspace of a fullscreen window whose Space just came up
    /// although the workspace is not up — the user swiped or ⌘-Tabbed into
    /// it. Only a Space that came up counts: one that stayed up while
    /// HyprMac leaves it must not pull the user back.
    static func workspaceShownOutOfTurn(_ refresh: Refresh, visibleWorkspaces: Set<Int>) -> Int? {
        refresh.newlyShown.map(\.workspace).filter { !visibleWorkspaces.contains($0) }.min()
    }

    /// The windows a workspace with no screen left has to refuse: those
    /// without a tile yet. Its tiles keep their slots behind the fullscreen
    /// Space, and floaters float on.
    static func windowsWithoutRoom(_ windows: [HyprWindow], tiled: Set<CGWindowID>,
                                   floating: Set<CGWindowID>) -> [HyprWindow] {
        windows.filter { !tiled.contains($0.windowID) && !floating.contains($0.windowID) }
    }

    // MARK: - snapshot

    /// The windows among `candidates` that sit on the desktop Space of a
    /// display showing a fullscreen Space: out of the on-screen list and
    /// AX's window list, but still there and still writable through the
    /// element `candidates` carry. Their frames are refreshed from the
    /// window server.
    func windowsBehindFullscreen(_ candidates: [HyprWindow]) -> [HyprWindow] {
        let covered = reader.displays().filter(\.currentIsFullscreen)
        guard !covered.isEmpty, !candidates.isEmpty else { return [] }
        let desktops = covered.reduce(into: Set<CGSSpaceID>()) { $0.formUnion($1.desktopSpaces) }
        return candidates.filter { window in
            let spaces = reader.spaces(of: window.windowID)
            guard !spaces.isEmpty, Set(spaces).isSubset(of: desktops),
                  NSRunningApplication(processIdentifier: window.ownerPID)?.isHidden == false,
                  !window.isMinimized,
                  let bounds = Self.windowServerBounds(window.windowID) else { return false }
            window.cachedFrame = bounds
            return true
        }
    }

    // MARK: - switching

    /// Show `workspace`'s fullscreen windows: activate each one's app,
    /// which brings its Space up, and put the cursor on its display so
    /// focus-follows-mouse does not hand focus to a tile under it.
    ///
    /// - Returns: whether the workspace has a fullscreen window.
    @discardableResult
    func present(workspace: Int, warpCursor: (CGRect) -> Void) -> Bool {
        let shown = members.members(onWorkspace: workspace)
        guard !shown.isEmpty else { return false }
        for member in shown {
            NSRunningApplication(processIdentifier: member.pid)?.activate(options: [.activateIgnoringOtherApps])
        }
        if let rect = shown.first.flatMap({ displayRect($0.displayUUID) }) {
            warpCursor(rect)
        }
        hyprLog(.notice, .lifecycle, "fullscreen: ws\(workspace) up — showing \(shown.map(\.windowID))")
        return true
    }

    /// Take every display that shows another workspace's fullscreen window
    /// back to its desktop Space.
    ///
    /// Focusing a window on the display's desktop Space does it. When the
    /// window the switch focuses (`focused`) is on that display, its focus
    /// already did; otherwise an anchor — a window of `anchors` on that
    /// desktop Space — is focused, and `refocus` runs once the desktop is
    /// up so focus ends where the switch put it.
    func leaveForeignSpaces(for workspace: Int, focused: HyprWindow?, anchors: [HyprWindow],
                            refocus: @escaping () -> Void) {
        let displays = reader.displays()
        for display in displays where display.currentIsFullscreen {
            guard let member = members.byWindow.values.first(where: { $0.space == display.currentSpace }),
                  member.workspace != workspace else { continue }
            if let focused, onDisplay(focused, display) { continue }
            guard let anchor = anchors.first(where: { window in
                let spaces = reader.spaces(of: window.windowID)
                return !spaces.isEmpty && Set(spaces).isSubset(of: display.desktopSpaces)
            }) else {
                hyprLog(.notice, .lifecycle, "fullscreen: \(screenName(display.displayUUID)) keeps ws\(member.workspace)'s window \(member.windowID) up — no window on its desktop to focus")
                continue
            }
            hyprLog(.notice, .lifecycle, "fullscreen: ws\(workspace) up — \(screenName(display.displayUUID)) leaves ws\(member.workspace)'s window \(member.windowID) via \(anchor.windowID)")
            anchor.focus()
            waitForDesktop(display.displayUUID, attempt: 0, then: refocus)
        }
    }

    private func waitForDesktop(_ displayUUID: String, attempt: Int, then work: @escaping () -> Void) {
        runAfter(0.05) { [weak self] in
            guard let self else { return }
            let display = self.reader.displays().first { $0.displayUUID == displayUUID }
            if display?.currentIsFullscreen == false || attempt >= 30 {
                if attempt >= 30 {
                    hyprLog(.notice, .lifecycle, "fullscreen: \(self.screenName(displayUUID)) still on a fullscreen Space after 1.5s")
                }
                work()
            } else {
                self.waitForDesktop(displayUUID, attempt: attempt + 1, then: work)
            }
        }
    }

    // MARK: - helpers

    private func onDisplay(_ window: HyprWindow, _ display: DisplaySpaceState) -> Bool {
        guard let frame = window.frame ?? window.cachedFrame, let rect = displayRect(display.displayUUID) else { return false }
        return rect.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// The display's frame in CG (top-left origin) coordinates.
    private func displayRect(_ displayUUID: String) -> CGRect? {
        guard let screen = NSScreen.screens.first(where: { FullscreenSpaceReader.displayUUID(for: $0) == displayUUID }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDisplayBounds(number.uint32Value)
    }

    private func screenName(_ displayUUID: String) -> String {
        NSScreen.screens.first { FullscreenSpaceReader.displayUUID(for: $0) == displayUUID }?.localizedName ?? displayUUID
    }

    private static func windowServerBounds(_ windowID: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first,
              let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    }
}
