import XCTest
import Cocoa
@testable import HyprMac

// SwitchDroppedTileTests pin the recovery for a switch whose retile reads a
// window list that misses some of the incoming workspace's tiles. Seen live
// right after a ⌘-Tab to an app whose windows were all parked: the retile
// dropped the tiles from the tree, the windows stayed parked, and the
// screens stayed empty until the user switched away and back.

final class SwitchDroppedTileTests: XCTestCase {

    private var screen: DroppedTileTestScreen!
    private var manager: WorkspaceManager!
    private var engine: TilingEngine!
    private var state: WindowStateCache!
    private var focus: FocusStateController!
    private var orchestrator: WorkspaceOrchestrator!
    private var tiles: [DroppedTileTestWindow] = []
    /// what the window list returns right now
    private var listed: [HyprWindow] = []
    private var pending: [() -> Void] = []
    private var retiles = 0
    private var visibleWorkspace = 0
    private var hiddenWorkspace = 0
    private var frames: [CGWindowID: CGRect] = [:]
    private var clock: TimeInterval = 0

    override func setUpWithError() throws {
        screen = DroppedTileTestScreen()
        let display = DisplayManager(screenSource: { [screen = screen!] in [screen] })
        manager = WorkspaceManager(displayManager: display)
        manager.initializeMonitors()
        var io: ((@escaping () -> UInt64) -> FrameSizingIO)?
        engine = TilingEngine(displayManager: display,
                              frameSizingIOFactory: { _, generation in io!(generation) })
        io = { [unowned self] generation in self.frameIO(generation) }
        state = WindowStateCache()
        let border = FocusBorder()
        focus = FocusStateController(focusBorder: border)
        orchestrator = WorkspaceOrchestrator(
            workspaceManager: manager, tilingEngine: engine,
            accessibility: AccessibilityManager(), displayManager: display,
            cursorManager: CursorManager(), stateCache: state,
            focusController: focus, focusBorder: border,
            dimmingOverlay: DimmingOverlay(), suppressions: SuppressionRegistry(),
            revalidation: MinimaRevalidation())

        visibleWorkspace = manager.workspaceForScreen(screen)
        hiddenWorkspace = try XCTUnwrap(manager.workspacesAnchoredTo(screen).first { $0 != visibleWorkspace })

        // two tiles on the hidden workspace, tiled while it was up last
        tiles = [401, 402].map { DroppedTileTestWindow(id: $0) }
        for w in tiles {
            frames[w.windowID] = CGRect(x: 1599, y: 999, width: 600, height: 400)
            manager.assignWindow(w.windowID, toWorkspace: hiddenWorkspace)
            state.knownWindowIDs.insert(w.windowID)
            state.cachedWindows[w.windowID] = w
        }
        let fixture = engine.tileWindows(tiles, onWorkspace: hiddenWorkspace, screen: screen)
        XCTAssertTrue(fixture.published, "fixture: the hidden workspace was tiled when it was up")

        orchestrator.allWindows = { [unowned self] in self.listed }
        orchestrator.screenUnderCursor = { [unowned self] in self.screen }
        orchestrator.warpToWindow = { _ in }
        orchestrator.runAfter = { [unowned self] _, work in self.pending.append(work) }
        // the real retile: each visible workspace keeps exactly the windows
        // the list has for it, so a missing one drops out of its tree
        orchestrator.tileAllVisibleSpaces = { [unowned self] in
            self.retiles += 1
            let ws = self.manager.workspaceForScreen(self.screen)
            let members = self.manager.windowIDs(onWorkspace: ws)
            self.engine.tileWindows(self.listed.filter { members.contains($0.windowID) },
                                    onWorkspace: ws, screen: self.screen)
        }
    }

    /// frame i/o that takes every write
    private func frameIO(_ generation: @escaping () -> UInt64) -> FrameSizingIO {
        FrameSizingIO(
            setMessagingTimeout: { _, _ in .success },
            writeSize: { [unowned self] id, size, _ in frames[id]?.size = size; return .success },
            writePosition: { [unowned self] id, point, _ in frames[id]?.origin = point; return .success },
            readPosition: { [unowned self] id, _ in (.success, frames[id]?.origin) },
            readSize: { [unowned self] id, _ in (.success, frames[id]?.size) },
            now: { [unowned self] in clock },
            sleep: { [unowned self] in clock += $0 },
            currentGeneration: generation)
    }

    private func tiled() -> Set<CGWindowID> {
        engine.windowIDs(inAnyTreeForWorkspace: hiddenWorkspace)
    }

    private func runPending() {
        let work = pending
        pending = []
        work.forEach { $0() }
    }

