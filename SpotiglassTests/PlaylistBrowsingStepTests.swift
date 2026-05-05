import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowsingStepTests: XCTestCase {
    func testSelectLikedSongsLoadsSavedTracks() async {
        let liked = Self.track(id: "liked-one")
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [liked], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)

        XCTAssertEqual(viewModel.sidebarSelection, .likedSongs)
        XCTAssertEqual(Self.playlistTracks(viewModel.detailState).map(\.title), ["Track liked-one"])
    }

    func testInitialLoadTransitionsToLoadedPlaylistAndTracks() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()

        XCTAssertEqual(viewModel.selectedPlaylistID, "one")
        XCTAssertEqual(viewModel.playlistState.currentValue?.map(\.title), ["One"])
        XCTAssertEqual(Self.playlistTracks(viewModel.detailState).map(\.title), ["Track track-one"])
    }

    func testCachedLoadUsesCacheWhenRefreshFails() async {
        let api = MockBrowsingAPI(
            playlistResults: [.failure(SpotifyAPIError.network("Offline"))],
            trackResults: [:]
        )
        let cache = MockBrowsingCache(cachedPlaylists: [Self.playlist(id: "cached", name: "Cached")])
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache)

        await viewModel.load()

        guard case let .staleCache(playlists, error) = viewModel.playlistState else {
            return XCTFail("Expected stale cached playlists")
        }
        XCTAssertEqual(playlists.map(\.title), ["Cached"])
        XCTAssertEqual(error?.title, "Network unavailable")
    }

    func testRefreshSuccessPreservesSelectionWhenPlaylistStillExists() async {
        let api = MockBrowsingAPI(
            playlistResults: [
                .success([Self.playlist(id: "one", name: "One"), Self.playlist(id: "two", name: "Two")]),
                .success([Self.playlist(id: "two", name: "Two Updated"), Self.playlist(id: "three", name: "Three")])
            ],
            trackResults: [
                "one": [.success([Self.track(id: "track-one")])],
                "two": [.success([Self.track(id: "track-two")]), .success([Self.track(id: "track-two-updated")])]
            ]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectPlaylist(id: "two")
        await viewModel.refreshPlaylists()

        XCTAssertEqual(viewModel.selectedPlaylistID, "two")
        XCTAssertEqual(viewModel.playlistState.currentValue?.map(\.title), ["Two Updated", "Three"])
        XCTAssertEqual(Self.playlistTracks(viewModel.detailState).map(\.title), ["Track track-two-updated"])
    }

    func testRefreshFailureWithoutCacheShowsErrorState() async {
        let api = MockBrowsingAPI(
            playlistResults: [.failure(SpotifyAPIError.rateLimited(retryAfter: 12))],
            trackResults: [:]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()

        guard case let .error(error) = viewModel.playlistState else {
            return XCTFail("Expected error state")
        }
        XCTAssertEqual(error.title, "Spotify is rate limiting requests")
        XCTAssertTrue(error.canRetry)
    }

    func testEmptyPlaylistLibraryShowsEmptyStates() async {
        let api = MockBrowsingAPI(playlistResults: [.success([])], trackResults: [:])
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()

        guard case let .empty(playlistMessage) = viewModel.playlistState else {
            return XCTFail("Expected empty playlist state")
        }
        XCTAssertEqual(playlistMessage, "Your Spotify library has no playlists yet.")
        XCTAssertNil(viewModel.selectedPlaylistID)
    }

    func testSelectedPlaylistDisappearingIsHandledCleanly() async {
        let api = MockBrowsingAPI(
            playlistResults: [
                .success([Self.playlist(id: "one", name: "One"), Self.playlist(id: "two", name: "Two")]),
                .success([Self.playlist(id: "one", name: "One")])
            ],
            trackResults: [
                "one": [.success([Self.track(id: "track-one")]), .success([Self.track(id: "track-one-new")])],
                "two": [.success([Self.track(id: "track-two")])]
            ]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectPlaylist(id: "two")
        await viewModel.refreshPlaylists()

        XCTAssertEqual(viewModel.selectedPlaylistID, "one")
        XCTAssertEqual(Self.playlistTracks(viewModel.detailState).map(\.title), ["Track track-one-new"])
    }

    func testDetailUsesCachedTracksThenSurfacesRefreshError() async {
        let playlist = Self.playlist(id: "one", name: "One", snapshotID: "snapshot")
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlist])],
            trackResults: ["one": [.failure(SpotifyAPIError.forbidden(message: "No access", details: "status 403"))]]
        )
        let cache = MockBrowsingCache(cachedTracks: ["one": [Self.track(id: "cached")]])
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache)

        await viewModel.load()

        guard case let .staleCache(.playlist(detail), error) = viewModel.detailState else {
            return XCTFail("Expected stale cached detail")
        }
        XCTAssertEqual(detail.tracks.map(\.title), ["Track cached"])
        XCTAssertEqual(error?.title, "Access denied")
    }

    func testDetailUsesCachedTracksThenSurfacesInvalidLimitError() async {
        let playlist = Self.playlist(id: "one", name: "One", snapshotID: "snapshot")
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlist])],
            trackResults: ["one": [.failure(SpotifyAPIError.badRequest(message: "Invalid limit", details: nil))]]
        )
        let cache = MockBrowsingCache(cachedTracks: ["one": [Self.track(id: "cached")]])
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache)

        await viewModel.load()

        guard case let .staleCache(.playlist(detail), error) = viewModel.detailState else {
            return XCTFail("Expected stale cached detail")
        }
        XCTAssertEqual(detail.tracks.map(\.title), ["Track cached"])
        XCTAssertEqual(error?.title, "Spotify rejected the request")
        XCTAssertEqual(error?.message, "Invalid limit")
    }

    func testExpiredPlaylistCacheStillRendersImmediatelyThenRefreshes() async {
        let playlist = Self.playlist(id: "one", name: "One", snapshotID: "snapshot")
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlist])],
            trackResults: ["one": [.success([Self.track(id: "fresh-track")])]]
        )
        let cache = MockBrowsingCache(
            cachedTracks: ["one": [Self.track(id: "stale-track")]],
            expiredTrackIDs: ["one"]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache)

        await viewModel.load()

        XCTAssertEqual(Self.playlistTracks(viewModel.detailState).map(\.title), ["Track fresh-track"])
        XCTAssertEqual(cache.savedTracks["one"]?.map(\.id), ["fresh-track"])
    }

    func testExpiredLikedSongsCacheStillRendersImmediatelyThenRefreshes() async {
        let likedStale = Self.track(id: "liked-stale")
        let likedFresh = Self.track(id: "liked-fresh")
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [likedFresh], totalAvailable: 1))
        )
        let cache = MockBrowsingCache(
            cachedTracks: [SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID: [likedStale]],
            expiredTrackIDs: [SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache)

        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)

        XCTAssertEqual(Self.playlistTracks(viewModel.detailState).map(\.title), ["Track liked-fresh"])
        XCTAssertEqual(
            cache.savedTracks[SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID]?.map(\.id),
            ["liked-fresh"]
        )
    }

    func testInsufficientScopeMapsToReconnectGuidance() async {
        let playlist = Self.playlist(id: "one", name: "One", snapshotID: "snapshot")
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlist])],
            trackResults: ["one": [.failure(SpotifyAPIError.insufficientScope(
                requiredScopes: ["playlist-read-private", "playlist-read-collaborative"],
                message: "Insufficient client scope",
                details: "status 403 insufficient scope"
            ))]]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()

        guard case let .error(error) = viewModel.detailState else {
            return XCTFail("Expected insufficient-scope error state")
        }
        XCTAssertEqual(error.title, "Reconnect Spotify")
        XCTAssertEqual(error.message, "Your current Spotify session is missing playlist or Liked Songs permissions. Disconnect and connect again to grant required scopes.")
        XCTAssertEqual(error.diagnosticDetails, "status 403 insufficient scope")
        XCTAssertFalse(error.canRetry)
    }

    func testTrackLoadRespectsSpotifyMaxItemsLimit() async {
        let api = LimitCapturingBrowsingAPI(
            playlists: [Self.playlist(id: "one", name: "One")],
            tracks: [Self.track(id: "track-one")]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()

        XCTAssertEqual(api.lastTracksLimit, 50, "Spotify's /v1/playlists/{id}/items endpoint caps limit at 50; passing more than 50 returns HTTP 400.")
        XCTAssertLessThanOrEqual(api.lastTracksLimit ?? Int.max, 50)
    }

    func testSelectArtistClearsPlaylistSelectionAndShowsArtistDetail() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        XCTAssertEqual(viewModel.selectedPlaylistID, "one")

        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertNil(viewModel.selectedPlaylistID)
        guard case let .loaded(.artist(detail)) = viewModel.detailState else {
            return XCTFail("Expected loaded artist detail")
        }
        XCTAssertEqual(detail.artist.id, "artist-xyz")
        XCTAssertEqual(detail.artist.name, "Artist artist-xyz")
        XCTAssertEqual(detail.tracks.count, 1)
        XCTAssertEqual(detail.tracks.first?.title, "Hit")
    }

    /// Mirrors `List` + `.onChange(of: sidebarSelection)` calling `selectPlaylist(nil)` after `selectArtist` clears sidebar selection.
    func testSelectArtistSurvivesSubsequentSelectPlaylistNilFromSidebarOnChange() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")
        await viewModel.selectPlaylist(id: nil)

        XCTAssertNil(viewModel.selectedPlaylistID)
        guard case let .loaded(.artist(detail)) = viewModel.detailState else {
            return XCTFail("Expected loaded artist detail after simulated onChange(nil)")
        }
        XCTAssertEqual(detail.artist.id, "artist-xyz")
    }

    func testArtistDetailFallsBackToSearchWhenTopTracksForbidden() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                throw SpotifyAPIError.forbidden(message: "Forbidden", details: "")
            },
            searchHandler: { _, _ in
                SpotifySearchResults(
                    tracks: [
                        SpotifyTrack(
                            id: "search-hit",
                            name: "Search Hit",
                            artists: ["Artist artist-xyz"],
                            artistRefs: [SpotifyArtistRef(id: "artist-xyz", name: "Artist artist-xyz")],
                            albumArtworkURL: nil,
                            durationMilliseconds: 100_000,
                            isExplicit: false,
                            isPlayable: true,
                            linkedFromID: nil,
                            uri: "spotify:track:search-hit"
                        )
                    ],
                    artists: [],
                    albums: [],
                    playlists: []
                )
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        guard case let .loaded(.artist(detail)) = viewModel.detailState else {
            return XCTFail("Expected loaded artist detail")
        }
        XCTAssertEqual(detail.tracks.count, 1)
        XCTAssertEqual(detail.tracks.first?.title, "Search Hit")
    }

    func testArtistDetailFallsBackToAlbumsWhenTopTracksForbiddenAndSearchEmpty() async {
        let coverB = URL(string: "https://example.com/b.jpg")!
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                throw SpotifyAPIError.forbidden(message: "Forbidden", details: "")
            },
            searchHandler: { _, _ in
                SpotifySearchResults(
                    tracks: [
                        SpotifyTrack(
                            id: "wrong",
                            name: "Wrong artist",
                            artists: ["Other"],
                            artistRefs: [SpotifyArtistRef(id: "other-artist", name: "Other")],
                            albumArtworkURL: nil,
                            durationMilliseconds: 100_000,
                            isExplicit: false,
                            isPlayable: true,
                            linkedFromID: nil,
                            uri: "spotify:track:wrong"
                        )
                    ],
                    artists: [],
                    albums: [],
                    playlists: []
                )
            },
            artistAlbumsHandler: { _, _, _ in
                [
                    SpotifyArtistAlbum(
                        id: "alb-b",
                        name: "Single 2021",
                        imageURL: coverB,
                        releaseYear: "2021",
                        totalTracks: 3,
                        group: .single,
                        uri: "spotify:album:alb-b"
                    ),
                    SpotifyArtistAlbum(
                        id: "alb-a",
                        name: "Album 2020",
                        imageURL: nil,
                        releaseYear: "2020",
                        totalTracks: 3,
                        group: .album,
                        uri: "spotify:album:alb-a"
                    )
                ]
            },
            albumTracksHandler: { albumID, _, _ in
                let aid = "artist-xyz"
                switch albumID {
                case "alb-b":
                    return [
                        Self.fallbackTrack(id: "t1", name: "A1", artistId: aid),
                        Self.fallbackTrack(id: "t2", name: "A2", artistId: aid),
                        Self.fallbackTrack(id: "t3", name: "Dup", artistId: aid)
                    ]
                case "alb-a":
                    return [
                        Self.fallbackTrack(id: "t4", name: "B1", artistId: aid),
                        Self.fallbackTrack(id: "t5", name: "B2", artistId: aid),
                        Self.fallbackTrack(id: "t6", name: "Dup", artistId: aid)
                    ]
                default:
                    return []
                }
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        guard case let .loaded(.artist(detail)) = viewModel.detailState else {
            return XCTFail("Expected loaded artist detail")
        }
        XCTAssertEqual(detail.tracks.map(\.title), ["A1", "A2", "Dup", "B1", "B2"])
        XCTAssertEqual(detail.tracks.first?.artworkURL, coverB)
    }

    func testSelectArtistSurfacesBadRequestWithCopyableDetails() async {
        let diagnosticDump = """
        GET https://api.spotify.com/v1/artists/x/albums?limit=50
        HTTP 400

        Response body:
        {"error":{"status":400,"message":"Invalid limit"}}
        """
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            artistAlbumsHandler: { _, _, _ in
                throw SpotifyAPIError.badRequest(message: "Invalid limit", details: diagnosticDump)
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-x")

        guard case let .error(error) = viewModel.detailState else {
            return XCTFail("Expected error detail state")
        }
        XCTAssertEqual(error.title, "Spotify rejected the request")
        XCTAssertEqual(error.message, "Invalid limit")
        XCTAssertFalse(error.canRetry)
        XCTAssertEqual(error.diagnosticDetails, diagnosticDump)
    }

    func testSignOutClearsBrowsingState() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        viewModel.clearForSignOut()

        XCTAssertNil(viewModel.selectedPlaylistID)
        guard case let .empty(playlistMessage) = viewModel.playlistState else {
            return XCTFail("Expected signed-out empty playlist state")
        }
        XCTAssertEqual(playlistMessage, "Connect Spotify to browse playlists.")
    }

    private static func playlistTracks(_ state: BrowsingLoadState<BrowsingDetailContent>) -> [TrackRowViewModel] {
        guard let content = state.currentValue else { return [] }
        if case let .playlist(detail) = content {
            return detail.tracks
        }
        return []
    }

    private static func playlist(id: String, name: String, snapshotID: String = "snapshot-\(UUID().uuidString)") -> SpotifyPlaylistSummary {
        SpotifyPlaylistSummary(
            id: id,
            name: name,
            description: nil,
            ownerName: "Owner",
            imageURL: nil,
            trackCount: 1,
            isPublic: nil,
            isCollaborative: false,
            snapshotID: snapshotID
        )
    }

    private static func fallbackTrack(id: String, name: String, artistId: String) -> SpotifyTrack {
        SpotifyTrack(
            id: id,
            name: name,
            artists: ["Artist \(artistId)"],
            artistRefs: [SpotifyArtistRef(id: artistId, name: "Artist \(artistId)")],
            albumArtworkURL: nil,
            durationMilliseconds: 100_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:\(id)"
        )
    }

    private static func track(id: String) -> SpotifyPlaylistTrackItem {
        SpotifyPlaylistTrackItem(
            id: id,
            addedAt: nil,
            content: .track(SpotifyTrack(
                id: id,
                name: "Track \(id)",
                artists: ["Artist"],
                albumArtworkURL: nil,
                durationMilliseconds: 180_000,
                isExplicit: false,
                isPlayable: true,
                linkedFromID: nil,
                uri: "spotify:track:\(id)"
            ))
        )
    }
}

