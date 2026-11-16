import XCTest
@testable import HyprMac

// Snagit's editor (pinned to the scratchpad) hides during a capture and comes
// back with the result while Snagit is the front app.
final class ScratchpadReturnSummonTests: XCTestCase {
    private let snagitPID: pid_t = 69156
    private let zenPID: pid_t = 5055

    private func editor(pinned: Bool = true, member: Bool = true) -> ScratchpadReturnSummon.Candidate {
        .init(windowID: 10043, ownerPID: snagitPID, pinned: pinned, member: member)
    }

    func testPinnedMemberBackWithItsAppInFrontShowsTheLayer() {
        XCTAssertEqual(ScratchpadReturnSummon.windowToSummon(
            [editor()], frontmostPID: snagitPID, layerVisible: false, transitionPending: false), 10043)
    }

    func testBackWhileAnotherAppIsInFrontStaysParked() {
        XCTAssertNil(ScratchpadReturnSummon.windowToSummon(
            [editor()], frontmostPID: zenPID, layerVisible: false, transitionPending: false))
    }

    func testMemberWithoutAPinStaysParked() {
        // sent to the scratchpad by hand: its app coming back is no request to see it
        XCTAssertNil(ScratchpadReturnSummon.windowToSummon(
            [editor(pinned: false)], frontmostPID: snagitPID, layerVisible: false, transitionPending: false))
    }

    func testPinnedWindowOutsideTheLayerIsLeftToTheWorkspaces() {
        XCTAssertNil(ScratchpadReturnSummon.windowToSummon(
            [editor(member: false)], frontmostPID: snagitPID, layerVisible: false, transitionPending: false))
    }

    func testLayerAlreadyUpTakesTheReturnAsUsual() {
        XCTAssertNil(ScratchpadReturnSummon.windowToSummon(
            [editor()], frontmostPID: snagitPID, layerVisible: true, transitionPending: false))
    }

    func testDisplayTransitionDoesNotSummon() {
        XCTAssertNil(ScratchpadReturnSummon.windowToSummon(
            [editor()], frontmostPID: snagitPID, layerVisible: false, transitionPending: true))
    }

    func testPicksTheFrontAppsWindowAmongSeveral() {
        let other = ScratchpadReturnSummon.Candidate(windowID: 728, ownerPID: zenPID, pinned: true, member: true)
        XCTAssertEqual(ScratchpadReturnSummon.windowToSummon(
            [other, editor()], frontmostPID: snagitPID, layerVisible: false, transitionPending: false), 10043)
    }
}
