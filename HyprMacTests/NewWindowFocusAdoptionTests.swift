import XCTest
import Cocoa
@testable import HyprMac

// an app focuses its new window (Cmd-N) before discovery knows it, so the
// AX focus event resolves to no tracked window and focus stays on the old
// one. on an accordion screen the retile then raised the old front over
// the new window. discovery adopts the app's focus before it retiles.

final class NewWindowFocusAdoptionTests: XCTestCase {

    // MARK: - decision

    func testTheAppsFocusedNewWindowIsAdopted() {
        XCTAssertEqual(ActionDispatcher.newWindowFocusToAdopt(
            newWindowIDs: [7], appFocusedID: 7, currentFocusID: 3, isVisible: { _ in true }), 7)
    }

    func testAFocusedOldWindowOrNoFocusChangesNothing() {
        XCTAssertNil(ActionDispatcher.newWindowFocusToAdopt(
            newWindowIDs: [7], appFocusedID: 3, currentFocusID: 3, isVisible: { _ in true }))
        XCTAssertNil(ActionDispatcher.newWindowFocusToAdopt(
            newWindowIDs: [7], appFocusedID: 5, currentFocusID: 3, isVisible: { _ in true }),
            "the app focused a window that is not new")
        XCTAssertNil(ActionDispatcher.newWindowFocusToAdopt(
            newWindowIDs: [7], appFocusedID: nil, currentFocusID: 3, isVisible: { _ in true }))
    }

    // a pin parked it on a hidden workspace: focus there would raise it over
    // the workspace the user is on
    func testANewWindowOnAHiddenWorkspaceIsNotAdopted() {
        XCTAssertNil(ActionDispatcher.newWindowFocusToAdopt(
            newWindowIDs: [7], appFocusedID: 7, currentFocusID: 3, isVisible: { _ in false }))
    }

    // MARK: - discovery pass

    func testFocusMovesToTheNewWindowBeforeTheRetile() {
        let env = makeEnvironment()
        let old = makeWindow(id: 2101), new = makeWindow(id: 2102)
        env.workspaces.assignWindow(old.windowID, toWorkspace: 1)
        env.focus.recordFocus(old.windowID, reason: "test")
        _ = env.dispatcher.applyChanges(Self.changes(new: []), allWindows: [old])

        env.dispatcher.appFocusedWindowID = { new.windowID }
        var focusAtRetile: CGWindowID?
        env.dispatcher.animatedRetile = { _ in
            focusAtRetile = env.focus.lastFocusedID
            return []
        }
        var bordered: CGWindowID?
        env.dispatcher.updateFocusBorder = { bordered = $0.windowID }

        _ = env.dispatcher.applyChanges(Self.changes(new: [new]), allWindows: [old, new])

        XCTAssertEqual(focusAtRetile, new.windowID, "the retile must see the new window as focused")
        XCTAssertEqual(env.focus.lastFocusedID, new.windowID)
        XCTAssertEqual(bordered, new.windowID)
    }

    func testANewWindowTheAppDidNotFocusLeavesFocusAlone() {
        let env = makeEnvironment()
        let old = makeWindow(id: 2201), new = makeWindow(id: 2202)
        env.workspaces.assignWindow(old.windowID, toWorkspace: 1)
        env.focus.recordFocus(old.windowID, reason: "test")
        _ = env.dispatcher.applyChanges(Self.changes(new: []), allWindows: [old])

        env.dispatcher.appFocusedWindowID = { old.windowID }
        _ = env.dispatcher.applyChanges(Self.changes(new: [new]), allWindows: [old, new])

        XCTAssertEqual(env.focus.lastFocusedID, old.windowID)
    }

    // at launch every window is new; the invariant picks focus there
    func testTheInitialDiscoveryAdoptsNothing() {
        let env = makeEnvironment()
        let new = makeWindow(id: 2301)
        env.dispatcher.appFocusedWindowID = { new.windowID }

        _ = env.dispatcher.applyChanges(Self.changes(new: [new]), allWindows: [new])

        XCTAssertNotEqual(env.focus.lastFocusedID, new.windowID)
    }

    // MARK: - fixtures

    private struct Environment {
        let dispatcher: ActionDispatcher
        let focus: FocusStateController
        let workspaces: WorkspaceManager
    }

    private static func changes(new: [HyprWindow]) -> WindowChanges {
        WindowChanges(newWindows: new, newOnDisabledMonitor: [], returned: [],
                      goneIDs: [], fullyForgottenIDs: [], screenDrift: [],
                      focusedWindowGone: false, requestsRecheck: false)
    }

    private func makeEnvironment() -> Environment {
        let screen = AdoptionTestScreen()
        let displayManager = DisplayManager(screenSource: { [screen] })
        let engine = TilingEngine(displayManager: displayManager,
                                  frameSizingIOFactory: acceptingFrameSizingIOFactory())
        let stateCache = WindowStateCache()
        let suppressions = SuppressionRegistry()
        let focusBorder = FocusBorder()
        let focusController = FocusStateController(focusBorder: focusBorder)
        let dimmingOverlay = DimmingOverlay()
        let accessibility = AccessibilityManager()
        let cursorManager = CursorManager()
        let workspaceManager = WorkspaceManager(displayManager: displayManager)
        workspaceManager.initializeMonitors()
        let orchestrator = WorkspaceOrchestrator(
            workspaceManager: workspaceManager, tilingEngine: engine,
            accessibility: accessibility, displayManager: displayManager,
            cursorManager: cursorManager, stateCache: stateCache,
            focusController: focusController, focusBorder: focusBorder,
            dimmingOverlay: dimmingOverlay, suppressions: suppressions,
            revalidation: MinimaRevalidation())
        let floating = FloatingWindowController(
            stateCache: stateCache, suppressions: suppressions,
            workspaceManager: workspaceManager, tilingEngine: engine,
            displayManager: displayManager, accessibility: accessibility,
            cursorManager: cursorManager, focusController: focusController,
            focusBorder: focusBorder, dimmingOverlay: dimmingOverlay)
        let dispatcher = ActionDispatcher(
            stateCache: stateCache, accessibility: accessibility,
            displayManager: displayManager, cursorManager: cursorManager,
            workspaceManager: workspaceManager, tilingEngine: engine,
            focusController: focusController, focusBorder: focusBorder,
            keybindOverlay: KeybindOverlayController(), appLauncher: AppLauncherManager(),
            workspaceOrchestrator: orchestrator, floatingController: floating,
            config: UserConfig())
        dispatcher.screenUnderCursor = { screen }
        // keeps the focus invariant from reaching for real AX state
        dispatcher.isMenuTracking = { true }
        return Environment(dispatcher: dispatcher, focus: focusController, workspaces: workspaceManager)
    }
}

private final class AdoptionTestScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 4000, y: 0, width: 1600, height: 1000) }
    override var visibleFrame: NSRect { frame }
}
