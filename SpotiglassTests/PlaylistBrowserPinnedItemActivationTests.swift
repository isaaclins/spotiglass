import XCTest

@testable import Spotiglass

@MainActor
final class PlaylistBrowserPinnedItemActivationTests: XCTestCase {
    func testRoutesForPinnedKinds() {
        let playlist = PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "p", name: "P"))
        XCTAssertEqual(
            PlaylistBrowserPinnedItemActivation.route(for: playlist, previousSelection: nil),
            .selectPlaylist("p")
        )

        let artist = PinnedItem.artist(
            SpotifyArtistDetail(
                id: "a", name: "A", imageURL: nil, followersTotal: nil, genres: [], uri: "spotify:artist:a")
        )
        if case .selectArtist(let id, let name)? = PlaylistBrowserPinnedItemActivation.route(
            for: artist, previousSelection: nil)
        {
            XCTAssertEqual(id, "a")
            XCTAssertEqual(name, "A")
        } else {
            XCTFail("expected artist route")
        }

        let stale = PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "s", name: "S"))
        var copy = stale
        copy.isStale = true
        if case .staleRevert(let selection)? = PlaylistBrowserPinnedItemActivation.route(
            for: copy, previousSelection: .home)
        {
            XCTAssertEqual(selection, .home)
        } else {
            XCTFail("expected stale revert")
        }
    }

    func testSidebarSelectionAfterActivationWhenLoaded() {
        let item = PinnedItem.artist(
            SpotifyArtistDetail(
                id: "a", name: "A", imageURL: nil, followersTotal: nil, genres: [], uri: "spotify:artist:a")
        )
        let detail = ArtistDetailViewModel(
            artist: SpotifyArtistDetail(
                id: "a", name: "A", imageURL: nil, followersTotal: nil, genres: [], uri: "spotify:artist:a"),
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
        if case .selectAlbum(let id, let title, let subtitle, let artwork)? = PlaylistBrowserPinnedItemActivation.route(
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
        if case .playTrack(let uri, let revert)? = PlaylistBrowserPinnedItemActivation.route(
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
