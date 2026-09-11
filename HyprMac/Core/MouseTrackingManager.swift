// Focus-follows-mouse plus menu-bar-tracking suppression and
// refocus-under-cursor recovery. Throttled to ~60 Hz with a short-TTL
// topmost-window cache so the global mouseMoved handler stays cheap.

import Cocoa

/// Mouse-driven focus controller for focus-follows-mouse (FFM).
///
/// `handleMouseMove` fires on every `NSMouseMoved` event, so the hot
/// path is built around early exits. The eligibility check
/// (`isFFMEligible`) gates on the FFM toggle, mouse button state, menu
/// tracking, dock activation, animation in flight, and the
/// `mouse-focus` suppression key. After eligibility, a 60 Hz throttle
/// caps resolve work, and a topmost-window cache (TTL +
/// spatial-tolerance) avoids redundant `CGWindowListCopyWindowInfo`
/// queries when the cursor jitters.
///
/// `refocusUnderCursor` is a separate path used when the previously
/// focused window vanishes mid-flight — it re-derives focus from the
/// current cursor position without going through the FFM gates.
///
/// Threading: main-thread only.
class MouseTrackingManager {

    /// Tunables. Empirical: throttle measured on M1 Air with ~30
    /// visible windows; raising past ~24 ms produces visible focus lag
    /// during fast cursor sweeps, lowering below ~16 ms wastes work on
    /// no-op resolves between display frames.
    private enum Tuning {
        // 120Hz cap on FFM resolve work. raising = slower focus, lowering =
        // wasted CG window-list queries between display frames.
        static let throttleInterval: CFAbsoluteTime = 0.008
        // dedupe burst of NSMouseMoved events on a single frame; short
        // enough that windows reshuffling under a stationary cursor still
        // re-resolve within ~80ms.
        static let topmostCacheTTL: CFAbsoluteTime = 0.08
        // cursor jitter within this radius reuses the cached hit-test result
        // without re-querying CGWindowListCopyWindowInfo.
        static let topmostCacheSpatialTolerance: CGFloat = 10
        // menu bar dead zone in CG (top-left) coords. focus changes inside
        // this band would compete with menu-bar interaction.
        static let menuBarDeadZonePx: CGFloat = 25
    }

    // state
    // set by HIToolbox begin/end notifications — true for both menu bar menus
    // and native right-click context menus (NSMenu). other code paths read this
    // to skip focus-stealing operations while a menu is open.
    var menuTracking = false
    // true while a transient system-UI process is frontmost: the Dock (its
    // popups), Control Center (menu-bar popovers), Notification Center,
    // Spotlight, sketchybar. none of these post the HIToolbox menu-tracking
    // notifications, yet hovering or refocusing under them dismisses their
    // popovers exactly like a menu. set/cleared by WindowManager from app
    // activation notifications, with a watchdog for the no-successor case.
    var overlayActive = false

    private var lastHandleTime: CFAbsoluteTime = 0
    // last time menuTrackingBegan was called. used by the watchdog to clear
    // a stuck menuTracking flag — Tahoe sometimes drops the end notification,
    // which would otherwise kill FFM until the next begin/end cycle.
    private var menuTrackingStart: CFAbsoluteTime = 0
    // hard ceiling on how long menuTracking can stay true without an explicit
    // end notification. real menus get dismissed by mouseDown anyway, so this
    // is just a safety net for the dropped-notification case.
    private static let menuTrackingMaxAge: CFAbsoluteTime = 5.0

    // dependencies injected by WindowManager
    var isFocusFollowsMouseEnabled: () -> Bool = { false }
    var isMouseButtonDown: () -> Bool = { false }
    var primaryScreenHeight: () -> CGFloat = { 0 }
    var screenAt: (CGPoint) -> NSScreen? = { _ in nil }
    var floatingWindowIDs: () -> Set<CGWindowID> = { [] }
    var isWindowVisible: (CGWindowID) -> Bool = { _ in false }
    var cachedWindow: (CGWindowID) -> HyprWindow? = { _ in nil }
    var tiledPositions: () -> [CGWindowID: CGRect] = { [:] }

