import XCTest
import Cocoa
@testable import HyprMac

// FullHeightTests pin the per-app full-height column rule: a ruled
// window's tile always spans the full tiled height. Enforcement is the
// column lock (BSPNode.forcedColumn) recomputed by BSPTree.applyFullHeight
// on every mapping change plus the full-height-aware insert direction, so
// prepareTileLayout is the test surface — same trick as SortPriorityTests.
// Assertions compare tile heights against the tallest tile rather than
// absolute pixels so they hold on any test display.

final class FullHeightTests: XCTestCase {

    private var displayManager: DisplayManager!
    private var engine: TilingEngine!
    private var screen: NSScreen!

    override func setUpWithError() throws {
        displayManager = DisplayManager()
        engine = TilingEngine(displayManager: displayManager)
        // the baseline these tests lean on — dwindle stacks the second and
        // third window in the right half — only holds when half the usable
        // width is shorter than the height (aspect below 2:1). an ultrawide
        // main display splits into three columns on its own, which would
        // mask the rule. prefer the main screen, else any qualifying one.
        let dm = displayManager!
        let qualifying = NSScreen.screens.filter { s in
            let r = dm.cgRect(for: s)
            return r.width >= r.height && r.width / 2 < r.height
        }
        guard let pick = qualifying.first(where: { $0 == NSScreen.main }) ?? qualifying.first else {
            throw XCTSkip("no display with aspect between 1:1 and 2:1 — dwindle baseline would not stack")
        }
        screen = pick
    }

    private func setFullHeight(_ ids: Set<CGWindowID>) {
        engine.fullHeight = { ids.contains($0.windowID) }
    }

    private func setPriorities(_ map: [CGWindowID: Int]) {
        engine.sortPriority = { map[$0.windowID] ?? 0 }
    }

    private func heights(_ layout: [(HyprWindow, CGRect)]) -> [CGWindowID: CGFloat] {
        Dictionary(uniqueKeysWithValues: layout.map { ($0.0.windowID, $0.1.height) })
    }

    private func assertFullHeight(_ ids: [CGWindowID], in layout: [(HyprWindow, CGRect)],
                                  file: StaticString = #filePath, line: UInt = #line) {
        let h = heights(layout)
        let tallest = h.values.max() ?? 0
        for id in ids {
            XCTAssertEqual(h[id] ?? 0, tallest, accuracy: 1,
                           "window \(id) should span the full height", file: file, line: line)
        }
    }

    private func assertNotFullHeight(_ ids: [CGWindowID], in layout: [(HyprWindow, CGRect)],
                                     file: StaticString = #filePath, line: UInt = #line) {
        let h = heights(layout)
        let tallest = h.values.max() ?? 0
        for id in ids {
            XCTAssertLessThan(h[id] ?? 0, tallest - 1,
                              "window \(id) should be stacked", file: file, line: line)
        }
    }

    // MARK: - model

    func testFullHeightDecodesFalseWhenAbsentAndRoundTrips() throws {
        let json = #"{"bundleID": "app.zen-browser.zen", "workspace": 0}"#.data(using: .utf8)!
        XCTAssertFalse(try JSONDecoder().decode(WindowRule.self, from: json).fullHeight)

        let original = [WindowRule(bundleID: "Mattermost.Desktop", workspace: 0, fullHeight: true)]
        let decoded = try JSONDecoder().decode([WindowRule].self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded[0].fullHeight)
    }

    func testIsFullHeightHelper() {
        let rules = [WindowRule(bundleID: "app.zen-browser.zen", workspace: 0, fullHeight: true)]
        XCTAssertTrue(rules.isFullHeight(bundleID: "app.zen-browser.zen"))
        XCTAssertFalse(rules.isFullHeight(bundleID: "com.apple.finder"))
        XCTAssertFalse(rules.isFullHeight(bundleID: nil))
    }

    // MARK: - baseline: dwindle stacks the right half

