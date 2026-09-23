// Pure geometry for accordion mode. No AX, no engine state — the frame
// and raise-order math is fully parameterized so it is unit-testable,
// mirroring LayoutEngine's design.

import Cocoa

/// Frame and z-order computation for accordion mode.
///
/// In accordion mode the BSP tree still owns membership and order (so
/// tile mode restores the exact layout when a second monitor returns),
/// but frames are presentation-only: every window gets the same
/// near-fullscreen rect, offset so `overlap` px of the neighboring
/// stacks peek out left and right of the focused window — AeroSpace's
/// horizontal accordion.
enum AccordionLayout {

    /// Effective per-side peek, clamped so the shared window width can
    /// never collapse when the user picks a huge overlap on a narrow
    /// screen. Quarter-width per side leaves at least half the screen
    /// for the window itself.
    static func clampedOverlap(_ overlap: CGFloat, innerWidth: CGFloat) -> CGFloat {
        max(0, min(overlap, innerWidth / 4))
    }

    /// Accordion frames for `order` (the tree's in-order window
    /// sequence) inside `rect` inset by `padding`.
    ///
    /// All windows share one size: the inset rect minus one `overlap`
    /// strip per side that has neighbors. Windows before the focused one
    /// align to the left edge (peeking out on the left), windows after
    /// it to the right edge; the focused window sits between the strips.
    /// An unknown/absent `focusedID` falls back to the first window so
    /// the layout is still deterministic before any focus is recorded.
    static func frames(order: [HyprWindow],
                       focusedID: CGWindowID?,
                       in rect: CGRect,
                       padding: OuterPadding,
                       overlap: CGFloat) -> [(HyprWindow, CGRect)] {
        let inner = padding.inset(rect)
        guard !order.isEmpty, inner.width > 0, inner.height > 0 else { return [] }

        let idx = focusedIndex(order: order, focusedID: focusedID)
        let peek = clampedOverlap(overlap, innerWidth: inner.width)
        let hasLeft = idx > 0
        let hasRight = idx < order.count - 1
        let width = inner.width - (hasLeft ? peek : 0) - (hasRight ? peek : 0)
        let focusedX = inner.minX + (hasLeft ? peek : 0)

        return order.enumerated().map { i, window in
            let x: CGFloat
            if i < idx {
                x = inner.minX
            } else if i > idx {
                x = inner.maxX - width
            } else {
                x = focusedX
            }
            return (window, CGRect(x: x, y: inner.minY, width: width, height: inner.height))
        }
    }

    /// Windows in back-to-front raise order for the accordion stack.
    ///
    /// The strips must show the *nearest* neighbor on each side, so the
    /// left stack raises outermost-first (index 0 … idx-1), the right
    /// stack likewise (count-1 … idx+1), and the focused window last.
    /// This also makes FFM correct for free: the CG topmost window under
    /// a peek strip is exactly the adjacent window in accordion order.
    ///
    /// `appFront` names, per app, the tile the user last focused there.
    /// That tile is raised above the app's other background tiles: a
    /// Cmd-Tab or Dock click makes the app's own topmost window key, and
    /// far-to-near stacking would leave the app's *outermost* tile there
    /// — the activation would flash that tile until the restore re-raised
    /// the remembered one. Only the order within the app changes; the
    /// tile lands right above the app's last other background tile, so
    /// a strip shows the remembered tile only where it would otherwise
    /// have shown a sibling of the same app.
    static func raiseOrder(_ order: [HyprWindow], focusedID: CGWindowID?,
                           appFront: [pid_t: CGWindowID] = [:]) -> [HyprWindow] {
        guard order.count > 1 else { return order }
        let idx = focusedIndex(order: order, focusedID: focusedID)
        var result: [HyprWindow] = []
        result.append(contentsOf: order[..<idx])
        result.append(contentsOf: order[(idx + 1)...].reversed())
        result.append(order[idx])
        guard !appFront.isEmpty else { return result }

        let focused = order[idx].windowID
        for (pid, frontID) in appFront.sorted(by: { $0.key < $1.key }) {
            guard frontID != focused,
                  let from = result.firstIndex(where: { $0.windowID == frontID }),
                  result[from].ownerPID == pid,
                  let lastSibling = result.lastIndex(where: {
                      $0.ownerPID == pid && $0.windowID != frontID && $0.windowID != focused
                  }),
                  lastSibling > from else { continue }
            let window = result.remove(at: from)
            // the sibling shifted down by one; inserting at its old index
            // puts the front tile directly above it
            result.insert(window, at: lastSibling)
        }
        return result
    }

