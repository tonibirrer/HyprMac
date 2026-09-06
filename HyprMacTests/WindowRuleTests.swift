import XCTest
@testable import HyprMac

final class WindowRuleTests: XCTestCase {

    func testFirstMatchPicksFirstRuleForBundleID() {
        let rules = [
            WindowRule(bundleID: "com.mitchellh.ghostty", workspace: 2),
            WindowRule(bundleID: "com.mitchellh.ghostty", workspace: 5),
            WindowRule(bundleID: "dev.zed.Zed", workspace: 3, silent: true),
        ]
        XCTAssertEqual(rules.firstMatch(bundleID: "com.mitchellh.ghostty")?.workspace, 2)
        XCTAssertEqual(rules.firstMatch(bundleID: "dev.zed.Zed")?.silent, true)
        XCTAssertNil(rules.firstMatch(bundleID: "com.apple.finder"))
        XCTAssertNil(rules.firstMatch(bundleID: nil))
    }

    func testFirstMatchSkipsInvalidWorkspace() {
        let rules = [WindowRule(bundleID: "a.b.c", workspace: 12)]
        XCTAssertNil(rules.firstMatch(bundleID: "a.b.c"))
    }

    func testDecodingDefaultsSilentToFalse() throws {
        let json = #"{"bundleID": "md.obsidian", "workspace": 5}"#.data(using: .utf8)!
        let rule = try JSONDecoder().decode(WindowRule.self, from: json)
        XCTAssertEqual(rule.bundleID, "md.obsidian")
        XCTAssertEqual(rule.workspace, 5)
        XCTAssertFalse(rule.silent)
    }

    func testRoundTripThroughSavedConfigStyleEncoding() throws {
        let original = [WindowRule(bundleID: "us.zoom.xos", workspace: 7, silent: true)]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([WindowRule].self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testFocusOnActivateDefaultsFalseAndRoundTrips() throws {
        let json = #"{"bundleID": "md.obsidian", "workspace": 5}"#.data(using: .utf8)!
        let rule = try JSONDecoder().decode(WindowRule.self, from: json)
        XCTAssertFalse(rule.focusOnActivate)

        let original = [WindowRule(bundleID: "app.zen-browser.zen", workspace: 0, focusOnActivate: true)]
        let decoded = try JSONDecoder().decode([WindowRule].self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testFocusOnActivateHelperMatchesWithoutWorkspacePin() {
        let rules = [WindowRule(bundleID: "app.zen-browser.zen", workspace: 0, focusOnActivate: true)]
        XCTAssertTrue(rules.focusOnActivate(bundleID: "app.zen-browser.zen"))
        XCTAssertFalse(rules.focusOnActivate(bundleID: "com.mitchellh.ghostty"))
        XCTAssertFalse(rules.focusOnActivate(bundleID: nil))
    }

    func testStickyDefaultsFalseAndRoundTrips() throws {
        let json = #"{"bundleID": "Mattermost.Desktop", "workspace": 0}"#.data(using: .utf8)!
        let rule = try JSONDecoder().decode(WindowRule.self, from: json)
        XCTAssertFalse(rule.sticky)

        let original = [WindowRule(bundleID: "app.zen-browser.zen", workspace: 0, sticky: true)]
        let decoded = try JSONDecoder().decode([WindowRule].self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded[0].sticky)
    }

    func testIsStickyHelperMatchesWithoutWorkspacePin() {
        let rules = [
            WindowRule(bundleID: "app.zen-browser.zen", workspace: 0, sticky: true),
            WindowRule(bundleID: "Mattermost.Desktop", workspace: 2, sortPriority: -1),
        ]
        XCTAssertTrue(rules.isSticky(bundleID: "app.zen-browser.zen"))
        XCTAssertFalse(rules.isSticky(bundleID: "Mattermost.Desktop"))
        XCTAssertFalse(rules.isSticky(bundleID: "com.apple.finder"))
        XCTAssertFalse(rules.isSticky(bundleID: nil))
    }
}
