import XCTest
@testable import HyprMac

// LayoutSnapshotStoreTests run the store against a temp file so the real
// persist()/load() pair is exercised — a fresh instance on the same URL
// must see what the previous one saved. Nothing here touches the shared
// store or ~/Library.

final class LayoutSnapshotStoreTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyprmac-layout-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func ref(_ bundleID: String, _ title: String = "") -> SavedWindowRef {
        SavedWindowRef(bundleID: bundleID, title: title)
    }

    private func single(_ bundleID: String, workspace: Int = 1) -> [WorkspaceLayout] {
        [WorkspaceLayout(workspace: workspace, root: .leaf(ref(bundleID)))]
    }

    // 2×2-ish: horizontal root, right child forced vertical, two same-ref leaves
    private func sampleTree() -> LayoutNode {
        .split(override: nil, ratio: 0.7, userSet: true,
               left: .leaf(ref("com.a", "A")),
               right: .split(override: .vertical, ratio: 0.5, userSet: false,
                             left: .leaf(ref("com.b", "zsh")),
                             right: .leaf(ref("com.b", "zsh"))))
    }

    // MARK: - display key

    func testDisplayKeySortsByName() {
        guard NSScreen.screens.count >= 1 else { return }
        let key = LayoutSnapshotStore.displayKey(screens: NSScreen.screens)
        let parts = key.split(separator: "|").map(String.init)
        XCTAssertEqual(parts, parts.sorted())
    }

    func testDisplayKeyDeterministic() {
        let screens = NSScreen.screens
        XCTAssertEqual(LayoutSnapshotStore.displayKey(screens: screens),
                       LayoutSnapshotStore.displayKey(screens: screens))
    }

    func testDisplayKeyEmptyScreens() {
        XCTAssertEqual(LayoutSnapshotStore.displayKey(screens: []), "")
    }

    // MARK: - disk round-trip through the real store

    func testSaveThenLoadFromDiskRoundTrips() throws {
        let tree = sampleTree()
        let writer = LayoutSnapshotStore(fileURL: fileURL)
        XCTAssertTrue(try writer.save(displayKey: "Test:1920x1080",
                                  workspaces: [WorkspaceLayout(workspace: 2, root: tree)],
                                  manual: true))

        let reader = LayoutSnapshotStore(fileURL: fileURL)
        let snap = try XCTUnwrap(reader.snapshot(for: "Test:1920x1080"))
        XCTAssertEqual(snap.schemaVersion, LayoutSnapshot.currentSchemaVersion)
        XCTAssertEqual(snap.displayKey, "Test:1920x1080")
        XCTAssertTrue(snap.isManual)
        XCTAssertEqual(snap.workspaces, [WorkspaceLayout(workspace: 2, root: tree)])
        let written = try XCTUnwrap(writer.snapshot(for: "Test:1920x1080"))
        // iso8601 keeps whole seconds
        XCTAssertEqual(snap.timestamp.timeIntervalSince1970,
                       written.timestamp.timeIntervalSince1970, accuracy: 1)
    }

    func testReloadedSnapshotIsIdenticalIncludingDate() throws {
        let writer = LayoutSnapshotStore(fileURL: fileURL)
        try writer.save(displayKey: "Test:1920x1080",
                        workspaces: [WorkspaceLayout(workspace: 2, root: sampleTree())], manual: true)
        let written = try XCTUnwrap(writer.snapshot(for: "Test:1920x1080"))

        let reader = LayoutSnapshotStore(fileURL: fileURL)
        XCTAssertEqual(reader.snapshot(for: "Test:1920x1080"), written)
        XCTAssertEqual(reader.snapshots, writer.snapshots)
    }

    // MARK: - failed writes

    func testSaveThrowsWhenParentDirectoryIsMissing() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyprmac-missing-\(UUID().uuidString)")
            .appendingPathComponent("layout-snapshots.json")
        let store = LayoutSnapshotStore(fileURL: url)
        XCTAssertThrowsError(try store.save(displayKey: "Test:1x1", workspaces: single("com.a"), manual: true))
        XCTAssertNil(store.snapshot(for: "Test:1x1"), "memory must not claim a snapshot the disk lacks")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(LayoutSnapshotStore(fileURL: url).snapshots.isEmpty)
    }

    func testFailedSaveRollsBackReplacementAndPruning() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyprmac-layout-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("layout-snapshots.json")
        let store = LayoutSnapshotStore(fileURL: url)
        for i in 0..<LayoutSnapshotStore.maxSnapshots {
            try store.save(displayKey: "Config\(i):100x100", workspaces: single("com.x"), manual: false)
        }
        let before = store.snapshots

        // the directory disappears under us: both a replace and a
        // pruning save must fail without touching memory
        try FileManager.default.removeItem(at: dir)
        XCTAssertThrowsError(try store.save(displayKey: "Config3:100x100", workspaces: single("com.y"), manual: true))
        XCTAssertThrowsError(try store.save(displayKey: "Overflow:100x100", workspaces: single("com.y"), manual: false))
        XCTAssertEqual(store.snapshots, before)
        XCTAssertNotNil(store.snapshot(for: "Config0:100x100"), "pruned entry comes back on rollback")
    }

    func testSkipIsNotAFailure() throws {
        let store = LayoutSnapshotStore(fileURL: fileURL)
        try store.save(displayKey: "Test:1x1", workspaces: single("com.a"), manual: true)
        var skipped: Bool?
        XCTAssertNoThrow(skipped = try store.save(displayKey: "Test:1x1", workspaces: single("com.b"), manual: false))
        XCTAssertEqual(skipped, false)
    }

    // MARK: - entries this build can't read

    func testNewerSchemaEntryIsKeptWhenFileIsRewritten() throws {
        // a future build may add fields and node kinds this build can't decode
        let futureEntry: [String: Any] = [
            "schemaVersion": LayoutSnapshot.currentSchemaVersion + 1,
            "displayKey": "Future:1x1",
            "timestamp": "2030-01-01T00:00:00Z",
            "isManual": true,
            "workspaces": [["workspace": 1, "root": ["tabs": ["a", "b"]]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: ["Future:1x1": futureEntry])
        try data.write(to: fileURL)

        let store = LayoutSnapshotStore(fileURL: fileURL)
        XCTAssertNil(store.snapshot(for: "Future:1x1"))
        try store.save(displayKey: "Test:1x1", workspaces: single("com.a"), manual: true)

        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        let kept = try XCTUnwrap(raw["Future:1x1"] as? NSDictionary)
        XCTAssertEqual(kept, futureEntry as NSDictionary)
        XCTAssertNotNil(LayoutSnapshotStore(fileURL: fileURL).snapshot(for: "Test:1x1"))
    }

    // a workspace whose windows never joined its tree saves no root
    func testUnplacedWindowsRoundTripWithoutARoot() throws {
        let layouts = [WorkspaceLayout(workspace: 3, root: nil, unplaced: [ref("com.a", "doc")])]
        try LayoutSnapshotStore(fileURL: fileURL).save(displayKey: "Test:1x1", workspaces: layouts, manual: true)

        XCTAssertEqual(LayoutSnapshotStore(fileURL: fileURL).snapshot(for: "Test:1x1")?.workspaces, layouts)
    }

    // files written before unplaced windows existed still load
    func testLayoutWithoutUnplacedKeyDecodes() throws {
        let json = #"{"workspace": 1, "root": {"leaf": {"bundleID": "com.a", "title": "t"}}}"#
        let layout = try JSONDecoder().decode(WorkspaceLayout.self, from: Data(json.utf8))
        XCTAssertEqual(layout, WorkspaceLayout(workspace: 1, root: .leaf(ref("com.a", "t"))))
    }

    // an unreadable entry may be a newer build's manual save
    func testAutoSaveDoesNotReplaceAnUnreadableEntry() throws {
        let futureEntry: [String: Any] = [
            "schemaVersion": LayoutSnapshot.currentSchemaVersion + 1,
            "displayKey": "Future:1x1", "timestamp": "2030-01-01T00:00:00Z",
            "isManual": true, "workspaces": [],
        ]
        try JSONSerialization.data(withJSONObject: ["Future:1x1": futureEntry]).write(to: fileURL)

        let store = LayoutSnapshotStore(fileURL: fileURL)
        XCTAssertFalse(try store.save(displayKey: "Future:1x1", workspaces: single("com.a"), manual: false))

        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        XCTAssertEqual(raw["Future:1x1"] as? NSDictionary, futureEntry as NSDictionary)
        XCTAssertTrue(try store.save(displayKey: "Future:1x1", workspaces: single("com.a"), manual: true))
    }

    // with every slot held by a manual snapshot, a new auto-save has nowhere to go
    func testAutoSaveThatWouldBePrunedAtOnceIsSkipped() throws {
        let store = LayoutSnapshotStore(fileURL: fileURL)
        for i in 0..<LayoutSnapshotStore.maxSnapshots {
            try store.save(displayKey: "Manual:\(i)", workspaces: single("com.a"), manual: true)
        }
        let before = try Data(contentsOf: fileURL)

        XCTAssertFalse(try store.save(displayKey: "Auto:1", workspaces: single("com.a"), manual: false))
        XCTAssertNil(store.snapshot(for: "Auto:1"))
        XCTAssertEqual(store.snapshots.count, LayoutSnapshotStore.maxSnapshots)
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
    }

    func testUnreadableFileIsMovedAsideNotOverwritten() throws {
        try Data("not json".utf8).write(to: fileURL)
        let aside = URL(fileURLWithPath: fileURL.path + ".unreadable")
        defer { try? FileManager.default.removeItem(at: aside) }

        let store = LayoutSnapshotStore(fileURL: fileURL)
        try store.save(displayKey: "Test:1x1", workspaces: single("com.a"), manual: true)

        XCTAssertEqual(try Data(contentsOf: aside), Data("not json".utf8))
        XCTAssertNotNil(LayoutSnapshotStore(fileURL: fileURL).snapshot(for: "Test:1x1"))
    }

    func testMissingFileLoadsEmpty() {
        let store = LayoutSnapshotStore(fileURL: fileURL)
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertNil(store.snapshot(for: "Unknown:800x600"))
    }

    func testCorruptFileLoadsEmptyWithoutCrashing() throws {
        try Data("not json".utf8).write(to: fileURL)
        let store = LayoutSnapshotStore(fileURL: fileURL)
        XCTAssertTrue(store.snapshots.isEmpty)
    }

    func testSnapshotFromNewerSchemaIsDropped() throws {
        let future = LayoutSnapshot(schemaVersion: LayoutSnapshot.currentSchemaVersion + 1,
                                    displayKey: "Future:1x1", timestamp: Date(),
                                    isManual: true, workspaces: single("com.a"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(["Future:1x1": future]).write(to: fileURL)

        let store = LayoutSnapshotStore(fileURL: fileURL)
        XCTAssertNil(store.snapshot(for: "Future:1x1"))
    }

    // MARK: - manual vs automatic

    func testAutoSaveSkipsWhenManualExists() throws {
        let store = LayoutSnapshotStore(fileURL: fileURL)
        let key = "Test:1920x1080"
        XCTAssertTrue(try store.save(displayKey: key, workspaces: single("com.a"), manual: true))
        XCTAssertFalse(try store.save(displayKey: key, workspaces: single("com.b"), manual: false))

        let snap = store.snapshot(for: key)!
        XCTAssertTrue(snap.isManual)
        XCTAssertEqual(snap.workspaces.first?.refs.first?.bundleID, "com.a")
    }

    func testManualSaveOverwritesManual() throws {
        let store = LayoutSnapshotStore(fileURL: fileURL)
        let key = "Test:1920x1080"
        try store.save(displayKey: key, workspaces: single("com.a"), manual: true)
        try store.save(displayKey: key, workspaces: single("com.b"), manual: true)
        XCTAssertEqual(store.snapshot(for: key)?.workspaces.first?.refs.first?.bundleID, "com.b")
    }

    func testAutoSaveOverwritesAuto() throws {
        let store = LayoutSnapshotStore(fileURL: fileURL)
        let key = "Test:1920x1080"
        try store.save(displayKey: key, workspaces: single("com.a"), manual: false)
        try store.save(displayKey: key, workspaces: single("com.b"), manual: false)
        XCTAssertEqual(store.snapshot(for: key)?.workspaces.first?.refs.first?.bundleID, "com.b")
    }

    // MARK: - pruning

    func testPruningEvictsOldestAutomatic() throws {
        let store = LayoutSnapshotStore(fileURL: fileURL)
        for i in 0..<LayoutSnapshotStore.maxSnapshots {
            try store.save(displayKey: "Config\(i):100x100", workspaces: single("com.x"), manual: false)
        }
        XCTAssertEqual(store.snapshots.count, LayoutSnapshotStore.maxSnapshots)

        try store.save(displayKey: "Overflow:100x100", workspaces: single("com.x"), manual: false)
        XCTAssertEqual(store.snapshots.count, LayoutSnapshotStore.maxSnapshots)
        XCTAssertNotNil(store.snapshot(for: "Overflow:100x100"))
        XCTAssertNil(store.snapshot(for: "Config0:100x100"), "oldest automatic snapshot is evicted")
    }

    func testPruningEvictsAutomaticBeforeManual() throws {
        let store = LayoutSnapshotStore(fileURL: fileURL)
        try store.save(displayKey: "Manual:100x100", workspaces: single("com.x"), manual: true)
        for i in 0..<LayoutSnapshotStore.maxSnapshots {
            try store.save(displayKey: "Auto\(i):100x100", workspaces: single("com.x"), manual: false)
        }
        XCTAssertEqual(store.snapshots.count, LayoutSnapshotStore.maxSnapshots)
        XCTAssertNotNil(store.snapshot(for: "Manual:100x100"),
                        "the oldest snapshot is manual and must outlive newer automatic ones")
        XCTAssertNil(store.snapshot(for: "Auto0:100x100"))
    }

    // MARK: - LayoutNode wire format

    func testLayoutNodeRoundTripsNestedSplit() throws {
        let tree = sampleTree()
        let data = try JSONEncoder().encode(tree)
        XCTAssertEqual(try JSONDecoder().decode(LayoutNode.self, from: data), tree)
    }

    func testLayoutNodeWireKeysAreFrozen() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let leaf = String(data: try encoder.encode(LayoutNode.leaf(ref("com.a", "A"))), encoding: .utf8)!
        XCTAssertEqual(leaf, #"{"leaf":{"bundleID":"com.a","title":"A"}}"#)

        let split = String(data: try encoder.encode(LayoutNode.split(
            override: .horizontal, ratio: 0.5, userSet: false,
            left: .leaf(ref("com.a")), right: .leaf(ref("com.b")))), encoding: .utf8)!
        XCTAssertEqual(split,
            #"{"split":{"left":{"leaf":{"bundleID":"com.a","title":""}},"override":"horizontal","ratio":0.5,"right":{"leaf":{"bundleID":"com.b","title":""}},"userSet":false}}"#)
    }

    func testLayoutNodeOmitsNilOverride() throws {
        let node = LayoutNode.split(override: nil, ratio: 0.5, userSet: true,
                                    left: .leaf(ref("com.a")), right: .leaf(ref("com.b")))
        let json = String(data: try JSONEncoder().encode(node), encoding: .utf8)!
        XCTAssertFalse(json.contains("override"))
        XCTAssertEqual(try JSONDecoder().decode(LayoutNode.self, from: Data(json.utf8)), node)
    }

    func testLayoutNodeRejectsUnknownCase() {
        XCTAssertThrowsError(try JSONDecoder().decode(LayoutNode.self, from: Data(#"{"bogus":{}}"#.utf8)))
    }

    func testLeavesAreLeftToRight() {
        XCTAssertEqual(sampleTree().leaves,
                       [ref("com.a", "A"), ref("com.b", "zsh"), ref("com.b", "zsh")])
    }

    // MARK: - keybind defaults

    func testDefaultsContainSaveAndRestore() {
        var hasSave = false
        var hasRestore = false
        for kb in Keybind.defaults {
            switch kb.action {
            case .saveLayout: hasSave = true
            case .restoreLayout: hasRestore = true
            default: break
            }
        }
        XCTAssertTrue(hasSave)
        XCTAssertTrue(hasRestore)
    }

    func testSaveRestoreActionsRoundTrip() throws {
        for action in [Action.saveLayout, Action.restoreLayout] {
            let kb = Keybind(keyCode: 1, modifiers: .hypr, action: action)
            let decoded = try JSONDecoder().decode(Keybind.self, from: try JSONEncoder().encode(kb))
            XCTAssertEqual(decoded.action, action)
        }
    }
}
