import XCTest
@testable import HyprMac

final class WorkspaceNameTests: XCTestCase {

    private func decode(_ json: String) throws -> SavedConfig {
        try JSONDecoder().decode(SavedConfig.self, from: Data(json.utf8))
    }

    func testNamesRoundTripThroughSavedConfig() throws {
        let saved = try decode("""
        {"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true,
         "workspaceNames":{"4":"term","10":"music"}}
        """)
        XCTAssertEqual(saved.workspaceNames, ["4": "term", "10": "music"])
        let reloaded = try JSONDecoder().decode(SavedConfig.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(reloaded.workspaceNames, saved.workspaceNames)
    }

    func testConfigWithoutNamesDecodesAsNoneAndWritesNoKey() throws {
        let saved = try decode(#"{"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true}"#)
        XCTAssertNil(saved.workspaceNames)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        XCTAssertNil(object["workspaceNames"])
        XCTAssertNil(try decode(#"{"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true,"workspaceNames":null}"#)
            .workspaceNames)
    }

    // only "1"…"10" with a non-empty name survive; a bad value costs only the names
    func testStrayKeysAndEmptyNamesAreDropped() throws {
        let saved = try decode("""
        {"keybinds":[],"gapSize":22,"outerPadding":8,"enabled":true,
         "workspaceNames":{"0":"pad","11":"x","04":"y","3":"","7":"web"}}
        """)
        XCTAssertEqual(saved.workspaceNames, ["7": "web"])
        XCTAssertNil(try decode("""
        {"keybinds":[],"gapSize":8,"outerPadding":8,"enabled":true,"workspaceNames":{"2":""}}
        """).workspaceNames)
        let unreadable = try decode("""
        {"keybinds":[],"gapSize":14,"outerPadding":8,"enabled":true,"workspaceNames":["term"]}
        """)
        XCTAssertNil(unreadable.workspaceNames)
        XCTAssertEqual(unreadable.gapSize, 14)
    }

    func testDisplayNameFallsBackWhenUnsetOrBlank() {
        let names = ["4": "term", "5": "   ", "6": " web "]
        XCTAssertEqual(UserConfig.workspaceDisplayName(4, names: names), "term")
        XCTAssertEqual(UserConfig.workspaceDisplayName(6, names: names), "web")
        XCTAssertEqual(UserConfig.workspaceDisplayName(5, names: names), "Workspace 5")
        XCTAssertEqual(UserConfig.workspaceDisplayName(1, names: names), "Workspace 1")
        XCTAssertEqual(UserConfig.workspaceDisplayName(1, names: [:], fallback: "1"), "1")
        XCTAssertEqual(UserConfig.workspaceDisplayName(4, names: names, fallback: "4"), "term")
    }
}