    /// `true` when the screen at this CG point is in accordion mode.
    /// Accordion suppresses ALL hover-driven focus: the stack re-layouts
    /// around whichever window is in front, so hover focus would shuffle
    /// windows under the cursor while it moves. Activation is click-only
    /// there (`WindowManager.syncFocusTrackerToCursor`).
    var isAccordionAt: (CGPoint) -> Bool = { _ in false }
    var onFocusForFFM: (HyprWindow) -> Void = { _ in }
    var onUpdateFocusBorder: (HyprWindow) -> Void = { _ in }
    var onHideFocusBorder: () -> Void = {}
    // routed to SuppressionRegistry["mouse-focus"] by WindowManager
    var isMouseFocusSuppressed: () -> Bool = { false }
    // true while the scratchpad layer is up — FFM must not reach through the
    // scrim to hover-focus a background tile (would dismiss the quasimodal layer)
    var isScratchpadVisible: () -> Bool = { false }
    // user-configurable throttle override; falls back to Tuning.throttleInterval
    var hoverThrottleInterval: () -> CFAbsoluteTime = { Tuning.throttleInterval }
    // routed to FocusStateController by WindowManager (canonical "last focused" id)
    var lastFocusedID: () -> CGWindowID = { 0 }
    var recordFocus: (CGWindowID, String) -> Void = { _, _ in }

    private struct FocusTarget {
        let windowID: CGWindowID
        let window: HyprWindow
        let reason: String
    }

    /// Entry point for FFM. Called from the global `NSMouseMoved`
    /// monitor on every event; gates and throttles before doing real
    /// work, then resolves a focus target and applies it.
    func handleMouseMove() {
        mainThreadOnly()
        guard isFFMEligible() else { return }

        // throttle: cap the resolve rate. note this records lastHandleTime
        // even when we end up bailing on the dead-zone check below — that
        // matches the prior behavior, where any pass through the eligibility
        // gate consumes the throttle window.
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastHandleTime < hoverThrottleInterval() { return }
        lastHandleTime = now

        let mouseNS = NSEvent.mouseLocation
        let cgY = primaryScreenHeight() - mouseNS.y
        let cgPoint = CGPoint(x: mouseNS.x, y: cgY)

        if isInMenuBarDeadZone(cgPoint) { return }

        // accordion mode: no hover activation, click-only.
        if isAccordionAt(cgPoint) { return }

        guard let target = determineFocusTarget(at: cgPoint) else { return }
        recordFocus(target.windowID, target.reason)
        onFocusForFFM(target.window)
    }

    /// `true` when FFM should react to the current mouse event.
    ///
    /// Each guard exists for a specific reason: `isMouseButtonDown`
    /// skips drags (`DragManager` owns those), `menuTracking` and
    /// `overlayActive` skip transient OS UI that would race with focus
    /// changes, and `isMouseFocusSuppressed` honors the post-action quiet window
    /// owned by `SuppressionRegistry["mouse-focus"]`.
    private func isFFMEligible() -> Bool {
        guard isFocusFollowsMouseEnabled() else { return false }
        // scratchpad quasimodality freezes focus to summoned members; hovering
        // the scrimmed background must not steal focus to a tile beneath it.
        if isScratchpadVisible() { hyprLog(.debug, .mouse, "ffm-bail: scratchpad visible"); return false }
        if isMouseButtonDown() { hyprLog(.debug, .mouse, "ffm-bail: mouseButtonDown"); return false }
        if menuTracking {
            // watchdog: HIToolbox sometimes drops endMenuTrackingNotification on
            // Tahoe, leaving menuTracking latched and FFM dead until the next
            // menu cycle. force-clear after the max age so a dropped notification
            // doesn't permanently kill hover focus.
            let age = CFAbsoluteTimeGetCurrent() - menuTrackingStart
            if age > Self.menuTrackingMaxAge {
                hyprLog(.notice, .mouse, "menuTracking stuck for \(String(format: "%.1f", age))s — force-clearing")
                menuTracking = false
            } else {
                hyprLog(.debug, .mouse, "ffm-bail: menuTracking (age=\(String(format: "%.1f", age))s)")
                return false
            }
        }
        if overlayActive { hyprLog(.debug, .mouse, "ffm-bail: overlayActive"); return false }
        if isMouseFocusSuppressed() { hyprLog(.debug, .mouse, "ffm-bail: mouse-focus suppressed"); return false }
        return true
    }

    /// `true` when `cgPoint` is in the menu-bar dead zone — focus
    /// changes that fired here would compete with menu interaction.
    ///
    /// The dead zone is anchored to the cursor's local screen, not the
    /// primary screen. Without this, a monitor stacked above the primary
    /// produces `cgY < 0` everywhere and FFM is dead across its full
    /// height — the bug from the multi-monitor FFM investigation.
    private func isInMenuBarDeadZone(_ cgPoint: CGPoint) -> Bool {
        guard let screen = screenAt(cgPoint) else {
            // fall back to the old primary-anchored check
            return cgPoint.y < Tuning.menuBarDeadZonePx
        }
        // screen.frame is in NS (bottom-left). its top edge in CG (top-left) is
        // primaryH - (origin.y + height).
        let screenTopCG = primaryScreenHeight() - (screen.frame.origin.y + screen.frame.height)
        return cgPoint.y - screenTopCG < Tuning.menuBarDeadZonePx
    }

