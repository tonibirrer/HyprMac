import XCTest
import Cocoa
@testable import HyprMac

// LinkedMonitorsTests pin the linked-monitors partition math and the
// order-pinning path it drives. The multi-screen strip assembly itself
// needs real NSScreens and is covered manually — the load balancer
// (linkedChunkSizes) and the per-tree order enforcement (tileWindows
// order:) are the deterministic pieces, so they get the coverage.

final class LinkedMonitorsTests: XCTestCase {

    // MARK: - linkedChunkSizes: equal screens (the user's example)

    func testEqualScreensFillLeftFirstThenBalance() {
        let w: [CGFloat] = [100, 100]
        let caps = [8, 8]
        XCTAssertEqual(TilingEngine.linkedChunkSizes(count: 1, weights: w, capacities: caps), [1, 0])
        XCTAssertEqual(TilingEngine.linkedChunkSizes(count: 2, weights: w, capacities: caps), [1, 1])
        XCTAssertEqual(TilingEngine.linkedChunkSizes(count: 3, weights: w, capacities: caps), [2, 1])
        XCTAssertEqual(TilingEngine.linkedChunkSizes(count: 4, weights: w, capacities: caps), [2, 2])
        XCTAssertEqual(TilingEngine.linkedChunkSizes(count: 5, weights: w, capacities: caps), [3, 2])
    }

    // MARK: - unequal screens (ultrawide + 4:3)

    func testUnequalScreensBalanceByArea() {
        // 3440×1440 ultrawide vs 1920×1440 4:3 — weights ≈ 0.64 / 0.36
        let w: [CGFloat] = [3440 * 1440, 1920 * 1440]
        let caps = [8, 8]
        XCTAssertEqual(TilingEngine.linkedChunkSizes(count: 2, weights: w, capacities: caps), [1, 1])
        XCTAssertEqual(TilingEngine.linkedChunkSizes(count: 3, weights: w, capacities: caps), [2, 1])
        XCTAssertEqual(TilingEngine.linkedChunkSizes(count: 5, weights: w, capacities: caps), [3, 2])
        XCTAssertEqual(TilingEngine.linkedChunkSizes(count: 8, weights: w, capacities: caps), [5, 3])
    }

    // MARK: - guarantees

    func testSizesAlwaysSumToCount() {
        let w: [CGFloat] = [3440 * 1440, 1920 * 1440, 1440 * 2560]
        for count in 0...20 {
            let sizes = TilingEngine.linkedChunkSizes(count: count, weights: w, capacities: [8, 8, 8])
            XCTAssertEqual(sizes.reduce(0, +), count, "count \(count) → \(sizes)")
        }
    }

    func testNoScreenEmptyWhenEnoughWindows() {
        let w: [CGFloat] = [10_000, 100] // extreme imbalance
        let sizes = TilingEngine.linkedChunkSizes(count: 2, weights: w, capacities: [8, 8])
        XCTAssertEqual(sizes, [1, 1], "second screen must not sit empty while the first holds two")
    }

    func testLoneWindowStaysOnFirstScreen() {
        let sizes = TilingEngine.linkedChunkSizes(count: 1, weights: [100, 10_000], capacities: [8, 8])
        XCTAssertEqual(sizes, [1, 0])
    }

    func testCapacityCapsSpillToOtherScreen() {
        // first screen huge but shallow (maxDepth 1 → 2 leaves)
        let sizes = TilingEngine.linkedChunkSizes(count: 6, weights: [10_000, 100], capacities: [2, 8])
        XCTAssertEqual(sizes, [2, 4])
    }

    func testOverflowBeyondAllCapacitiesLandsOnLastScreen() {
        // 10 windows into 2+2 capacity — the tail lands on the last screen,
        // whose membership pass auto-floats what doesn't fit
        let sizes = TilingEngine.linkedChunkSizes(count: 10, weights: [100, 100], capacities: [2, 2])
        XCTAssertEqual(sizes[0], 2)
        XCTAssertEqual(sizes.reduce(0, +), 10)
    }

    func testZeroCountAndNoScreens() {
        XCTAssertEqual(TilingEngine.linkedChunkSizes(count: 0, weights: [1, 1], capacities: [8, 8]), [0, 0])
        XCTAssertEqual(TilingEngine.linkedChunkSizes(count: 3, weights: [], capacities: []), [])
    }

    // MARK: - order pinning (the mechanism tileLinked uses per chunk)

    private var displayManager: DisplayManager!
    private var engine: TilingEngine!
    private var screen: NSScreen!

    override func setUpWithError() throws {
        displayManager = DisplayManager()
        engine = TilingEngine(displayManager: displayManager)
        guard let main = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no NSScreen available — test requires a display")
        }
        screen = main
    }

    private func order() -> [CGWindowID] {
        engine.existingTree(forWorkspace: 1, screen: screen)?.allWindows.map(\.windowID) ?? []
    }

    func testExplicitOrderPinsStripSequence() {
        let ws = (1...4).map { makeWindow(id: CGWindowID($0)) }
        _ = engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen, order: [3, 1, 4, 2])
        XCTAssertEqual(order(), [3, 1, 4, 2])

        // membership pass with a new pinned order re-permutes in place
        _ = engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen, order: [1, 2, 3, 4])
        XCTAssertEqual(order(), [1, 2, 3, 4])
    }

    func testOrderIgnoresUnknownIDsAndKeepsUnlistedStable() {
        let ws = (1...3).map { makeWindow(id: CGWindowID($0)) }
        _ = engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen)
        XCTAssertEqual(order(), [1, 2, 3])

        // 99 isn't in the tree; 1 and 2 are unlisted and keep their
        // relative order after the listed window
        _ = engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen, order: [99, 3])
        XCTAssertEqual(order(), [3, 1, 2])
    }

    func testOrderPreservesSplitTopologyLeafCount() {
        let ws = (1...4).map { makeWindow(id: CGWindowID($0)) }
        let before = engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen)
        let after = engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen, order: [4, 3, 2, 1])
        XCTAssertEqual(order(), [4, 3, 2, 1])
        // same tile geometry, different occupants
        let sortRects = { (rects: [CGRect]) in
            rects.sorted { $0.minX != $1.minX ? $0.minX < $1.minX : $0.minY < $1.minY }
        }
        XCTAssertEqual(sortRects(before.map { $0.1 }), sortRects(after.map { $0.1 }))
    }
}
