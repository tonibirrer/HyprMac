import XCTest
import Cocoa
@testable import HyprMac

// TopPaddingTests pin the per-monitor top padding override: only the top
// edge moves, a monitor without an entry keeps outerPadding everywhere, and
// the engine's layout and its intended rects (what the drift monitor reads)
// agree on it. runs on a synthetic screen so it executes headless.

final class TopPaddingTests: XCTestCase {

    private let usable = CGRect(x: 0, y: 25, width: 2000, height: 1000)

    private func padded(_ rect: CGRect, outer: CGFloat) -> CGRect {
        rect.insetBy(dx: outer, dy: outer)
    }

    // MARK: - tilingRect

    func testNoOverrideKeepsTheUsableFrame() {
        XCTAssertEqual(TilingEngine.tilingRect(usable, outerPadding: 8, topPadding: nil), usable)
    }

    func testLargerOverrideMovesOnlyTheTopEdge() {
        let rect = TilingEngine.tilingRect(usable, outerPadding: 8, topPadding: 40)
        let inner = padded(rect, outer: 8)
        XCTAssertEqual(inner.minY, usable.minY + 40)
        XCTAssertEqual(inner.maxY, usable.maxY - 8)
        XCTAssertEqual(inner.minX, usable.minX + 8)
        XCTAssertEqual(inner.maxX, usable.maxX - 8)
    }

    func testSmallerOverrideMovesOnlyTheTopEdge() {
        let rect = TilingEngine.tilingRect(usable, outerPadding: 8, topPadding: 2)
        let inner = padded(rect, outer: 8)
        XCTAssertEqual(inner.minY, usable.minY + 2)
        XCTAssertEqual(inner.maxY, usable.maxY - 8)
        XCTAssertEqual(inner.width, usable.width - 16)
    }

    func testOverrideEqualToOuterPaddingChangesNothing() {
        XCTAssertEqual(TilingEngine.tilingRect(usable, outerPadding: 8, topPadding: 8), usable)
    }

    func testOutOfRangeOverrideIsClamped() {
        let negative = padded(TilingEngine.tilingRect(usable, outerPadding: 8, topPadding: -30), outer: 8)
        XCTAssertEqual(negative.minY, usable.minY)
        let huge = padded(TilingEngine.tilingRect(usable, outerPadding: 8, topPadding: 99_999), outer: 8)
        XCTAssertEqual(huge.minY, usable.minY + usable.height / 2)
        XCTAssertGreaterThan(huge.height, 0)
    }

    // MARK: - engine

