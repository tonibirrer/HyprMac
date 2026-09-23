import XCTest
import Carbon
@testable import HyprMac

// ActivationGestureTests pin which keystrokes leave the ⌘ breadcrumb the
// activation gate reads: only a ⌘-Tab app switch, refreshed by the ⌘
// release that commits it — never a plain ⌘ shortcut or an unrelated ⌘
// press/release.

final class ActivationGestureTests: XCTestCase {

    private var manager: HotkeyManager!

    override func setUp() {
        manager = HotkeyManager()
    }

    private func keyDown(_ key: Int, flags: CGEventFlags) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true)!
        e.flags = flags
        return e
    }

    private func commandFlagsChanged(down: Bool) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Command), keyDown: down)!
        e.flags = down ? .maskCommand : []
        return e
    }

    func testCmdTabLeavesBreadcrumb() {
        let before = CFAbsoluteTimeGetCurrent()
        _ = manager.handleEvent(.keyDown, keyDown(kVK_Tab, flags: .maskCommand))
        XCTAssertGreaterThanOrEqual(manager.lastCommandGestureTime, before)
    }

    func testPlainCommandShortcutLeavesNoBreadcrumb() {
        _ = manager.handleEvent(.keyDown, keyDown(kVK_ANSI_C, flags: .maskCommand))
        _ = manager.handleEvent(.keyDown, keyDown(kVK_ANSI_V, flags: .maskCommand))
        XCTAssertEqual(manager.lastCommandGestureTime, 0)
    }

    func testCommandPressAndReleaseAloneLeaveNoBreadcrumb() {
        _ = manager.handleEvent(.flagsChanged, commandFlagsChanged(down: true))
        _ = manager.handleEvent(.flagsChanged, commandFlagsChanged(down: false))
        XCTAssertEqual(manager.lastCommandGestureTime, 0)
    }

    func testCommandReleaseRefreshesAPendingCmdTabOnce() {
        _ = manager.handleEvent(.keyDown, keyDown(kVK_Tab, flags: .maskCommand))
        let atTab = manager.lastCommandGestureTime
        Thread.sleep(forTimeInterval: 0.02)
        _ = manager.handleEvent(.flagsChanged, commandFlagsChanged(down: false))
        let atRelease = manager.lastCommandGestureTime
        XCTAssertGreaterThan(atRelease, atTab)
        // a later, unrelated ⌘ release is not a gesture
        Thread.sleep(forTimeInterval: 0.02)
        _ = manager.handleEvent(.flagsChanged, commandFlagsChanged(down: true))
        _ = manager.handleEvent(.flagsChanged, commandFlagsChanged(down: false))
        XCTAssertEqual(manager.lastCommandGestureTime, atRelease)
    }

    func testConsumeClearsBreadcrumbAndPendingTab() {
        _ = manager.handleEvent(.keyDown, keyDown(kVK_Tab, flags: .maskCommand))
        manager.consumeCommandGesture()
        XCTAssertEqual(manager.lastCommandGestureTime, 0)
        _ = manager.handleEvent(.flagsChanged, commandFlagsChanged(down: false))
        XCTAssertEqual(manager.lastCommandGestureTime, 0)
    }
}