    /// The windows `raiseOrder` actually has to raise, given the stack's
    /// current back-to-front z-order.
    ///
    /// An AX raise puts a window on top of everything, so the only way to
    /// reach `desired` is to raise some suffix of it, in order, and leave
    /// the rest where it is. Every raise of a background tile covers the
    /// front window until the front is raised again — with near-identical
    /// rects that is a visible flash of the wrong tile — so the suffix is
    /// the shortest one whose remainder is already in the desired order.
    /// An empty result means the stack is already right. A window missing
    /// from `current` (not on screen) forces a full re-raise.
    static func minimalRaises(current: [CGWindowID], desired: [CGWindowID]) -> [CGWindowID] {
        let onScreen = Set(current)
        guard desired.allSatisfy({ onScreen.contains($0) }) else { return desired }
        let members = Set(desired)
        let stack = current.filter { members.contains($0) }
        for j in stride(from: desired.count, through: 0, by: -1) {
            let suffix = Set(desired[j...])
            if stack.filter({ !suffix.contains($0) }) == Array(desired[..<j]) {
                return Array(desired[j...])
            }
        }
        return desired
    }

    /// Deterministic hit test for the accordion stack.
    ///
    /// Frame containment is useless here — every window's rect overlaps
    /// nearly the whole screen — so the pick is by *visible region*: the
    /// front window owns everything between the peek strips, the left
    /// strip belongs to the adjacent window before it in order, the right
    /// strip to the one after. Returns `nil` outside the inset area
    /// (padding, menu bar), so callers leave focus alone there.
    static func windowAt(_ point: CGPoint,
                         order: [HyprWindow],
                         focusedID: CGWindowID?,
                         in rect: CGRect,
                         padding: OuterPadding,
                         overlap: CGFloat) -> HyprWindow? {
        let inner = padding.inset(rect)
        guard !order.isEmpty, inner.contains(point) else { return nil }
        let idx = focusedIndex(order: order, focusedID: focusedID)
        let peek = clampedOverlap(overlap, innerWidth: inner.width)
        let hasLeft = idx > 0
        let hasRight = idx < order.count - 1
        if hasLeft, point.x < inner.minX + peek { return order[idx - 1] }
        if hasRight, point.x > inner.maxX - peek { return order[idx + 1] }
        return order[idx]
    }

    /// The window currently in the front slot — `focusedID` when it is in
    /// `order`, else the first window (matching `frames`' fallback).
    static func frontWindow(order: [HyprWindow], focusedID: CGWindowID?) -> HyprWindow? {
        guard !order.isEmpty else { return nil }
        return order[focusedIndex(order: order, focusedID: focusedID)]
    }

    /// The window to put focus on after the system activated an app and
    /// made `systemPick` its key window.
    ///
    /// `raiseOrder` keeps each app's remembered tile on top of the app's
    /// other background tiles (`appFront`), so a Cmd-Tab / Dock activation
    /// normally lands there directly. This is the fallback for when it did
    /// not — the app re-ordered its own windows, or the memory changed
    /// after the last layout. `remembered` is the app's last focus
    /// intent; it wins when it and `systemPick` are both members of
    /// `order` and differ. `nil` means keep the system's pick.
    static func activationRestoreTarget(order: [HyprWindow],
                                        systemPick: CGWindowID,
                                        remembered: CGWindowID?) -> HyprWindow? {
        guard let remembered, remembered != systemPick,
              order.contains(where: { $0.windowID == systemPick }),
              let target = order.first(where: { $0.windowID == remembered }) else { return nil }
        return target
    }

    private static func focusedIndex(order: [HyprWindow], focusedID: CGWindowID?) -> Int {
        guard let focusedID,
              let idx = order.firstIndex(where: { $0.windowID == focusedID }) else { return 0 }
        return idx
    }
}
