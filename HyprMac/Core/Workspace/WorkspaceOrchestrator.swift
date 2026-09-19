// Coordinates workspace switch / move-window / move-workspace workflows on
// top of `WorkspaceManager` and `TilingEngine`. No new policy lives here —
// the orchestrator just sequences the right calls and supplies the
// focus/cursor/border glue each workflow needs.

import Cocoa

/// Coordinator for workspace-level user actions.
///
/// Delegates the data ownership to the services it composes:
/// `WorkspaceManager` still owns workspace-to-screen mapping and home
/// screens; `TilingEngine` still owns BSP trees. The orchestrator
/// sequences switch, move-window-to-workspace, and move-workspace-to-
/// monitor flows, applies suppression keys (`activation-switch`,
/// `mouse-focus`) for the duration of each action, and routes focus and
/// cursor-warp results through closure handles back into
/// `WindowManager`.
///
/// Threading: main-thread only.
final class WorkspaceOrchestrator {

    private let workspaceManager: WorkspaceManager
    private let tilingEngine: TilingEngine
    private let accessibility: AccessibilityManager
    private let displayManager: DisplayManager
    private let cursorManager: CursorManager
    private let stateCache: WindowStateCache
    private let focusController: FocusStateController
    private let focusBorder: FocusBorder
    private let dimmingOverlay: DimmingOverlay
    private let suppressions: SuppressionRegistry
    private let revalidation: MinimaRevalidation

    var screenUnderCursor: () -> NSScreen = { NSScreen.main! }
    var currentFocusedWindow: () -> HyprWindow? = { nil }
    var updateFocusBorder: (HyprWindow) -> Void = { _ in }
    var tileAllVisibleSpaces: () -> Void = { }
    /// Every window AX can see right now. A seam because the explicit
    /// revalidation attempt needs the destination's tenants, and a test has
    /// no desktop to read them off.
    var allWindows: () -> [HyprWindow] = { [] }
    var animatedRetile: (_ prepare: (() -> Void)?, _ completion: (() -> Void)?) -> Void = { _, _ in }

    init(workspaceManager: WorkspaceManager,
         tilingEngine: TilingEngine,
         accessibility: AccessibilityManager,
         displayManager: DisplayManager,
         cursorManager: CursorManager,
         stateCache: WindowStateCache,
         focusController: FocusStateController,
         focusBorder: FocusBorder,
         dimmingOverlay: DimmingOverlay,
         suppressions: SuppressionRegistry,
         revalidation: MinimaRevalidation) {
        self.revalidation = revalidation
        self.workspaceManager = workspaceManager
        self.tilingEngine = tilingEngine
        self.accessibility = accessibility
        self.displayManager = displayManager
        self.cursorManager = cursorManager
        self.stateCache = stateCache
        self.focusController = focusController
        self.focusBorder = focusBorder
        self.dimmingOverlay = dimmingOverlay
        self.suppressions = suppressions
        self.allWindows = { [weak accessibility] in accessibility?.getAllWindows() ?? [] }
    }

    // MARK: - switch

