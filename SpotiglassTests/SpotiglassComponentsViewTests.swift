import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class SpotiglassComponentsViewTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testPillButtonRendersLabel() throws {
        let view = Button("Action") {}
            .buttonStyle(SpotiglassPillStyle(variant: .glass))
        ViewTestHost.host(view)
        XCTAssertNoThrow(try view.inspect().find(text: "Action"))
    }
}
