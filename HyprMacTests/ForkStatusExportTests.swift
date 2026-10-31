import XCTest
@testable import HyprMac

// The fork's addition to upstream's state.json: each workspace's accent
// color, which the sketchybar example highlights the focused workspace in.

final class ForkStatusExportTests: XCTestCase {

    private func input(colors: [String: String]) -> StatusSnapshot.Input {
        StatusSnapshot.Input(
            screens: [.init(name: "Built-in Retina Display", visibleWorkspace: 2)],
            homeScreens: Dictionary(uniqueKeysWithValues: Constants.workspaceRange.map { ($0, "Built-in Retina Display") }),
            assigned: [2: [7]], scratchpad: [], scratchpadVisible: false, hidden: [], floating: [],
            focusedWindowID: 7, cursorScreen: "Built-in Retina Display",
            apps: [7: .init(name: "Ghostty", bundleID: "com.mitchellh.ghostty")], names: [:],
            colors: colors)
    }

    func testAWorkspaceColorIsWrittenWithAHash() throws {
        let snapshot = StatusSnapshot.build(input(colors: ["2": "08A56A"]))

        XCTAssertEqual(snapshot.workspaces.first { $0.id == 2 }?.color, "#08A56A")
        XCTAssertNil(snapshot.workspaces.first { $0.id == 1 }?.color)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(snapshot), encoding: .utf8))
        XCTAssertTrue(json.contains("\"color\":\"#08A56A\""))
    }

    func testNoColorsWriteNoColorKey() throws {
        let snapshot = StatusSnapshot.build(input(colors: [:]))
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(snapshot), encoding: .utf8))
        XCTAssertFalse(json.contains("\"color\""))
    }
}
