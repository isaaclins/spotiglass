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

    func testLikedSongsFreshCacheSkipsImmediateRevalidationWithinRefreshWindow() async {
        let likedFresh = Self.track(id: "liked-fresh")
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
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
        let liked = Self.track(id: "liked-shared")
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
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
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            playlistsHandler: {
                try await Task.sleep(nanoseconds: 120_000_000)
                return [Self.playlist(id: "one", name: "One")]
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
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]]
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

    func testBackNavigationTracksPlaylistHistory() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One"), Self.playlist(id: "two", name: "Two")])],
            trackResults: [
                "one": [.success([Self.track(id: "track-one")])],
                "two": [.success([Self.track(id: "track-two")])]
            ]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        XCTAssertFalse(viewModel.canNavigateBack)
        XCTAssertEqual(viewModel.selectedPlaylistID, "one")

        await viewModel.selectPlaylist(id: "two")
        XCTAssertTrue(viewModel.canNavigateBack)
        XCTAssertEqual(viewModel.selectedPlaylistID, "two")

        await viewModel.navigateBack()
        XCTAssertEqual(viewModel.selectedPlaylistID, "one")
        XCTAssertFalse(viewModel.canNavigateBack)
        XCTAssertEqual(Self.playlistTracks(viewModel.detailState).map(\.title), ["Track track-one"])
    }

    func testSelectAlbumLoadsAlbumAsPlaylistStyleDetail() async {
        let albumCoverURL = URL(string: "https://example.com/cover.png")
        let albumTrack = SpotifyTrack(
            id: "alb-track-1",
            name: "Album Track 1",
            artists: ["Artist Name"],
            albumArtworkURL: nil,
            durationMilliseconds: 180_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:alb-track-1"
        )
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            albumTracksHandler: { _, _, _ in [albumTrack] }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectAlbum(
            id: "album-123",
            displayTitle: "Album Name",
            displaySubtitle: "Artist Name",
            artworkURL: albumCoverURL
        )

        guard case let .loaded(.playlist(detail)) = viewModel.detailState else {
            return XCTFail("Expected album detail to render through playlist-style content.")
        }
        XCTAssertEqual(detail.playlist.id, "album-123")
        XCTAssertEqual(detail.playlist.title, "Album Name")
        XCTAssertEqual(detail.playlist.owner, "Artist Name")
        XCTAssertEqual(detail.tracks.map(\.title), ["Album Track 1"])
        XCTAssertEqual(detail.tracks.first?.artworkURL, albumCoverURL)
        XCTAssertEqual(api.albumTracksCallCount, 1, "Album detail should reuse the already-fetched album cover locally, without extra Spotify calls.")
        XCTAssertEqual(api.searchCallCount, 0)
        XCTAssertEqual(api.albumsBatchedCallCount, 0)
    }

    func testBackNavigationReturnsFromAlbumToArtist() async {
        let albumTrack = SpotifyTrack(
            id: "alb-track-1",
            name: "Album Track 1",
            artists: ["Artist Name"],
            albumArtworkURL: nil,
            durationMilliseconds: 180_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:alb-track-1"
        )
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            albumTracksHandler: { _, _, _ in [albumTrack] }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")
        await viewModel.selectAlbum(
            id: "album-123",
            displayTitle: "Album Name",
            displaySubtitle: "Artist Name",
            artworkURL: URL(string: "https://example.com/cover.png")
        )
        XCTAssertTrue(viewModel.canNavigateBack)
        guard case let .loaded(.playlist(albumDetail)) = viewModel.detailState else {
            return XCTFail("Expected album detail before back navigation.")
        }
        XCTAssertEqual(albumDetail.playlist.id, "album-123")

        await viewModel.navigateBack()
        XCTAssertTrue(viewModel.canNavigateBack)
        guard case let .loaded(.artist(detail)) = viewModel.detailState else {
            return XCTFail("Expected artist detail after navigating back from album.")
        }
        XCTAssertEqual(detail.artist.id, "artist-xyz")
    }

    func testAlbumCardTapRouterSingleTapOpensAndDoubleTapCancelsPendingSingle() async {
        let router = AlbumCardTapRouter(doubleClickDelayNanoseconds: 20_000_000)
        var openedIDs: [String] = []
        var openAndPlayCount = 0

        router.handleSingleTap(albumID: "album-1") {
            openedIDs.append("album-1")
        }
        try? await Task.sleep(nanoseconds: 35_000_000)
        XCTAssertEqual(openedIDs, ["album-1"])

        router.handleSingleTap(albumID: "album-2") {
            openedIDs.append("album-2")
        }
        router.handleDoubleTap {
            openedIDs.append("album-2")
            openAndPlayCount += 1
        }
        try? await Task.sleep(nanoseconds: 35_000_000)
        XCTAssertEqual(openAndPlayCount, 1)
        XCTAssertEqual(openedIDs.filter { $0 == "album-2" }.count, 1, "Double-tap should cancel pending single-tap open.")
    }

    func testCommandPaletteContextEligibleWhenArtistDetailLoaded() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertTrue(viewModel.isCommandPaletteContextSearchEligible)
        XCTAssertEqual(viewModel.loadedContextTracksForPalette?.map(\.title), ["Hit"])
    }

    func testCommandPaletteContextEligibleWhenPlaylistDetailLoaded() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()

        XCTAssertTrue(viewModel.isCommandPaletteContextSearchEligible)
        XCTAssertEqual(viewModel.loadedContextTracksForPalette?.map(\.title), ["Track track-one"])
    }

    func testCommandPaletteContextNotEligibleWhenSidebarHome() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectSidebar(.home)

        XCTAssertFalse(viewModel.isCommandPaletteContextSearchEligible)
        XCTAssertNil(viewModel.loadedContextTracksForPalette)
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

    func testArtistTopTracksForbiddenEntersCooldownAndSkipsRepeatedProbe() async {
        let now = Date(timeIntervalSince1970: 1_000)
        var currentTime = now
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
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache(), now: { currentTime })

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertEqual(api.artistTopTracksCallCount, 1, "Second artist load during forbidden cooldown should skip top-tracks probe.")
        XCTAssertEqual(api.searchCallCount, 1, "Repeated artist opens within TTL should reuse cached detail instead of repeating fallback search.")
    }

    func testArtistTopTracksRateLimitedUsesReducedAlbumFallbackBudget() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                throw SpotifyAPIError.rateLimited(retryAfter: 1)
            },
            searchHandler: { _, _ in
                SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in
                [
                    SpotifyArtistAlbum(id: "alb-1", name: "A1", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:alb-1"),
                    SpotifyArtistAlbum(id: "alb-2", name: "A2", imageURL: nil, releaseYear: "2023", totalTracks: 1, group: .album, uri: "spotify:album:alb-2"),
                    SpotifyArtistAlbum(id: "alb-3", name: "A3", imageURL: nil, releaseYear: "2022", totalTracks: 1, group: .album, uri: "spotify:album:alb-3")
                ]
            },
            albumTracksHandler: { albumID, _, _ in
                [Self.fallbackTrack(id: "track-\(albumID)", name: "Track \(albumID)", artistId: "artist-xyz")]
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertEqual(api.artistTopTracksCallCount, 1)
        XCTAssertEqual(api.searchCallCount, 1)
        XCTAssertEqual(api.albumTracksCallCount, 0, "Short-retry rate-limit should still avoid the per-album N+1; fallback uses one batched call.")
        XCTAssertEqual(api.albumsBatchedCallCount, 1, "Fallback collapses the rate-limited album loop into a single batched /v1/albums call.")
        XCTAssertEqual(api.albumsBatchedLastIDs?.count, 3, "Reduced budget caps batched IDs at 3 under rate-limit pressure.")
    }

    func testArtistAlbumFallbackDeduplicatesRepeatedAlbumIDs() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                throw SpotifyAPIError.forbidden(message: "Forbidden", details: "")
            },
            searchHandler: { _, _ in
                SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in
                [
                    SpotifyArtistAlbum(id: "alb-dup", name: "Dup 2024", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:alb-dup"),
                    SpotifyArtistAlbum(id: "alb-dup", name: "Dup 2024 Deluxe", imageURL: nil, releaseYear: "2024", totalTracks: 9, group: .album, uri: "spotify:album:alb-dup"),
                    SpotifyArtistAlbum(id: "alb-unique", name: "Unique", imageURL: nil, releaseYear: "2023", totalTracks: 1, group: .single, uri: "spotify:album:alb-unique")
                ]
            },
            albumTracksHandler: { albumID, _, _ in
                [Self.fallbackTrack(id: "track-\(albumID)", name: "Track \(albumID)", artistId: "artist-xyz")]
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertEqual(api.albumTracksCallCount, 0, "Fallback no longer issues per-album track requests; one batched call covers them.")
        XCTAssertEqual(api.albumsBatchedCallCount, 1, "Fallback should make exactly one batched /v1/albums call.")
        XCTAssertEqual(api.albumsBatchedLastIDs, ["alb-dup", "alb-unique"], "Batched IDs should be deduplicated by album.id before the request.")
    }

    func testArtistTopTracksLongRateLimitSkipsAlbumFallbackEntirely() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                // Long Retry-After means Spotify is actively throttling; stacking the album fallback
                // onto the same back-off window would just earn another 429.
                throw SpotifyAPIError.rateLimited(retryAfter: 30)
            },
            searchHandler: { _, _ in
                SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in
                [
                    SpotifyArtistAlbum(id: "alb-1", name: "A1", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:alb-1")
                ]
            },
            albumTracksHandler: { albumID, _, _ in
                [Self.fallbackTrack(id: "track-\(albumID)", name: "Track \(albumID)", artistId: "artist-xyz")]
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertEqual(api.artistTopTracksCallCount, 1)
        XCTAssertEqual(api.searchCallCount, 1)
        XCTAssertEqual(api.albumTracksCallCount, 0, "Long-retry rate-limit must not cascade into per-album track fetches.")
        XCTAssertEqual(api.albumsBatchedCallCount, 0, "Long-retry rate-limit must skip the batched album fallback as well.")
        XCTAssertGreaterThanOrEqual(viewModel.artistFetchMetrics.albumFallbackBudgetStops, 1, "Skip should record exactly one budget stop for telemetry.")
    }

    func testArtistAlbumFallbackRecoversWhenBatchedResponseLacksTracks() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                throw SpotifyAPIError.forbidden(message: "Forbidden", details: "")
            },
            searchHandler: { _, _ in
                SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in
                [
                    SpotifyArtistAlbum(id: "alb-empty", name: "Empty 2024", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:alb-empty"),
                    SpotifyArtistAlbum(id: "alb-other", name: "Other 2023", imageURL: nil, releaseYear: "2023", totalTracks: 1, group: .album, uri: "spotify:album:alb-other")
                ]
            },
            albumTracksHandler: { albumID, _, _ in
                // Only invoked by the recovery path. The recovery should target alb-empty (highest
                // priority album whose batched entry returned no tracks).
                XCTAssertEqual(albumID, "alb-empty", "Recovery should target the empty-batched album in priority order.")
                return [Self.fallbackTrack(id: "rec-1", name: "Recovered", artistId: "artist-xyz")]
            },
            albumsHandler: { ids, _ in
                ids.map { id in
                    SpotifyBatchedAlbum(
                        id: id,
                        name: nil,
                        imageURL: nil,
                        // alb-empty intentionally returns no tracks -> recovery candidate.
                        tracks: id == "alb-empty" ? [] : [Self.fallbackTrack(id: "track-\(id)", name: "Track \(id)", artistId: "artist-xyz")],
                        tracksAvailable: id != "alb-empty"
                    )
                }
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertEqual(api.albumsBatchedCallCount, 1, "Batched call should be issued once.")
        XCTAssertEqual(api.albumTracksCallCount, 1, "Recovery should issue exactly one single-album fallback request.")
        XCTAssertEqual(viewModel.artistFetchMetrics.albumFallbackBatchedCalls, 1)
        XCTAssertEqual(viewModel.artistFetchMetrics.albumFallbackRecoveryCalls, 1)
    }

    func testArtistAlbumFallbackSkipsRecoveryWhenTracksFieldWasPresentButEmpty() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                throw SpotifyAPIError.forbidden(message: "Forbidden", details: "")
            },
            searchHandler: { _, _ in
                SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in
                [
                    SpotifyArtistAlbum(id: "alb-present-empty", name: "Present Empty", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:alb-present-empty")
                ]
            },
            albumTracksHandler: { _, _, _ in
                XCTFail("Recovery should not run when batched payload had tracksAvailable=true.")
                return []
            },
            albumsHandler: { ids, _ in
                ids.map { id in
                    SpotifyBatchedAlbum(
                        id: id,
                        name: nil,
                        imageURL: nil,
                        tracks: [],
                        tracksAvailable: true
                    )
                }
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertEqual(api.albumsBatchedCallCount, 1)
        XCTAssertEqual(api.albumTracksCallCount, 0, "Recovery should be reserved for missing tracks payloads only.")
    }

    func testArtistAlbumFallbackBatchedRateLimitEntersCooldownAndSuppressesImmediateRetry() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                throw SpotifyAPIError.forbidden(message: "Forbidden", details: "")
            },
            searchHandler: { _, _ in
                SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in
                [SpotifyArtistAlbum(id: "alb-1", name: "A1", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:alb-1")]
            },
            albumsHandler: { _, _ in
                throw SpotifyAPIError.rateLimited(retryAfter: 30)
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache(), now: { clock })

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")
        XCTAssertEqual(api.albumsBatchedCallCount, 1)
        await viewModel.selectArtist(id: "artist-xyz", forceRefresh: true)
        XCTAssertEqual(api.albumsBatchedCallCount, 1, "Active cooldown should suppress immediate re-request of the same batched albums fallback.")

        clock = clock.addingTimeInterval(31)
        await viewModel.selectArtist(id: "artist-xyz", forceRefresh: true)
        XCTAssertEqual(api.albumsBatchedCallCount, 2, "After cooldown expires, fallback may probe the batched endpoint once again.")
    }

    func testArtistAlbumFallbackDoesNotLoopSingleAlbumRecoveryAcrossRepeatedRefreshes() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                throw SpotifyAPIError.forbidden(message: "Forbidden", details: "")
            },
            searchHandler: { _, _ in
                SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in
                [SpotifyArtistAlbum(id: "alb-empty", name: "A1", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:alb-empty")]
            },
            albumTracksHandler: { _, _, _ in
                [Self.fallbackTrack(id: "rec-1", name: "Recovered", artistId: "artist-xyz")]
            },
            albumsHandler: { ids, _ in
                ids.map { id in
                    SpotifyBatchedAlbum(
                        id: id,
                        name: nil,
                        imageURL: nil,
                        tracks: [],
                        tracksAvailable: false
                    )
                }
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")
        await viewModel.selectArtist(id: "artist-xyz", forceRefresh: true)

        XCTAssertEqual(api.albumsBatchedCallCount, 2, "Batched fallback can still run per refresh.")
        XCTAssertEqual(api.albumTracksCallCount, 1, "Single-album recovery must not loop repeatedly for the same album in one app session.")
    }

    func testArtistAlbumFallbackRendersFromStaleBatchedCacheUnderRateLimit() async {
        // When `/v1/albums?ids=...` is throttled, `SpotifyAPIClient.albums(...)` transparently serves
        // the prior cached body via its stale-on-rate-limit path (covered by the unit test in
        // `SpotifyWebAPIStepTests`). From the caller's perspective albums(...) just succeeds, so the
        // artist detail renders without triggering the cooldown breaker or any per-album recovery.
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            artistTopTracksHandler: { _, _ in
                throw SpotifyAPIError.forbidden(message: "Forbidden", details: "")
            },
            searchHandler: { _, _ in
                SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in
                [
                    SpotifyArtistAlbum(id: "alb-1", name: "Stale Album", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:alb-1")
                ]
            },
            albumTracksHandler: { _, _, _ in
                XCTFail("Stale-on-rate-limit fallback delivers tracks; no per-album recovery should fire.")
                return []
            },
            albumsHandler: { ids, _ in
                ids.map { id in
                    SpotifyBatchedAlbum(
                        id: id,
                        name: nil,
                        imageURL: nil,
                        tracks: [Self.fallbackTrack(id: "stale-\(id)", name: "Stale \(id)", artistId: "artist-xyz")],
                        tracksAvailable: true
                    )
                }
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertEqual(api.albumsBatchedCallCount, 1)
        XCTAssertEqual(api.albumTracksCallCount, 0)
        XCTAssertEqual(viewModel.artistFetchMetrics.albumFallbackBatchedCalls, 1)
        XCTAssertEqual(viewModel.artistFetchMetrics.albumFallbackRecoveryCalls, 0)
        XCTAssertEqual(viewModel.artistFetchMetrics.albumFallbackBudgetStops, 0, "Stale-cache fallback succeeded; no budget stop should be recorded.")

        guard case let .loaded(.artist(detail)) = viewModel.detailState else {
            return XCTFail("Expected artist detail to load from the stale fallback path.")
        }
        XCTAssertEqual(detail.tracks.map(\.id), ["stale-alb-1"], "Tracks rendered for the artist must come from the stale batched body.")
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

    func testConcurrentSelectArtistCoalescesSingleNetworkChain() async {
        let page1 = SpotifyArtistAlbum(
            id: "alb-1", name: "First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:alb-1"
        )
        let page2 = SpotifyArtistAlbum(
            id: "alb-2", name: "Second", imageURL: nil, releaseYear: "2023", totalTracks: 1, group: .album, uri: "spotify:album:alb-2"
        )
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
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

        XCTAssertEqual(api.artistAlbumsPageCallCount, 2, "Concurrent same-artist opens should share one in-flight artist load.")
    }

    func testSelectArtistWithinTTLUsesCachedSnapshotWithoutRefetch() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            artistAlbumsPageHandler: { _, _, _, offset, _ in
                if offset == 0 {
                    return SpotifyAPIClient.SpotifyArtistAlbumsPage(
                        items: [SpotifyArtistAlbum(id: "alb-1", name: "First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:alb-1")],
                        next: nil
                    )
                }
                return SpotifyAPIClient.SpotifyArtistAlbumsPage(items: [], next: nil)
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache(), now: { now }, artistDetailCacheTTL: 120)

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")
        let firstCount = api.artistAlbumsPageCallCount
        now = now.addingTimeInterval(30)
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(api.artistAlbumsPageCallCount, 1, "Reopening same artist within TTL should reuse cached snapshot.")
    }

    func testLoadMoreArtistAlbumsFetchesOneAdditionalPageOnDemand() async {
        let nextURL = URL(string: "https://api.spotify.com/v1/artists/artist-xyz/albums?offset=10&limit=10")!
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            artistAlbumsPageHandler: { _, _, _, offset, providedNext in
                if offset == 0 {
                    return SpotifyAPIClient.SpotifyArtistAlbumsPage(
                        items: [SpotifyArtistAlbum(id: "alb-1", name: "First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:alb-1")],
                        next: nextURL
                    )
                }
                XCTAssertEqual(providedNext, nextURL)
                return SpotifyAPIClient.SpotifyArtistAlbumsPage(
                    items: [SpotifyArtistAlbum(id: "alb-2", name: "Second", imageURL: nil, releaseYear: "2023", totalTracks: 1, group: .single, uri: "spotify:album:alb-2")],
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

    func testReselectingPlaylistWithinCooldownSkipsSecondItemsFetch() async {
        let snapshot = "snapshot-stable"
        let playlistA = Self.playlist(id: "a", name: "A", snapshotID: snapshot)
        let playlistB = Self.playlist(id: "b", name: "B", snapshotID: snapshot)
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlistA, playlistB])],
            trackResults: [
                "a": [.success([Self.track(id: "ta")])],
                "b": [.success([Self.track(id: "tb")])]
            ]
        )
        let cache = MockBrowsingCache(cachedPlaylists: [playlistA, playlistB], playlistListCacheAge: 20_000)
        let start = Date(timeIntervalSince1970: 0)
        var clock = start
        let viewModel = PlaylistBrowserViewModel(
            api: api,
            cache: cache,
            now: { clock },
            playlistListAutoRefreshMinInterval: 50_000,
            tracksRevalidateMinInterval: 30
        )

        await viewModel.load()
        XCTAssertEqual(api.playlistTracksInvocationCountByID["a"], 1)
        await viewModel.selectPlaylist(id: "b")
        XCTAssertEqual(api.playlistTracksInvocationCountByID["b"], 1)
        await viewModel.selectPlaylist(id: "a")
        XCTAssertEqual(api.playlistTracksInvocationCountByID["a"], 1, "Cooldown should skip a second `/items` fetch for the same playlist snapshot.")
    }

    func testReselectingPlaylistAfterCooldownRefetchesItems() async {
        let snapshot = "snapshot-stable"
        let playlistA = Self.playlist(id: "a", name: "A", snapshotID: snapshot)
        let playlistB = Self.playlist(id: "b", name: "B", snapshotID: snapshot)
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlistA, playlistB])],
            trackResults: [
                "a": [
                    .success([Self.track(id: "ta")]),
                    .success([Self.track(id: "ta2")])
                ],
                "b": [.success([Self.track(id: "tb")])]
            ]
        )
        let cache = MockBrowsingCache(cachedPlaylists: [playlistA, playlistB], playlistListCacheAge: 20_000)
        let start = Date(timeIntervalSince1970: 0)
        var clock = start
        let viewModel = PlaylistBrowserViewModel(
            api: api,
            cache: cache,
            now: { clock },
            playlistListAutoRefreshMinInterval: 50_000,
            tracksRevalidateMinInterval: 30
        )

        await viewModel.load()
        XCTAssertEqual(api.playlistTracksInvocationCountByID["a"], 1)
        await viewModel.selectPlaylist(id: "b")
        clock = start.addingTimeInterval(31)
        await viewModel.selectPlaylist(id: "a")
        XCTAssertEqual(api.playlistTracksInvocationCountByID["a"], 2)
    }

    func testPlaylistSnapshotRotationForcesItemsRefetchEvenWithinCooldown() async {
        let s1 = "snap-1"
        let s2 = "snap-2"
        let playlistOneV1 = Self.playlist(id: "one", name: "One", snapshotID: s1)
        let playlistTwo = Self.playlist(id: "two", name: "Two", snapshotID: s1)
        let playlistOneV2 = Self.playlist(id: "one", name: "One", snapshotID: s2)
        let api = MockBrowsingAPI(
            playlistResults: [
                .success([playlistOneV1, playlistTwo]),
                .success([playlistOneV2, playlistTwo])
            ],
            trackResults: [
                "one": [.success([Self.track(id: "t1")]), .success([Self.track(id: "t2")])],
                "two": [.success([Self.track(id: "u1")])]
            ]
        )
        let cache = MockBrowsingCache()
        let start = Date(timeIntervalSince1970: 0)
        var clock = start
        let viewModel = PlaylistBrowserViewModel(
            api: api,
            cache: cache,
            now: { clock },
            tracksRevalidateMinInterval: 300
        )

        await viewModel.load()
        await viewModel.selectPlaylist(id: "two")
        await viewModel.selectPlaylist(id: "one")
        XCTAssertEqual(api.playlistTracksInvocationCountByID["one"], 1)
        await viewModel.refreshPlaylists(trigger: .automatic)
        XCTAssertEqual(api.playlistTracksInvocationCountByID["one"], 2)
    }

    func testRefreshPlaylistsWithUnchangedSnapshotDoesNotRefetchSelectedTracks() async {
        let snapshot = "snap-unchanged"
        let playlistOne = Self.playlist(id: "one", name: "One", snapshotID: snapshot)
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlistOne]), .success([playlistOne])],
            trackResults: ["one": [.success([Self.track(id: "t1")])]]
        )
        let cache = MockBrowsingCache()
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache)

        await viewModel.load()
        XCTAssertEqual(api.playlistTracksInvocationCountByID["one"], 1)
        await viewModel.refreshPlaylists(trigger: .automatic)
        XCTAssertEqual(api.playlistTracksInvocationCountByID["one"], 1)
    }

    func testExplicitRefreshBypassesTracksCooldown() async {
        let snapshot = "snap"
        let playlistOne = Self.playlist(id: "one", name: "One", snapshotID: snapshot)
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlistOne])],
            trackResults: [
                "one": [
                    .success([Self.track(id: "a")]),
                    .success([Self.track(id: "b")])
                ]
            ]
        )
        let cache = MockBrowsingCache()
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache, tracksRevalidateMinInterval: 300)

        await viewModel.load()
        XCTAssertEqual(api.playlistTracksInvocationCountByID["one"], 1)
        await viewModel.refreshSelectedPlaylist()
        XCTAssertEqual(api.playlistTracksInvocationCountByID["one"], 2)
    }

    func testRapidPlaylistSelectionCancelsInflightItemsFetch() async {
        let snapshot = "snap"
        let playlistA = Self.playlist(id: "a", name: "A", snapshotID: snapshot)
        let playlistB = Self.playlist(id: "b", name: "B", snapshotID: snapshot)
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlistA, playlistB])],
            trackResults: [
                "a": [.success([Self.track(id: "ta")])],
                "b": [.success([Self.track(id: "tb")])]
            ]
        )
        api.playlistTracksDelayOnInvocation = 400_000_000
        let cache = MockBrowsingCache(cachedPlaylists: [playlistA, playlistB], playlistListCacheAge: 20_000)
        let viewModel = PlaylistBrowserViewModel(
            api: api,
            cache: cache,
            playlistListAutoRefreshMinInterval: 50_000,
            tracksRevalidateMinInterval: 30
        )

        await viewModel.load()
        XCTAssertEqual(api.playlistTracksInvocationCountByID["a"], 1)

        let firstSwitch = Task { await viewModel.selectPlaylist(id: "b") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await viewModel.selectPlaylist(id: "a")
        await firstSwitch.value

        XCTAssertEqual(api.playlistTracksInvocationCountByID["a"], 1, "Cancelled in-flight fetch for B should not complete.")
        XCTAssertEqual(api.playlistTracksInvocationCountByID["b"] ?? 0, 0)
    }

    func testDoubleArrowNextDebouncesToSingleItemsFetch() async {
        let snapshot = "snap"
        let playlistA = Self.playlist(id: "a", name: "A", snapshotID: snapshot)
        let playlistB = Self.playlist(id: "b", name: "B", snapshotID: snapshot)
        let playlistC = Self.playlist(id: "c", name: "C", snapshotID: snapshot)
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlistA, playlistB, playlistC])],
            trackResults: [
                "a": [.success([Self.track(id: "ta")])],
                "b": [.success([Self.track(id: "tb")])],
                "c": [.success([Self.track(id: "tc")])]
            ]
        )
        let cache = MockBrowsingCache(cachedPlaylists: [playlistA, playlistB, playlistC], playlistListCacheAge: 20_000)
        let viewModel = PlaylistBrowserViewModel(
            api: api,
            cache: cache,
            playlistListAutoRefreshMinInterval: 50_000,
            tracksRevalidateMinInterval: 30
        )

        await viewModel.load()
        XCTAssertEqual(api.playlistTracksInvocationCountByID["a"], 1)

        await viewModel.selectPlaylist(id: "a")
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await viewModel.selectNextPlaylist() }
            group.addTask { await viewModel.selectNextPlaylist() }
        }
        try? await Task.sleep(nanoseconds: 220_000_000)

        XCTAssertEqual(api.playlistTracksInvocationCountByID["b"] ?? 0, 0)
        XCTAssertEqual(api.playlistTracksInvocationCountByID["c"], 1)
    }

    // MARK: - Breadcrumbs

    func testBreadcrumbSidebarLikedSongs() async {
        let liked = Self.track(id: "liked-one")
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [liked], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)

        XCTAssertEqual(viewModel.breadcrumbPath.count, 1)
        XCTAssertEqual(viewModel.breadcrumbPath[0].label, "Liked Songs")
        XCTAssertEqual(viewModel.breadcrumbPath[0].systemImage, "heart.fill")
        guard case .likedSongs = viewModel.breadcrumbPath[0].kind else {
            return XCTFail("Expected likedSongs kind")
        }
    }

    func testBreadcrumbExtendFromLikedToArtistThenAlbum() async {
        let liked = Self.track(id: "liked-one")
        let albumTrack = SpotifyTrack(
            id: "alb-track-1",
            name: "Album Track 1",
            artists: ["Artist Name"],
            albumArtworkURL: nil,
            durationMilliseconds: 180_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:alb-track-1"
        )
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            albumTracksHandler: { _, _, _ in [albumTrack] },
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [liked], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectSidebar(SidebarSelection.likedSongs)
        await viewModel.selectArtist(id: "artist-xyz", origin: BrowserNavigationOrigin.extend, displayName: "Malcolm Todd")
        await viewModel.selectAlbum(
            id: "album-123",
            displayTitle: "Sweet Boy",
            displaySubtitle: "Malcolm Todd",
            artworkURL: URL(string: "https://example.com/a.png"),
            origin: BrowserNavigationOrigin.extend
        )

        XCTAssertEqual(viewModel.breadcrumbPath.count, 3)
        XCTAssertEqual(viewModel.breadcrumbPath[0].label, "Liked Songs")
        XCTAssertEqual(viewModel.breadcrumbPath[1].label, "Artist artist-xyz", "Artist load refines the crumb label from the mock API.")
        XCTAssertEqual(viewModel.breadcrumbPath[2].label, "Sweet Boy")
        XCTAssertEqual(viewModel.breadcrumbPath[2].systemImage, "opticaldisc")
    }

    func testBreadcrumbNavigateBackPopsLeafCrumb() async {
        let liked = Self.track(id: "liked-one")
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [liked], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)
        await viewModel.selectArtist(id: "artist-xyz", origin: .extend, displayName: "Malcolm Todd")

        XCTAssertEqual(viewModel.breadcrumbPath.count, 2)

        await viewModel.navigateBack()

        XCTAssertEqual(viewModel.breadcrumbPath.count, 1)
        XCTAssertEqual(viewModel.breadcrumbPath[0].label, "Liked Songs")
        XCTAssertEqual(viewModel.sidebarSelection, .likedSongs)
    }

    func testBreadcrumbPaletteArtistResetReplacesTrail() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [Self.track(id: "liked-one")], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)
        await viewModel.selectArtist(id: "artist-a", origin: .extend, displayName: "First")
        await viewModel.selectArtist(id: "artist-b", origin: .reset, displayName: "Second Artist")

        XCTAssertEqual(viewModel.breadcrumbPath.count, 1)
        XCTAssertEqual(viewModel.breadcrumbPath[0].label, "Artist artist-b", "Mock API artist name replaces the interim label.")
        guard case let .artist(id) = viewModel.breadcrumbPath[0].kind else {
            return XCTFail("Expected artist crumb")
        }
        XCTAssertEqual(id, "artist-b")
    }

    func testBreadcrumbJumpToBreadcrumbTrimsPrefix() async {
        let liked = Self.track(id: "liked-one")
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [liked], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)
        await viewModel.selectArtist(id: "artist-xyz", origin: .extend, displayName: "Malcolm Todd")

        await viewModel.jumpToBreadcrumb(at: 0)

        XCTAssertEqual(viewModel.breadcrumbPath.count, 1)
        XCTAssertEqual(viewModel.breadcrumbPath[0].label, "Liked Songs")
        XCTAssertEqual(viewModel.sidebarSelection, .likedSongs)
        XCTAssertFalse(viewModel.canNavigateBack)
    }

    func testBreadcrumbJumpToHomeClearsTrailAndSelectsHome() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [Self.track(id: "liked-one")], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)

        await viewModel.jumpToHome()

        XCTAssertTrue(viewModel.breadcrumbPath.isEmpty)
        XCTAssertEqual(viewModel.sidebarSelection, .home)
        XCTAssertFalse(viewModel.canNavigateBack)
    }

    func testBreadcrumbClearForSignOutEmptiesTrail() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([Self.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [Self.track(id: "liked-one")], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)

        viewModel.clearForSignOut()

        XCTAssertTrue(viewModel.breadcrumbPath.isEmpty)
    }

    func testBreadcrumbAfterPlaylistSwitchBackShowsPriorPlaylistTitle() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([Self.playlist(id: "one", name: "One"), Self.playlist(id: "two", name: "Two")])],
            trackResults: [
                "one": [.success([Self.track(id: "track-one")])],
                "two": [.success([Self.track(id: "track-two")])]
            ]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectPlaylist(id: "two")
        XCTAssertEqual(viewModel.breadcrumbPath.last?.label, "Two")

        await viewModel.navigateBack()

        XCTAssertEqual(viewModel.selectedPlaylistID, "one")
        XCTAssertEqual(viewModel.breadcrumbPath.count, 1)
        XCTAssertEqual(viewModel.breadcrumbPath.last?.label, "One")
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
    private(set) var lastTracksMaxPages: Int?

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

    func artistCached(id: String, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyAPIClient.CachedResponse<SpotifyArtistDetail> {
        SpotifyAPIClient.CachedResponse(
            value: try await artist(id: id),
            isStale: false
        )
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

    func albums(ids: [String], market: String?) async throws -> [SpotifyBatchedAlbum] {
        []
    }

    func artistAlbums(id: String, includeGroups: String, limit: Int, cacheMode: SpotifyRequestCacheMode) async throws -> [SpotifyArtistAlbum] {
        []
    }

    func artistAlbumsCached(
        id: String,
        includeGroups: String,
        limit: Int,
        cacheMode: SpotifyRequestCacheMode
    ) async throws -> SpotifyAPIClient.CachedResponse<[SpotifyArtistAlbum]> {
        SpotifyAPIClient.CachedResponse(value: [], isStale: false)
    }

    func artist(id: String, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyArtistDetail {
        try await artist(id: id)
    }

    func artistAlbumsPage(
        id: String,
        includeGroups: String,
        limit: Int,
        offset: Int,
        nextURL: URL?,
        cacheMode: SpotifyRequestCacheMode
    ) async throws -> SpotifyAPIClient.SpotifyArtistAlbumsPage {
        return SpotifyAPIClient.SpotifyArtistAlbumsPage(items: [], next: nil)
    }

    func currentUserPlaylists(limit: Int) async throws -> [SpotifyPlaylistSummary] {
        playlists
    }

    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [SpotifyPlaylistTrackItem] {
        lastTracksLimit = limit
        lastTracksMaxPages = maxPages
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
    private let artistAlbumsPageHandler: ((String, String, Int, Int, URL?) async throws -> SpotifyAPIClient.SpotifyArtistAlbumsPage)?
    private let albumTracksHandler: ((String, String?, Int) async throws -> [SpotifyTrack])?
    private let albumsHandler: (([String], String?) async throws -> [SpotifyBatchedAlbum])?
    private let savedTracksResult: Result<SpotifySavedTracksResult, Error>?
    private let savedTracksHandler: (() async throws -> SpotifySavedTracksResult)?
    private let playlistsHandler: (() async throws -> [SpotifyPlaylistSummary])?
    private(set) var savedTracksCallCount = 0
    private(set) var currentUserPlaylistsCallCount = 0
    private(set) var artistTopTracksCallCount = 0
    private(set) var searchCallCount = 0
    private(set) var albumTracksCallCount = 0
    private(set) var albumsBatchedCallCount = 0
    private(set) var albumsBatchedLastIDs: [String]?
    private(set) var artistAlbumsPageCallCount = 0
    private(set) var playlistTracksInvocationCountByID: [String: Int] = [:]
    var playlistTracksDelayOnInvocation: UInt64?

    init(
        playlistResults: [Result<[SpotifyPlaylistSummary], Error>],
        trackResults: [String: [Result<[SpotifyPlaylistTrackItem], Error>]],
        artistTopTracksHandler: ((String, String?) async throws -> [SpotifyTrack])? = nil,
        searchHandler: ((String, Int) async throws -> SpotifySearchResults)? = nil,
        artistAlbumsHandler: ((String, String, Int) async throws -> [SpotifyArtistAlbum])? = nil,
        artistAlbumsPageHandler: ((String, String, Int, Int, URL?) async throws -> SpotifyAPIClient.SpotifyArtistAlbumsPage)? = nil,
        albumTracksHandler: ((String, String?, Int) async throws -> [SpotifyTrack])? = nil,
        albumsHandler: (([String], String?) async throws -> [SpotifyBatchedAlbum])? = nil,
        savedTracksResult: Result<SpotifySavedTracksResult, Error>? = nil,
        savedTracksHandler: (() async throws -> SpotifySavedTracksResult)? = nil,
        playlistsHandler: (() async throws -> [SpotifyPlaylistSummary])? = nil
    ) {
        self.playlistResults = playlistResults
        self.trackResults = trackResults
        self.artistTopTracksHandler = artistTopTracksHandler
        self.searchHandler = searchHandler
        self.artistAlbumsHandler = artistAlbumsHandler
        self.artistAlbumsPageHandler = artistAlbumsPageHandler
        self.albumTracksHandler = albumTracksHandler
        self.albumsHandler = albumsHandler
        self.savedTracksResult = savedTracksResult
        self.savedTracksHandler = savedTracksHandler
        self.playlistsHandler = playlistsHandler
    }

    func currentUserPlaylists(limit: Int) async throws -> [SpotifyPlaylistSummary] {
        currentUserPlaylistsCallCount += 1
        if let playlistsHandler {
            return try await playlistsHandler()
        }
        guard !playlistResults.isEmpty else { return [] }
        return try playlistResults.removeFirst().get()
    }

    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [SpotifyPlaylistTrackItem] {
        if let playlistTracksDelayOnInvocation {
            try await Task.sleep(nanoseconds: playlistTracksDelayOnInvocation)
        }
        playlistTracksInvocationCountByID[playlistID, default: 0] += 1
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

    func artist(id: String, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyArtistDetail {
        try await artist(id: id)
    }

    func artistCached(id: String, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyAPIClient.CachedResponse<SpotifyArtistDetail> {
        SpotifyAPIClient.CachedResponse(
            value: try await artist(id: id),
            isStale: false
        )
    }

    func artistTopTracks(id: String, market: String?) async throws -> [SpotifyTrack] {
        artistTopTracksCallCount += 1
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
        searchCallCount += 1
        if let searchHandler {
            return try await searchHandler(query, limit)
        }
        return SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
    }

    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [SpotifyTrack] {
        albumTracksCallCount += 1
        if let albumTracksHandler {
            return try await albumTracksHandler(albumID, market, limit)
        }
        return []
    }

    func albums(ids: [String], market: String?) async throws -> [SpotifyBatchedAlbum] {
        albumsBatchedCallCount += 1
        albumsBatchedLastIDs = ids
        if let albumsHandler {
            return try await albumsHandler(ids, market)
        }
        // Fallback synthesizer: legacy tests that only set `albumTracksHandler` keep working — the
        // batched call hands the same per-album tracks back through `SpotifyBatchedAlbum`. This bypasses
        // the public `albumTracks(...)` method so `albumTracksCallCount` stays at 0 (the new flow only
        // increments it on recovery calls).
        if let albumTracksHandler {
            var result: [SpotifyBatchedAlbum] = []
            for id in ids {
                let tracks = try await albumTracksHandler(id, market, 50)
                result.append(SpotifyBatchedAlbum(
                    id: id,
                    name: nil,
                    imageURL: nil,
                    tracks: tracks,
                    tracksAvailable: true
                ))
            }
            return result
        }
        return []
    }

    func artistAlbums(id: String, includeGroups: String, limit: Int, cacheMode: SpotifyRequestCacheMode) async throws -> [SpotifyArtistAlbum] {
        if let artistAlbumsHandler {
            return try await artistAlbumsHandler(id, includeGroups, limit)
        }
        return []
    }

    func artistAlbums(id: String, includeGroups: String, limit: Int) async throws -> [SpotifyArtistAlbum] {
        try await artistAlbums(id: id, includeGroups: includeGroups, limit: limit, cacheMode: .freshOnly)
    }

    func artistAlbumsCached(
        id: String,
        includeGroups: String,
        limit: Int,
        cacheMode: SpotifyRequestCacheMode
    ) async throws -> SpotifyAPIClient.CachedResponse<[SpotifyArtistAlbum]> {
        SpotifyAPIClient.CachedResponse(
            value: try await artistAlbums(id: id, includeGroups: includeGroups, limit: limit, cacheMode: cacheMode),
            isStale: false
        )
    }

    func artistAlbumsPage(
        id: String,
        includeGroups: String,
        limit: Int,
        offset: Int,
        nextURL: URL?,
        cacheMode: SpotifyRequestCacheMode
    ) async throws -> SpotifyAPIClient.SpotifyArtistAlbumsPage {
        artistAlbumsPageCallCount += 1
        if let artistAlbumsPageHandler {
            return try await artistAlbumsPageHandler(id, includeGroups, limit, offset, nextURL)
        }
        return SpotifyAPIClient.SpotifyArtistAlbumsPage(
            items: try await artistAlbums(id: id, includeGroups: includeGroups, limit: limit, cacheMode: cacheMode),
            next: nil
        )
    }

    func currentUserSavedTracks(limit: Int, maxPages: Int) async throws -> SpotifySavedTracksResult {
        savedTracksCallCount += 1
        if let savedTracksHandler {
            return try await savedTracksHandler()
        }
        if let savedTracksResult {
            return try savedTracksResult.get()
        }
        return SpotifySavedTracksResult(tracks: [], totalAvailable: 0)
    }
}

private final class MockBrowsingCache: SpotifyBrowsingCache {
    var cachedPlaylists: [SpotifyPlaylistSummary]?
    var cachedTracks: [String: [SpotifyPlaylistTrackItem]]
    /// Mirrors disk cache snapshot binding so `snapshotID` rotation invalidates track rows.
    private var trackSnapshotByPlaylistID: [String: String] = [:]
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
        if let cachedPlaylists {
            for playlist in cachedPlaylists where cachedTracks[playlist.id] != nil {
                trackSnapshotByPlaylistID[playlist.id] = playlist.snapshotID
            }
        }
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
        // When no snapshot was seeded (tracks-only tests), accept any requested snapshot.
        if let bound = trackSnapshotByPlaylistID[playlistID], bound != snapshotID {
            return nil
        }
        return cachedTracks[playlistID]
    }

    func loadTracksIgnoringAge(playlistID: String, snapshotID: String) throws -> [SpotifyPlaylistTrackItem]? {
        if let bound = trackSnapshotByPlaylistID[playlistID], bound != snapshotID {
            return nil
        }
        return cachedTracks[playlistID]
    }

    func saveTracks(_ tracks: [SpotifyPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws {
        savedTracks[playlistID] = tracks
        cachedTracks[playlistID] = tracks
        trackSnapshotByPlaylistID[playlistID] = snapshotID
    }

    func invalidateTracks(playlistID: String) throws {
        cachedTracks[playlistID] = nil
        trackSnapshotByPlaylistID[playlistID] = nil
    }
}
