import XCTest
@testable import Spotiglass

final class BrowsingLoadStateTests: XCTestCase {
    func testBrowsingDisplayErrorEqualityIgnoresID() {
        let a = BrowsingDisplayError(title: "T", message: "M", canRetry: true, diagnosticDetails: "d")
        let b = BrowsingDisplayError(title: "T", message: "M", canRetry: true, diagnosticDetails: "d")
        let c = BrowsingDisplayError(title: "Other", message: "M", canRetry: true, diagnosticDetails: "d")

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testCurrentValueForAllCases() {
        XCTAssertNil(BrowsingLoadState<String>.loading.currentValue)
        XCTAssertEqual(BrowsingLoadState<String>.loaded("loaded").currentValue, "loaded")
        XCTAssertNil(BrowsingLoadState<String>.empty("none").currentValue)
        XCTAssertEqual(BrowsingLoadState<String>.staleCache("stale", nil).currentValue, "stale")
        XCTAssertEqual(BrowsingLoadState<String>.refreshing("refreshing").currentValue, "refreshing")
        XCTAssertNil(BrowsingLoadState<String>.error(
            BrowsingDisplayError(title: "E", message: "m", canRetry: false)
        ).currentValue)
    }
}
