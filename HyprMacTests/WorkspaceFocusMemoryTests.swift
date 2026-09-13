import XCTest
import Cocoa
@testable import HyprMac

// WorkspaceFocusMemoryTests pin the per-workspace last-focused memory the
// workspace switch consults: returning to a workspace must land on the
// window the user left there (in accordion mode that is the front slot),
// and the memory must not outlive the window's membership.

final class WorkspaceFocusMemoryTests: XCTestCase {

    private var workspaces: WorkspaceManager!

    override func setUp() {
        workspaces = WorkspaceManager(displayManager: DisplayManager())
    }

    func testNothingRememberedInitially() {
        XCTAssertNil(workspaces.lastFocusedWindow(onWorkspace: 1))
    }

    func testNoteFocusRemembersPerWorkspace() {
        workspaces.assignWindow(11, toWorkspace: 1)
        workspaces.assignWindow(12, toWorkspace: 1)
        workspaces.assignWindow(21, toWorkspace: 2)
        workspaces.noteFocus(11)
        workspaces.noteFocus(12)
        workspaces.noteFocus(21)
        XCTAssertEqual(workspaces.lastFocusedWindow(onWorkspace: 1), 12)
        XCTAssertEqual(workspaces.lastFocusedWindow(onWorkspace: 2), 21)
    }

    func testFocusOnAnotherWorkspaceDoesNotClobber() {
        // Cmd-Tab to a browser on ws2 and back: ws1's memory survives.
        workspaces.assignWindow(11, toWorkspace: 1)
        workspaces.assignWindow(13, toWorkspace: 1)
        workspaces.assignWindow(21, toWorkspace: 2)
        workspaces.noteFocus(13)
        workspaces.noteFocus(21)
        XCTAssertEqual(workspaces.lastFocusedWindow(onWorkspace: 1), 13)
    }

    func testUnassignedWindowIsIgnored() {
        workspaces.assignWindow(11, toWorkspace: 1)
        workspaces.noteFocus(11)
        workspaces.noteFocus(99)
        XCTAssertEqual(workspaces.lastFocusedWindow(onWorkspace: 1), 11)
    }

    func testRemovedWindowIsForgotten() {
        workspaces.assignWindow(11, toWorkspace: 1)
        workspaces.noteFocus(11)
        workspaces.removeWindow(11)
        XCTAssertNil(workspaces.lastFocusedWindow(onWorkspace: 1))
    }

    func testMovedWindowIsForgottenOnOldWorkspace() {
        workspaces.assignWindow(11, toWorkspace: 1)
        workspaces.noteFocus(11)
        workspaces.moveWindow(11, toWorkspace: 2)
        XCTAssertNil(workspaces.lastFocusedWindow(onWorkspace: 1))
        // it is not automatically the memory of the new workspace either
        // — focus there has not been observed yet.
        XCTAssertNil(workspaces.lastFocusedWindow(onWorkspace: 2))
    }

    func testReassignToSameWorkspaceKeepsMemory() {
        // discovery re-assigns known windows to their current workspace on
        // every poll; that must not wipe the memory.
        workspaces.assignWindow(11, toWorkspace: 1)
        workspaces.noteFocus(11)
        workspaces.assignWindow(11, toWorkspace: 1)
        XCTAssertEqual(workspaces.lastFocusedWindow(onWorkspace: 1), 11)
    }

    func testOtherWindowLeavingDoesNotForget() {
        workspaces.assignWindow(11, toWorkspace: 1)
        workspaces.assignWindow(12, toWorkspace: 1)
        workspaces.noteFocus(12)
        workspaces.removeWindow(11)
        XCTAssertEqual(workspaces.lastFocusedWindow(onWorkspace: 1), 12)
    }
}
