import XCTest
import Cocoa
@testable import HyprMac

// FullscreenWorkspaceTests pin how a native-fullscreen window behaves like
// any other window of its workspace: it belongs to one workspace, takes its
// screen while that workspace is up, shows on a switch to the workspace, and
// gets out of the way on a switch to another one.

final class FullscreenMembersTests: XCTestCase {

    private func seen(_ id: CGWindowID, pid: pid_t = 50, space: CGSSpaceID = 217,
                      display: String = "AW", showing: Bool = false) -> FullscreenWindowObservation {
        FullscreenWindowObservation(windowID: id, pid: pid, space: space, displayUUID: display, isShowing: showing)
    }

    func testANewFullscreenWindowJoinsTheWorkspaceItIsAssigned() {
        let members = FullscreenMembers()

        let change = members.reconcile([seen(4367)], assign: { _ in 4 })

        XCTAssertEqual(change.added.map(\.windowID), [4367])
        XCTAssertEqual(members.members(onWorkspace: 4).map(\.windowID), [4367])
        XCTAssertEqual(members.occupiedDisplays(onWorkspace: 4), ["AW"])
        XCTAssertEqual(members.workspaces(ownedBy: 50), [4])
    }

    func testAMemberKeepsItsWorkspaceAndTracksWhetherItShows() {
        let members = FullscreenMembers()
        members.reconcile([seen(4367)], assign: { _ in 4 })

        let change = members.reconcile([seen(4367, showing: true)], assign: { _ in 9 })

        XCTAssertTrue(change.added.isEmpty)
        XCTAssertEqual(members.byWindow[4367]?.workspace, 4, "assigned once")
        XCTAssertEqual(members.showingMember(onDisplay: "AW")?.windowID, 4367)
    }

    func testAWindowNoLongerFullscreenLeaves() {
        let members = FullscreenMembers()
        members.reconcile([seen(4367), seen(5000, pid: 60, display: "DELL")], assign: { _ in 4 })

        let change = members.reconcile([seen(5000, pid: 60, display: "DELL")], assign: { _ in 4 })

        XCTAssertEqual(change.removed.map(\.windowID), [4367])
        XCTAssertEqual(members.occupiedDisplays(onWorkspace: 4), ["DELL"])
    }

    func testARecycledIDFromAnotherAppIsANewMember() {
        let members = FullscreenMembers()
        members.reconcile([seen(4367, pid: 50)], assign: { _ in 4 })

        let change = members.reconcile([seen(4367, pid: 77)], assign: { _ in 6 })

        XCTAssertEqual(change.added.map(\.workspace), [6])
    }

    func testOnlyASpaceThatCameUpCountsAsShownOutOfTurn() {
        let fresh = FullscreenSpaceController.Refresh(
            membershipChanged: false,
            newlyShown: [FullscreenMember(windowID: 4367, pid: 50, workspace: 4, space: 217,
                                          displayUUID: "AW", isShowing: true)])

        XCTAssertEqual(FullscreenSpaceController.workspaceShownOutOfTurn(fresh, visibleWorkspaces: [2]), 4)
        XCTAssertNil(FullscreenSpaceController.workspaceShownOutOfTurn(fresh, visibleWorkspaces: [4]),
                     "its workspace is up: nothing to follow")
        XCTAssertNil(FullscreenSpaceController.workspaceShownOutOfTurn(.init(), visibleWorkspaces: [2]),
                     "a Space that stayed up does not pull the user back")
    }
}

// MARK: - the linked strip gives up the screen a fullscreen window takes

final class FullscreenScreenVacateTests: XCTestCase {

    private var frames: [CGWindowID: CGRect] = [:]
    private var clock: TimeInterval = 0

