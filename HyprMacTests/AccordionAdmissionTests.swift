import XCTest
import Cocoa
@testable import HyprMac

// AccordionAdmissionTests pin how a workspace on an accordion screen admits
// windows. Every accordion member gets the same near-fullscreen frame, so
// admission judges that frame and not the BSP slot the window would get in
// tile mode. The bug these guard against: after unplugging the desk
// monitors, the laptop screen refused every Ghostty window past the fourth
// (a learned 1304 px minimum cannot fit half of a 1512 px screen). Refused
// incumbents stayed parked off-screen, refused newcomers floated over the
// stack, and the accordion navigation could reach neither.

final class AccordionAdmissionTests: XCTestCase {

    private var screen: LaptopScreen!
    private var engine: TilingEngine!
    private var accordion = true

    override func setUp() {
        screen = LaptopScreen()
        engine = TilingEngine(displayManager: DisplayManager(screenSource: { [self.screen] }))
        accordion = true
        engine.accordionActive = { [unowned self] _ in self.accordion }
        engine.accordionOverlap = 0
    }

    /// A Ghostty-like window: wider minimum than any half of the screen.
    private func wideWindow(_ id: CGWindowID) -> AdmissionTestWindow {
        let w = AdmissionTestWindow(id: id)
        w.observedMinSize = CGSize(width: 1304, height: 500)
        return w
    }

    private func treeCount() -> Int {
        engine.windowIDs(inTreeForWorkspace: 2, screen: screen).count
    }

    func testAccordionAdmitsWindowsTheTileSlotsCannotHold() {
        let windows = (1...8).map { wideWindow(CGWindowID(500 + $0)) }

        engine.tileWindows(windows, onWorkspace: 2, screen: screen)

        XCTAssertEqual(treeCount(), 8, "every window fits the shared accordion frame")
    }

    func testTileModeStillRefusesThem() {
        accordion = false
        let windows = (1...3).map { wideWindow(CGWindowID(500 + $0)) }

        _ = engine.prepareTileLayout(windows, onWorkspace: 2, screen: screen)

        XCTAssertEqual(treeCount(), 1, "outside accordion the slot geometry still decides")
    }

    func testAMinimumWiderThanTheAccordionFrameIsStillRefused() {
        let normal = wideWindow(601)
        let huge = AdmissionTestWindow(id: 602)
        huge.observedMinSize = CGSize(width: 2000, height: 500)

        engine.tileWindows([normal, huge], onWorkspace: 2, screen: screen)

        XCTAssertEqual(engine.windowIDs(inTreeForWorkspace: 2, screen: screen), [601])
    }

    func testPeekStripsShrinkTheFrameAWindowMustFit() {
        // inner width 1512 - 16 padding = 1496; two 100 px strips leave 1296
        engine.accordionOverlap = 100
        let windows = (1...3).map { wideWindow(CGWindowID(700 + $0)) }

        engine.tileWindows(windows, onWorkspace: 2, screen: screen)

        XCTAssertEqual(treeCount(), 1, "1304 px cannot fit the middle slot between two strips")
    }

    func testDepthFollowsTheAccordion() {
        engine.maxSplitsPerMonitor = [screen.localizedName: 2]

        XCTAssertEqual(engine.maxDepth(for: screen), TilingConfig.accordionMaxDepth)
        XCTAssertEqual(engine.configuredMaxDepth(for: screen), 2)
        accordion = false
        XCTAssertEqual(engine.maxDepth(for: screen), 2)
    }

    func testMoreWindowsThanTheConfiguredDepthAllows() {
        engine.maxSplitsPerMonitor = [screen.localizedName: 1]
        let windows = (1...6).map { AdmissionTestWindow(id: CGWindowID(800 + $0)) }

        engine.tileWindows(windows, onWorkspace: 2, screen: screen)

        XCTAssertEqual(treeCount(), 6)
    }