    func testDwindleStacksWithoutRule() {
        let ws = (1...3).map { makeWindow(id: CGWindowID($0)) }
        let layout = engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen)
        assertFullHeight([1], in: layout)
        assertNotFullHeight([2, 3], in: layout)
    }

    // MARK: - enforcement

    func testStackedFullHeightWindowIsUnlockedIntoColumn() {
        // dwindle would put 2 in the top half of the right side
        setFullHeight([2])
        let ws = (1...3).map { makeWindow(id: CGWindowID($0)) }
        let layout = engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen)
        assertFullHeight([1, 2, 3], in: layout)
    }

    func testLateWindowsOpenBesideFullHeightColumnsThenStackAmongThemselves() {
        // the user's setup: zen and mattermost lead by priority and are
        // both full height; terminals open later
        setFullHeight([1, 2])
        setPriorities([1: 10, 2: 9])
        let zen = makeWindow(id: 1), mm = makeWindow(id: 2)
        engine.prepareTileLayout([zen, mm], onWorkspace: 1, screen: screen)

        let t1 = makeWindow(id: 3)
        var layout = engine.prepareTileLayout([zen, mm, t1], onWorkspace: 1, screen: screen)
        assertFullHeight([1, 2, 3], in: layout)

        let t2 = makeWindow(id: 4)
        layout = engine.prepareTileLayout([zen, mm, t1, t2], onWorkspace: 1, screen: screen)
        assertFullHeight([1, 2], in: layout)
        assertNotFullHeight([3, 4], in: layout)
        XCTAssertEqual(engine.existingTree(forWorkspace: 1, screen: screen)?.allWindows.map(\.windowID), [1, 2, 3, 4])
    }

    func testFullHeightNewcomerPrefersColumnSlotOverStack() {
        // 1 | (2 / 3) — a full-height 4 must not force the 2/3 stack open
        let ws = (1...3).map { makeWindow(id: CGWindowID($0)) }
        engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen)
        setFullHeight([4])
        let layout = engine.prepareTileLayout(ws + [makeWindow(id: 4)], onWorkspace: 1, screen: screen)
        assertFullHeight([1, 4], in: layout)
        assertNotFullHeight([2, 3], in: layout)
    }

    func testRemovingFullHeightWindowReleasesColumnLock() {
        setFullHeight([2])
        let ws = (1...3).map { makeWindow(id: CGWindowID($0)) }
        engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen)

        // 2 closes: 1 | 3, and the next window may stack under 3 again
        engine.prepareTileLayout([ws[0], ws[2]], onWorkspace: 1, screen: screen)
        let layout = engine.prepareTileLayout([ws[0], ws[2], makeWindow(id: 4)], onWorkspace: 1, screen: screen)
        assertFullHeight([1], in: layout)
        assertNotFullHeight([3, 4], in: layout)
    }

    func testRuleEditAppliesOnNextLayoutWithoutMembershipChange() {
        let ws = (1...3).map { makeWindow(id: CGWindowID($0)) }
        var layout = engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen)
        assertNotFullHeight([2, 3], in: layout)

        setFullHeight([3])
        layout = engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen)
        assertFullHeight([1, 2, 3], in: layout)
    }

    func testToggleSplitAboveFullHeightWindowIsNoOp() {
        setFullHeight([2])
        let ws = (1...3).map { makeWindow(id: CGWindowID($0)) }
        engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen)
        guard let layout = engine.prepareToggleSplitLayout(ws[2], onWorkspace: 1, screen: screen) else {
            return XCTFail("window 3 should be in the tree")
        }
        assertFullHeight([1, 2, 3], in: layout)
    }

    func testSwapKeepsLockOnTheWindowNotTheSlot() {
        // 1 | (2 / 3) with 3 full height → 1 | (2 | 3); swapping 1 and 3
        // moves the lock: 3 takes the left column, 1 | 2 may stack again
        setFullHeight([3])
        let ws = (1...3).map { makeWindow(id: CGWindowID($0)) }
        engine.prepareTileLayout(ws, onWorkspace: 1, screen: screen)
        guard let tree = engine.existingTree(forWorkspace: 1, screen: screen) else { return XCTFail("no tree") }
        tree.swap(ws[0], ws[2])
        tree.root.resetSplitRatios()
        let layout = tree.layout(in: displayManager.cgRect(for: screen), gap: engine.gapSize, padding: engine.outerPadding)
        assertFullHeight([3], in: layout)
        assertNotFullHeight([1, 2], in: layout)
    }
}
