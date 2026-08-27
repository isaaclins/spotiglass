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
            openAlbum: { _, _, _, _ in },
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
            environment: env,
            currentUserSpotifyID: "owner-id"
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
            visiblePlaylists: [],
            currentUserSpotifyID: nil
        )
        XCTAssertEqual(result.inPlaylistMatches.count, 1)
        XCTAssertTrue(result.tracks.isEmpty)
        XCTAssertTrue(result.myPlaylists.isEmpty)
    }

    func testAllCategoryMapsSpotifyCatalogHits() async throws {
        let (env, _, _, _) = recordingEnvironment()
        let searchJSON = """
        {
          "tracks": {
            "items": [
              {
                "type": "track",
                "id": "track-1",
                "name": "Midnight City",
                "artists": [{ "name": "M83" }],
                "album": { "images": [] },
                "duration_ms": 240000,
                "explicit": true,
                "uri": "spotify:track:track-1"
              }
            ]
          },
          "artists": {
            "items": [
              { "id": "artist-1", "name": "M83", "images": [], "uri": "spotify:artist:artist-1" }
            ]
          },
          "albums": {
            "items": [
              {
                "id": "album-1",
                "name": "Album",
                "artists": [{ "name": "M83" }],
                "images": [],
                "uri": "spotify:album:album-1"
              }
            ]
          },
          "playlists": {
            "items": [
              {
                "id": "playlist-1",
                "name": "Mix",
                "owner": { "id": "o1", "display_name": "Me" },
                "images": [],
                "items": { "total": 2 },
                "snapshot_id": "snap"
              }
            ]
          }
        }
        """
        let http = QueueHTTPClient([.json(searchJSON)])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "tok"),
            httpClient: http
        )
        let result = try await PlaylistBrowserPaletteSearchBuilder.search(
            query: "midnight",
            category: .all,
            spotifySearchClient: client,
            environment: env,
            loadedContextTracks: nil,
            visiblePlaylists: [],
            currentUserSpotifyID: nil
        )
        XCTAssertEqual(result.tracks.count, 1)
        XCTAssertEqual(result.artists.count, 1)
        XCTAssertEqual(result.albums.count, 1)
        XCTAssertEqual(result.catalogPlaylists.count, 1)
    }

    func testAlbumResultActionOpensAlbumWithMetadata() async throws {
        var openedAlbum: (id: String, title: String, subtitle: String, artworkURL: URL?)?
        let environment = PlaylistBrowserPaletteSearchEnvironment(
            isPinnedByID: { _ in false },
            pin: { _ in },
            unpin: { _ in },
            playURI: { _ in },
            openPlaylist: { _ in },
            openArtist: { _ in },
            openAlbum: { id, title, subtitle, artworkURL in
                openedAlbum = (id, title, subtitle, artworkURL)
            },
            addToQueue: { _ in }
        )
        let http = QueueHTTPClient([
            .json(#"""
            {
              "albums": {
                "limit": 1,
                "next": null,
                "total": 1,
                "items": [
                  {
                    "id": "album-1",
                    "name": "Night Drive",
                    "artists": [{ "name": "M83" }],
                    "images": [{ "url": "https://example.com/album.png", "height": 640, "width": 640 }],
                    "uri": "spotify:album:album-1"
                  }
                ]
              }
            }
            """#)
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "tok"),
            httpClient: http
        )

        let result = try await PlaylistBrowserPaletteSearchBuilder.search(
            query: "night",
            category: .all,
            spotifySearchClient: client,
            environment: environment,
            loadedContextTracks: nil,
            visiblePlaylists: [],
            currentUserSpotifyID: nil
        )
        let album = try XCTUnwrap(result.albums.first)
        await album.action()

        XCTAssertEqual(
            openedAlbum?.id,
            "album-1"
        )
        XCTAssertEqual(openedAlbum?.title, "Night Drive")
        XCTAssertEqual(openedAlbum?.subtitle, "M83")
        XCTAssertEqual(openedAlbum?.artworkURL, URL(string: "https://example.com/album.png"))
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
            visiblePlaylists: [row],
            currentUserSpotifyID: "owner-id"
        )
        XCTAssertEqual(result.myPlaylists.count, 1)
        XCTAssertTrue(http.requests.isEmpty)
    }
}
