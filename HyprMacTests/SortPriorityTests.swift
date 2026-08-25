import XCTest
import Cocoa
@testable import HyprMac

// SortPriorityTests pin the per-app tile sort priority (Hyprland-style
// window rule): higher priority tiles further top-left (earlier in the
// in-order traversal), lower further bottom-right. Enforcement happens
// in updateTreeMembership, so prepareTileLayout is the test surface —
// same trick as PrepareLayoutMutationTests.

final class SortPriorityTests: XCTestCase {

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

    private func tree() -> BSPTree? {
        engine.existingTree(forWorkspace: 1, screen: screen)
    }

    private func order() -> [CGWindowID] {
        tree()?.allWindows.map(\.windowID) ?? []
    }

    /// Priority resolver keyed by windowID.
    private func setPriorities(_ map: [CGWindowID: Int]) {
        engine.sortPriority = { map[$0.windowID] ?? 0 }
    }

    // MARK: - model

    func testSortPriorityDecodesToZeroWhenAbsent() throws {
        let json = #"{"bundleID": "md.obsidian", "workspace": 5}"#.data(using: .utf8)!
        let rule = try JSONDecoder().decode(WindowRule.self, from: json)
        XCTAssertEqual(rule.sortPriority, 0)
    }

    func testSortPriorityRoundTrips() throws {
        let original = [WindowRule(bundleID: "com.mattermost.desktop", workspace: 0, sortPriority: -3)]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([WindowRule].self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testPriorityOnlyRuleDoesNotPinButContributesPriority() {
        let rules = [WindowRule(bundleID: "com.mattermost.desktop", workspace: 0, sortPriority: -3)]
        XCTAssertNil(rules.firstMatch(bundleID: "com.mattermost.desktop"))
        XCTAssertEqual(rules.sortPriority(bundleID: "com.mattermost.desktop"), -3)
        XCTAssertEqual(rules.sortPriority(bundleID: "app.zen-browser.zen"), 0)
        XCTAssertEqual(rules.sortPriority(bundleID: nil), 0)
    }

    func testPinnedRuleContributesPriorityToo() {
        let rules = [WindowRule(bundleID: "a.b.c", workspace: 3, sortPriority: 5)]
        XCTAssertEqual(rules.firstMatch(bundleID: "a.b.c")?.workspace, 3)
        XCTAssertEqual(rules.sortPriority(bundleID: "a.b.c"), 5)
    }

    // MARK: - batch insert ordering

    func testBatchInsertOrdersByPriorityDescending() {
        // id 2 is low priority — must land bottom-right despite its id
        setPriorities([2: -5])
        let ws = (1...3).map { makeWindow(id: CGWindowID($0)) }
        engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen)
        XCTAssertEqual(order(), [1, 3, 2])
    }

    func testBatchInsertHighPriorityLandsTopLeft() {
        setPriorities([3: 5])
        let ws = (1...3).map { makeWindow(id: CGWindowID($0)) }
        engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen)
        XCTAssertEqual(order(), [3, 1, 2])
    }

    // MARK: - late-insert reorder (the "mattermost stays rightmost" case)

    func testLowPriorityWindowStaysRightmostWhenOthersOpenLater() {
        setPriorities([1: -5])
        let mattermost = makeWindow(id: 1)
        engine.prepareTileLayout([mattermost], onWorkspace: 1, screen: screen)

        // a new window opens later — dwindle would put it at the spiral
        // tip (right of mattermost); the priority reorder must flip that
        let zen = makeWindow(id: 2)
        engine.prepareTileLayout([mattermost, zen], onWorkspace: 1, screen: screen)
        XCTAssertEqual(order(), [2, 1])

        // and again with a third window
        let ghostty = makeWindow(id: 3)
        engine.prepareTileLayout([mattermost, zen, ghostty], onWorkspace: 1, screen: screen)
        XCTAssertEqual(order().last, 1)
    }

    func testHighPriorityWindowTakesTopLeftWhenOpenedLast() {
        setPriorities([3: 9])
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        engine.prepareTileLayout([w1, w2], onWorkspace: 1, screen: screen)
        XCTAssertEqual(order(), [1, 2])

        let w3 = makeWindow(id: 3)
        engine.prepareTileLayout([w1, w2, w3], onWorkspace: 1, screen: screen)
        XCTAssertEqual(order(), [3, 1, 2])
    }

    // MARK: - stability

    func testEqualPrioritiesKeepInsertionOrder() {
        setPriorities([:])
        let ws = (1...4).map { makeWindow(id: CGWindowID($0)) }
        engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen)
        XCTAssertEqual(order(), [1, 2, 3, 4])
    }

    func testManualSwapBetweenNeutralWindowsSurvivesRetile() {
        setPriorities([3: -5])
        let ws = (1...3).map { makeWindow(id: CGWindowID($0)) }
        engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen)
        XCTAssertEqual(order(), [1, 2, 3])

        // user swaps the two neutral windows — a later membership pass
        // must not undo it (stable sort touches only ruled windows)
        tree()?.swap(ws[0], ws[1])
        XCTAssertEqual(order(), [2, 1, 3])
        engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen)
        XCTAssertEqual(order(), [2, 1, 3])
    }

    func testReorderPreservesTopologyAndRatios() {
        setPriorities([1: -5])
        let ws = (1...3).map { makeWindow(id: CGWindowID($0)) }
        engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen)
        XCTAssertEqual(order(), [2, 3, 1])

        // same leaf count, every window still laid out exactly once
        let layout = engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen)
        XCTAssertEqual(layout.count, 3)
        XCTAssertEqual(Set(layout.map { $0.0.windowID }), [1, 2, 3])
    }

    // MARK: - assignWindows(inOrder:)

    func testAssignWindowsCountMismatchIsNoOp() {
        let t = BSPTree()
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        t.insert(w1, maxDepth: 5)
        t.insert(w2, maxDepth: 5)
        t.assignWindows(inOrder: [w2])
        XCTAssertEqual(t.allWindows.map(\.windowID), [1, 2])
    }

    func testAssignWindowsPermutesReferencesOnly() {
        let t = BSPTree()
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        for w in [w1, w2, w3] { t.insert(w, maxDepth: 5) }
        t.assignWindows(inOrder: [w3, w1, w2])
        XCTAssertEqual(t.allWindows.map(\.windowID), [3, 1, 2])
    }
}
