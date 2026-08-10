import XCTest

@testable import Spotiglass

@MainActor
final class PlaylistBrowserConcurrencyTests: XCTestCase {

    func testConcurrentSelectArtistCoalescesSingleNetworkChain() async {
        let page1 = SpotifyArtistAlbum(
            id: "alb-1", name: "First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album,
            uri: "spotify:album:alb-1"
        )
        let page2 = SpotifyArtistAlbum(
            id: "alb-2", name: "Second", imageURL: nil, releaseYear: "2023", totalTracks: 1, group: .album,
            uri: "spotify:album:alb-2"
        )
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistAlbumsPageHandler: { _, _, _, offset, _ in
                try await Task.sleep(nanoseconds: 50_000_000)
                if offset == 0 {
                    return SpotifyAPIClient.SpotifyArtistAlbumsPage(
                        items: [page1],
                        next: URL(string: "https://api.spotify.com/v1/artists/artist-xyz/albums?offset=10&limit=10")
                    )
                }
                return SpotifyAPIClient.SpotifyArtistAlbumsPage(items: [page2], next: nil)
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        async let first: Void = viewModel.selectArtist(id: "artist-xyz")
        async let second: Void = viewModel.selectArtist(id: "artist-xyz")
        _ = await (first, second)

        XCTAssertEqual(
            api.artistAlbumsPageCallCount, 2, "Concurrent same-artist opens should share one in-flight artist load.")
    }

    func testSelectArtistWithinTTLUsesCachedSnapshotWithoutRefetch() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistAlbumsPageHandler: { _, _, _, offset, _ in
                if offset == 0 {
                    return SpotifyAPIClient.SpotifyArtistAlbumsPage(
                        items: [
                            SpotifyArtistAlbum(
                                id: "alb-1", name: "First", imageURL: nil, releaseYear: "2024", totalTracks: 1,
                                group: .album, uri: "spotify:album:alb-1")
                        ],
                        next: nil
                    )
                }
                return SpotifyAPIClient.SpotifyArtistAlbumsPage(items: [], next: nil)
            }
        )
        let viewModel = PlaylistBrowserViewModel(
            api: api, cache: MockBrowsingCache(), now: { now }, artistDetailCacheTTL: 120)

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")
        let firstCount = api.artistAlbumsPageCallCount
        now = now.addingTimeInterval(30)
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(
            api.artistAlbumsPageCallCount, 1, "Reopening same artist within TTL should reuse cached snapshot.")
    }

    func testLoadMoreArtistAlbumsFetchesOneAdditionalPageOnDemand() async {
        let nextURL = URL(string: "https://api.spotify.com/v1/artists/artist-xyz/albums?offset=10&limit=10")!
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistAlbumsPageHandler: { _, _, _, offset, providedNext in
                if offset == 0 {
                    return SpotifyAPIClient.SpotifyArtistAlbumsPage(
                        items: [
                            SpotifyArtistAlbum(
                                id: "alb-1", name: "First", imageURL: nil, releaseYear: "2024", totalTracks: 1,
                                group: .album, uri: "spotify:album:alb-1")
                        ],
                        next: nextURL
                    )
                }
                XCTAssertEqual(providedNext, nextURL)
                return SpotifyAPIClient.SpotifyArtistAlbumsPage(
                    items: [
                        SpotifyArtistAlbum(
                            id: "alb-2", name: "Second", imageURL: nil, releaseYear: "2023", totalTracks: 1,
                            group: .single, uri: "spotify:album:alb-2")
                    ],
                    next: nil
                )
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache(), initialArtistAlbumPageCount: 1)

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")
        XCTAssertEqual(api.artistAlbumsPageCallCount, 1)
        await viewModel.loadMoreArtistAlbums()
        XCTAssertEqual(api.artistAlbumsPageCallCount, 2, "Load more should fetch exactly one additional albums page.")
    }

    func testSignOutClearsBrowsingState() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        viewModel.clearForSignOut()

        XCTAssertNil(viewModel.selectedPlaylistID)
        guard case .empty(let playlistMessage) = viewModel.playlistState else {
            return XCTFail("Expected signed-out empty playlist state")
        }
        XCTAssertEqual(playlistMessage, "Connect Spotify to browse playlists.")
    }
}
