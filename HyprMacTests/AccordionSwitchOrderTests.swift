import XCTest
import Cocoa
@testable import HyprMac

// AccordionSwitchOrderTests pin the order in which an accordion layout
// touches its windows, and which window it fronts during a workspace
// switch. The flicker these guard against: the incoming stack un-parked
// from the hide corner in whatever z-order it was parked, sorted around the
// tree's first window (the engine's focus lookup still named the displaced
// workspace's window), then re-raised around the real focus target — a
// visible reshuffle on every switch, repeated by the relayouts the focus
// change schedules.

final class AccordionSwitchOrderTests: XCTestCase {

    private var screen: AccordionTestScreen!
    private var display: DisplayManager!
    private var engine: TilingEngine!
    private var log: [String] = []
    private var windows: [AccordionTestWindow] = []

    override func setUp() {
        screen = AccordionTestScreen()
        display = DisplayManager(screenSource: { [self.screen] })
        engine = TilingEngine(displayManager: display)
        engine.accordionActive = { _ in true }
        engine.accordionFocusedWindowID = { nil }
        log = []
        windows = (1...3).map { i in
            AccordionTestWindow(id: CGWindowID(100 + i), frame: CGRect(x: 1599, y: 999, width: 600, height: 400)) { [weak self] in
                self?.log.append($0)
            }
        }
    }

    private func raises() -> [String] { log.filter { $0.hasPrefix("raise") } }
    private func frames() -> [String] { log.filter { $0.hasPrefix("frame") } }

    func testZOrderIsSetBeforeAnyFrameIsWritten() {
        engine.tileWindows(windows, onWorkspace: 1, screen: screen)

        let firstFrame = log.firstIndex { $0.hasPrefix("frame") }
        let lastRaise = log.lastIndex { $0.hasPrefix("raise") }
        XCTAssertEqual(raises().count, 3)
        XCTAssertEqual(frames().count, 3)
        XCTAssertNotNil(firstFrame); XCTAssertNotNil(lastRaise)
        XCTAssertLessThan(lastRaise!, firstFrame!, "every raise precedes the first frame write: \(log)")
    }

    func testTheFrontWindowIsRaisedLastAndPlacedFirst() {
        engine.accordionFrontOverride = 102

        engine.tileWindows(windows, onWorkspace: 1, screen: screen)

        XCTAssertEqual(raises().last, "raise:102")
        XCTAssertEqual(frames().first, "frame:102")
    }

    func testWithoutAnyFocusHintTheFirstWindowFronts() {
        engine.tileWindows(windows, onWorkspace: 1, screen: screen)

        XCTAssertEqual(raises().last, "raise:101")
        XCTAssertEqual(frames().first, "frame:101")
    }

    func testTheAppMemoryKeepsItsTileOnTopOfTheAppsOtherTiles() {
        // 101 is app A and fronted; 102 and 103 are app B behind it. far-
        // to-near raises 103 then 102, leaving 102 on top of B's windows;
        // the memory says the user left 103, so 103 goes above 102.
        let a = AccordionTestWindow(id: 101, pid: 1, frame: .zero) { [weak self] in self?.log.append($0) }
        let b1 = AccordionTestWindow(id: 102, pid: 2, frame: .zero) { [weak self] in self?.log.append($0) }
        let b2 = AccordionTestWindow(id: 103, pid: 2, frame: .zero) { [weak self] in self?.log.append($0) }
        engine.accordionFrontOverride = 101
        engine.accordionAppFrontWindowID = { pid in pid == 2 ? 103 : nil }

        engine.tileWindows([a, b1, b2], onWorkspace: 1, screen: screen)

        XCTAssertEqual(raises(), ["raise:102", "raise:103", "raise:101"])
    }

    func testARelayoutSkipsWindowsAlreadyInPlace() {
        engine.accordionFrontOverride = 102
        engine.tileWindows(windows, onWorkspace: 1, screen: screen)
        XCTAssertEqual(frames().count, 3)
        log = []

        // same front, same rects: the stack is re-raised but nothing moves
        engine.tileWindows(windows, onWorkspace: 1, screen: screen)

        XCTAssertEqual(raises().count, 3)
        XCTAssertEqual(frames(), [], "windows already at their frame are not rewritten")
    }

    func testARelayoutRaisesOnlyWhatTheWindowServerHasOutOfPlace() {
        engine.accordionFrontOverride = 102
        // desired back-to-front is [101, 103, 102]; the server says 102 sank
        engine.accordionCurrentZOrder = { _ in [102, 101, 103] }

        engine.tileWindows(windows, onWorkspace: 1, screen: screen)

        XCTAssertEqual(raises(), ["raise:102"])
    }

