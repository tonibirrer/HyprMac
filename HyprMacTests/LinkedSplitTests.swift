import XCTest
@testable import HyprMac

// Linked monitors: a tile moved across the border keeps its screen, and the
// split it leaves holds through later passes (TilingEngine+LinkedSplit).

final class LinkedSplitTests: XCTestCase {
    private var frames: [CGWindowID: CGRect] = [:]
    private var clock: TimeInterval = 0
    private var left: LinkedSplitScreen!
    private var right: LinkedSplitScreen!
    private var engine: TilingEngine!
    private var windows: [LinkedSplitWindow] = []

    override func setUp() {
        left = LinkedSplitScreen(x: 0, name: "left-split")
        right = LinkedSplitScreen(x: 1600, name: "right-split")
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
        windows = (1...4).map { LinkedSplitWindow(id: CGWindowID(700 + $0)) }
        for (i, w) in windows.enumerated() {
            frames[w.windowID] = CGRect(x: 20 + CGFloat(i) * 10, y: 20, width: 300, height: 300)
        }
    }

    private var screens: [NSScreen] { [left, right] }

    private func onScreens() -> [[CGWindowID]] {
        screens.map { engine.windowIDs(inTreeForWorkspace: 3, screen: $0) }
    }

    private func id(_ n: Int) -> CGWindowID { windows[n - 1].windowID }

    // MARK: - moves

    func testATileMovedLeftJoinsTheLeftScreenAtTheBorder() {
        engine.tileLinked(windows, onWorkspace: 3, screens: screens)
        XCTAssertEqual(onScreens(), [[id(1), id(2)], [id(3), id(4)]], "the area split of two equal screens")

        XCTAssertEqual(engine.moveAcrossLinkedScreens(id(4), onWorkspace: 3, to: 0, screens: screens),
                       .moved(from: 1, to: 0))
        engine.tileLinked(windows, onWorkspace: 3, screens: screens)

        XCTAssertEqual(onScreens(), [[id(1), id(2), id(4)], [id(3)]],
                       "the left screen grows, the right one shrinks; nothing else changes screen")
    }

    func testATileMovedRightJoinsTheRightScreenAtTheBorder() {
        engine.tileLinked(windows, onWorkspace: 3, screens: screens)

        XCTAssertEqual(engine.moveAcrossLinkedScreens(id(1), onWorkspace: 3, to: 1, screens: screens),
                       .moved(from: 0, to: 1))
        engine.tileLinked(windows, onWorkspace: 3, screens: screens)

        XCTAssertEqual(onScreens(), [[id(2)], [id(1), id(3), id(4)]])
    }

    func testTheSplitHoldsThroughLaterPasses() {
        engine.tileLinked(windows, onWorkspace: 3, screens: screens)
        _ = engine.moveAcrossLinkedScreens(id(3), onWorkspace: 3, to: 0, screens: screens)
        engine.tileLinked(windows, onWorkspace: 3, screens: screens)
        engine.tileLinked(windows, onWorkspace: 3, screens: screens)

        XCTAssertEqual(onScreens(), [[id(1), id(2), id(3)], [id(4)]], "not re-balanced by area")
    }

    func testTheLastTileCanLeaveAScreenEmpty() {
        let two = Array(windows.prefix(2))
        engine.tileLinked(two, onWorkspace: 3, screens: screens)
        XCTAssertEqual(onScreens(), [[id(1)], [id(2)]])

        _ = engine.moveAcrossLinkedScreens(id(2), onWorkspace: 3, to: 0, screens: screens)
        engine.tileLinked(two, onWorkspace: 3, screens: screens)

        XCTAssertEqual(onScreens(), [[id(1), id(2)], []])
    }

    func testANewWindowJoinsTheScreenOfTheTileBeforeIt() {
        let three = Array(windows.prefix(3))
        engine.tileLinked(three, onWorkspace: 3, screens: screens)
        XCTAssertEqual(onScreens(), [[id(1), id(2)], [id(3)]], "the area split of three on two equal screens")
        _ = engine.moveAcrossLinkedScreens(id(2), onWorkspace: 3, to: 1, screens: screens)
        engine.tileLinked(three, onWorkspace: 3, screens: screens)
        XCTAssertEqual(onScreens(), [[id(1)], [id(2), id(3)]])

        engine.tileLinked(windows, onWorkspace: 3, screens: screens)

        XCTAssertEqual(onScreens(), [[id(1)], [id(2), id(3), id(4)]],
                       "appended at the strip's right end, on the screen of the tile before it")
    }

