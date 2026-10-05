import XCTest
@testable import HyprMac

// CapsLockGuardTests pin the guard that keeps the Caps Lock lock off while
// Caps Lock is the Hypr key: the key is remapped to F18 and cannot toggle
// the lock, so anything else switching it on would strand every keystroke
// in capitals.

final class CapsLockGuardTests: XCTestCase {

    private var lockOn = false
    /// what the guard asked the HID system for
    private var requests: [Bool] = []
    /// whether a request takes; a re-syncing app ignores the guard
    private var requestsTake = true
    private var guardUnderTest: CapsLockGuard!

    override func setUp() {
        lockOn = false
        requests = []
        requestsTake = true
        guardUnderTest = CapsLockGuard()
        guardUnderTest.isActive = { true }
        guardUnderTest.isLockOn = { [unowned self] in lockOn }
        guardUnderTest.setLock = { [unowned self] on in
            requests.append(on)
            if requestsTake { lockOn = on }
            return true
        }
        guardUnderTest.frontmostApp = { "com.citrix.receiver.icaviewer.mac" }
        guardUnderTest.runAfter = { _, work in work() }
    }

    func testALockSwitchedOnIsSwitchedOff() {
        lockOn = true

        XCTAssertTrue(guardUnderTest.check(reason: "test"))

        XCTAssertEqual(requests, [false])
        XCTAssertFalse(lockOn)
        XCTAssertEqual(guardUnderTest.failedClears, 0)
    }

    func testALockThatIsOffIsLeftAlone() {
        XCTAssertFalse(guardUnderTest.check(reason: "test"))
        XCTAssertEqual(requests, [])
    }

    func testAnotherHyprKeyLeavesCapsLockToTheUser() {
        guardUnderTest.isActive = { false }
        lockOn = true

        XCTAssertFalse(guardUnderTest.check(reason: "test"))
        XCTAssertEqual(requests, [])
        XCTAssertTrue(lockOn)
    }

    func testALockThatSurvivesAClearGetsOnThenOff() {
        lockOn = true
        requestsTake = false

        guardUnderTest.check(reason: "test")
        XCTAssertEqual(guardUnderTest.failedClears, 1)
        requestsTake = true
        guardUnderTest.check(reason: "test")

        XCTAssertEqual(requests, [false, true, false])
        XCTAssertFalse(lockOn)
        XCTAssertEqual(guardUnderTest.failedClears, 0, "recovered")
    }

    func testItKeepsSwitchingItOffPastTheLogLimit() {
        for _ in 0..<6 {
            lockOn = true
            guardUnderTest.check(reason: "test")
        }

        XCTAssertEqual(requests.count, 6, "the log goes quiet, the guard does not")
        XCTAssertFalse(lockOn)
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
