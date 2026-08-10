import ViewInspector
import XCTest

@testable import Spotiglass

@MainActor
final class PlaylistListRowViewTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testPlaylistRowShowsTitle() throws {
        let row = PlaylistRowViewModel(
            SpotifyPlaylistSummary(
                id: "pl", name: "Focus",
                ownerID: "test-owner", ownerName: "Me",
                imageURL: nil, trackCount: 4, snapshotID: "snap"
            )
        )
        let view = PlaylistListRow(playlist: row, isListSelected: true)
        ViewTestHost.host(view)
        XCTAssertNoThrow(try view.inspect().find(text: "Focus"))
    }

    func testLikedSongsRowUsesHeartIcon() throws {
        let row = PlaylistRowViewModel(likedSongsOwnerDisplay: "Me", totalTrackCount: 10, artworkURL: nil)
        let view = PlaylistListRow(playlist: row, isListSelected: false)
        ViewTestHost.host(view)
        XCTAssertNoThrow(try view.inspect().find(ViewType.Image.self))
    }
}
