import XCTest
@testable import HyprMac

// Upstream decodes monitor-config.json per field through an explicit key
// list (a bad value costs only its field). The fork's machine-local
// settings live in the same file, so each must be in that list too, or a
// relaunch silently drops linked monitors, accordion and the game screen.

final class ForkMonitorConfigTests: XCTestCase {

    func testForkFieldsSurviveARoundTrip() throws {
        let saved = SavedMonitorConfig(
            maxSplitsPerMonitor: ["AW3425DW": 7], disabledMonitors: [],
            outerPaddingPerMonitor: ["AW3425DW": EdgePadding(top: 34)],
            linkedMonitors: true, accordionMode: true, accordionMonitor: "Built-in Retina Display",
            accordionOverlap: 0, singleScreenRestore: ["DELL S3220DGF"],
            gameMonitor: "AW3425DW", gameBundleIDs: ["com.factorio"])

        let decoded = try JSONDecoder().decode(SavedMonitorConfig.self, from: JSONEncoder().encode(saved))

        XCTAssertEqual(decoded.linkedMonitors, true)
        XCTAssertEqual(decoded.accordionMode, true)
        XCTAssertEqual(decoded.accordionMonitor, "Built-in Retina Display")
        XCTAssertEqual(decoded.accordionOverlap, 0)
        XCTAssertEqual(decoded.singleScreenRestore, ["DELL S3220DGF"])
        XCTAssertEqual(decoded.gameMonitor, "AW3425DW")
        XCTAssertEqual(decoded.gameBundleIDs, ["com.factorio"])
        XCTAssertEqual(decoded.outerPaddingPerMonitor, ["AW3425DW": EdgePadding(top: 34)])
    }

    func testABadForkValueCostsOnlyItsField() throws {
        let json = #"{"accordionOverlap":"wide","accordionMode":true,"linkedMonitors":true,"maxSplitsPerMonitor":{}}"#

        let decoded = try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(json.utf8))

        XCTAssertNil(decoded.accordionOverlap)
        XCTAssertEqual(decoded.accordionMode, true)
        XCTAssertEqual(decoded.linkedMonitors, true)
    }

    func testTodaysFileStillLoads() throws {
        // the shape the fork wrote before the sync
        let json = #"{"accordionOverlap":0,"disabledMonitors":[],"accordionMode":true,"gameMonitor":"AW3425DW","#
            + #""maxSplitsPerMonitor":{"DELL S3220DGF":7,"AW3425DW":7},"linkedMonitors":true}"#

        let decoded = try JSONDecoder().decode(SavedMonitorConfig.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.maxSplitsPerMonitor, ["DELL S3220DGF": 7, "AW3425DW": 7])
        XCTAssertEqual(decoded.gameMonitor, "AW3425DW")
        XCTAssertEqual(decoded.linkedMonitors, true)
        XCTAssertEqual(decoded.accordionMode, true)
    }
}

// The fork's global per-side padding (config.json `outerPaddingSides`) moves
// onto upstream's per-monitor overrides once.

final class ForkPaddingMigrationTests: XCTestCase {

    func testLegacySidesLandOnEveryKnownMonitor() {
        let result = ConfigMigration.perMonitorPadding(
            legacy: PaddingSides(top: 34, left: nil, bottom: nil, right: nil),
            existing: [:], monitors: ["Built-in Retina Display", "AW3425DW", "DELL S3220DGF"])

        XCTAssertTrue(result.migrated)
        XCTAssertEqual(result.padding, [
            "Built-in Retina Display": EdgePadding(top: 34),
            "AW3425DW": EdgePadding(top: 34),
            "DELL S3220DGF": EdgePadding(top: 34),
        ])
    }

    func testAMonitorsOwnSideWins() {
        let result = ConfigMigration.perMonitorPadding(
            legacy: PaddingSides(top: 34, left: 4, bottom: nil, right: nil),
            existing: ["AW3425DW": EdgePadding(top: 50)], monitors: ["AW3425DW"])

        XCTAssertEqual(result.padding["AW3425DW"], EdgePadding(top: 50, left: 4))
    }

    func testNothingToMoveLeavesTheOverridesAlone() {
        let existing = ["AW3425DW": EdgePadding(bottom: 60)]

        for legacy in [nil, PaddingSides.none] {
            let result = ConfigMigration.perMonitorPadding(legacy: legacy, existing: existing, monitors: ["AW3425DW", "X"])
            XCTAssertFalse(result.migrated)
            XCTAssertEqual(result.padding, existing)
        }
    }
}
