import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class ArtworkViewTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testPlaceholderWhenURLMissing() throws {
        let view = ArtworkView(url: nil, size: 48)
        ViewTestHost.host(view)
        XCTAssertNoThrow(try view.inspect().find(ViewType.Image.self))
    }

    func testLoadsWhenURLPresent() throws {
        let view = ArtworkView(url: URL(string: "https://example.com/a.jpg"), size: 48)
        ViewTestHost.host(view, size: CGSize(width: 80, height: 80))
        XCTAssertNoThrow(try view.inspect().find(ViewType.Group.self))
    }
}