    private func engineAndScreen(_ screen: NSScreen = TopPaddingTestScreen()) -> (TilingEngine, NSScreen) {
        let screens: [NSScreen] = [screen]
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { screens }),
                                  frameSizingIOFactory: acceptingFrameSizingIOFactory())
        engine.gapSize = 8
        engine.outerPadding = 8
        return (engine, screen)
    }

    func testVerifiedLayoutUsesTheOverrideForTheTopEdgeOnly() {
        let (engine, screen) = engineAndScreen()
        engine.topPaddingPerMonitor = [screen.localizedName: 40]
        let window = makeWindow(id: 1)

        XCTAssertTrue(engine.tileWindows([window], onWorkspace: 1, screen: screen).published)
        // intendedTileRects is what the drift monitor compares against
        XCTAssertEqual(engine.intendedTileRects()[window.windowID],
                       CGRect(x: 8, y: 40, width: 2384, height: 1552))

        // a live change below outerPadding retiles too, and still verifies
        engine.topPaddingPerMonitor = [screen.localizedName: 2]
        XCTAssertTrue(engine.tileWindows([window], onWorkspace: 1, screen: screen).published)
        XCTAssertEqual(engine.intendedTileRects()[window.windowID],
                       CGRect(x: 8, y: 2, width: 2384, height: 1590))
    }

    func testEngineWithoutAnOverrideKeepsOuterPadding() {
        let (engine, screen) = engineAndScreen()
        engine.topPaddingPerMonitor = ["Some other monitor": 40]
        let window = makeWindow(id: 1)

        XCTAssertTrue(engine.tileWindows([window], onWorkspace: 1, screen: screen).published)
        XCTAssertEqual(engine.intendedTileRects()[window.windowID],
                       CGRect(x: 8, y: 8, width: 2384, height: 1584))
    }

    // the live setup from 2026-10-25: a 3440x1440 external with the menu
    // bar hidden, outerPadding 8, top override 37. the bottom keeps its 8
    func testWideExternalSingleWindowKeepsTheBottomPadding() {
        let (engine, screen) = engineAndScreen(WideTestScreen())
        engine.topPaddingPerMonitor = [screen.localizedName: 37]
        let window = makeWindow(id: 1)

        XCTAssertTrue(engine.tileWindows([window], onWorkspace: 1, screen: screen).published)
        XCTAssertEqual(engine.intendedTileRects()[window.windowID],
                       CGRect(x: 8, y: 37, width: 3424, height: 1395))
    }

    func testWideExternalSplitKeepsTheBottomPadding() {
        let (engine, screen) = engineAndScreen(WideTestScreen())
        engine.topPaddingPerMonitor = [screen.localizedName: 37]
        let left = makeWindow(id: 1), right = makeWindow(id: 2)

        XCTAssertTrue(engine.tileWindows([left, right], onWorkspace: 1, screen: screen).published)
        let rects = engine.intendedTileRects()
        XCTAssertEqual(rects[left.windowID], CGRect(x: 8, y: 37, width: 1708, height: 1395))
        XCTAssertEqual(rects[right.windowID], CGRect(x: 1724, y: 37, width: 1708, height: 1395))
    }

    // raising the top padding moves the tiling rect below a window that
    // still stands at the old top. a refused candidate must roll it back
    // there instead of calling the original off-screen
    func testRefusedLayoutRollsBackAWindowAboveTheNewTopEdge() {
        let screen = TopPaddingTestScreen()
        let screens: [NSScreen] = [screen]
        var positions: [CGWindowID: CGPoint] = [:]
        let stuckSize = CGSize(width: 1200, height: 800)
        let engine = TilingEngine(displayManager: DisplayManager(screenSource: { screens }),
                                  frameSizingIOFactory: { _, generation in
            FrameSizingIO(
                setMessagingTimeout: { _, _ in .success },
                writeSize: { _, _, _ in .success },
                writePosition: { id, position, _ in positions[id] = position; return .success },
                readPosition: { id, _ in (.success, positions[id] ?? .zero) },
                readSize: { _, _ in (.success, stuckSize) },
                now: { 0 }, sleep: { _ in }, currentGeneration: generation)
        })
        engine.outerPadding = 8
        engine.topPaddingPerMonitor = [screen.localizedName: 40]
        let window = makeWindow(id: 7)
        let tree = BSPTree()
        tree.insert(window)
        let original = CGRect(origin: CGPoint(x: 8, y: 8), size: stuckSize)
        positions[window.windowID] = original.origin
        let rect = TilingEngine.tilingRect(engine.displayManager.cgRect(for: screen),
                                           outerPadding: 8, topPadding: 40)

        let outcome = engine.applyVerifiedLayout(tree, in: rect, generation: engine.beginLayoutGeneration(),
                                                 originalFrames: [window.windowID: original])

        guard case .rejectedRestored = outcome else {
            return XCTFail("expected the original to be restored, got \(outcome)")
        }
        XCTAssertEqual(positions[window.windowID], original.origin)
    }

    // MARK: - monitor-config

    func testMonitorConfigRoundTripsTopPadding() throws {
        let original = SavedMonitorConfig(maxSplitsPerMonitor: ["A": 4], disabledMonitors: [],
                                          topPaddingPerMonitor: ["A": 36, "Built-in": 4])
        let decoded = try JSONDecoder().decode(SavedMonitorConfig.self,
                                               from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.topPaddingPerMonitor, ["A": 36, "Built-in": 4])
        XCTAssertEqual(decoded.maxSplitsPerMonitor, ["A": 4])
    }

    // monitor-config.json is hand-editable now. one unreadable value must
    // cost only that field, or the next save writes the others away.
    func testUnreadableMonitorConfigValueCostsOnlyItsField() throws {
        let json = #"{"maxSplitsPerMonitor":{"A":2},"disabledMonitors":["B"],"topPaddingPerMonitor":{"A":"37"}}"#
        let decoded = try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.maxSplitsPerMonitor, ["A": 2])
        XCTAssertEqual(decoded.disabledMonitors, ["B"])
        XCTAssertNil(decoded.topPaddingPerMonitor)

        let badSplits = #"{"maxSplitsPerMonitor":{"A":null},"topPaddingPerMonitor":{"A":37}}"#
        let other = try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(badSplits.utf8))
        XCTAssertNil(other.maxSplitsPerMonitor)
        XCTAssertEqual(other.topPaddingPerMonitor, ["A": 37])
    }

    func testMonitorConfigWithoutTopPaddingLoadsUnchanged() throws {
        let json = #"{"maxSplitsPerMonitor":{"A":2},"disabledMonitors":["B"]}"#
        let decoded = try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(json.utf8))
        XCTAssertNil(decoded.topPaddingPerMonitor)
        XCTAssertEqual(decoded.maxSplitsPerMonitor, ["A": 2])
        XCTAssertEqual(decoded.disabledMonitors, ["B"])
    }
}

private final class TopPaddingTestScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 2400, height: 1600) }
    override var visibleFrame: NSRect { frame }
}

private final class WideTestScreen: SyntheticScreen {
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 3440, height: 1440) }
    override var visibleFrame: NSRect { frame }
}
