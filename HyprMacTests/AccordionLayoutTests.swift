import XCTest
@testable import HyprMac

// AccordionLayout.frames / raiseOrder — pure geometry, no AX.
final class AccordionLayoutTests: XCTestCase {

    private let rect = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let pad = OuterPadding(uniform: 10)
    private let overlap: CGFloat = 50

    private func frames(_ order: [HyprWindow], focused: CGWindowID?) -> [CGWindowID: CGRect] {
        var out: [CGWindowID: CGRect] = [:]
        for (w, f) in AccordionLayout.frames(order: order, focusedID: focused,
                                             in: rect, padding: pad, overlap: overlap) {
            out[w.windowID] = f
        }
        return out
    }

    func testSingleWindowFillsInsetRect() {
        let w = makeWindow(id: 1)
        let f = frames([w], focused: 1)
        XCTAssertEqual(f[1], CGRect(x: 10, y: 10, width: 980, height: 580))
    }

    func testEmptyOrderProducesNoFrames() {
        XCTAssertTrue(AccordionLayout.frames(order: [], focusedID: nil,
                                             in: rect, padding: pad, overlap: overlap).isEmpty)
    }

    func testMiddleFocusPeeksBothSides() {
        let order = [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)]
        let f = frames(order, focused: 2)
        // inner = (10,10,980,580); both sides have neighbors → width 980-2*50
        let width: CGFloat = 980 - 100
        XCTAssertEqual(f[2], CGRect(x: 60, y: 10, width: width, height: 580))
        // left window aligned to left edge, right window to right edge
        XCTAssertEqual(f[1], CGRect(x: 10, y: 10, width: width, height: 580))
        XCTAssertEqual(f[3], CGRect(x: 990 - width, y: 10, width: width, height: 580))
        // visible strips are exactly `overlap` px on each side
        XCTAssertEqual(f[2]!.minX - f[1]!.minX, 50)
        XCTAssertEqual(f[3]!.maxX - f[2]!.maxX, 50)
    }

    func testFirstFocusedHasNoLeftPeek() {
        let order = [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)]
        let f = frames(order, focused: 1)
        let width: CGFloat = 980 - 50 // only a right stack
        XCTAssertEqual(f[1], CGRect(x: 10, y: 10, width: width, height: 580))
        XCTAssertEqual(f[2], CGRect(x: 990 - width, y: 10, width: width, height: 580))
        XCTAssertEqual(f[3], CGRect(x: 990 - width, y: 10, width: width, height: 580))
    }

    func testLastFocusedHasNoRightPeek() {
        let order = [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)]
        let f = frames(order, focused: 3)
        let width: CGFloat = 980 - 50 // only a left stack
        XCTAssertEqual(f[3], CGRect(x: 60, y: 10, width: width, height: 580))
        XCTAssertEqual(f[1], CGRect(x: 10, y: 10, width: width, height: 580))
        XCTAssertEqual(f[2], CGRect(x: 10, y: 10, width: width, height: 580))
    }

    func testUnknownFocusFallsBackToFirst() {
        let order = [makeWindow(id: 1), makeWindow(id: 2)]
        let withNil = frames(order, focused: nil)
        let withStale = frames(order, focused: 99)
        let withFirst = frames(order, focused: 1)
        XCTAssertEqual(withNil, withFirst)
        XCTAssertEqual(withStale, withFirst)
    }

    // Regression guard for the cross-workspace focus steal: a stale
    // focusedID (one not in this tree — e.g. the user's focus is on
    // another workspace) makes index 0 the front slot, so raiseOrder
    // puts a *foreign* tree's first window frontmost. WindowManager
    // must therefore never hand a non-visible id to the layout; this
    // pins the consequence if that guard is ever removed.
    func testStaleFocusPromotesFirstWindowToFront() {
        let order = [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)]
        let raised = AccordionLayout.raiseOrder(order, focusedID: 99)
        XCTAssertEqual(raised.last?.windowID, 1)
        XCTAssertEqual(AccordionLayout.frontWindow(order: order, focusedID: 99)?.windowID, 1)
        // and with a real member it is that member, not index 0
        XCTAssertEqual(AccordionLayout.raiseOrder(order, focusedID: 3).last?.windowID, 3)
    }

    func testOverlapClampedOnNarrowRect() {
        // overlap larger than a quarter of the inner width gets clamped so
        // the shared window width can't collapse
        let clamped = AccordionLayout.clampedOverlap(500, innerWidth: 980)
        XCTAssertEqual(clamped, 245)
        let order = [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)]
        let all = AccordionLayout.frames(order: order, focusedID: 2,
                                         in: rect, padding: pad, overlap: 500)
        for (_, frame) in all {
            XCTAssertEqual(frame.width, 980 - 2 * 245)
            XCTAssertGreaterThan(frame.width, 0)
        }
    }

    func testRaiseOrderShowsNearestNeighborsOnTop() {
        let order = (1...5).map { makeWindow(id: CGWindowID($0)) }
        // focused = 3: back-to-front should be 1, 2 (left, outermost first),
        // 5, 4 (right, outermost first), 3 (focused frontmost)
        let raised = AccordionLayout.raiseOrder(order, focusedID: 3).map { $0.windowID }
        XCTAssertEqual(raised, [1, 2, 5, 4, 3])
    }

    private func windowAt(_ x: CGFloat, _ y: CGFloat = 300,
                          order: [HyprWindow], focused: CGWindowID?) -> CGWindowID? {
        AccordionLayout.windowAt(CGPoint(x: x, y: y), order: order, focusedID: focused,
                                 in: rect, padding: pad, overlap: overlap)?.windowID
    }

    func testWindowAtResolvesStripsAndFront() {
        let order = (1...4).map { makeWindow(id: CGWindowID($0)) }
        // focused = 2: inner (10,10,980,580), left strip x < 60, right strip x > 940
        XCTAssertEqual(windowAt(30, order: order, focused: 2), 1)   // left strip → prev
        XCTAssertEqual(windowAt(500, order: order, focused: 2), 2)  // middle → front
        XCTAssertEqual(windowAt(960, order: order, focused: 2), 3)  // right strip → next
    }

    func testWindowAtEdgesHaveNoPhantomStrip() {
        let order = (1...3).map { makeWindow(id: CGWindowID($0)) }
        // first focused: no left strip — far-left click is still the front
        XCTAssertEqual(windowAt(30, order: order, focused: 1), 1)
        // last focused: no right strip
        XCTAssertEqual(windowAt(960, order: order, focused: 3), 3)
    }

    func testWindowAtOutsideInsetReturnsNil() {
        let order = [makeWindow(id: 1), makeWindow(id: 2)]
        XCTAssertNil(windowAt(5, order: order, focused: 1))          // in padding
        XCTAssertNil(windowAt(500, 5, order: order, focused: 1))     // above inset
        XCTAssertNil(AccordionLayout.windowAt(CGPoint(x: 500, y: 300), order: [],
                                              focusedID: nil, in: rect,
                                              padding: pad, overlap: overlap))
    }

    func testFrontWindowFallsBackToFirst() {
        let order = (1...3).map { makeWindow(id: CGWindowID($0)) }
        XCTAssertEqual(AccordionLayout.frontWindow(order: order, focusedID: 2)?.windowID, 2)
        XCTAssertEqual(AccordionLayout.frontWindow(order: order, focusedID: 99)?.windowID, 1)
        XCTAssertEqual(AccordionLayout.frontWindow(order: order, focusedID: nil)?.windowID, 1)
        XCTAssertNil(AccordionLayout.frontWindow(order: [], focusedID: 1))
    }

    func testRaiseOrderEdges() {
        let order = (1...3).map { makeWindow(id: CGWindowID($0)) }
        XCTAssertEqual(AccordionLayout.raiseOrder(order, focusedID: 1).map { $0.windowID }, [3, 2, 1])
        XCTAssertEqual(AccordionLayout.raiseOrder(order, focusedID: 3).map { $0.windowID }, [1, 2, 3])
        let single = [makeWindow(id: 7)]
        XCTAssertEqual(AccordionLayout.raiseOrder(single, focusedID: 7).map { $0.windowID }, [7])
    }

    // MARK: - per-app front tile

    func testAppFrontTileIsRaisedAboveItsSiblingsOnly() {
        // zen(1) in front; ghostty tiles 2,3,4 behind it, the user left 4.
        // far-to-near would put 2 on top of ghostty's windows; with the
        // memory, 4 goes right above ghostty's last other tile (2) and
        // stays below the focused window.
        let order = [makeWindow(id: 1, pid: 10), makeWindow(id: 2, pid: 20),
                     makeWindow(id: 3, pid: 20), makeWindow(id: 4, pid: 20)]
        XCTAssertEqual(AccordionLayout.raiseOrder(order, focusedID: 1, appFront: [20: 4]).map(\.windowID),
                       [3, 2, 4, 1])
    }

    func testAppFrontTileDoesNotCrossOtherApps() {
        // left of the focused window (5): ghostty 1, zen 2, ghostty 3, zen 4.
        // ghostty's front (1) moves right above its sibling 3 and no further.
        let order = [makeWindow(id: 1, pid: 20), makeWindow(id: 2, pid: 10),
                     makeWindow(id: 3, pid: 20), makeWindow(id: 4, pid: 10), makeWindow(id: 5, pid: 30)]
        XCTAssertEqual(AccordionLayout.raiseOrder(order, focusedID: 5, appFront: [20: 1]).map(\.windowID),
                       [2, 3, 1, 4, 5])
    }

    func testAppFrontIsANoOpWhenAlreadyOnTopOrFocusedOrUnknown() {
        let order = [makeWindow(id: 1, pid: 10), makeWindow(id: 2, pid: 20),
                     makeWindow(id: 3, pid: 20), makeWindow(id: 4, pid: 20)]
        let plain = AccordionLayout.raiseOrder(order, focusedID: 1).map(\.windowID)
        XCTAssertEqual(plain, [4, 3, 2, 1])
        // 2 is already ghostty's topmost background tile
        XCTAssertEqual(AccordionLayout.raiseOrder(order, focusedID: 1, appFront: [20: 2]).map(\.windowID), plain)
        // the focused window is raised last regardless
        XCTAssertEqual(AccordionLayout.raiseOrder(order, focusedID: 1, appFront: [10: 1]).map(\.windowID), plain)
        // a memory pointing outside the stack, or at another app's window
        XCTAssertEqual(AccordionLayout.raiseOrder(order, focusedID: 1, appFront: [20: 99]).map(\.windowID), plain)
        XCTAssertEqual(AccordionLayout.raiseOrder(order, focusedID: 1, appFront: [20: 1]).map(\.windowID), plain)
    }

    func testAppFrontWithFocusedWindowOfTheSameApp() {
        // ghostty 3 focused, ghostty 1 remembered: 1 goes above sibling 2,
        // the focused tile still last
        let order = [makeWindow(id: 1, pid: 20), makeWindow(id: 2, pid: 20), makeWindow(id: 3, pid: 20)]
        XCTAssertEqual(AccordionLayout.raiseOrder(order, focusedID: 3, appFront: [20: 1]).map(\.windowID),
                       [2, 1, 3])
    }

    // MARK: - activation restore

    func testActivationRestorePrefersRememberedTileOfSameStack() {
        // zen(1) in front raises ghostty tiles 4,3,2 far-to-near, so 2 is
        // ghostty's topmost window and Cmd-Tab lands there; the user left 4.
        let order = [makeWindow(id: 1, pid: 10), makeWindow(id: 2, pid: 20),
                     makeWindow(id: 3, pid: 20), makeWindow(id: 4, pid: 20)]
        XCTAssertEqual(AccordionLayout.raiseOrder(order, focusedID: 1).map(\.windowID), [4, 3, 2, 1])
        let target = AccordionLayout.activationRestoreTarget(order: order, systemPick: 2, remembered: 4)
        XCTAssertEqual(target?.windowID, 4)
    }

    func testActivationRestoreKeepsSystemPickWhenItIsTheRememberedTile() {
        let order = [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)]
        XCTAssertNil(AccordionLayout.activationRestoreTarget(order: order, systemPick: 3, remembered: 3))
    }

    func testActivationRestoreKeepsSystemPickWithoutMemory() {
        let order = [makeWindow(id: 1), makeWindow(id: 2)]
        XCTAssertNil(AccordionLayout.activationRestoreTarget(order: order, systemPick: 1, remembered: nil))
    }

    func testActivationRestoreIgnoresWindowsOutsideTheStack() {
        // remembered tile moved to another workspace / closed: not in order
        let order = [makeWindow(id: 1), makeWindow(id: 2)]
        XCTAssertNil(AccordionLayout.activationRestoreTarget(order: order, systemPick: 1, remembered: 9))
        // system picked a window that is not part of this stack (floater)
        XCTAssertNil(AccordionLayout.activationRestoreTarget(order: order, systemPick: 9, remembered: 2))
    }
}