    func testARetileThatMissesTheTilesDropsThemFromTheTree() {
        listed = []

        orchestrator.switchWorkspace(hiddenWorkspace)

        XCTAssertEqual(tiled(), [], "the mechanism behind the empty screens")
        XCTAssertEqual(pending.count, 1, "a retry is scheduled")
    }

    func testTheRetryTilesThemOnceTheWindowListHasThem() {
        listed = []
        orchestrator.switchWorkspace(hiddenWorkspace)

        listed = tiles
        runPending()

        XCTAssertEqual(tiled(), [401, 402])
        XCTAssertEqual(pending.count, 0, "nothing left to retry")
    }

    func testTheRetryFocusesAReTiledWindowWhenTheSwitchFoundNone() {
        manager.noteFocus(402)
        listed = []
        orchestrator.switchWorkspace(hiddenWorkspace)
        XCTAssertNotEqual(focus.lastFocusedID, 402, "the switch had nothing to focus")

        listed = tiles
        runPending()

        XCTAssertEqual(focus.lastFocusedID, 402, "the window the user last had there")
    }

    func testTheRetryLeavesAWindowTheUserFocusedSince() {
        listed = []
        orchestrator.switchWorkspace(hiddenWorkspace)
        focus.recordFocus(999, reason: "test")

        listed = tiles
        runPending()

        XCTAssertEqual(tiled(), [401, 402])
        XCTAssertEqual(focus.lastFocusedID, 999)
    }

    func testRetriesStopAfterAboutASecondWhileTheListStillMissesThem() {
        listed = []
        orchestrator.switchWorkspace(hiddenWorkspace)
        let retilesAfterSwitch = retiles

        for _ in 0..<5 { runPending() }

        XCTAssertEqual(pending.count, 0)
        XCTAssertEqual(retiles, retilesAfterSwitch, "no retile while the list still misses them")
        XCTAssertEqual(tiled(), [])
    }

    func testHyprNOnTheVisibleWorkspaceRetriesOnceTheRetriesRanOut() {
        listed = []
        orchestrator.switchWorkspace(hiddenWorkspace)
        for _ in 0..<5 { runPending() }

        listed = tiles
        orchestrator.switchWorkspace(hiddenWorkspace)

        XCTAssertEqual(tiled(), [401, 402])
    }

    func testAPollRetriesOnceTheRetriesRanOut() {
        listed = []
        orchestrator.switchWorkspace(hiddenWorkspace)
        for _ in 0..<5 { runPending() }

        listed = tiles
        XCTAssertTrue(orchestrator.retileDroppedTiles("poll"))

        XCTAssertEqual(tiled(), [401, 402])
        XCTAssertFalse(orchestrator.retileDroppedTiles("poll"), "done: the next poll is a no-op")
    }

    func testAnotherSwitchCancelsTheRetry() {
        listed = []
        orchestrator.switchWorkspace(hiddenWorkspace)
        orchestrator.switchWorkspace(visibleWorkspace)
        let retilesAfterSwitches = retiles

        listed = tiles
        runPending()

        XCTAssertEqual(retiles, retilesAfterSwitches)
        XCTAssertFalse(orchestrator.retileDroppedTiles("poll"))
    }

    func testAWindowThatWentHiddenIsNotRetried() {
        listed = []
        orchestrator.switchWorkspace(hiddenWorkspace)
        // discovery saw both go: minimized, Cmd-H'd, or onto another Space
        state.hiddenWindowIDs.formUnion([401, 402])
        let retilesAfterSwitch = retiles

        listed = tiles
        runPending()

        XCTAssertEqual(retiles, retilesAfterSwitch)
    }

    func testACompleteRetileSchedulesNothing() {
        listed = tiles

        orchestrator.switchWorkspace(hiddenWorkspace)

        XCTAssertEqual(tiled(), [401, 402])
        XCTAssertEqual(pending.count, 0)
    }
}

// MARK: - doubles

private final class DroppedTileTestScreen: NSScreen {
    private let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    override init() { super.init() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var frame: NSRect { bounds }
    override var visibleFrame: NSRect { bounds }
    // detached test screen: AppKit traps on both of these on macOS 26
    override var localizedName: String { "dropped-tile-test" }
    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: 920_000)]
    }
}

private final class DroppedTileTestWindow: HyprWindow {
    init(id: CGWindowID) {
        super.init(element: AXUIElementCreateApplication(9878), windowID: id, ownerPID: 9878)
    }
    override var isFullscreen: Bool { false }
    override var isSizeSettable: Bool? { true }
    override func raise() { }
    override func focus() { }
    override func focusWithoutRaise() { }
}