    func testAClosedTileLeavesTheOtherTilesWhereTheyAre() {
        engine.tileLinked(windows, onWorkspace: 3, screens: screens)
        _ = engine.moveAcrossLinkedScreens(id(3), onWorkspace: 3, to: 0, screens: screens)
        engine.tileLinked(windows, onWorkspace: 3, screens: screens)

        engine.removeWindowID(id(1))
        engine.tileLinked(Array(windows.dropFirst()), onWorkspace: 3, screens: screens)

        XCTAssertEqual(onScreens(), [[id(2), id(3)], [id(4)]])
    }

    func testRefusals() {
        engine.tileLinked(windows, onWorkspace: 3, screens: screens)

        XCTAssertEqual(engine.moveAcrossLinkedScreens(id(1), onWorkspace: 3, to: -1, screens: screens), .noScreen)
        XCTAssertEqual(engine.moveAcrossLinkedScreens(id(4), onWorkspace: 3, to: 2, screens: screens), .noScreen)
        XCTAssertEqual(engine.moveAcrossLinkedScreens(999, onWorkspace: 3, to: 0, screens: screens), .notTiled)
        XCTAssertNil(engine.linkedSplit(onWorkspace: 3, screens: screens), "a refusal records no split")
    }

    func testAFullScreenRefusesTheMove() {
        engine.maxSplitsPerMonitor = [left.localizedName: 1]   // two tiles on the left screen
        engine.tileLinked(windows, onWorkspace: 3, screens: screens)
        XCTAssertEqual(onScreens(), [[id(1), id(2)], [id(3), id(4)]])

        XCTAssertEqual(engine.moveAcrossLinkedScreens(id(3), onWorkspace: 3, to: 0, screens: screens),
                       .full(capacity: 2))
    }

    func testClearingGoesBackToTheAreaSplit() {
        engine.tileLinked(windows, onWorkspace: 3, screens: screens)
        _ = engine.moveAcrossLinkedScreens(id(4), onWorkspace: 3, to: 0, screens: screens)
        engine.tileLinked(windows, onWorkspace: 3, screens: screens)

        engine.clearLinkedSplits()
        engine.tileLinked(windows, onWorkspace: 3, screens: screens)

        XCTAssertEqual(onScreens().map(\.count), [2, 2])
    }

    func testASplitForOtherScreensDoesNotApply() {
        engine.tileLinked(windows, onWorkspace: 3, screens: screens)
        _ = engine.moveAcrossLinkedScreens(id(4), onWorkspace: 3, to: 0, screens: screens)

        XCTAssertNotNil(engine.linkedSplit(onWorkspace: 3, screens: screens))
        XCTAssertNil(engine.linkedSplit(onWorkspace: 3, screens: [right, left]))
        XCTAssertNil(engine.linkedSplit(onWorkspace: 4, screens: screens))
    }

    func testADragsSplitIsPinnedFromTheTrees() {
        engine.tileLinked(windows, onWorkspace: 3, screens: screens)
        engine.pinLinkedSplit(onWorkspace: 3, screens: screens)

        XCTAssertEqual(engine.linkedSplit(onWorkspace: 3, screens: screens)?.screenOf,
                       [id(1): 0, id(2): 0, id(3): 1, id(4): 1])
    }

    // MARK: - pure helpers

    func testAssignmentInheritsThePreviousScreen() {
        XCTAssertEqual(TilingEngine.linkedAssignment(strip: [1, 2, 3, 4], screenOf: [2: 1], screenCount: 2),
                       [0, 1, 1, 1], "unknown at the front is the first screen, later ones follow the tile before")
        XCTAssertEqual(TilingEngine.linkedAssignment(strip: [1, 2], screenOf: [1: 5, 2: -3], screenCount: 2),
                       [1, 0], "clamped to the screens there are")
    }

    func testCutGroupsScreensAndOrdersPrioritiesWithinThem() {
        let cut = TilingEngine.linkedCut(strip: [1, 2, 3, 4], assignment: [1, 0, 1, 0],
                                         priorities: [0, 0, 5, 0], screenCount: 3)
        XCTAssertEqual(cut.strip, [2, 4, 3, 1], "screen 0's tiles first; on screen 1 the higher priority leads")
        XCTAssertEqual(cut.sizes, [2, 2, 0])
        XCTAssertEqual(cut.screenOf, [1: 1, 2: 0, 3: 1, 4: 0])
    }
}

// MARK: - doubles

private final class LinkedSplitScreen: SyntheticScreen {
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
    override var localizedName: String { name }
}

private final class LinkedSplitWindow: HyprWindow {
    init(id: CGWindowID) {
        super.init(element: AXUIElementCreateApplication(9878), windowID: id, ownerPID: 9878)
    }
    override var isFullscreen: Bool { false }
    override var isSizeSettable: Bool? { true }
    override func raise() { }
    override func focus() { }
    override func focusWithoutRaise() { }
}