private final class LimitCapturingBrowsingAPI: SpotifyBrowsingAPI {
    let playlists: [SpotifyPlaylistSummary]
    let tracks: [SpotifyPlaylistTrackItem]
    private(set) var lastTracksLimit: Int?

    init(playlists: [SpotifyPlaylistSummary], tracks: [SpotifyPlaylistTrackItem]) {
        self.playlists = playlists
        self.tracks = tracks
    }

    func currentUserProfile() async throws -> SpotifyUserProfile {
        SpotifyUserProfile(id: "u", displayName: nil, imageURL: nil, country: "US", product: .premium)
    }

    func artist(id: String) async throws -> SpotifyArtistDetail {
        SpotifyArtistDetail(id: id, name: "Artist \(id)", imageURL: nil, followersTotal: nil, genres: [], uri: "spotify:artist:\(id)")
    }

    func artistTopTracks(id: String, market: String?) async throws -> [SpotifyTrack] {
        []
    }

    func search(query: String, limit: Int) async throws -> SpotifySearchResults {
        SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
    }

    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [SpotifyTrack] {
        []
    }

    func artistAlbums(id: String, includeGroups: String, limit: Int) async throws -> [SpotifyArtistAlbum] {
        []
    }

    func currentUserPlaylists(limit: Int) async throws -> [SpotifyPlaylistSummary] {
        playlists
    }

