import XCTest
@testable import HyprMac

// timing for the main-thread layout paths on a big synthetic workload:
// 10 workspaces x 30 windows, 10 stored snapshots. the numbers land in
// the test log as measure{} averages; nothing here asserts a budget.

final class LayoutPersistencePerformanceTests: XCTestCase {

    private static let workspaces = 10
    private static let perWorkspace = 30

    // 10 apps, so every leaf competes with 29 other windows of its app;
    // every fifth window has no title and only matches by app
    private static func ref(_ n: Int) -> SavedWindowRef {
        SavedWindowRef(bundleID: "com.perf.app\(n % 10)", title: n % 5 == 0 ? "" : "Document \(n)")
    }

    private static func tree(_ ids: ArraySlice<Int>) -> LayoutNode {
        if ids.count == 1 { return .leaf(ref(ids.first!)) }
        let mid = ids.startIndex + ids.count / 2
        return .split(override: nil, ratio: 0.5, userSet: false,
                      left: tree(ids[ids.startIndex..<mid]), right: tree(ids[mid..<ids.endIndex]))
    }

    private static var layouts: [WorkspaceLayout] {
        (1...workspaces).map { ws in
            let ids = Array((ws - 1) * perWorkspace..<ws * perWorkspace)
            return WorkspaceLayout(workspace: ws, root: tree(ids[...]))
        }
    }

    private static func snapshot(_ key: String) -> LayoutSnapshot {
        LayoutSnapshot(schemaVersion: LayoutSnapshot.currentSchemaVersion, displayKey: key,
                       timestamp: Date(), isManual: true, workspaces: layouts)
    }

    // every window open, shuffled onto the wrong workspace
    private static var candidates: [LayoutMatcher.Candidate] {
        (0..<workspaces * perWorkspace).map { n in
            let r = ref(n)
            return LayoutMatcher.Candidate(windowID: CGWindowID(1000 + n), bundleID: r.bundleID,
                                           title: r.title, workspace: (n * 7) % workspaces + 1)
        }
    }

    private var fileURL: URL!

    override func setUp() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-perf-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testMatcherPlanTiming() {
        let snapshot = Self.snapshot("perf")
        let candidates = Self.candidates
        var plan = LayoutMatcher.Plan()
        measure { plan = LayoutMatcher.plan(snapshot, candidates: candidates) }
        XCTAssertEqual(plan.workspaceByWindow.count, Self.workspaces * Self.perWorkspace)
    }

    func testStoreSaveTiming() throws {
        let store = LayoutSnapshotStore(fileURL: fileURL)
        for i in 0..<LayoutSnapshotStore.maxSnapshots - 1 {
            try store.save(displayKey: "display-\(i)", workspaces: Self.layouts, manual: true)
        }
        // one more save rewrites the full ten-snapshot file each time
        measure { _ = try? store.save(displayKey: "display-last", workspaces: Self.layouts, manual: true) }
        XCTAssertEqual(store.snapshots.count, LayoutSnapshotStore.maxSnapshots)
    }

    func testStoreLoadTiming() throws {
        let store = LayoutSnapshotStore(fileURL: fileURL)
        for i in 0..<LayoutSnapshotStore.maxSnapshots {
            try store.save(displayKey: "display-\(i)", workspaces: Self.layouts, manual: true)
        }
        let url = fileURL!
        var loaded = 0
        measure { loaded = LayoutSnapshotStore(fileURL: url).snapshots.count }
        XCTAssertEqual(loaded, LayoutSnapshotStore.maxSnapshots)
    }
}