    func testAVacatedScreensTilesJoinTheRemainingScreen() {
        let left = FullscreenTestScreen(x: 0, name: "left-fs")
        let right = FullscreenTestScreen(x: 1600, name: "right-fs")
        let display = DisplayManager(screenSource: { [left, right] })
        var io: ((@escaping () -> UInt64) -> FrameSizingIO)?
        let engine = TilingEngine(displayManager: display,
                                  frameSizingIOFactory: { _, generation in io!(generation) })
        io = { [unowned self] generation in
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
        let windows = (1...4).map { FullscreenTestWindow(id: CGWindowID(500 + $0)) }
        for w in windows { frames[w.windowID] = CGRect(x: 20, y: 20, width: 300, height: 300) }
        engine.tileLinked(windows, onWorkspace: 4, screens: [left, right])
        XCTAssertFalse(engine.windowIDs(inTreeForWorkspace: 4, screen: right).isEmpty, "fixture: both screens hold tiles")

        let vacated = engine.vacateTree(forWorkspace: 4, screen: right)
        engine.tileLinked(windows, onWorkspace: 4, screens: [left])

        XCTAssertFalse(vacated.isEmpty)
        XCTAssertEqual(Set(engine.windowIDs(inTreeForWorkspace: 4, screen: left)), Set(windows.map(\.windowID)))
        XCTAssertEqual(engine.windowIDs(inTreeForWorkspace: 4, screen: right), [])
        XCTAssertEqual(engine.windowIDs(inAnyTreeForWorkspace: 4).count, 4, "no window in two trees")
    }
}

// MARK: - the switch shows a fullscreen window, and leaves another's Space

final class FullscreenSwitchTests: XCTestCase {

    private var screen: FullscreenTestScreen!
    private var manager: WorkspaceManager!
    private var focus: FocusStateController!
    private var orchestrator: WorkspaceOrchestrator!
    private var tile: FullscreenTestWindow!
    private var target = 0
    private var presented: [Int] = []
    private var left: [(workspace: Int, focused: CGWindowID?, refocus: () -> Void)] = []
    private var withFullscreen: Set<Int> = []

    override func setUpWithError() throws {
        screen = FullscreenTestScreen(x: 0, name: "fs-switch")
        let display = DisplayManager(screenSource: { [screen = screen!] in [screen] })
        manager = WorkspaceManager(displayManager: display)
        manager.initializeMonitors()
        let state = WindowStateCache()
        let border = FocusBorder()
        focus = FocusStateController(focusBorder: border)
        orchestrator = WorkspaceOrchestrator(
            workspaceManager: manager, tilingEngine: TilingEngine(displayManager: display),
            accessibility: AccessibilityManager(), displayManager: display,
            cursorManager: CursorManager(), stateCache: state,
            focusController: focus, focusBorder: border,
            dimmingOverlay: DimmingOverlay(), suppressions: SuppressionRegistry(),
            revalidation: MinimaRevalidation())

        let visible = manager.workspaceForScreen(screen)
        target = try XCTUnwrap(manager.workspacesAnchoredTo(screen).first { $0 != visible })
        tile = FullscreenTestWindow(id: 601)
        manager.assignWindow(tile.windowID, toWorkspace: target)
        state.knownWindowIDs.insert(tile.windowID)
        state.cachedWindows[tile.windowID] = tile

        orchestrator.allWindows = { [unowned self] in [self.tile] }
        orchestrator.screenUnderCursor = { [unowned self] in self.screen }
        orchestrator.tileAllVisibleSpaces = { }
        orchestrator.runAfter = { _, work in work() }
        orchestrator.presentFullscreenWindows = { [unowned self] ws in
            self.presented.append(ws)
            return self.withFullscreen.contains(ws)
        }
        orchestrator.leaveFullscreenSpaces = { [unowned self] ws, focused, refocus in
            self.left.append((ws, focused?.windowID, refocus))
        }
    }

    func testAWorkspaceWithAFullscreenWindowShowsItInsteadOfFocusingATile() {
        withFullscreen = [target]

        orchestrator.switchWorkspace(target)

        XCTAssertEqual(presented, [target])
        XCTAssertNotEqual(focus.lastFocusedID, tile.windowID, "the fullscreen window keeps focus")
        XCTAssertEqual(left.map(\.workspace), [target], "other workspaces' fullscreen Spaces still go")
        XCTAssertNil(left.first?.focused)
    }