    func playlistTracks(playlistID: String, limit: Int) async throws -> [SpotifyPlaylistTrackItem] {
        lastTracksLimit = limit
        return tracks
    }

    func currentUserSavedTracks(limit: Int, maxPages: Int) async throws -> SpotifySavedTracksResult {
        SpotifySavedTracksResult(tracks: [], totalAvailable: 0)
    }
}

private final class MockBrowsingAPI: SpotifyBrowsingAPI {
    private var playlistResults: [Result<[SpotifyPlaylistSummary], Error>]
    private var trackResults: [String: [Result<[SpotifyPlaylistTrackItem], Error>]]

    private let artistTopTracksHandler: ((String, String?) async throws -> [SpotifyTrack])?
    private let searchHandler: ((String, Int) async throws -> SpotifySearchResults)?
    private let artistAlbumsHandler: ((String, String, Int) async throws -> [SpotifyArtistAlbum])?
    private let albumTracksHandler: ((String, String?, Int) async throws -> [SpotifyTrack])?
    private let savedTracksResult: Result<SpotifySavedTracksResult, Error>?

    init(
        playlistResults: [Result<[SpotifyPlaylistSummary], Error>],
        trackResults: [String: [Result<[SpotifyPlaylistTrackItem], Error>]],
        artistTopTracksHandler: ((String, String?) async throws -> [SpotifyTrack])? = nil,
        searchHandler: ((String, Int) async throws -> SpotifySearchResults)? = nil,
        artistAlbumsHandler: ((String, String, Int) async throws -> [SpotifyArtistAlbum])? = nil,
        albumTracksHandler: ((String, String?, Int) async throws -> [SpotifyTrack])? = nil,
        savedTracksResult: Result<SpotifySavedTracksResult, Error>? = nil
    ) {
        self.playlistResults = playlistResults
        self.trackResults = trackResults
        self.artistTopTracksHandler = artistTopTracksHandler
        self.searchHandler = searchHandler
        self.artistAlbumsHandler = artistAlbumsHandler
        self.albumTracksHandler = albumTracksHandler
        self.savedTracksResult = savedTracksResult
    }

