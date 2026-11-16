import XCTest
@testable import HyprMac

final class StrandedFloaterRestoreTests: XCTestCase {
    // the desk: DELL left of the AW ultrawide, CG coordinates
    private let dell = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
    private let aw = CGRect(x: 0, y: 0, width: 3440, height: 1440)

    // parked at the DELL-only corner (2559, 1439), then nudged up by macOS
    // until the title bar shows: 32 of 243 points on the AW
    private let strandedAbout = CGRect(x: 2559, y: 1408, width: 280, height: 243)

    func testStrandedFloaterGoesBackToItsSavedFrame() {
        let saved = CGRect(x: 616, y: 386, width: 280, height: 243)
        let target = StrandedFloaterRestore.target(frame: strandedAbout, saved: saved,
                                                   screens: [dell, aw], home: aw)
        XCTAssertEqual(target, saved)
    }

    func testStrandedFloaterWithoutSavedFrameIsCenteredOnItsHome() {
        let target = StrandedFloaterRestore.target(frame: strandedAbout, saved: nil,
                                                   screens: [dell, aw], home: aw)
        XCTAssertEqual(target, CGRect(x: 1580, y: 598.5, width: 280, height: 243))
    }

    func testOnePixelParkSliverIsStranded() {
        let sliver = CGRect(x: 3439, y: 1439, width: 870, height: 950)
        XCTAssertNotNil(StrandedFloaterRestore.target(frame: sliver, saved: nil,
                                                      screens: [dell, aw], home: aw))
    }

    func testVisibleFloaterStays() {
        let onDell = CGRect(x: -1200, y: 300, width: 800, height: 600)
        XCTAssertNil(StrandedFloaterRestore.target(frame: onDell, saved: nil,
                                                   screens: [dell, aw], home: aw))
    }

    func testFloaterHangingPartlyOffAnEdgeStays() {
        // half of it still shows: the user put it there, it is not parked
        let halfOff = CGRect(x: 3040, y: 400, width: 800, height: 600)
        XCTAssertNil(StrandedFloaterRestore.target(frame: halfOff, saved: CGRect(x: 0, y: 0, width: 10, height: 10),
                                                   screens: [dell, aw], home: aw))
    }

    func testNoSavedFrameAndNoHomeLeavesIt() {
        XCTAssertNil(StrandedFloaterRestore.target(frame: strandedAbout, saved: nil,
                                                   screens: [dell, aw], home: nil))
    }
}
