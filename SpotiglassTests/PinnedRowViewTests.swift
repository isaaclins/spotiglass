import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class PinnedRowViewTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testPlaylistPinRendersTitle() throws {
        let pin = PinnedItem.playlist(
            SpotifyPlaylistSummary(
                id: "p1", name: "Daily", ownerName: "Me",
                imageURL: nil, trackCount: 3, snapshotID: "s"
            )
        )
        let view = PinnedRowView(item: pin, isSelected: false, onUnpin: {})
        ViewTestHost.host(view)
        XCTAssertNoThrow(try view.inspect().find(text: "Daily"))
    }

    func testStaleBadge() throws {
        var pin = PinnedItem.playlist(
            SpotifyPlaylistSummary(
                id: "p2", name: "Gone", ownerName: "Me",
                imageURL: nil, trackCount: 0, snapshotID: "s"
            )
        )
        pin.isStale = true
        let view = PinnedRowView(item: pin, onUnpin: {})
        ViewTestHost.host(view)
        XCTAssertNoThrow(try view.inspect().find(text: "Unavailable"))
    }
}
