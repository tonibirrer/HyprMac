import XCTest
@testable import HyprMac

// CapsLockGuardTests pin the guard that keeps the Caps Lock lock off while
// Caps Lock is the Hypr key: the key is remapped to F18 and cannot toggle
// the lock, so anything else switching it on would strand every keystroke
// in capitals.

final class CapsLockGuardTests: XCTestCase {

    private var lockOn = false
    private var clears = 0
    private var guardUnderTest: CapsLockGuard!

    override func setUp() {
        lockOn = false
        clears = 0
        guardUnderTest = CapsLockGuard()
        guardUnderTest.isActive = { true }
        guardUnderTest.isLockOn = { [unowned self] in lockOn }
        guardUnderTest.switchLockOff = { [unowned self] in clears += 1; lockOn = false; return true }
        guardUnderTest.frontmostApp = { "com.citrix.receiver.icaviewer.mac" }
    }

    func testALockSwitchedOnIsSwitchedOff() {
        lockOn = true

        XCTAssertTrue(guardUnderTest.check(reason: "test"))

        XCTAssertEqual(clears, 1)
        XCTAssertFalse(lockOn)
    }

    func testALockThatIsOffIsLeftAlone() {
        XCTAssertFalse(guardUnderTest.check(reason: "test"))
        XCTAssertEqual(clears, 0)
    }

    func testAnotherHyprKeyLeavesCapsLockToTheUser() {
        guardUnderTest.isActive = { false }
        lockOn = true

        XCTAssertFalse(guardUnderTest.check(reason: "test"))
        XCTAssertEqual(clears, 0)
        XCTAssertTrue(lockOn)
    }

    func testItKeepsSwitchingItOffPastTheLogLimit() {
        for _ in 0..<6 {
            lockOn = true
            guardUnderTest.check(reason: "test")
        }

        XCTAssertEqual(clears, 6, "the log goes quiet, the guard does not")
    }
}

final class FullscreenNoRoomTests: XCTestCase {

    func testOnlyAWindowWithoutATileIsRefused() {
        let tile = HyprWindow(element: AXUIElementCreateApplication(9880), windowID: 701, ownerPID: 9880)
        let floater = HyprWindow(element: AXUIElementCreateApplication(9880), windowID: 702, ownerPID: 9880)
        let newcomer = HyprWindow(element: AXUIElementCreateApplication(9880), windowID: 703, ownerPID: 9880)

        let refused = FullscreenSpaceController.windowsWithoutRoom(
            [tile, floater, newcomer], tiled: [701], floating: [702])

        XCTAssertEqual(refused.map(\.windowID), [703],
                       "tiles keep their slots behind the fullscreen Space; floaters float on")
    }
}