    func testAWorkspaceWithoutOneFocusesItsTileAndLeavesForeignSpacesAroundIt() {
        orchestrator.switchWorkspace(target)

        XCTAssertEqual(focus.lastFocusedID, tile.windowID)
        XCTAssertEqual(left.first?.focused, tile.windowID)
    }

    func testFocusReturnsToTheTileOnceTheForeignSpaceIsGone() {
        orchestrator.switchWorkspace(target)
        let focusesBySwitch = tile.focusCount

        left.first?.refocus()

        XCTAssertEqual(tile.focusCount, focusesBySwitch + 1, "the anchor took focus; the tile gets it back")
    }

    func testARefocusLeavesAWindowTheUserFocusedSince() {
        orchestrator.switchWorkspace(target)
        let focusesBySwitch = tile.focusCount
        focus.recordFocus(999, reason: "user")

        left.first?.refocus()

        XCTAssertEqual(tile.focusCount, focusesBySwitch)
        XCTAssertEqual(focus.lastFocusedID, 999)
    }

    func testAnOverviewPickBeatsTheFullscreenWindow() {
        withFullscreen = [target]

        orchestrator.switchWorkspace(target, preferredWindowID: tile.windowID)

        XCTAssertEqual(presented, [], "an explicit target wins")
        XCTAssertEqual(focus.lastFocusedID, tile.windowID)
    }

    func testHyprNOnTheWorkspaceThatIsUpBringsItsFullscreenWindowBack() {
        orchestrator.switchWorkspace(target)
        withFullscreen = [target]
        presented = []

        orchestrator.switchWorkspace(target)

        XCTAssertEqual(presented, [target])
    }
}

// MARK: - doubles

private final class FullscreenTestScreen: NSScreen {
    private let bounds: CGRect
    private let name: String
    init(x: CGFloat, name: String) {
        bounds = CGRect(x: x, y: 0, width: 1600, height: 1000)
        self.name = name
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var frame: NSRect { bounds }
    override var visibleFrame: NSRect { bounds }
    // detached test screen: AppKit traps on both of these on macOS 26
    override var localizedName: String { name }
    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: 930_000 + Int(bounds.minX))]
    }
}

private final class FullscreenTestWindow: HyprWindow {
    init(id: CGWindowID) {
        super.init(element: AXUIElementCreateApplication(9879), windowID: id, ownerPID: 9879)
    }
    override var isFullscreen: Bool { false }
    override var isSizeSettable: Bool? { true }
    private(set) var focusCount = 0
    override func raise() { }
    override func focus() { focusCount += 1 }
    override func focusWithoutRaise() { }
}

// MARK: - a replaced session window is held back, not tiled away

final class FullscreenHandoverTests: XCTestCase {

    private var clock = Date(timeIntervalSince1970: 1_000)
    private var controller: FullscreenSpaceController!

    override func setUp() {
        controller = FullscreenSpaceController()
        controller.now = { [unowned self] in clock }
        controller.workspaceForNewMember = { _ in 4 }
    }

    private func session(_ id: CGWindowID, pid: pid_t = 50) -> FullscreenWindowObservation {
        FullscreenWindowObservation(windowID: id, pid: pid, bundleID: "com.citrix.receiver.icaviewer.mac",
                                    space: 217, displayUUID: "AW", isShowing: true)
    }

    func testAnAppNeverFullscreenIsNotHeld() {
        XCTAssertNil(controller.holdRemaining(bundleID: "com.mitchellh.ghostty", firstSeen: clock))
    }

    func testANewWindowOfAFullscreenAppWaitsAMoment() {
        controller.apply([session(4367)])

        XCTAssertEqual(controller.holdRemaining(bundleID: "com.citrix.receiver.icaviewer.mac", firstSeen: clock),
                       FullscreenSpaceController.freshWindowHold)
        clock += FullscreenSpaceController.freshWindowHold + 0.1
        XCTAssertNil(controller.holdRemaining(bundleID: "com.citrix.receiver.icaviewer.mac",
                                              firstSeen: clock - FullscreenSpaceController.freshWindowHold - 0.1))
    }

