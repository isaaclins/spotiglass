import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserPinnedItemActivationTests: XCTestCase {
    func testRoutesForPinnedKinds() {
        let playlist = PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "p", name: "P"))
        XCTAssertEqual(
            PlaylistBrowserPinnedItemActivation.route(for: playlist, previousSelection: nil),
            .selectPlaylist(playlist.playlistSummary!)
        )

        let artist = PinnedItem.artist(
            SpotifyArtistDetail(id: "a", name: "A", imageURL: nil, followersTotal: nil, genres: [], uri: "spotify:artist:a")
        )
        if case let .selectArtist(id, name)? = PlaylistBrowserPinnedItemActivation.route(for: artist, previousSelection: nil) {
            XCTAssertEqual(id, "a")
            XCTAssertEqual(name, "A")
        } else {
            XCTFail("expected artist route")
        }

        let stale = PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "s", name: "S"))
        var copy = stale
        copy.isStale = true
        if case let .staleRevert(selection)? = PlaylistBrowserPinnedItemActivation.route(for: copy, previousSelection: .home) {
            XCTAssertEqual(selection, .home)
        } else {
            XCTFail("expected stale revert")
        }
    }

    func testPinnedPlaylistRouteCarriesStoredSummaryMetadata() {
        let summary = SpotifyPlaylistSummary(
            id: "public-playlist",
            name: "Public Mix",
            ownerID: "public-owner",
            ownerName: "Public Owner",
            imageURL: nil,
            trackCount: 42,
            snapshotID: "public-snapshot"
        )
        let item = PinnedItem.playlist(summary)

        guard case let .selectPlaylist(routedSummary)? = PlaylistBrowserPinnedItemActivation.route(
            for: item,
            previousSelection: nil
        ) else {
            return XCTFail("expected playlist route with summary")
        }
        XCTAssertEqual(routedSummary, summary)
    }

    func testSidebarSelectionAfterActivationWhenLoaded() {
        let item = PinnedItem.artist(
            SpotifyArtistDetail(id: "a", name: "A", imageURL: nil, followersTotal: nil, genres: [], uri: "spotify:artist:a")
        )
        let detail = ArtistDetailViewModel(
            artist: SpotifyArtistDetail(id: "a", name: "A", imageURL: nil, followersTotal: nil, genres: [], uri: "spotify:artist:a"),
            tracks: [],
            albums: [],
            canLoadMoreAlbums: false
        )
        let selection = PlaylistBrowserPinnedItemActivation.sidebarSelectionAfterActivation(
            item: item,
            detailState: .loaded(.artist(detail))
        )
        XCTAssertEqual(selection, .pinnedItem(item.id))
    }

    func testAlbumTrackAndLikedSongsRoutes() {
        let album = PinnedItem.album(
            SpotifyArtistAlbum(
                id: "alb",
                name: "Album",
                imageURL: nil,
                releaseYear: "2024",
                totalTracks: 10,
                group: .album,
                uri: "spotify:album:alb"
            )
        )
        if case let .selectAlbum(id, title, subtitle, artwork)? = PlaylistBrowserPinnedItemActivation.route(
            for: album,
            previousSelection: nil
        ) {
            XCTAssertEqual(id, "alb")
            XCTAssertEqual(title, "Album")
            XCTAssertEqual(subtitle, album.subtitle)
            XCTAssertEqual(artwork, album.artworkURL)
        } else {
            XCTFail("expected album route")
        }

        let track = PinnedItem.track(
            PlaylistBrowsingTestFixtures.fallbackTrack(id: "t1", name: "Track", artistId: "a1")
        )
        if case let .playTrack(uri, revert)? = PlaylistBrowserPinnedItemActivation.route(
            for: track,
            previousSelection: .home
        ) {
            XCTAssertEqual(uri, track.spotifyURI)
            XCTAssertEqual(revert, .home)
        } else {
            XCTFail("expected track route")
        }

        XCTAssertEqual(
            PlaylistBrowserPinnedItemActivation.route(
                for: PinnedItem.likedSongs(ownerDisplay: "You", artworkURL: nil),
                previousSelection: nil
            ),
            .likedSongs
        )

    }
}