    func currentUserPlaylists(limit: Int) async throws -> [SpotifyPlaylistSummary] {
        guard !playlistResults.isEmpty else { return [] }
        return try playlistResults.removeFirst().get()
    }

    func playlistTracks(playlistID: String, limit: Int) async throws -> [SpotifyPlaylistTrackItem] {
        guard var results = trackResults[playlistID], !results.isEmpty else { return [] }
        let result = results.removeFirst()
        trackResults[playlistID] = results
        return try result.get()
    }

    func currentUserProfile() async throws -> SpotifyUserProfile {
        SpotifyUserProfile(id: "u", displayName: nil, imageURL: nil, country: "US", product: .premium)
    }

    func artist(id: String) async throws -> SpotifyArtistDetail {
        SpotifyArtistDetail(id: id, name: "Artist \(id)", imageURL: nil, followersTotal: 1_000, genres: ["pop"], uri: "spotify:artist:\(id)")
    }

    func artistTopTracks(id: String, market: String?) async throws -> [SpotifyTrack] {
        if let artistTopTracksHandler {
            return try await artistTopTracksHandler(id, market)
        }
        return [
            SpotifyTrack(
                id: "hit-\(id)",
                name: "Hit",
                artists: ["Artist \(id)"],
                artistRefs: [SpotifyArtistRef(id: id, name: "Artist \(id)")],
                albumArtworkURL: nil,
                durationMilliseconds: 200_000,
                isExplicit: false,
                isPlayable: true,
                linkedFromID: nil,
                uri: "spotify:track:hit-\(id)"
            )
        ]
    }