    /// Resolve which window should receive focus for `cgPoint`, or `nil`
    /// when no change is appropriate.
    ///
    /// Returns `nil` for the common no-change cases: cursor over a
    /// floater (leave focus alone), cursor over the already-focused
    /// tile, cursor over an unmanaged normal-layer overlay (popover,
    /// autocomplete panel), or no managed window at all.
    private func determineFocusTarget(at cgPoint: CGPoint) -> FocusTarget? {
        // snapshot closures once per move event
        let floating = floatingWindowIDs()
        let managed = tiledPositions()

        let hit = topmostWindow(at: cgPoint)
        if case .overlay = hit {
            // the cursor is over a menu, popover, palette, the Dock or the
            // menu bar — something above the normal window layer that is
            // not ours. refocusing the tile underneath would dismiss it.
            hyprLog(.debug, .mouse, "ffm-bail: cursor over overlay window")
            return nil
        }
        if case .window(let topmostID) = hit {
            // cursor is over a visible floater — leave focus alone
            if floating.contains(topmostID), isWindowVisible(topmostID) {
                return nil
            }

            if managed[topmostID] != nil {
                guard topmostID != lastFocusedID() else { return nil }
                guard let target = cachedWindow(topmostID) else {
                    hyprLog(.debug, .mouse, "ffm-bail: topmost \(topmostID) in managed but cachedWindow nil")
                    return nil
                }
                return FocusTarget(windowID: topmostID, window: target, reason: "ffm-topmost")
            }

            // an unmanaged normal-layer window is above the tiled window
            // here, such as a popover or autocomplete panel.
            hyprLog(.debug, .mouse, "ffm-bail: topmost \(topmostID) not in managed (managed.count=\(managed.count), cached=\(cachedWindow(topmostID) != nil), floating=\(floating.contains(topmostID)))")
            return nil
        }

        // fast path: cursor still inside the last-focused window's rect.
        // O(1) check that short-circuits before walking every floater + tile.
        // huge win during normal mouse movement (cursor stays in one window).
        let lastID = lastFocusedID()
        if lastID != 0,
           let lastRect = managed[lastID],
           lastRect.contains(cgPoint) {
            return nil
        }

        // CG topmost returned nothing but a floater may still cover the
        // point at the AX-frame level (e.g. transparent regions where CG
        // hit-test passes through). don't refocus the tile underneath.
        for wid in floating {
            guard isWindowVisible(wid),
                  let w = cachedWindow(wid), let frame = w.frame else { continue }
            if frame.contains(cgPoint) { return nil }
        }

        for (wid, rect) in managed {
            if rect.contains(cgPoint) {
                guard wid != lastFocusedID() else { return nil }
                guard let target = cachedWindow(wid) else { return nil }
                return FocusTarget(windowID: wid, window: target, reason: "ffm-managed")
            }
        }
        return nil
    }

    /// Re-derive focus from the current cursor position after a window
    /// vanishes mid-flight.
    ///
    /// Bypasses the FFM eligibility gates — this is invoked from
    /// `ActionDispatcher.applyChanges` when `focusedWindowGone` fires.
    /// When the cursor is not over any tiled window the border is left
    /// alone so `ensureFocusInvariant` can pick a fallback target on
    /// the next pass.
    func refocusUnderCursor() {
        mainThreadOnly()
        let mouseNS = NSEvent.mouseLocation
        let cgY = primaryScreenHeight() - mouseNS.y
        let cgPoint = CGPoint(x: mouseNS.x, y: cgY)

        // accordion mode: never refocus from cursor position — the
        // containment scan below is nondeterministic over the stack's
        // overlapping rects. click sync handles clicks; the ensureFocus
        // invariants recover a vanished window via the accordion front.
        if isAccordionAt(cgPoint) { return }

        // already-focused fast path: cursor is still over the last-focused
        // tile and that tile still exists — no refocus needed. without this,
        // every click inside the focused window would re-fire the synthetic
        // click and re-show the focus border (visible "re-highlight" flash).
        // matches the same guard determineFocusTarget uses on the live FFM
        // path. when the previously-focused window is gone, tiledPositions
        // won't contain its ID, the guard falls through, and a fallback is
        // picked below.
        let lastID = lastFocusedID()
        if lastID != 0, let lastRect = tiledPositions()[lastID], lastRect.contains(cgPoint) {
            return
        }

        // bail if cursor is over a visible floater — refocusing the tile below
        // would pull the tile above the floater (the synthetic click in
        // focusForFFM raises the clicked window's app). matches the same guard
        // determineFocusTarget uses on the live FFM path.
        for wid in floatingWindowIDs() where isWindowVisible(wid) {
            if let f = cachedWindow(wid)?.frame, f.contains(cgPoint) { return }
        }

        for (wid, rect) in tiledPositions() {
            if rect.contains(cgPoint), let target = cachedWindow(wid) {
                recordFocus(wid, "refocus-under-cursor")
                if isFocusFollowsMouseEnabled() {
                    onFocusForFFM(target)
                } else {
                    onUpdateFocusBorder(target)
                }
                return
            }
        }
        // cursor not over any tiled window — clear FFM state but leave the
        // border alone so the invariant check can put it on a sensible target
        recordFocus(0, "refocus-under-cursor-clear")
    }

