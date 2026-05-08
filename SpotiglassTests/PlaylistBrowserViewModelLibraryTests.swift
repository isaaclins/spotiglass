import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserViewModelLibraryTests: XCTestCase {
    func testSelectLikedSongsLoadsSavedTracks() async {
        let liked = PlaylistBrowsingTestFixtures.track(id: "liked-one")
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [liked], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)

        XCTAssertEqual(viewModel.sidebarSelection, .likedSongs)
        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.title), ["Track liked-one"])
    }

    func testInitialLoadTransitionsToLoadedPlaylistAndTracks() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()

        XCTAssertEqual(viewModel.selectedPlaylistID, "one")
        XCTAssertEqual(viewModel.playlistState.currentValue?.map(\.title), ["One"])
        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.title), ["Track track-one"])
    }

    func testCachedLoadUsesCacheWhenRefreshFails() async {
        let api = MockBrowsingAPI(
            playlistResults: [.failure(SpotifyAPIError.network("Offline"))],
            trackResults: [:]
        )
        let cache = MockBrowsingCache(cachedPlaylists: [PlaylistBrowsingTestFixtures.playlist(id: "cached", name: "Cached")])
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
                .success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One"), PlaylistBrowsingTestFixtures.playlist(id: "two", name: "Two")]),
                .success([PlaylistBrowsingTestFixtures.playlist(id: "two", name: "Two Updated"), PlaylistBrowsingTestFixtures.playlist(id: "three", name: "Three")])
            ],
            trackResults: [
                "one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])],
                "two": [.success([PlaylistBrowsingTestFixtures.track(id: "track-two")]), .success([PlaylistBrowsingTestFixtures.track(id: "track-two-updated")])]
            ]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectPlaylist(id: "two")
        await viewModel.refreshPlaylists()

        XCTAssertEqual(viewModel.selectedPlaylistID, "two")
        XCTAssertEqual(viewModel.playlistState.currentValue?.map(\.title), ["Two Updated", "Three"])
        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.title), ["Track track-two-updated"])
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
                .success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One"), PlaylistBrowsingTestFixtures.playlist(id: "two", name: "Two")]),
                .success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])
            ],
            trackResults: [
                "one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")]), .success([PlaylistBrowsingTestFixtures.track(id: "track-one-new")])],
                "two": [.success([PlaylistBrowsingTestFixtures.track(id: "track-two")])]
            ]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectPlaylist(id: "two")
        await viewModel.refreshPlaylists()

        XCTAssertEqual(viewModel.selectedPlaylistID, "one")
        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.title), ["Track track-one-new"])
    }

    func testDetailUsesCachedTracksThenSurfacesRefreshError() async {
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One", snapshotID: "snapshot")
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlist])],
            trackResults: ["one": [.failure(SpotifyAPIError.forbidden(message: "No access", details: "status 403"))]]
        )
        let cache = MockBrowsingCache(cachedTracks: ["one": [PlaylistBrowsingTestFixtures.track(id: "cached")]])
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache)

        await viewModel.load()

        guard case let .staleCache(.playlist(detail), error) = viewModel.detailState else {
            return XCTFail("Expected stale cached detail")
        }
        XCTAssertEqual(detail.tracks.map(\.title), ["Track cached"])
        XCTAssertEqual(error?.title, "Access denied")
    }

    func testDetailUsesCachedTracksThenSurfacesInvalidLimitError() async {
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One", snapshotID: "snapshot")
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlist])],
            trackResults: ["one": [.failure(SpotifyAPIError.badRequest(message: "Invalid limit", details: nil))]]
        )
        let cache = MockBrowsingCache(cachedTracks: ["one": [PlaylistBrowsingTestFixtures.track(id: "cached")]])
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
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One", snapshotID: "snapshot")
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlist])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "fresh-track")])]]
        )
        let cache = MockBrowsingCache(
            cachedTracks: ["one": [PlaylistBrowsingTestFixtures.track(id: "stale-track")]],
            expiredTrackIDs: ["one"]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache)

        await viewModel.load()

        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.title), ["Track fresh-track"])
        XCTAssertEqual(cache.savedTracks["one"]?.map(\.id), ["fresh-track"])
    }

    func testExpiredLikedSongsCacheStillRendersImmediatelyThenRefreshes() async {
        let likedStale = PlaylistBrowsingTestFixtures.track(id: "liked-stale")
        let likedFresh = PlaylistBrowsingTestFixtures.track(id: "liked-fresh")
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [likedFresh], totalAvailable: 1))
        )
        let cache = MockBrowsingCache(
            cachedTracks: [SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID: [likedStale]],
            expiredTrackIDs: [SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache)

        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)

        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.title), ["Track liked-fresh"])
        XCTAssertEqual(
            cache.savedTracks[SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID]?.map(\.id),
            ["liked-fresh"]
        )
    }

    func testLikedSongsFreshCacheSkipsImmediateRevalidationWithinRefreshWindow() async {
        let likedFresh = PlaylistBrowsingTestFixtures.track(id: "liked-fresh")
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [likedFresh], totalAvailable: 1))
        )
        let cache = MockBrowsingCache()
        let viewModel = PlaylistBrowserViewModel(
            api: api,
            cache: cache,
            likedSongsAutoRefreshMinInterval: 3_600
        )

        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)
        await viewModel.selectSidebar(.home)
        await viewModel.selectSidebar(.likedSongs)

        XCTAssertEqual(api.savedTracksCallCount, 1, "Fresh cache should not immediately trigger a second liked-songs revalidation.")
    }

    func testLikedSongsConcurrentSelectionsShareSingleRevalidationRequest() async {
        let liked = PlaylistBrowsingTestFixtures.track(id: "liked-shared")
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            savedTracksHandler: {
                try await Task.sleep(nanoseconds: 80_000_000)
                return SpotifySavedTracksResult(tracks: [liked], totalAvailable: 1)
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        async let first: Void = viewModel.selectSidebar(.likedSongs)
        async let second: Void = viewModel.selectSidebar(.likedSongs)
        _ = await (first, second)

        XCTAssertEqual(api.savedTracksCallCount, 1, "Concurrent liked-songs refreshes should dedupe into one in-flight request.")
    }

    func testConcurrentPlaylistRefreshesShareSingleInFlightRequest() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            playlistsHandler: {
                try await Task.sleep(nanoseconds: 120_000_000)
                return [PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")]
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectSidebar(.home)
        async let first: Void = viewModel.unifiedRefreshMainSurface()
        async let second: Void = viewModel.unifiedRefreshMainSurface()
        _ = await (first, second)

        XCTAssertEqual(api.currentUserPlaylistsCallCount, 2, "Initial load + one coalesced home refresh should issue exactly two playlist list requests.")
    }

    func testManualHomeRefreshCooldownSkipsImmediateSecondRoundTrip() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]]
        )
        let viewModel = PlaylistBrowserViewModel(
            api: api,
            cache: MockBrowsingCache(),
            manualPlaylistRefreshCooldown: 60
        )

        await viewModel.load()
        await viewModel.selectSidebar(.home)
        await viewModel.unifiedRefreshMainSurface()
        await viewModel.unifiedRefreshMainSurface()

        XCTAssertEqual(api.currentUserPlaylistsCallCount, 2, "Second immediate manual Home refresh should reuse current data inside cooldown.")
    }

    func testInsufficientScopeMapsToReconnectGuidance() async {
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One", snapshotID: "snapshot")
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
            playlists: [PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")],
            tracks: [PlaylistBrowsingTestFixtures.track(id: "track-one")]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()

        XCTAssertEqual(api.lastTracksLimit, 50, "Spotify's /v1/playlists/{id}/items endpoint caps limit at 50; passing more than 50 returns HTTP 400.")
        XCTAssertLessThanOrEqual(api.lastTracksLimit ?? Int.max, 50)
    }
}