    func testToggleToTileJoinsAFullAccordionStack() {
        let tiled = (1...5).map { wideWindow(CGWindowID(900 + $0)) }
        engine.tileWindows(tiled, onWorkspace: 2, screen: screen)
        let floater = wideWindow(906)

        let result = engine.forceInsertWindow(floater, toWorkspace: 2, on: screen)

        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(treeCount(), 6)
    }

    func testDisplayChangeMergesIntoAnAccordionScreen() throws {
        // the desk trees collide on the laptop's key; tile mode refused the
        // second window there (FitAwareDisplayMigrationTests), accordion takes it
        let left = DeskScreen(x: 0)
        let right = DeskScreen(x: 2000)
        let laptop = DeskScreen(x: 4000)
        let display = DisplayManager(screenSource: { [left, right, laptop] })
        let engine = TilingEngine(displayManager: display)
        engine.accordionActive = { $0 === laptop }
        let first = makeWindow(id: 971)
        let second = makeWindow(id: 972)
        first.observedMinSize = CGSize(width: 1000, height: 500)
        second.observedMinSize = CGSize(width: 1000, height: 500)
        engine.prepareTileLayout([first], onWorkspace: 1, screen: left)
        engine.prepareTileLayout([second], onWorkspace: 1, screen: right)

        engine.handleDisplayChange(currentScreens: [laptop],
                                   homeScreensForWorkspace: { _ in [laptop] })

        let merged = try XCTUnwrap(engine.existingTree(forWorkspace: 1, screen: laptop))
        XCTAssertEqual(Set(merged.allWindows.map(\.windowID)), [971, 972])
    }

    func testSmallestFrameSizeSubtractsPaddingAndBothStrips() {
        let rect = CGRect(x: 0, y: 32, width: 1512, height: 950)
        let padding = OuterPadding(uniform: 8)

        XCTAssertEqual(AccordionLayout.smallestFrameSize(in: rect, padding: padding, overlap: 0),
                       CGSize(width: 1496, height: 934))
        XCTAssertEqual(AccordionLayout.smallestFrameSize(in: rect, padding: padding, overlap: 25),
                       CGSize(width: 1446, height: 934))
        // the strips clamp to a quarter of the width per side
        XCTAssertEqual(AccordionLayout.smallestFrameSize(in: rect, padding: padding, overlap: 5000),
                       CGSize(width: 748, height: 934))
    }
}

// MARK: - doubles

/// The built-in screen of a 14" MacBook Pro at default scaling.
private final class LaptopScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1512, height: 982) }
    override var visibleFrame: NSRect { NSRect(x: 0, y: 0, width: 1512, height: 950) }
}

private final class DeskScreen: SyntheticScreen {
    let bounds: NSRect
    init(x: CGFloat) {
        bounds = NSRect(x: x, y: 0, width: 1400, height: 900)
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var frame: NSRect { bounds }
    override var visibleFrame: NSRect { bounds }
}

/// Answers AX reads and writes from memory so the accordion apply path runs
/// without a real window behind it.
private final class AdmissionTestWindow: HyprWindow {
    private var storedFrame = CGRect(x: 0, y: 0, width: 600, height: 400)
    init(id: CGWindowID) {
        super.init(element: AXUIElementCreateApplication(9878), windowID: id, ownerPID: 9878)
    }
    override var isFullscreen: Bool { false }
    override var isSizeSettable: Bool? { true }
    override func readPosition() -> (AXError, CGPoint?) { (.success, storedFrame.origin) }
    override func readSize() -> (AXError, CGSize?) { (.success, storedFrame.size) }
    override func writePosition(_ point: CGPoint) -> AXError { storedFrame.origin = point; return .success }
    override func writeSize(_ size: CGSize) -> AXError { storedFrame.size = size; return .success }
    override func setMessagingTimeout(_ timeout: TimeInterval) -> AXError { .success }
    override func raise() { }
    override func setFrame(_ rect: CGRect, crossMonitor: Bool = true) { storedFrame = rect }
    override func setPositionOnly(_ point: CGPoint) -> AXError { storedFrame.origin = point; return .success }
    override func focus() { }
    override func focusWithoutRaise() { }
}
