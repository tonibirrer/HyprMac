import XCTest
import Cocoa
@testable import HyprMac

// StickyWindowsTests pin the candidate selection behind sticky window
// rules (Hyprland's `pin`, adapted): which windows follow the user into a
// workspace being shown. The carry itself (capacity, tree detach, moves)
// lives in WorkspaceOrchestrator and needs live windows — covered manually.
// Single-screen only: the multi-monitor anchoring branch needs several
// real NSScreens.

final class StickyWindowsTests: XCTestCase {

    private var workspaces: WorkspaceManager!
    private var sticky: Set<CGWindowID> = []

    override func setUpWithError() throws {
        guard NSScreen.main ?? NSScreen.screens.first != nil else {
            throw XCTSkip("no NSScreen available — test requires a display")
        }
        let display = DisplayManager()
        // static anchoring is exercised with a single home screen: all nine
        // workspaces anchor to it, so every hidden one is a carry source.
        workspaces = WorkspaceManager(displayManager: display)
        workspaces.disabledMonitors = Set(display.screens.dropFirst().map { $0.localizedName })
        workspaces.initializeMonitors()
        sticky = []
        workspaces.isStickyWindow = { [unowned self] wid in self.sticky.contains(wid) }
    }

    private var visible: Int {
        workspaces.workspaceForScreen(workspaces.enabledScreensLeftToRight()[0])
    }

    private func switchTo(_ ws: Int) {
        let screen = workspaces.enabledScreensLeftToRight()[0]
        _ = workspaces.switchWorkspace(ws, cursorScreen: screen)
    }

    func testNoOptInMeansNothingIsCarried() {
        sticky = [10]
        workspaces.assignWindow(10, toWorkspace: visible)
        switchTo(2)
        XCTAssertEqual(workspaces.stickyWindowsToCarry(into: 2), [])
    }

    func testStickyWindowsFromDisplacedAndHiddenWorkspacesAreCarried() {
        sticky = [10, 12]
        workspaces.stickyWorkspaces = [1, 2]
        let start = visible
        workspaces.assignWindow(10, toWorkspace: start) // sticky, on the displaced workspace
        workspaces.assignWindow(11, toWorkspace: start) // plain — stays behind
        workspaces.assignWindow(12, toWorkspace: 4)     // sticky, parked on a hidden workspace
        let target = start == 1 ? 2 : 1
        switchTo(target)
        XCTAssertEqual(workspaces.stickyWindowsToCarry(into: target), [10, 12])
    }

    func testWorkspaceWithoutOptInHidesStickyWindows() {
        sticky = [10]
        workspaces.stickyWorkspaces = [1, 2]
        workspaces.assignWindow(10, toWorkspace: visible)
        switchTo(3)
        XCTAssertEqual(workspaces.stickyWindowsToCarry(into: 3), [])
    }

    func testStickyWindowLeftOnNonOptInWorkspaceReturnsOnNextOptIn() {
        sticky = [10]
        workspaces.stickyWorkspaces = [1, 2]
        workspaces.assignWindow(10, toWorkspace: 3) // e.g. Hypr+Shift+3 while on ws3
        switchTo(3)
        XCTAssertEqual(workspaces.stickyWindowsToCarry(into: 3), [])
        switchTo(2)
        XCTAssertEqual(workspaces.stickyWindowsToCarry(into: 2), [10])
    }

    func testTargetWorkspaceOwnWindowsAreNotCandidates() {
        sticky = [10]
        workspaces.stickyWorkspaces = [1, 2]
        workspaces.assignWindow(10, toWorkspace: 2)
        switchTo(2)
        // already on the target — nothing to carry, nothing to detach
        XCTAssertEqual(workspaces.stickyWindowsToCarry(into: 2), [])
    }

    func testScratchpadMembersNeverCarry() {
        sticky = [10]
        workspaces.stickyWorkspaces = [1, 2]
        workspaces.assignWindow(10, toWorkspace: ScratchpadController.workspace)
        switchTo(2)
        XCTAssertEqual(workspaces.stickyWindowsToCarry(into: 2), [])
    }

    func testOutOfRangeTargetIsEmpty() {
        sticky = [10]
        workspaces.stickyWorkspaces = [1, 2, 0, 10]
        workspaces.assignWindow(10, toWorkspace: 1)
        XCTAssertEqual(workspaces.stickyWindowsToCarry(into: 0), [])
        XCTAssertEqual(workspaces.stickyWindowsToCarry(into: 10), [])
    }
}
