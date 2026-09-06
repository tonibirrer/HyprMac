import XCTest
@testable import HyprMac

// SupportDirectoryImportTests pin the one-time import from the stock
// app's Application Support directory into this build's own directory
// (ConfigMigration.importUpstreamDirectory). Runs entirely in a temp dir.

final class SupportDirectoryImportTests: XCTestCase {

    private var root: URL!
    private var legacy: URL!
    private var current: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("hyprmac-import-\(UUID().uuidString)", isDirectory: true)
        legacy = root.appendingPathComponent("HyprMac", isDirectory: true)
        current = root.appendingPathComponent("HyprMacExperiments", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)!.write(to: url)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private var marker: URL { current.appendingPathComponent(ConfigMigration.importMarkerName) }

    func testCopiesBothFilesAndStampsMarker() throws {
        try write(#"{"gapSize": 12}"#, to: legacy.appendingPathComponent("config.json"))
        try write(#"{"linkedMonitors": true}"#, to: legacy.appendingPathComponent("monitor-config.json"))

        XCTAssertTrue(ConfigMigration.importUpstreamDirectory(from: legacy, to: current, fileManager: fm))

        XCTAssertEqual(read(current.appendingPathComponent("config.json")), #"{"gapSize": 12}"#)
        XCTAssertEqual(read(current.appendingPathComponent("monitor-config.json")), #"{"linkedMonitors": true}"#)
        XCTAssertTrue(fm.fileExists(atPath: marker.path))
        // source untouched
        XCTAssertEqual(read(legacy.appendingPathComponent("config.json")), #"{"gapSize": 12}"#)
    }

    func testRunsOnlyOnce() throws {
        try write("first", to: legacy.appendingPathComponent("config.json"))
        XCTAssertTrue(ConfigMigration.importUpstreamDirectory(from: legacy, to: current, fileManager: fm))

        // user resets by deleting config.json; upstream changes theirs —
        // neither may re-trigger the import
        try fm.removeItem(at: current.appendingPathComponent("config.json"))
        try write("second", to: legacy.appendingPathComponent("config.json"))
        XCTAssertFalse(ConfigMigration.importUpstreamDirectory(from: legacy, to: current, fileManager: fm))
        XCTAssertFalse(fm.fileExists(atPath: current.appendingPathComponent("config.json").path))
    }

    func testNothingToImportStillStampsMarker() {
        XCTAssertFalse(ConfigMigration.importUpstreamDirectory(from: legacy, to: current, fileManager: fm))
        XCTAssertTrue(fm.fileExists(atPath: marker.path))
        XCTAssertFalse(fm.fileExists(atPath: current.appendingPathComponent("config.json").path))
    }

    func testMissingLegacyDirectoryIsHarmless() throws {
        try fm.removeItem(at: legacy)
        XCTAssertFalse(ConfigMigration.importUpstreamDirectory(from: legacy, to: current, fileManager: fm))
        XCTAssertTrue(fm.fileExists(atPath: current.path))
        XCTAssertTrue(fm.fileExists(atPath: marker.path))
    }

    func testExistingDestinationFileIsNotOverwritten() throws {
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try write("mine", to: current.appendingPathComponent("config.json"))
        try write("theirs", to: legacy.appendingPathComponent("config.json"))
        try write("mc", to: legacy.appendingPathComponent("monitor-config.json"))

        XCTAssertTrue(ConfigMigration.importUpstreamDirectory(from: legacy, to: current, fileManager: fm))
        XCTAssertEqual(read(current.appendingPathComponent("config.json")), "mine")
        XCTAssertEqual(read(current.appendingPathComponent("monitor-config.json")), "mc")
    }

    func testICloudSymlinkIsResolvedIntoRegularFile() throws {
        let cloud = root.appendingPathComponent("cloud", isDirectory: true)
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
        try write("synced", to: cloud.appendingPathComponent("config.json"))
        try fm.createSymbolicLink(at: legacy.appendingPathComponent("config.json"),
                                  withDestinationURL: cloud.appendingPathComponent("config.json"))

        XCTAssertTrue(ConfigMigration.importUpstreamDirectory(from: legacy, to: current, fileManager: fm))
        let dst = current.appendingPathComponent("config.json")
        XCTAssertEqual(read(dst), "synced")
        let isLink = (try? dst.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
        XCTAssertFalse(isLink, "destination must be a regular file, not a link into the stock app's iCloud folder")
    }
}
