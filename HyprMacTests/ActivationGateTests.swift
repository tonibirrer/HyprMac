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

    func testFocusOnActivateRuleSwitchesWithoutGesture() {
        let d = ActivationGate.decide(input { $0.ruleActivate = true })
        guard case .allowed = d else { return XCTFail("expected allowed, got \(d)") }
        // but never through our own churn window
        let s = ActivationGate.decide(input { $0.ruleActivate = true; $0.ownChurnSuppressed = true })
        guard case .suppressed = s else { return XCTFail("expected suppressed, got \(s)") }
    }
}
