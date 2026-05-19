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

    func testLikedSongsAndArtistRows() throws {
        let liked = PinnedRowView(
            item: .likedSongs(ownerDisplay: "You", artworkURL: nil),
            isSelected: true,
            onUnpin: {}
        )
        ViewTestHost.host(liked)
        XCTAssertNoThrow(try liked.inspect().find(text: "Liked Songs"))

        let artist = PinnedRowView(
            item: .artist(SpotifyArtist(id: "a1", name: "M83", imageURL: nil, uri: "spotify:artist:a1")),
            onUnpin: {}
        )
        ViewTestHost.host(artist)
        XCTAssertNoThrow(try artist.inspect().find(text: "M83"))
    }

    func testAlbumAndTrackPins() throws {
        let album = PinnedRowView(
            item: .album(SpotifyAlbum(
                id: "al1", name: "Hurry Up", artists: ["M83"], imageURL: nil, uri: "spotify:album:al1"
            )),
            onUnpin: {}
        )
        ViewTestHost.host(album)
        XCTAssertNoThrow(try album.inspect().find(text: "Hurry Up"))

        let track = PinnedRowView(
            item: .track(SpotifyTrack(
                id: "t1",
                name: "Midnight",
                artists: ["M83"],
                albumArtworkURL: URL(string: "https://example.com/a.jpg"),
                durationMilliseconds: 240_000,
                isExplicit: false,
                isPlayable: true,
                linkedFromID: nil,
                uri: "spotify:track:t1"
            )),
            onUnpin: {}
        )
        ViewTestHost.host(track)
        XCTAssertNoThrow(try track.inspect().find(text: "Midnight"))
    }

    func testDragPillKinds() throws {
        let playlist = PinnedItem.playlist(
            SpotifyPlaylistSummary(
                id: "p3", name: "Mix", ownerName: "Me",
                imageURL: nil, trackCount: 1, snapshotID: "s"
            )
        )
        ViewTestHost.host(PinnedItemDragPill(item: playlist))
        ViewTestHost.host(PinnedItemDragPill(item: .likedSongs(ownerDisplay: "You", artworkURL: nil)))
    }
}
