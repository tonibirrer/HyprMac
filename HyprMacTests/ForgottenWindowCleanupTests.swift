import XCTest
import Cocoa
@testable import HyprMac

// a window discovery forgets for good (its app died) leaves no slot memory
// behind. CGWindowIDs get recycled, and a new window under the dead one's
// id took the dead one's slot.

final class ForgottenWindowCleanupTests: XCTestCase {

    func testAForgottenWindowLeavesNoSlotForARecycledID() throws {
        let screen = CleanupTestScreen()
        let displayManager = DisplayManager(screenSource: { [screen] })
        let engine = TilingEngine(displayManager: displayManager,
                                  frameSizingIOFactory: acceptingFrameSizingIOFactory())
        let dispatcher = makeDispatcher(displayManager: displayManager, engine: engine)
        // the engine half of WindowManager's cleanup, in its order: the
        // memory is forgotten, then the scratchpad sweeps the id out of
        // whichever tree still holds it
        dispatcher.applyForgottenIDCleanup = { id in
            engine.forgetMinimumSize(windowID: id)
            engine.removeWindowID(id)
        }
        dispatcher.isMenuTracking = { true }

        let a = makeWindow(id: 1101), b = makeWindow(id: 1102)
        let c = makeWindow(id: 1103), d = makeWindow(id: 1104)
        XCTAssertTrue(engine.tileWindows([a, b, c, d], onWorkspace: 1, screen: screen).published)
        let before = engine.intendedTileRects()

        _ = dispatcher.applyChanges(WindowChanges(newWindows: [], newOnDisabledMonitor: [], returned: [],
                                                  goneIDs: [b.windowID], fullyForgottenIDs: [b.windowID],
                                                  screenDrift: [], focusedWindowGone: false,
                                                  requestsRecheck: false),
                                    allWindows: [a, c, d])
        XCTAssertTrue(engine.tileWindows([a, c, d], onWorkspace: 1, screen: screen).published)

        let recycled = makeWindow(id: b.windowID)
        XCTAssertTrue(engine.tileWindows([a, recycled, c, d], onWorkspace: 1, screen: screen).published)

        let rects = engine.intendedTileRects()
        XCTAssertNotNil(rects[recycled.windowID])
        XCTAssertNotEqual(rects[recycled.windowID], before[b.windowID],
                          "a new window, not the dead one back in its slot")
    }

    private func makeDispatcher(displayManager: DisplayManager, engine: TilingEngine) -> ActionDispatcher {
        let stateCache = WindowStateCache()
        let suppressions = SuppressionRegistry()
        let focusBorder = FocusBorder()
        let focusController = FocusStateController(focusBorder: focusBorder)
        let dimmingOverlay = DimmingOverlay()
        let accessibility = AccessibilityManager()
        let cursorManager = CursorManager()
        let workspaceManager = WorkspaceManager(displayManager: displayManager)
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
        return ActionDispatcher(
            stateCache: stateCache, accessibility: accessibility,
            displayManager: displayManager, cursorManager: cursorManager,
            workspaceManager: workspaceManager, tilingEngine: engine,
            focusController: focusController, focusBorder: focusBorder,
            keybindOverlay: KeybindOverlayController(), appLauncher: AppLauncherManager(),
            workspaceOrchestrator: orchestrator, floatingController: floating,
            config: UserConfig())
    }
}

private final class CleanupTestScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 4000, y: 0, width: 1600, height: 1000) }
    override var visibleFrame: NSRect { frame }
}
