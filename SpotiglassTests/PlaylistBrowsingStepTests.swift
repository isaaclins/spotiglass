import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowsingStepTests: XCTestCase {
    func testInitialLoadTransitionsToLoadedPlaylistAndTracks() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()

        XCTAssertEqual(viewModel.selectedPlaylistID, "one")
        XCTAssertEqual(viewModel.playlistState.currentValue?.map(\.title), ["One"])
        XCTAssertEqual(viewModel.detailState.currentValue?.tracks.map(\.title), ["Track track-one"])
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
        XCTAssertEqual(viewModel.detailState.currentValue?.tracks.map(\.title), ["Track track-two-updated"])
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
        XCTAssertEqual(viewModel.detailState.currentValue?.tracks.map(\.title), ["Track track-one-new"])
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

        guard case let .staleCache(detail, error) = viewModel.detailState else {
            return XCTFail("Expected stale cached detail")
        }
        XCTAssertEqual(detail.tracks.map(\.title), ["Track cached"])
        XCTAssertEqual(error?.title, "Access denied")
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
        XCTAssertEqual(error.message, "Your current Spotify session is missing playlist permissions. Disconnect and connect again to grant required scopes.")
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

    func currentUserPlaylists(limit: Int) async throws -> [SpotifyPlaylistSummary] {
        playlists
    }

    func playlistTracks(playlistID: String, limit: Int) async throws -> [SpotifyPlaylistTrackItem] {
        lastTracksLimit = limit
        return tracks
    }
}

private final class MockBrowsingAPI: SpotifyBrowsingAPI {
    private var playlistResults: [Result<[SpotifyPlaylistSummary], Error>]
    private var trackResults: [String: [Result<[SpotifyPlaylistTrackItem], Error>]]

    init(
        playlistResults: [Result<[SpotifyPlaylistSummary], Error>],
        trackResults: [String: [Result<[SpotifyPlaylistTrackItem], Error>]]
    ) {
        self.playlistResults = playlistResults
        self.trackResults = trackResults
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
}

private final class MockBrowsingCache: SpotifyBrowsingCache {
    var cachedPlaylists: [SpotifyPlaylistSummary]?
    var cachedTracks: [String: [SpotifyPlaylistTrackItem]]
    private(set) var savedPlaylists: [SpotifyPlaylistSummary]?
    private(set) var savedTracks: [String: [SpotifyPlaylistTrackItem]] = [:]

    init(
        cachedPlaylists: [SpotifyPlaylistSummary]? = nil,
        cachedTracks: [String: [SpotifyPlaylistTrackItem]] = [:]
    ) {
        self.cachedPlaylists = cachedPlaylists
        self.cachedTracks = cachedTracks
    }

    func loadPlaylists(now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistSummary]? {
        cachedPlaylists
    }

    func savePlaylists(_ playlists: [SpotifyPlaylistSummary], cachedAt: Date) throws {
        savedPlaylists = playlists
        cachedPlaylists = playlists
    }

    func loadTracks(playlistID: String, snapshotID: String, now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistTrackItem]? {
        cachedTracks[playlistID]
    }

    func saveTracks(_ tracks: [SpotifyPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws {
        savedTracks[playlistID] = tracks
        cachedTracks[playlistID] = tracks
    }

    func invalidateTracks(playlistID: String) throws {
        cachedTracks[playlistID] = nil
    }
}
