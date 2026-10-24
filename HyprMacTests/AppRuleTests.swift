import XCTest
@testable import HyprMac

// The fork's per-app effects (AppRule) and their move out of the legacy
// windowRules entries, which upstream's WindowRule now owns as pins.

final class AppRuleTests: XCTestCase {

    private func decodeConfig(_ json: String) throws -> SavedConfig {
        try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
    }

    private let base = #""keybinds": [], "gapSize": 8, "outerPadding": 8, "enabled": true"#

    // MARK: - model

    func testEffectsDefaultOffAndRoundTrip() throws {
        let rule = try JSONDecoder().decode(AppRule.self, from: Data(#"{"bundleID": "md.obsidian"}"#.utf8))
        XCTAssertEqual(rule, AppRule(bundleID: "md.obsidian"))
        XCTAssertFalse(rule.hasEffect)

        let original = [AppRule(bundleID: "app.zen-browser.zen", sortPriority: 10, focusOnActivate: true,
                                sticky: true, fullHeight: true, noSyntheticClick: true)]
        let decoded = try JSONDecoder().decode([AppRule].self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testHelpersMatchTheFirstRuleForTheApp() {
        let rules = [
            AppRule(bundleID: "app.zen-browser.zen", sortPriority: 10, focusOnActivate: true, fullHeight: true),
            AppRule(bundleID: "app.zen-browser.zen", sortPriority: -5, sticky: true),
            AppRule(bundleID: "com.example.rdp", noSyntheticClick: true),
        ]
        XCTAssertEqual(rules.sortPriority(bundleID: "app.zen-browser.zen"), 10)
        XCTAssertTrue(rules.focusOnActivate(bundleID: "app.zen-browser.zen"))
        XCTAssertTrue(rules.isFullHeight(bundleID: "app.zen-browser.zen"))
        XCTAssertFalse(rules.isSticky(bundleID: "app.zen-browser.zen"), "first match wins")
        XCTAssertTrue(rules.blocksSyntheticClick(bundleID: "com.example.rdp"))
        for bundleID in ["com.apple.finder", nil] {
            XCTAssertEqual(rules.sortPriority(bundleID: bundleID), 0)
            XCTAssertFalse(rules.focusOnActivate(bundleID: bundleID))
            XCTAssertFalse(rules.isSticky(bundleID: bundleID))
            XCTAssertFalse(rules.isFullHeight(bundleID: bundleID))
            XCTAssertFalse(rules.blocksSyntheticClick(bundleID: bundleID))
        }
    }

    func testBuiltInSyntheticClickBlockListCoversRemoteDesktopClients() {
        let blocked = HyprWindow.syntheticClickBlockedBundleIDs
        XCTAssertTrue(blocked.contains("com.citrix.receiver.icaviewer.mac"))
        XCTAssertTrue(blocked.contains("com.microsoft.rdc.macos"))
        XCTAssertFalse(blocked.contains("com.mitchellh.ghostty"))
    }

    // MARK: - legacy windowRules

    func testLegacyRulesSplitIntoPinsAndEffects() throws {
        let saved = try decodeConfig("""
        {\(base), "windowRules": [
            {"bundleID": "app.zen-browser.zen", "workspace": 1, "silent": false, "sortPriority": 10,
             "focusOnActivate": true, "sticky": false, "fullHeight": true, "noSyntheticClick": false},
            {"bundleID": "net.whatsapp.WhatsApp", "workspace": 5, "silent": false, "sortPriority": 0,
             "focusOnActivate": false, "sticky": false, "fullHeight": false, "noSyntheticClick": false},
            {"bundleID": "com.example.priorityOnly", "workspace": 0, "sortPriority": -2}
        ]}
        """)
        XCTAssertEqual(saved.windowRules, [
            WindowRule(bundleID: "app.zen-browser.zen", workspace: 1),
            WindowRule(bundleID: "net.whatsapp.WhatsApp", workspace: 5),
        ], "every pin stays; a priority-only entry pinned nothing")
        XCTAssertEqual(saved.appRules, [
            AppRule(bundleID: "app.zen-browser.zen", sortPriority: 10, focusOnActivate: true, fullHeight: true),
            AppRule(bundleID: "com.example.priorityOnly", sortPriority: -2),
        ], "only entries with an effect become app rules")
    }

    func testAConfigWithAppRulesIsNotSplitAgain() throws {
        let saved = try decodeConfig("""
        {\(base),
         "windowRules": [{"bundleID": "dev.zed.Zed", "workspace": 2}],
         "experimentsAppRules": [{"bundleID": "dev.zed.Zed", "fullHeight": true, "sortPriority": 1}]}
        """)
        XCTAssertEqual(saved.windowRules, [WindowRule(bundleID: "dev.zed.Zed", workspace: 2)])
        XCTAssertEqual(saved.appRules, [AppRule(bundleID: "dev.zed.Zed", sortPriority: 1, fullHeight: true)])
    }

    func testUpstreamShapedRulesMoveNothing() throws {
        let saved = try decodeConfig("""
        {\(base), "windowRules": [{"bundleID": "com.apple.finder", "workspace": 6}]}
        """)
        XCTAssertEqual(saved.windowRules, [WindowRule(bundleID: "com.apple.finder", workspace: 6)])
        XCTAssertNil(saved.appRules)
    }

    func testTheSplitSurvivesASaveAndReload() throws {
        let legacy = try decodeConfig("""
        {\(base), "windowRules": [
            {"bundleID": "Mattermost.Desktop", "workspace": 3, "sortPriority": -1, "fullHeight": true}
        ]}
        """)
        // what UserConfig writes back: upstream's pins plus the fork's key
        var resaved = legacy
        resaved.appRules = legacy.appRules
        let reloaded = try JSONDecoder().decode(SavedConfig.self, from: JSONEncoder().encode(resaved))
        XCTAssertEqual(reloaded.windowRules, [WindowRule(bundleID: "Mattermost.Desktop", workspace: 3)])
        XCTAssertEqual(reloaded.appRules, [AppRule(bundleID: "Mattermost.Desktop", sortPriority: -1, fullHeight: true)])

        let json = try XCTUnwrap(String(data: JSONEncoder().encode(resaved), encoding: .utf8))
        XCTAssertTrue(json.contains("\"experimentsAppRules\""), json)
        XCTAssertFalse(json.contains("\"appRules\""), "the fork's key is namespaced: \(json)")
    }
}
