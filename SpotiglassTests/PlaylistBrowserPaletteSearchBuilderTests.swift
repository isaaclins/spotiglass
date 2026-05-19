import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserPaletteSearchBuilderTests: XCTestCase {
    private func recordingEnvironment() -> (
        PlaylistBrowserPaletteSearchEnvironment,
        [String],
        [PinnedItem],
        [String]
    ) {
        var pinnedIDs: [String] = []
        var pinnedItems: [PinnedItem] = []
        var playedURIs: [String] = []
        let env = PlaylistBrowserPaletteSearchEnvironment(
            isPinnedByID: { pinnedIDs.contains($0) },
            pin: { pinnedItems.append($0); pinnedIDs.append($0.id) },
            unpin: { id in pinnedIDs.removeAll { $0 == id } },
            playURI: { playedURIs.append($0) },
            openPlaylist: { _ in },
            openArtist: { _ in },
            addToQueue: { _ in }
        )
        return (env, playedURIs, pinnedItems, pinnedIDs)
    }

    func testInPlaylistMatchesFiltersByScoreAndSorts() async {
        let (env, played, _, _) = recordingEnvironment()
        let rows = [
            TrackRowViewModel(
                topTrack: PlaylistBrowsingTestFixtures.fallbackTrack(id: "a", name: "Alpha Song", artistId: "ar"),
                listPosition: 1
            ),
            TrackRowViewModel(
                topTrack: PlaylistBrowsingTestFixtures.fallbackTrack(id: "b", name: "Beta Song", artistId: "ar"),
                listPosition: 2
            ),
        ]
        let matches = PlaylistBrowserPaletteSearchBuilder.inPlaylistMatches(
            from: rows,
            trimmedQuery: "alpha",
            environment: env
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.title, "Alpha Song")
        XCTAssertNotNil(matches.first?.queueAction)
    }

    func testLocalLibraryPlaylistMatches() {
        let (env, _, _, _) = recordingEnvironment()
        let row = PlaylistRowViewModel(
            PlaylistBrowsingTestFixtures.playlist(id: "pl1", name: "Focus Flow")
        )
        let items = PlaylistBrowserPaletteSearchBuilder.localLibraryPlaylistMatches(
            visiblePlaylists: [row],
            trimmedQuery: "focus",
            environment: env
        )
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Focus Flow")
    }

    func testThisPlaylistCategoryReturnsOnlyLocalMatches() async throws {
        let (env, _, _, _) = recordingEnvironment()
        let rows = [
            TrackRowViewModel(
                topTrack: PlaylistBrowsingTestFixtures.fallbackTrack(id: "t1", name: "Local Hit", artistId: "a"),
                listPosition: 1
            ),
        ]
        let http = QueueHTTPClient([.json(#"{"tracks":{"items":[]},"artists":{"items":[]},"albums":{"items":[]},"playlists":{"items":[]}}"#)])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "tok"),
            httpClient: http
        )
        let result = try await PlaylistBrowserPaletteSearchBuilder.search(
            query: "local",
            category: .thisPlaylist,
            spotifySearchClient: client,
            environment: env,
            loadedContextTracks: rows,
            visiblePlaylists: []
        )
        XCTAssertEqual(result.inPlaylistMatches.count, 1)
        XCTAssertTrue(result.tracks.isEmpty)
        XCTAssertTrue(result.myPlaylists.isEmpty)
    }

    func testMyPlaylistsCategorySkipsNetworkSearch() async throws {
        let (env, _, _, _) = recordingEnvironment()
        let row = PlaylistRowViewModel(
            PlaylistBrowsingTestFixtures.playlist(id: "mine", name: "Mine")
        )
        let http = QueueHTTPClient([])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "tok"),
            httpClient: http
        )
        let result = try await PlaylistBrowserPaletteSearchBuilder.search(
            query: "mine",
            category: .myPlaylists,
            spotifySearchClient: client,
            environment: env,
            loadedContextTracks: nil,
            visiblePlaylists: [row]
        )
        XCTAssertEqual(result.myPlaylists.count, 1)
        XCTAssertTrue(http.requests.isEmpty)
    }
}