    /// Switch to workspace `number` on the cursor's monitor.
    ///
    /// Two paths:
    /// - Already visible (on this or another screen): focus the best
    ///   window on it and warp the cursor; no hide/show needed.
    /// - Not visible: hide the displaced workspace's windows, restore
    ///   floating frames on the incoming workspace, retile, then focus
    ///   the best new window.
    ///
    /// Suppresses `activation-switch` and `mouse-focus` for the duration
    /// (and a tail) of the switch — `best.focus()` queues asynchronous
    /// notifications that would otherwise re-bounce focus.
    func switchWorkspace(_ number: Int) {
        // hold polls off for the duration of the transition. Tahoe AX
        // writes lag, so a poll mid-transition reads stale frames and
        // drift detection can falsely reassign windows.
        suppressions.suppress("workspace-transition", for: 1.5)
        suppressions.suppress("activation-switch", for: 0.5)
        suppressions.suppress("mouse-focus", for: 0.15)

        let currentScreen = screenUnderCursor()

        let allWindows = accessibility.getAllWindows()
        let result = workspaceManager.switchWorkspace(number, cursorScreen: currentScreen)

        if result.alreadyVisible {
            // workspace is showing on result.screen — just focus it. the
            // window the user last had focused there wins over the first
            // tiled window in enumeration order.
            let visibleWindows = allWindows.filter { result.toShow.contains($0.windowID) }
            let remembered = workspaceManager.lastFocusedWindow(onWorkspace: number)
            if let best = visibleWindows.first(where: { $0.windowID == remembered })
                ?? visibleWindows.first(where: { !stateCache.floatingWindowIDs.contains($0.windowID) })
                ?? visibleWindows.first {
                best.focus()
                cursorManager.warpToCenter(of: best)
                focusController.recordFocus(best.windowID, reason: "switchWorkspace-already-visible")
                updateFocusBorder(best)
            } else {
                let rect = displayManager.cgRect(for: result.screen)
                CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: rect.midY))
                focusBorder.hide(); dimmingOverlay.hideAll()
            }
            // focused workspace changed even though nothing was hidden or
            // shown — IPC subscribers (status bars) still need the event.
            NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
            return
        }

        // the monitor→workspace mapping just flipped — let the wallpaper
        // swap NOW, before the hide/retile/focus work (frame readback can
        // take ~0.5s and the desktop image change should feel instant).
        NotificationCenter.default.post(name: .hyprMacWorkspaceWillShow, object: nil)

        // sticky windows follow into an opted-in workspace: a carried
        // window that was visible on the displaced workspace must not be
        // parked; one coming from a hidden workspace shows with the
        // incoming set (floaters restore their saved frame there).
        var toHide = result.toHide
        var toShow = result.toShow
        let carried = carryStickyWindows(into: number, allWindows: allWindows)
        for wid in carried {
            if toHide.remove(wid) != nil {
                // stayed on screen — a stale saved frame must not yank it
                workspaceManager.clearSavedFloatingFrame(for: wid)
            }
            toShow.insert(wid)
        }

        // the focused window is about to be parked: drop its border NOW,
        // before the wallpaper swap, hide pass and retile (~0.5–1.5 s in
        // total). Left in place it stays painted at the old rect on top of
        // the windows arriving there. No fade — a fade would play over the
        // incoming layout too. The border comes back on the new focus
        // target after the retile.
        focusBorder.hide(animated: false)
        for wid in toHide where stateCache.floatingWindowIDs.contains(wid) {
            focusBorder.hideFloatingBorder(for: wid, animated: false)
        }

        // batch: hide old + restore floating new in one tight pass
        for wid in toHide {
            if let w = allWindows.first(where: { $0.windowID == wid }) ?? stateCache.cachedWindows[wid] {
                if stateCache.floatingWindowIDs.contains(wid) { workspaceManager.saveFloatingFrame(w) }
                workspaceManager.hideInCorner(w, on: result.screen)
            }
        }
        for wid in toShow where stateCache.floatingWindowIDs.contains(wid) {
            if let w = allWindows.first(where: { $0.windowID == wid }) ?? stateCache.cachedWindows[wid] {
                workspaceManager.restoreFloatingFrame(w)
            }
        }

        // retile immediately — no delay between hide and show
        tileAllVisibleSpaces()

        // focus the window the user last had focused on the new workspace
        // (so a Cmd-Tab away and back — or Hypr+N — lands on the tile they
        // left, which in accordion mode is also the front slot). Without a
        // usable memory: best tiled window, then any floating window, and
        // only warp+hide if truly empty. the workspace's own windows win
        // over carried sticky ones — the user switched here for this
        // workspace's content, and the sticky app was already in front of
        // them.
        let newWorkspaceWindows = allWindows.filter { toShow.contains($0.windowID) }
        let own = newWorkspaceWindows.filter { !carried.contains($0.windowID) }
        let remembered = workspaceManager.lastFocusedWindow(onWorkspace: number)
        let recalled = own.first { $0.windowID == remembered }
        let tiled = own.first { !stateCache.floatingWindowIDs.contains($0.windowID) }
            ?? newWorkspaceWindows.first { !stateCache.floatingWindowIDs.contains($0.windowID) }
        if let best = recalled ?? tiled ?? own.first ?? newWorkspaceWindows.first {
            best.focus()
            cursorManager.warpToCenter(of: best)
            focusController.recordFocus(best.windowID, reason: "switchWorkspace-after-show")
            updateFocusBorder(best)
        } else {
            let rect = displayManager.cgRect(for: result.screen)
            CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: rect.midY))
            focusBorder.hide(); dimmingOverlay.hideAll()
        }

        NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
    }

    // MARK: - sticky windows

    /// Pull sticky windows (Hyprland's `pin`, per app) onto `workspace`,
    /// which is — or is about to be — visible on its home screen(s).
    ///
    /// `WorkspaceManager.stickyWindowsToCarry` picks the candidates; this
    /// applies the dwindle-depth capacity check (a sticky tile that would
    /// not fit stays where it is rather than auto-floating), detaches
    /// tiled windows from their old trees, and reassigns them. The retile
    /// that follows inserts the tiles into the target tree; floaters keep
    /// their frame and are shown by the caller.
    ///
    /// Called from `switchWorkspace` (after the mapping flip) and from
    /// `WindowManager`'s sticky reconcile (startup, Retile All, rule or
    /// opt-in edits, monitor changes).
    ///
    /// - Returns: the window ids that were carried.
    @discardableResult
    func carryStickyWindows(into workspace: Int, allWindows: [HyprWindow]) -> Set<CGWindowID> {
        let candidates = workspaceManager.stickyWindowsToCarry(into: workspace)
        guard !candidates.isEmpty else { return [] }

        // capacity: live tiled windows on the target plus carried tiles
        // must stay within the dwindle depth (summed over screens in
        // linked mode — the balancer spreads the strip across all of them).
        let homes = workspaceManager.homeScreensForWorkspace(workspace)
        let capacity = homes.reduce(0) { $0 + (1 << tilingEngine.maxDepth(for: $1)) }
        var tiledCount = workspaceManager.windowIDs(onWorkspace: workspace)
            .subtracting(stateCache.hiddenWindowIDs)
            .filter { !stateCache.floatingWindowIDs.contains($0) }
            .count

        var carried: Set<CGWindowID> = []
        for wid in candidates.sorted() {
            guard let from = workspaceManager.workspaceFor(wid) else { continue }
            let window = allWindows.first { $0.windowID == wid } ?? stateCache.cachedWindows[wid]
            let floating = stateCache.floatingWindowIDs.contains(wid)
            let live = !stateCache.hiddenWindowIDs.contains(wid)
            if !floating && live {
                guard tiledCount < capacity else {
                    hyprLog(.notice, .workspace, "sticky: ws\(workspace) full (\(tiledCount)/\(capacity)) — '\(window?.title ?? "?")' (\(wid)) stays on ws\(from)")
                    continue
                }
                tiledCount += 1
            }
            if !floating, let window {
                tilingEngine.detachWindow(window, fromWorkspace: from)
            }
            workspaceManager.moveWindow(wid, toWorkspace: workspace)
            carried.insert(wid)
            hyprLog(.notice, .workspace, "sticky: carried '\(window?.title ?? "?")' (\(wid)) ws\(from) → ws\(workspace) floating=\(floating)")
        }
        return carried
    }

    // MARK: - move focused window to workspace

    /// Move the focused window to workspace `number`.
    ///
    /// Capacity is checked before any mutation. `admissionOutlook` answers
    /// for visible and hidden destinations alike: it fits, only learned
    /// bounds refuse it, or the refusal is one no attempt can change. A
    /// hidden destination then also gets the raw tile-count vs.
    /// dwindle-depth check. Rejections beep and flash a red border;
    /// successful moves animate the surrounding tile and post a
    /// workspace-changed notification. A refusal that only learned bounds
    /// produced buys one revalidation — run here for a visible destination,
    /// left as a marker for the reveal when the destination is hidden.
    ///
    /// Special-cases windows on disabled monitors: they unfloat into
    /// the target as tiled windows on success.
    func moveToWorkspace(_ number: Int) {
        guard let focused = currentFocusedWindow() else { return }
        // hold polls off for the duration of the transition. Tahoe AX
        // writes lag, so a poll mid-transition reads the moved window
        // at its OLD pre-hide tile rect and drift detection
        // erroneously reassigns it back to its source workspace.
        suppressions.suppress("workspace-transition", for: 1.5)
        tilingEngine.primeMinimumSizes([focused])
        guard let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else { return }

        // window on a disabled monitor — send it to the target workspace as a tiled window
        let onDisabledMonitor = workspaceManager.isMonitorDisabled(screen)

        let currentWorkspace = onDisabledMonitor ? nil : Optional(workspaceManager.workspaceForScreen(screen))

        if let cw = currentWorkspace, number == cw {
            hyprLog(.debug, .workspace, "window already on workspace \(number)")
            return
        }

        let isFloating = stateCache.floatingWindowIDs.contains(focused.windowID)

        hyprLog(.notice, .workspace, "moveToWorkspace(\(number)): '\(focused.title ?? "?")' (\(focused.windowID)) floating=\(isFloating) currentWs=\(currentWorkspace.map(String.init) ?? "nil") srcScreen=\(screen.localizedName)")

        // when coming from disabled monitor, unfloat so it enters tiling on target
        let willTile = onDisabledMonitor || !isFloating

        // target screen is the workspace's static home — same answer
        // whether the workspace is currently visible or hidden.
        let targetScreen = workspaceManager.homeScreenForWorkspace(number) ?? screen
        let targetVisible = workspaceManager.screenForWorkspace(number) != nil

        // the user asking again replaces whatever the last ask left pending
        revalidation.cancel(focused.windowID, reason: "moved again")

        // check capacity on target workspace before moving a tiled window.
        var decision = MinimaRevalidation.Decision.admit
        if willTile {
            let outlook = tilingEngine.admissionOutlook(focused, onWorkspace: number, screen: targetScreen)
            decision = MinimaRevalidation.decide(outlook, destinationVisible: targetVisible)
            if decision == .refuse {
                hyprLog(.notice, .workspace, "workspace \(number) can't fit \(focused.windowID)"
                        + " on \(targetScreen.localizedName) — rejected move")
                NSSound.beep()
                if let frame = focused.frame {
                    focusBorder.flashError(around: frame, windowID: focused.windowID, window: focused,
                                           message: "Won't fit on workspace \(number)")
                }
                return
            }

            if workspaceManager.screenForWorkspace(number) == nil {
                // count occupancy the way admission does: a closed-but-alive
                // ghost holds no slot, a minimized or Cmd-H'd window still does
                let excluded = ActionDispatcher.admissionExclusions(
                    floatingWindowIDs: stateCache.floatingWindowIDs,
                    hiddenWindowIDs: stateCache.hiddenWindowIDs,
                    reservedHiddenWindowIDs: stateCache.reservedHiddenWindowIDs)
                let tiledCount = workspaceManager.windowIDs(onWorkspace: number)
                    .subtracting(excluded).count
                let maxDepth = tilingEngine.maxDepth(for: targetScreen)
                let maxWindows = RetileAllPlanner.workspaceCapacity(maxDepth: maxDepth)
                if tiledCount >= maxWindows {
                    hyprLog(.notice, .workspace, "workspace \(number) full: incoming=\(focused.windowID)"
                            + " tiled=\(tiledCount) max=\(maxWindows) axis=count source=structural"
                            + " — rejected move")
                    NSSound.beep()
                    if let frame = focused.frame {
                        focusBorder.flashError(around: frame, windowID: focused.windowID, window: focused,
                                               message: "Workspace \(number) is full")
                    }
                    return
                }
            }
        }

        // the destination refused on learned bounds alone. a visible one gets
        // its one attempt right here, and nothing about the source changes
        // until the screen has accepted the layout; a hidden one keeps a
        // marker and is settled on its reveal.
        switch decision {
        case .revalidateHere:
            guard revalidateVisibleDestination(focused, workspace: number, screen: targetScreen,
                                               from: screen) else {
                hyprLog(.notice, .workspace, "moveToWorkspace(\(number)): revalidation refused"
                        + " incoming=\(focused.windowID) — \(focused.windowID) stays on"
                        + " ws\(currentWorkspace.map(String.init) ?? "none")")
                NSSound.beep()
                if let frame = focused.frame {
                    focusBorder.flashError(around: frame, windowID: focused.windowID, window: focused,
                                           message: "Won't fit on workspace \(number)")
                }
                return
            }
        case .parkForReveal:
            revalidation.park(focused.windowID, toWorkspace: number, screen: targetScreen,
                              sourceWorkspace: currentWorkspace, sourceScreen: screen)
        case .admit, .refuse:
            break
        }

        // unfloat if coming from disabled monitor
        if onDisabledMonitor && isFloating {
            stateCache.floatingWindowIDs.remove(focused.windowID)
            focused.isFloating = false
            hyprLog(.debug, .workspace, "unfloating '\(focused.title ?? "?")' from disabled monitor → workspace \(number)")
        }

        // animate remaining windows filling the gap
        animatedRetile({ [self] in
            // remove from current workspace's tiling tree
            if !isFloating, let cw = currentWorkspace {
                tilingEngine.removeWindow(focused, fromWorkspace: cw)
            }

            // reassign globally
            workspaceManager.moveWindow(focused.windowID, toWorkspace: number)

            if targetVisible {
                // target workspace is on screen — no park. tiled windows
                // get their frame from the retile that follows; floaters
                // are carried to the target screen directly. parking here
                // used to strand floaters in the hide corner: nothing
                // restores a floating frame until the next workspace
                // switch, and the switch's hide pass would re-save the
                // park position as the "real" frame.
                hyprLog(.notice, .workspace, "moveToWorkspace(\(number)): target visible — placing '\(focused.title ?? "?")' (\(focused.windowID)) on \(targetScreen.localizedName) tiled=\(willTile)")
                if !willTile {
                    carryFloaterToScreen(focused, targetScreen)
                }
            } else {
                // target hidden — park at the global hide corner until the
                // workspace is shown. park on the workspace's static home
                // monitor, not the source screen (AeroSpace pattern: a
                // window assigned to ws N belongs physically near ws N's
                // monitor so the next show is a single-screen transition).
                if isFloating && !onDisabledMonitor {
                    workspaceManager.saveFloatingFrame(focused)
                }
                hyprLog(.notice, .workspace, "moveToWorkspace(\(number)): parking '\(focused.title ?? "?")' (\(focused.windowID)) homeScreen=\(targetScreen.localizedName) at \(workspaceManager.hidePosition())")
                workspaceManager.hideInCorner(focused, on: targetScreen)
            }
        }, { [self] in
            if targetVisible {
                // destination is on screen — focus follows the window,
                // matching switchWorkspace's focus+warp behavior.
                focused.focusWithoutRaise()
                cursorManager.warpToCenter(of: focused)
                focusController.recordFocus(focused.windowID, reason: "moveToWorkspace-follow")
                updateFocusBorder(focused)
            } else {
                // window vanished into a hidden workspace — re-anchor focus
                // on whatever remains on the source workspace instead of
                // leaving the border tracking a parked window.
                refocusAfterMove(on: screen, excluding: focused.windowID)
            }
            NotificationCenter.default.post(name: .hyprMacWorkspaceChanged, object: nil)
        })
    }

    /// The one bypassed attempt for a destination that is on screen.
    ///
    /// The window is laid out into the destination alongside its tenants
    /// before anything about the source is touched, so a refusal costs the
    /// user nothing: the rollback puts every incumbent back and the window
    /// back on `sourceScreen`, it keeps its place in the source tree and its
    /// floating flag, and the caller shows the ordinary rejection.
    ///
    /// `sourceScreen` is not decoration. A visible destination is always
    /// another screen, so the window is standing on `sourceScreen` when the
    /// attempt captures it, and a captured original outside the restoration
    /// rect cancels the whole rollback — the incumbents would keep the failed
    /// candidate's frames and the window would be left on a screen it is not
    /// assigned to, which the next poll reads as drift and acts on. The
    /// engine is told to reach both screens.
    ///
    /// - Returns: whether the screen accepted a layout holding `window`.
    private func revalidateVisibleDestination(_ window: HyprWindow, workspace: Int,
                                              screen: NSScreen, from sourceScreen: NSScreen) -> Bool {
        let all = allWindows()
        for w in all where stateCache.floatingWindowIDs.contains(w.windowID) { w.isFloating = true }
        let assigned = workspaceManager.windowIDs(onWorkspace: workspace)
        var windows = all.filter {
            assigned.contains($0.windowID) && $0.windowID != window.windowID && !$0.isFloating
        }
        // the live element if AX still knows it, so the attempt writes to the
        // same window the retile will
        let incoming = all.first { $0.windowID == window.windowID } ?? window
        let wasFloating = incoming.isFloating
        // the move is what makes it tiled; the flag goes back if this fails
        incoming.isFloating = false
        windows.append(incoming)

        let result = tilingEngine.revalidateAdmission(
            windows, incoming: [window.windowID], onWorkspace: workspace, screen: screen,
            restorationReach: displayManager.cgRect(for: sourceScreen))
        guard result.publishedIDs.contains(window.windowID) else {
            incoming.isFloating = wasFloating
            return false
        }
        return true
    }

    /// Place a floating window onto `screen`, preserving its size and its
    /// relative position. No-op when the floater is already substantially
    /// visible on the target screen.
    private func carryFloaterToScreen(_ window: HyprWindow, _ screen: NSScreen) {
        guard let frame = window.frame else { return }
        let targetRect = displayManager.cgRect(for: screen)
        if frame.isSubstantiallyVisible(on: targetRect, threshold: 0.5) { return }

        let sourceScreen = displayManager.screen(for: window) ?? screen
        let sourceRect = displayManager.cgRect(for: sourceScreen)
        let relX = sourceRect.width > 0 ? (frame.midX - sourceRect.minX) / sourceRect.width : 0.5
        let relY = sourceRect.height > 0 ? (frame.midY - sourceRect.minY) / sourceRect.height : 0.5
        let size = CGSize(width: min(frame.width, targetRect.width),
                          height: min(frame.height, targetRect.height))
        var origin = CGPoint(x: targetRect.minX + relX * targetRect.width - size.width / 2,
                             y: targetRect.minY + relY * targetRect.height - size.height / 2)
        origin.x = max(targetRect.minX, min(origin.x, targetRect.maxX - size.width))
        origin.y = max(targetRect.minY, min(origin.y, targetRect.maxY - size.height))
        window.setFrame(CGRect(origin: origin, size: size))
    }

    /// Focus the best remaining window on `screen`'s active workspace
    /// after `movedID` left it. Prefers tiled windows; hides the chrome
    /// when the workspace emptied out.
    private func refocusAfterMove(on screen: NSScreen, excluding movedID: CGWindowID) {
        guard !workspaceManager.isMonitorDisabled(screen) else { return }
        let ws = workspaceManager.workspaceForScreen(screen)
        let remaining = workspaceManager.windowIDs(onWorkspace: ws)
            .subtracting(stateCache.hiddenWindowIDs)
            .subtracting([movedID])
            .filter { stateCache.cachedWindows[$0] != nil }
            .sorted()
        let pick = remaining.first { !stateCache.floatingWindowIDs.contains($0) } ?? remaining.first
        guard let wid = pick, let w = stateCache.cachedWindows[wid] else {
            focusBorder.hide(); dimmingOverlay.hideAll()
            return
        }
        w.focusWithoutRaise()
        focusController.recordFocus(wid, reason: "moveToWorkspace-refocus")
        updateFocusBorder(w)
    }

    // MARK: - move window to adjacent monitor

    /// Move the focused window to the monitor adjacent in `direction`,
    /// landing on whatever workspace is visible there. Delegates to
    /// `moveToWorkspace` so capacity checks, floater handling, and focus
    /// follow all behave identically to `Hypr+Shift+N`.
    ///
    /// Replaces the old workspace-to-monitor move, which static
    /// anchoring turned into a permanent no-op.
    func moveWindowToMonitor(_ direction: Direction) {
        guard direction == .left || direction == .right else {
            NSSound.beep()
            return
        }
        guard let focused = currentFocusedWindow(),
              let screen = displayManager.screen(for: focused) ?? displayManager.screens.first else {
            NSSound.beep()
            return
        }

        let enabled = displayManager.screens.filter { !workspaceManager.isMonitorDisabled($0) }
        let candidates = enabled.filter {
            direction == .left
                ? $0.frame.maxX <= screen.frame.minX + 1
                : $0.frame.minX >= screen.frame.maxX - 1
        }
        // nearest screen in the requested direction
        let target = direction == .left
            ? candidates.max(by: { $0.frame.origin.x < $1.frame.origin.x })
            : candidates.min(by: { $0.frame.origin.x < $1.frame.origin.x })
        guard let target else {
            hyprLog(.debug, .workspace, "moveWindowToMonitor(\(direction.rawValue)): no monitor in that direction")
            NSSound.beep()
            if let frame = focused.frame {
                focusBorder.flashError(around: frame, windowID: focused.windowID, window: focused,
                                       message: "No monitor to the \(direction.rawValue)")
            }
            return
        }

        moveToWorkspace(workspaceManager.workspaceForScreen(target))
    }
}
