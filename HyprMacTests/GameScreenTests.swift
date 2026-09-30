import XCTest
@testable import HyprMac

// GameScreenTests pin which apps count as games, when the game screen is
// reserved, and that a reserved screen hosts no tiles without joining
// the user's disabled monitors.

final class GameScreenTests: XCTestCase {

    // MARK: detection

    func testGameCategoriesAndGameModeSupportAreGames() {
        // Factorio, Death Must Die, Baldur's Gate 3 as they ship
        XCTAssertTrue(GameDetection.isGame(
            info: ["LSApplicationCategoryType": "public.app-category.simulation-games", "LSSupportsGameMode": true],
            bundleID: "com.factorio", extraBundleIDs: []))
        XCTAssertTrue(GameDetection.isGame(
            info: ["LSApplicationCategoryType": "public.app-category.games"],
            bundleID: "com.Realm-Archive.Death-Must-Die", extraBundleIDs: []))
        XCTAssertTrue(GameDetection.isGame(
            info: ["LSApplicationCategoryType": "public.app-category.role-playing-games"],
            bundleID: "com.larian.bg3", extraBundleIDs: []))
        XCTAssertTrue(GameDetection.isGame(
            info: ["LSSupportsGameMode": true], bundleID: "com.example.game", extraBundleIDs: []))
    }

    func testOtherAppsAreNotGames() {
        // Steam declares no category
        XCTAssertFalse(GameDetection.isGame(info: ["CFBundleName": "Steam"],
                                            bundleID: "com.valvesoftware.steam", extraBundleIDs: []))
        XCTAssertFalse(GameDetection.isGame(
            info: ["LSApplicationCategoryType": "public.app-category.developer-tools"],
            bundleID: "com.mitchellh.ghostty", extraBundleIDs: []))
        XCTAssertFalse(GameDetection.isGame(info: ["LSSupportsGameMode": false],
                                            bundleID: nil, extraBundleIDs: []))
        XCTAssertFalse(GameDetection.isGame(info: nil, bundleID: nil, extraBundleIDs: []))
    }

    func testTheManualListAddsGamesWithoutACategory() {
        XCTAssertTrue(GameDetection.isGame(info: [:], bundleID: "com.example.indie",
                                           extraBundleIDs: ["com.example.indie"]))
        XCTAssertTrue(GameDetection.isGame(info: nil, bundleID: "com.example.indie",
                                           extraBundleIDs: ["com.example.indie"]))
    }

    // MARK: policy

    private let desk = ["AW3425DW", "DELL S3220DGF"]

    func testARunningGameReservesTheGameMonitor() {
        XCTAssertEqual(GameScreenPolicy.reservedMonitor(
            gameMonitor: "AW3425DW", gameRunning: true, connected: desk, userDisabled: []), "AW3425DW")
    }

    func testNothingIsReservedWithoutAGameOrAGameMonitor() {
        XCTAssertNil(GameScreenPolicy.reservedMonitor(
            gameMonitor: "AW3425DW", gameRunning: false, connected: desk, userDisabled: []))
        XCTAssertNil(GameScreenPolicy.reservedMonitor(
            gameMonitor: nil, gameRunning: true, connected: desk, userDisabled: []))
    }

    func testAMissingOrUserDisabledGameMonitorIsNotReserved() {
        XCTAssertNil(GameScreenPolicy.reservedMonitor(
            gameMonitor: "AW3425DW", gameRunning: true,
            connected: ["DELL S3220DGF", "Built-in Retina Display"], userDisabled: []))
        XCTAssertNil(GameScreenPolicy.reservedMonitor(
            gameMonitor: "AW3425DW", gameRunning: true, connected: desk, userDisabled: ["AW3425DW"]))
    }

    // the tiles need somewhere to go: the only enabled screen is never reserved
    func testTheLastEnabledScreenIsNeverReserved() {
        XCTAssertNil(GameScreenPolicy.reservedMonitor(
            gameMonitor: "AW3425DW", gameRunning: true, connected: ["AW3425DW"], userDisabled: []))
        XCTAssertNil(GameScreenPolicy.reservedMonitor(
            gameMonitor: "AW3425DW", gameRunning: true, connected: desk, userDisabled: ["DELL S3220DGF"]))
    }

    // MARK: workspace manager

    func testAReservedScreenHostsNoTilesButIsNotUserDisabled() {
        let screen = GameTestScreen(name: "AW3425DW", x: 0)
        let workspaces = WorkspaceManager(displayManager: DisplayManager())
        XCTAssertFalse(workspaces.isMonitorDisabled(screen))

        workspaces.reservedMonitors = ["AW3425DW"]
        XCTAssertTrue(workspaces.isMonitorDisabled(screen))
        XCTAssertTrue(workspaces.isMonitorReserved(screen))
        XCTAssertFalse(workspaces.isMonitorUserDisabled(screen))
        XCTAssertTrue(workspaces.disabledMonitors.isEmpty)

        workspaces.reservedMonitors = []
        workspaces.disabledMonitors = ["AW3425DW"]
        XCTAssertTrue(workspaces.isMonitorDisabled(screen))
        XCTAssertTrue(workspaces.isMonitorUserDisabled(screen))
        XCTAssertFalse(workspaces.isMonitorReserved(screen))
    }

    func testAnUnreservedScreenAdmitsItsOwnWindows() {
        let screen = GameTestScreen(name: "DELL S3220DGF", x: 3440)
        let workspaces = WorkspaceManager(displayManager: DisplayManager())
        workspaces.reservedMonitors = ["AW3425DW"]
        XCTAssertTrue(workspaces.admissionScreen(for: screen) === screen)
    }

    func testWindowsOnAReservedScreenGoToTheNearestScreen() {
        let game = GameTestScreen(name: "AW3425DW", x: 0)
        let near = GameTestScreen(name: "DELL S3220DGF", x: 3440)
        let far = GameTestScreen(name: "LG", x: 8000)
        XCTAssertTrue(WorkspaceManager.nearestScreen(to: game, among: [far, near]) === near)
        XCTAssertNil(WorkspaceManager.nearestScreen(to: game, among: []))
    }
}

private final class GameTestScreen: NSScreen {
    private let name: String
    private let bounds: NSRect

    init(name: String, x: CGFloat) {
        self.name = name
        bounds = NSRect(x: x, y: 0, width: 2560, height: 1440)
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    // detached test screen: AppKit traps naming it on macOS 26
    override var localizedName: String { name }
    override var frame: NSRect { bounds }
    override var visibleFrame: NSRect { bounds }
    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: Int(bounds.minX) + 900)]
    }
}