    func search(query: String, limit: Int) async throws -> SpotifySearchResults {
        if let searchHandler {
            return try await searchHandler(query, limit)
        }
        return SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
    }

    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [SpotifyTrack] {
        if let albumTracksHandler {
            return try await albumTracksHandler(albumID, market, limit)
        }
        return []
    }

    func artistAlbums(id: String, includeGroups: String, limit: Int) async throws -> [SpotifyArtistAlbum] {
        if let artistAlbumsHandler {
            return try await artistAlbumsHandler(id, includeGroups, limit)
        }
        return []
    }

    func currentUserSavedTracks(limit: Int, maxPages: Int) async throws -> SpotifySavedTracksResult {
        if let savedTracksResult {
            return try savedTracksResult.get()
        }
        return SpotifySavedTracksResult(tracks: [], totalAvailable: 0)
    }
}

private final class MockBrowsingCache: SpotifyBrowsingCache {
    var cachedPlaylists: [SpotifyPlaylistSummary]?
    var cachedTracks: [String: [SpotifyPlaylistTrackItem]]
    /// Simulated age of the playlist list on disk; large values force `load()` to call `refreshPlaylists()` so tests exercise network refresh.
    var playlistListCacheAge: TimeInterval
    /// Track caches treated as TTL-expired by `loadTracks(...)` but still
    /// available to `loadTracksIgnoringAge(...)`.
    var expiredTrackIDs: Set<String>
    private(set) var savedPlaylists: [SpotifyPlaylistSummary]?
    private(set) var savedTracks: [String: [SpotifyPlaylistTrackItem]] = [:]

