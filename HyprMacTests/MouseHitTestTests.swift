import XCTest
@testable import HyprMac

// The FFM hit-test rule: the first foreign window under the cursor decides.
// A normal-layer window is a focus candidate; anything above the normal
// layer (menu, popover, palette, Dock, menu bar) blocks FFM instead of
// being looked through — looking through is what dismissed popovers.

final class MouseHitTestTests: XCTestCase {

    private func win(_ id: Int, pid: pid_t = 100, layer: Int = 0, alpha: CGFloat = 1,
                     x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> [String: Any] {
        [
            kCGWindowNumber as String: id,
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h] as [String: CGFloat],
        ]
    }

    private let screenArea: CGFloat = 1512 * 982

    func testNormalWindowUnderCursorIsACandidate() {
        let list = [win(10, x: 0, y: 0, w: 800, h: 600)]
        XCTAssertEqual(MouseTrackingManager.classifyHit(at: CGPoint(x: 100, y: 100), windowList: list,
                                                        selfPID: 1, screenArea: screenArea),
                       .window(10))
    }

    func testPopupAboveTileBlocksInsteadOfSeeingThrough() {
        let list = [
            win(20, pid: 200, layer: 101, x: 900, y: 30, w: 300, h: 400),   // Control Center popover
            win(10, x: 0, y: 0, w: 1512, h: 982),                            // tile beneath
        ]
        XCTAssertEqual(MouseTrackingManager.classifyHit(at: CGPoint(x: 1000, y: 200), windowList: list,
                                                        selfPID: 1, screenArea: screenArea),
                       .overlay)
        // outside the popover the tile is still found
        XCTAssertEqual(MouseTrackingManager.classifyHit(at: CGPoint(x: 100, y: 500), windowList: list,
                                                        selfPID: 1, screenArea: screenArea),
                       .window(10))
    }

    func testOwnWindowsAndTransparentWindowsAreSkipped() {
        let list = [
            win(30, pid: 1, layer: 3, x: 0, y: 0, w: 1512, h: 982),          // our own border panel
            win(40, pid: 300, layer: 101, alpha: 0, x: 0, y: 0, w: 500, h: 500), // invisible popup
            win(10, x: 0, y: 0, w: 800, h: 600),
        ]
        XCTAssertEqual(MouseTrackingManager.classifyHit(at: CGPoint(x: 100, y: 100), windowList: list,
                                                        selfPID: 1, screenArea: screenArea),
                       .window(10))
    }

    func testScreenWideOverlayIsLookedThrough() {
        // a screen dimmer / color filter window covers the whole screen at a
        // high layer — that is not a popup and must not kill FFM.
        let list = [
            win(50, pid: 400, layer: 1000, x: 0, y: 0, w: 1512, h: 982),
            win(10, x: 0, y: 0, w: 800, h: 600),
        ]
        XCTAssertEqual(MouseTrackingManager.classifyHit(at: CGPoint(x: 100, y: 100), windowList: list,
                                                        selfPID: 1, screenArea: screenArea),
                       .window(10))
    }

    func testNothingUnderCursor() {
        let list = [win(10, x: 0, y: 0, w: 800, h: 600)]
        XCTAssertEqual(MouseTrackingManager.classifyHit(at: CGPoint(x: 1000, y: 900), windowList: list,
                                                        selfPID: 1, screenArea: screenArea),
                       .none)
    }
}
