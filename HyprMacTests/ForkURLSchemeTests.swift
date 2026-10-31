import XCTest
@testable import HyprMac

// The fork registers its own link scheme so links never land in the stock
// app installed beside it. Upstream's `hyprmac` spelling still parses.

final class ForkURLSchemeTests: XCTestCase {

    func testTheForkSchemeIsNotTheStockOne() {
        XCTAssertNotEqual(AppIdentity.urlScheme, "hyprmac")
        XCTAssertTrue(AppIdentity.urlScheme.hasPrefix("hyprmac-experiments"))
    }

    func testForkLinksParseLikeUpstreamOnes() throws {
        let fork = try XCTUnwrap(URL(string: "\(AppIdentity.urlScheme)://workspace?n=4"))
        let stock = try XCTUnwrap(URL(string: "hyprmac://workspace?n=4"))

        XCTAssertEqual(ExternalCommand.parse(fork), .workspace(4))
        XCTAssertEqual(ExternalCommand.parse(stock), .workspace(4))
        XCTAssertEqual(ExternalCommand.parse(try XCTUnwrap(URL(string: "\(AppIdentity.urlScheme)://action/retileAll"))),
                       .action(.retileAll))
    }

    func testAnotherSchemeIsIgnored() throws {
        XCTAssertNil(ExternalCommand.parse(try XCTUnwrap(URL(string: "hyprland://workspace?n=4"))))
    }
}