    init(
        cachedPlaylists: [SpotifyPlaylistSummary]? = nil,
        cachedTracks: [String: [SpotifyPlaylistTrackItem]] = [:],
        playlistListCacheAge: TimeInterval = 10_000,
        expiredTrackIDs: Set<String> = []
    ) {
        self.cachedPlaylists = cachedPlaylists
        self.cachedTracks = cachedTracks
        self.playlistListCacheAge = playlistListCacheAge
        self.expiredTrackIDs = expiredTrackIDs
    }

    func loadPlaylists(now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistSummary]? {
        cachedPlaylists
    }

    func loadPlaylistsBundle(now: Date) throws -> (playlists: [SpotifyPlaylistSummary], age: TimeInterval)? {
        guard let playlists = cachedPlaylists, !playlists.isEmpty else { return nil }
        return (playlists, playlistListCacheAge)
    }

    func savePlaylists(_ playlists: [SpotifyPlaylistSummary], cachedAt: Date) throws {
        savedPlaylists = playlists
        cachedPlaylists = playlists
    }

    func loadTracks(playlistID: String, snapshotID: String, now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistTrackItem]? {
        if expiredTrackIDs.contains(playlistID) {
            return nil
        }
        return cachedTracks[playlistID]
    }

    func loadTracksIgnoringAge(playlistID: String, snapshotID: String) throws -> [SpotifyPlaylistTrackItem]? {
        return cachedTracks[playlistID]
    }

    func saveTracks(_ tracks: [SpotifyPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws {
        savedTracks[playlistID] = tracks
        cachedTracks[playlistID] = tracks
    }

    func invalidateTracks(playlistID: String) throws {
        cachedTracks[playlistID] = nil
    }
}