    func testARelayoutRaisesNothingWhenTheStackIsAlreadyRight() {
        engine.accordionFrontOverride = 102
        engine.accordionCurrentZOrder = { _ in [101, 103, 102] }

        engine.tileWindows(windows, onWorkspace: 1, screen: screen)

        XCTAssertEqual(raises(), [])
        XCTAssertEqual(frames().count, 3, "frames are still written for parked windows")
    }

    func testTheOverrideBeatsTheFocusLookup() {
        engine.accordionFocusedWindowID = { 101 }
        engine.accordionFrontOverride = 103

        engine.tileWindows(windows, onWorkspace: 1, screen: screen)

        XCTAssertEqual(raises().last, "raise:103")
        XCTAssertEqual(engine.accordionFrontWindow(onWorkspace: 1, screen: screen)?.windowID, 103)
        engine.accordionFrontOverride = nil
        XCTAssertEqual(engine.accordionFrontWindow(onWorkspace: 1, screen: screen)?.windowID, 101)
    }
}

// MARK: - the switch picks the front before it retiles

final class AccordionSwitchFrontTests: XCTestCase {

    func testTheSwitchFrontsTheRememberedWindowDuringTheRetile() throws {
        let screen = AccordionTestScreen()
        let display = DisplayManager(screenSource: { [screen] })
        let manager = WorkspaceManager(displayManager: display)
        manager.initializeMonitors()
        let engine = TilingEngine(displayManager: display)
        engine.accordionActive = { _ in true }
        let state = WindowStateCache()
        let border = FocusBorder()
        let orchestrator = WorkspaceOrchestrator(
            workspaceManager: manager, tilingEngine: engine,
            accessibility: AccessibilityManager(), displayManager: display,
            cursorManager: CursorManager(), stateCache: state,
            focusController: FocusStateController(focusBorder: border), focusBorder: border,
            dimmingOverlay: DimmingOverlay(), suppressions: SuppressionRegistry(),
            revalidation: MinimaRevalidation())

        let visible = manager.workspaceForScreen(screen)
        let hidden = try XCTUnwrap(manager.workspacesAnchoredTo(screen).first { $0 != visible })
        let first = AccordionTestWindow(id: 201, frame: CGRect(x: 1599, y: 999, width: 600, height: 400)) { _ in }
        let remembered = AccordionTestWindow(id: 202, frame: CGRect(x: 1599, y: 999, width: 600, height: 400)) { _ in }
        for w in [first, remembered] {
            manager.assignWindow(w.windowID, toWorkspace: hidden)
            state.cachedWindows[w.windowID] = w
        }
        manager.noteFocus(remembered.windowID)
        orchestrator.allWindows = { [first, remembered] }
        orchestrator.screenUnderCursor = { screen }
        orchestrator.warpToWindow = { _ in }

        var frontDuringRetile: CGWindowID?
        orchestrator.tileAllVisibleSpaces = { frontDuringRetile = engine.accordionFrontOverride }

        orchestrator.switchWorkspace(hidden)

        XCTAssertEqual(frontDuringRetile, remembered.windowID,
                       "the retile that un-parks the stack already knows the focus target")
        XCTAssertNil(engine.accordionFrontOverride, "one-shot: cleared right after the retile")
        XCTAssertEqual(manager.workspaceForScreen(screen), hidden)
    }
}

// MARK: - doubles

private final class AccordionTestScreen: NSScreen {
    private let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    override init() { super.init() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var frame: NSRect { bounds }
    override var visibleFrame: NSRect { bounds }
    // detached test screen: AppKit traps on both of these on macOS 26
    override var localizedName: String { "accordion-test" }
    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: 910_000)]
    }
}

private final class AccordionTestWindow: HyprWindow {
    private var storedFrame: CGRect
    private let record: (String) -> Void
    init(id: CGWindowID, pid: pid_t = 9877, frame: CGRect, record: @escaping (String) -> Void) {
        storedFrame = frame
        self.record = record
        super.init(element: AXUIElementCreateApplication(pid), windowID: id, ownerPID: pid)
    }
    override var isFullscreen: Bool { false }
    override var isSizeSettable: Bool? { true }
    override func readPosition() -> (AXError, CGPoint?) { (.success, storedFrame.origin) }
    override func readSize() -> (AXError, CGSize?) { (.success, storedFrame.size) }
    override func writePosition(_ point: CGPoint) -> AXError { storedFrame.origin = point; return .success }
    override func writeSize(_ size: CGSize) -> AXError { storedFrame.size = size; return .success }
    override func setMessagingTimeout(_ timeout: TimeInterval) -> AXError { .success }
    override func raise() { record("raise:\(windowID)") }
    override func setFrame(_ rect: CGRect, crossMonitor: Bool = true) {
        storedFrame = rect
        record("frame:\(windowID)")
    }
    override func setPositionOnly(_ point: CGPoint) { storedFrame.origin = point }
    override func focus() { }
    override func focusWithoutRaise() { }
}
