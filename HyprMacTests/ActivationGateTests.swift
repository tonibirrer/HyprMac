import XCTest
@testable import HyprMac

// ActivationGateTests pin the gesture rules behind the "app activated →
// show its workspace" affordance. The bugs these guard against: a click
// on a tile authorizing a switch for whatever app macOS activated next
// (the fallback activation of a parked window when Citrix refused focus),
// a plain ⌘C acting as a Cmd-Tab, and a programmatic activation riding
// the gesture of an explicit workspace switch made a moment earlier.

final class ActivationGateTests: XCTestCase {

    private let now: CFAbsoluteTime = 1_000

    private func input(_ mutate: (inout ActivationGate.Input) -> Void = { _ in }) -> ActivationGate.Input {
        var i = ActivationGate.Input(now: now)
        mutate(&i)
        return i
    }

    // MARK: gestures

    func testRecentCmdTabQualifies() {
        XCTAssertEqual(ActivationGate.gesture(input { $0.lastCmdTabTime = now - 0.3 }), .cmdTab)
    }

    func testStaleCmdTabDoesNotQualify() {
        XCTAssertNil(ActivationGate.gesture(input { $0.lastCmdTabTime = now - 0.8 }))
    }

    func testClickOutsideManagedWindowsQualifies() {
        XCTAssertEqual(ActivationGate.gesture(input { $0.lastClickTime = now - 0.2 }), .click)
    }

    func testClickOnManagedWindowDoesNotQualify() {
        let i = input { $0.lastClickTime = now - 0.2; $0.clickHitManagedWindow = true }
        XCTAssertNil(ActivationGate.gesture(i))
    }

    func testLauncherPredecessorQualifies() {
        let i = input { $0.predecessorBundleID = "com.apple.dock" }
        XCTAssertEqual(ActivationGate.gesture(i), .launcher("com.apple.dock"))
        XCTAssertNil(ActivationGate.gesture(input { $0.predecessorBundleID = "com.mitchellh.ghostty" }))
    }

    func testExplicitSwitchBlocksClickAndLauncherButNotCmdTab() {
        XCTAssertNil(ActivationGate.gesture(input {
            $0.explicitSwitchRecent = true; $0.lastClickTime = now - 0.1
        }))
        XCTAssertNil(ActivationGate.gesture(input {
            $0.explicitSwitchRecent = true; $0.predecessorBundleID = "com.apple.Spotlight"
        }))
        XCTAssertEqual(ActivationGate.gesture(input {
            $0.explicitSwitchRecent = true; $0.lastCmdTabTime = now - 0.1
        }), .cmdTab)
    }

    // MARK: decisions

    func testVisibleWindowPassesThrough() {
        XCTAssertEqual(ActivationGate.decide(input { $0.hasVisibleWindow = true }), .passThrough)
        XCTAssertEqual(ActivationGate.decide(input {
            $0.hasVisibleWindow = true; $0.lastClickTime = now
        }), .passThrough)
    }

    func testOwnChurnWithoutGestureIsSuppressedEvenWithVisibleWindow() {
        let d = ActivationGate.decide(input { $0.ownChurnSuppressed = true; $0.hasVisibleWindow = true })
        guard case .suppressed = d else { return XCTFail("expected suppressed, got \(d)") }
    }

    func testFreshGestureOverridesOwnChurnSuppression() {
        let d = ActivationGate.decide(input { $0.ownChurnSuppressed = true; $0.lastCmdTabTime = now })
        guard case .allowed = d else { return XCTFail("expected allowed, got \(d)") }
    }

    func testParkedWindowFallbackActivationIsIgnored() {
        // the reproduction: user clicked into the Citrix tile on ws4, Citrix
        // refused activation, macOS activated ghostty's parked window
        let d = ActivationGate.decide(input {
            $0.lastClickTime = now - 0.4
            $0.clickHitManagedWindow = true
            $0.predecessorBundleID = "com.citrix.receiver.icaviewer.mac"
        })
        guard case .ignoredProgrammatic(let why) = d else { return XCTFail("expected ignored, got \(d)") }
        XCTAssertTrue(why.contains("hit a managed window"), why)
    }

    func testDockClickSwitches() {
        let d = ActivationGate.decide(input { $0.lastClickTime = now - 0.1 })
        guard case .allowed(let why) = d else { return XCTFail("expected allowed, got \(d)") }
        XCTAssertTrue(why.contains("click"), why)
    }

    func testProgrammaticActivationAfterExplicitSwitchIsIgnored() {
        let d = ActivationGate.decide(input {
            $0.explicitSwitchRecent = true; $0.lastClickTime = now - 0.1
        })
        guard case .ignoredProgrammatic(let why) = d else { return XCTFail("expected ignored, got \(d)") }
        XCTAssertTrue(why.contains("explicit switch"), why)
    }

    func testClickOnTheAppsOwnUnmanagedWindowStays() {
        // the reproduction: a 1Password approval prompt over Factorio on
        // ws2. 1Password's only tracked window lived on ws8, and every
        // click on the prompt switched there
        let d = ActivationGate.decide(input { $0.lastClickTime = now - 0.1; $0.clickHitAppWindow = true })
        guard case .clickedAppWindow = d else { return XCTFail("expected clickedAppWindow, got \(d)") }
    }

    func testCmdTabSwitchesEvenRightAfterAClickOnTheAppsWindow() {
        let d = ActivationGate.decide(input {
            $0.lastCmdTabTime = now - 0.1; $0.lastClickTime = now - 0.3; $0.clickHitAppWindow = true
        })
        guard case .allowed = d else { return XCTFail("expected allowed, got \(d)") }
    }

    // MARK: window under a click

    private func win(pid: pid_t, alpha: CGFloat = 1,
                     x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h] as [String: CGFloat],
        ]
    }

    func testTheFrontmostWindowUnderThePointOwnsTheClick() {
        let list = [win(pid: 931, x: 500, y: 300, w: 400, h: 300),
                    win(pid: 68366, x: 0, y: 0, w: 1512, h: 982)]
        XCTAssertEqual(ActivationGate.ownerPID(at: CGPoint(x: 600, y: 400), windowList: list, selfPID: 1), 931)
        XCTAssertEqual(ActivationGate.ownerPID(at: CGPoint(x: 100, y: 100), windowList: list, selfPID: 1), 68366)
    }

    func testOwnOverlaysAndTransparentWindowsAreLookedThrough() {
        let list = [win(pid: 1, x: 0, y: 0, w: 1512, h: 982),
                    win(pid: 77, alpha: 0, x: 0, y: 0, w: 1512, h: 982),
                    win(pid: 931, x: 500, y: 300, w: 400, h: 300)]
        XCTAssertEqual(ActivationGate.ownerPID(at: CGPoint(x: 600, y: 400), windowList: list, selfPID: 1), 931)
        XCTAssertNil(ActivationGate.ownerPID(at: CGPoint(x: 100, y: 100), windowList: list, selfPID: 1))
    }

    func testFocusOnActivateRuleSwitchesWithoutGesture() {
        let d = ActivationGate.decide(input { $0.ruleActivate = true })
        guard case .allowed = d else { return XCTFail("expected allowed, got \(d)") }
        // but never through our own churn window
        let s = ActivationGate.decide(input { $0.ruleActivate = true; $0.ownChurnSuppressed = true })
        guard case .suppressed = s else { return XCTFail("expected suppressed, got \(s)") }
    }
}
