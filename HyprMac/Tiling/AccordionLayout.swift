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
    static func raiseOrder(_ order: [HyprWindow], focusedID: CGWindowID?) -> [HyprWindow] {
        guard order.count > 1 else { return order }
        let idx = focusedIndex(order: order, focusedID: focusedID)
        var result: [HyprWindow] = []
        result.append(contentsOf: order[..<idx])
        result.append(contentsOf: order[(idx + 1)...].reversed())
        result.append(order[idx])
        return result
    }

    private static func focusedIndex(order: [HyprWindow], focusedID: CGWindowID?) -> Int {
        guard let focusedID,
              let idx = order.firstIndex(where: { $0.windowID == focusedID }) else { return 0 }
        return idx
    }
}
