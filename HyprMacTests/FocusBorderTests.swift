import XCTest
import AppKit
@testable import HyprMac

// State-machine invariants of the focused-window border. No pixels are
// asserted — the tests drive show/hide and read the state introspection.

final class FocusBorderTests: XCTestCase {

    private func makeBorder() -> FocusBorder {
        let b = FocusBorder()
        b.primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080
        b.fadeDurationSec = 0
        return b
    }

    private let rect = CGRect(x: 100, y: 100, width: 400, height: 300)

    func testShowStartsInActiveTint() {
        let b = makeBorder()
        b.show(around: rect, windowID: 7)
        XCTAssertTrue(b.isShowingBorder)
        XCTAssertTrue(b.isShowingActiveTint, "a focus change paints the tint first")
        XCTAssertEqual(b.trackedWindowID, 7)
    }

    func testSettledShowSkipsTint() {
        // re-showing after a mechanical hide (floater drag) must not replay
        // the tint: that is the "window lights up on every click" flash.
        let b = makeBorder()
        b.show(around: rect, windowID: 7)
        b.hide(animated: false)
        XCTAssertFalse(b.isShowingBorder)
        b.show(around: rect, windowID: 7, settled: true)
        XCTAssertTrue(b.isShowingBorder)
        XCTAssertFalse(b.isShowingActiveTint)
        XCTAssertEqual(b.trackedWindowID, 7)
    }

    func testRedundantShowIsIdempotent() {
        let b = makeBorder()
        b.show(around: rect, windowID: 7)
        b.settle()
        XCTAssertFalse(b.isShowingActiveTint)
        // same window, same frame → no state change, no tint replay
        b.show(around: rect, windowID: 7)
        XCTAssertFalse(b.isShowingActiveTint)
    }

    func testHideClearsTracking() {
        let b = makeBorder()
        b.show(around: rect, windowID: 7)
        b.hide()
        XCTAssertNil(b.trackedWindowID)
        XCTAssertFalse(b.isShowingBorder)
    }
}
