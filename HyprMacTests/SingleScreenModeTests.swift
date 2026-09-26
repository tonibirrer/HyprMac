import XCTest
@testable import HyprMac

// SingleScreenModeTests pin which screen the screen-sharing collapse keeps
// and what it disables. The kept screen must be the one accordion mode
// would use, so one press yields a stacked single screen.

final class SingleScreenModeTests: XCTestCase {

    private let builtIn = SingleScreenMode.Screen(name: "Built-in Retina Display", isBuiltIn: true, isPrimary: false)
    private let alienware = SingleScreenMode.Screen(name: "AW3425DW", isBuiltIn: false, isPrimary: true)
    private let dell = SingleScreenMode.Screen(name: "DELL S3220DGF", isBuiltIn: false, isPrimary: false)

    func testTheAccordionMonitorWinsWhenConnected() {
        let keep = SingleScreenMode.screenToKeep([builtIn, alienware, dell], accordionMonitor: "DELL S3220DGF")
        XCTAssertEqual(keep, dell)
    }

    func testTheBuiltInDisplayIsKeptByDefault() {
        XCTAssertEqual(SingleScreenMode.screenToKeep([alienware, builtIn, dell], accordionMonitor: nil), builtIn)
        // an accordion monitor that is not plugged in falls back the same way
        XCTAssertEqual(SingleScreenMode.screenToKeep([alienware, builtIn, dell], accordionMonitor: "LG UltraFine"), builtIn)
    }

    func testThePrimaryIsKeptWithoutABuiltInDisplay() {
        XCTAssertEqual(SingleScreenMode.screenToKeep([dell, alienware], accordionMonitor: nil), alienware)
    }

    func testTheFirstScreenIsKeptAsALastResort() {
        let a = SingleScreenMode.Screen(name: "A", isBuiltIn: false, isPrimary: false)
        let b = SingleScreenMode.Screen(name: "B", isBuiltIn: false, isPrimary: false)
        XCTAssertEqual(SingleScreenMode.screenToKeep([a, b], accordionMonitor: nil), a)
        XCTAssertNil(SingleScreenMode.screenToKeep([], accordionMonitor: nil))
    }

    func testEveryOtherScreenIsDisabled() {
        let disabled = SingleScreenMode.disabledMonitors(keeping: builtIn, screens: [builtIn, alienware, dell])
        XCTAssertEqual(disabled, ["AW3425DW", "DELL S3220DGF"])
    }
}