    /// Result of the CG hit-test under the cursor.
    enum HitTest: Equatable {
        /// A normal-layer window of another process.
        case window(CGWindowID)
        /// Something above the normal layer that is not ours covers the
        /// point: a menu, popover, palette, the Dock, the menu bar.
        case overlay
        /// Nothing visible covers the point.
        case none
    }

    /// Short-TTL cache of the most recent hit-test result.
    /// `CGWindowListCopyWindowInfo` is expensive enough to dominate the
    /// FFM hot path without this.
    private var topmostCache: (hit: HitTest, time: CFAbsoluteTime, point: CGPoint)?

    /// A non-zero-layer window covering at least this share of its screen
    /// is treated as a screen-wide overlay (dimmers, color filters,
    /// screen-recording frames) and looked through, not as a popup that
    /// blocks FFM. Popovers, menus and palettes are far smaller.
    private static let screenWideOverlayFraction: CGFloat = 0.85

    /// Front-to-back CG hit-test for the real window under `point`.
    /// Skips this process's own windows (the focus border, dim panel,
    /// settings/welcome) and screen-wide overlays. The first other
    /// window that contains the point decides: layer 0 → `.window`,
    /// anything else → `.overlay`. Looking *through* a popup to the tile
    /// beneath it is exactly what dismissed menus and popovers under FFM.
    func topmostWindow(at point: CGPoint) -> HitTest {
        let now = CFAbsoluteTimeGetCurrent()
        if let cache = topmostCache,
           now - cache.time < Tuning.topmostCacheTTL,
           abs(point.x - cache.point.x) < Tuning.topmostCacheSpatialTolerance,
           abs(point.y - cache.point.y) < Tuning.topmostCacheSpatialTolerance {
            return cache.hit
        }

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return .none
        }
        let screenArea = screenAt(point).map { $0.frame.width * $0.frame.height } ?? .greatestFiniteMagnitude

        let hit = Self.classifyHit(at: point, windowList: windowList, selfPID: getpid(), screenArea: screenArea)
        topmostCache = (hit: hit, time: now, point: point)
        return hit
    }

    /// Pure classification over a CG window list (front-to-back), split
    /// out so the rule is unit-testable without a live window server.
    static func classifyHit(at point: CGPoint, windowList: [[String: Any]],
                            selfPID: pid_t, screenArea: CGFloat) -> HitTest {
        for info in windowList {
            if let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == selfPID {
                continue
            }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"] else { continue }
            let frame = CGRect(x: x, y: y, width: w, height: h)
            guard frame.contains(point) else { continue }
            let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1.0
            guard alpha > 0.01 else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 {
                // screen-wide tinted overlays are not popups — keep looking
                if frame.width * frame.height >= screenArea * screenWideOverlayFraction { continue }
                return .overlay
            }
            let wid = (info[kCGWindowNumber as String] as? Int).map { CGWindowID($0) } ?? 0
            return wid == 0 ? .none : .window(wid)
        }
        return .none
    }

    /// Called when a menu (app menu or right-click context menu) opens.
    /// Sets the suppression flag so FFM stops reacting; deliberately
    /// leaves the focus border intact, since hiding it would clear
    /// `trackedWindowID` and cause `ensureFocusInvariant` to re-assert
    /// focus and dismiss the menu. The border drawing on top while the
    /// menu is open is harmless — the menu is at a higher window level.
    func menuTrackingBegan() {
        mainThreadOnly()
        menuTracking = true
        menuTrackingStart = CFAbsoluteTimeGetCurrent()
    }

    /// Called when the menu closes. Refreshes the focus border on the
    /// last-focused window so its rect tracks any motion that happened
    /// during the menu's lifetime.
    func menuTrackingEnded() {
        mainThreadOnly()
        menuTracking = false
        if let w = cachedWindow(lastFocusedID()) {
            onUpdateFocusBorder(w)
        }
    }
}
