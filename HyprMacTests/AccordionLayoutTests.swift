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
}