    func testAReplacedSessionWindowIsHeldLongerEvenUnderANewProcess() {
        controller.apply([session(4367, pid: 50)])
        controller.apply([])   // the login closed the session window

        clock += 1
        let remaining = controller.holdRemaining(bundleID: "com.citrix.receiver.icaviewer.mac", firstSeen: clock)

        XCTAssertEqual(remaining ?? 0, FullscreenSpaceController.handoverHold - 1, accuracy: 0.001)
        clock += FullscreenSpaceController.handoverHold
        XCTAssertNil(controller.holdRemaining(bundleID: "com.citrix.receiver.icaviewer.mac",
                                              firstSeen: clock - FullscreenSpaceController.freshWindowHold - 1))
    }
}

// MARK: - a window that comes back takes its own slot

final class LinkedOrderMemoryTests: XCTestCase {

    private var frames: [CGWindowID: CGRect] = [:]
    private var clock: TimeInterval = 0
    private var left: FullscreenTestScreen!
    private var right: FullscreenTestScreen!
    private var engine: TilingEngine!
    private var windows: [FullscreenTestWindow] = []

    override func setUp() {
        left = FullscreenTestScreen(x: 0, name: "left-order")
        right = FullscreenTestScreen(x: 1600, name: "right-order")
        let display = DisplayManager(screenSource: { [left = left!, right = right!] in [left, right] })
        var io: ((@escaping () -> UInt64) -> FrameSizingIO)?
        engine = TilingEngine(displayManager: display,
                              frameSizingIOFactory: { _, generation in io!(generation) })
        io = { [unowned self] generation in
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
        windows = (1...4).map { FullscreenTestWindow(id: CGWindowID(800 + $0)) }
        for (i, w) in windows.enumerated() {
            frames[w.windowID] = CGRect(x: 20 + CGFloat(i) * 10, y: 20, width: 300, height: 300)
        }
    }

    private func strip() -> [CGWindowID] {
        engine.windowIDs(inTreeForWorkspace: 2, screen: left) + engine.windowIDs(inTreeForWorkspace: 2, screen: right)
    }

    func testAWindowThatLeftAndCameBackTakesItsOwnSlot() {
        engine.tileLinked(windows, onWorkspace: 2, screens: [left, right])
        let before = strip()
        let second = windows[1]

        engine.removeWindowID(second.windowID)   // hidden, or missed by a snapshot
        engine.tileLinked(windows.filter { $0 !== second }, onWorkspace: 2, screens: [left, right])
        engine.tileLinked(windows, onWorkspace: 2, screens: [left, right])

        XCTAssertEqual(strip(), before, "not appended at the right end")
    }

    func testAWindowMovedAwayAndBackIsNew() {
        engine.tileLinked(windows, onWorkspace: 2, screens: [left, right])
        let first = windows[0]

        engine.removeWindow(first, fromWorkspace: 2)
        engine.tileLinked(Array(windows.dropFirst()), onWorkspace: 2, screens: [left, right])
        engine.tileLinked(Array(windows.dropFirst()) + [first], onWorkspace: 2, screens: [left, right])

        XCTAssertEqual(strip().last, first.windowID, "a window that moved in appends at the right end")
    }

    func testReinsertionGoesAfterTheNearestRememberedPredecessor() {
        XCTAssertEqual(TilingEngine.insertingRemembered([2], into: [1, 3, 4], remembered: [1, 2, 3, 4]), [1, 2, 3, 4])
        XCTAssertEqual(TilingEngine.insertingRemembered([1], into: [3, 4], remembered: [1, 2, 3, 4]), [1, 3, 4])
        XCTAssertEqual(TilingEngine.insertingRemembered([2], into: [3, 1, 4], remembered: [1, 2, 3, 4]), [3, 1, 2, 4],
                       "after its predecessor wherever a swap put it")
    }
}
