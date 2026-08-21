import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserPrefetchAllTracksTests: XCTestCase {
    /// Pre-seeds the view-model so `runBulkPlaylistTrackPrefetch()` skips
    /// `loadIfNeeded()` (which would otherwise trigger a side-effect detail
    /// fetch for the auto-selected playlist).
    private func seed(_ vm: PlaylistBrowserViewModel, with playlists: [SpotifyPlaylistSummary]) {
        vm.playlistsByID = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        vm.playlistState = .loaded(playlists.map(PlaylistRowViewModel.init))
        vm.hasLoaded = true
    }

    func testRunBulkPrefetchSkipsFreshCacheAndFetchesMissingAndIncludesLikedSongs() async throws {
        let p1 = PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Fresh", snapshotID: "snap-1")
        let p2 = PlaylistBrowsingTestFixtures.playlist(id: "p2", name: "Missing", snapshotID: "snap-2")
        let p3 = PlaylistBrowsingTestFixtures.playlist(id: "p3", name: "Expired", snapshotID: "snap-3")

        // p1 fresh on disk, p3 has stale on disk (expired), p2 has nothing.
        let cache = MockBrowsingCache(
            cachedPlaylists: [p1, p2, p3],
            cachedTracks: [
                "p1": [PlaylistBrowsingTestFixtures.track(id: "p1-cached")],
                "p3": [PlaylistBrowsingTestFixtures.track(id: "p3-stale")]
            ],
            playlistListCacheAge: 5,
            expiredTrackIDs: ["p3"]
        )

        let counter = ConcurrencyCounter()
        let api = ConcurrencyTrackingBrowsingAPI(
            playlists: [p1, p2, p3],
            counter: counter,
            trackFactory: { id in [PlaylistBrowsingTestFixtures.track(id: "\(id)-fetched")] },
            savedTracksFactory: {
                SpotifySavedTracksResult(
                    tracks: [PlaylistBrowsingTestFixtures.track(id: "liked-1")],
                    totalAvailable: 1
                )
            }
        )

        let vm = PlaylistBrowserViewModel(api: api, cache: cache)
        seed(vm, with: [p1, p2, p3])
        await vm.runBulkPlaylistTrackPrefetch()

        let counts = await counter.invocationCounts
        XCTAssertEqual(counts["p1"] ?? 0, 0, "Fresh disk cache should be skipped")
        XCTAssertEqual(counts["p2"] ?? 0, 1, "Missing cache should trigger one fetch")
        XCTAssertEqual(counts["p3"] ?? 0, 1, "Expired cache should trigger one fetch")
        let savedCount = await counter.savedTracksCount
        XCTAssertEqual(savedCount, 1, "Liked Songs should be fetched once")

        // Disk cache is warmed for the fetched IDs and Liked Songs.
        XCTAssertEqual(cache.savedTracks["p2"]?.first?.id, "p2-fetched")
        XCTAssertEqual(cache.savedTracks["p3"]?.first?.id, "p3-fetched")
        XCTAssertEqual(cache.savedTracks[SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID]?.first?.id, "liked-1")

        // Progress finalizes with the right tallies.
        let progress = try XCTUnwrap(vm.prefetchAllPlaylistsProgress)
        XCTAssertEqual(progress.phase, .finished)
        XCTAssertEqual(progress.total, 4) // 3 playlists + liked songs
        XCTAssertEqual(progress.completed, 3) // p2, p3, liked
        XCTAssertEqual(progress.skipped, 1)   // p1
        XCTAssertEqual(progress.failed, 0)
    }

    func testRunBulkPrefetchBoundsConcurrencyToThree() async {
        let playlists = (1...8).map { PlaylistBrowsingTestFixtures.playlist(id: "p\($0)", name: "P\($0)") }
        let cache = MockBrowsingCache(cachedPlaylists: playlists, cachedTracks: [:], playlistListCacheAge: 5)
        let counter = ConcurrencyCounter()
        let api = ConcurrencyTrackingBrowsingAPI(playlists: playlists, counter: counter)

        let vm = PlaylistBrowserViewModel(api: api, cache: cache)
        seed(vm, with: playlists)
        await vm.runBulkPlaylistTrackPrefetch()

        let peak = await counter.peak
        XCTAssertLessThanOrEqual(peak, PlaylistBrowserViewModel.prefetchAllPlaylistsConcurrency,
                                 "Peak concurrency must not exceed the bound")
        XCTAssertGreaterThanOrEqual(peak, 2,
                                    "With 8 items + Liked Songs and concurrency=3, peak should reach at least 2")
    }

    func testEmptyLibraryStillFinalizesWithLikedSongsOnlyWork() async throws {
        let cache = MockBrowsingCache(cachedPlaylists: [], cachedTracks: [:], playlistListCacheAge: 5)
        let api = MockBrowsingAPI(
            playlistResults: [.success([])],
            trackResults: [:],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [], totalAvailable: 0))
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: cache)
        seed(vm, with: [])
        await vm.runBulkPlaylistTrackPrefetch()

        let progress = try XCTUnwrap(vm.prefetchAllPlaylistsProgress)
        XCTAssertEqual(progress.phase, .finished)
        // Only Liked Songs is in the worklist; it succeeded.
        XCTAssertEqual(progress.total, 1)
        XCTAssertEqual(progress.completed, 1)
        XCTAssertEqual(progress.skipped, 0)
        XCTAssertEqual(progress.failed, 0)
    }

    func testToggleBulkPrefetchCancelsInFlightRun() async throws {
        let playlists = (1...4).map { PlaylistBrowsingTestFixtures.playlist(id: "p\($0)", name: "P\($0)") }
        let cache = MockBrowsingCache(cachedPlaylists: playlists, cachedTracks: [:], playlistListCacheAge: 5)
        let api = ConcurrencyTrackingBrowsingAPI(playlists: playlists, counter: ConcurrencyCounter())
        let vm = PlaylistBrowserViewModel(api: api, cache: cache)
        seed(vm, with: playlists)

        let run = Task { await vm.toggleBulkPlaylistTrackPrefetch() }
        try await Task.sleep(nanoseconds: 30_000_000)
        await vm.toggleBulkPlaylistTrackPrefetch()
        await run.value

        let progress = try XCTUnwrap(vm.prefetchAllPlaylistsProgress)
        XCTAssertEqual(progress.phase, .cancelled)
    }

    func testCoalescesWithRecentRevalidation() async throws {
        let p1 = PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Recently Revalidated", snapshotID: "snap-1")
        let cache = MockBrowsingCache(cachedPlaylists: [p1], cachedTracks: [:], playlistListCacheAge: 5)
        let api = MockBrowsingAPI(
            playlistResults: [.success([p1])],
            trackResults: ["p1": [.success([PlaylistBrowsingTestFixtures.track(id: "p1-new")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [], totalAvailable: 0))
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: cache)
        seed(vm, with: [p1])
        // Simulate the detail-loader having just revalidated this playlist.
        vm.lastTracksRevalidationByID["p1"] = (snapshotID: "snap-1", at: Date())
        await vm.runBulkPlaylistTrackPrefetch()

        XCTAssertEqual(api.playlistTracksInvocationCountByID["p1"] ?? 0, 0,
                       "Recently revalidated playlist must be skipped by prefetch")
        let progress = try XCTUnwrap(vm.prefetchAllPlaylistsProgress)
        XCTAssertEqual(progress.skipped, 1)
    }
}

// MARK: - Test doubles

private actor ConcurrencyCounter {
    private(set) var peak: Int = 0
    private var current: Int = 0
    private(set) var invocationCounts: [String: Int] = [:]
    private(set) var savedTracksCount: Int = 0

    func enter() {
        current += 1
        if current > peak { peak = current }
    }
    func exit() { current -= 1 }
    func recordPlaylist(_ id: String) { invocationCounts[id, default: 0] += 1 }
    func recordSavedTracks() { savedTracksCount += 1 }
}

private final class ConcurrencyTrackingBrowsingAPI: SpotifyBrowsingAPI, @unchecked Sendable {
    private let playlistsList: [SpotifyPlaylistSummary]
    private let counter: ConcurrencyCounter
    private let trackFactory: @Sendable (String) -> [SpotifyPlaylistTrackItem]
    private let savedTracksFactory: @Sendable () -> SpotifySavedTracksResult

    init(
        playlists: [SpotifyPlaylistSummary],
        counter: ConcurrencyCounter,
        trackFactory: @escaping @Sendable (String) -> [SpotifyPlaylistTrackItem] = { _ in [] },
        savedTracksFactory: @escaping @Sendable () -> SpotifySavedTracksResult = {
            SpotifySavedTracksResult(tracks: [], totalAvailable: 0)
        }
    ) {
        self.playlistsList = playlists
        self.counter = counter
        self.trackFactory = trackFactory
        self.savedTracksFactory = savedTracksFactory
    }

    func currentUserPlaylists(limit: Int) async throws -> [SpotifyPlaylistSummary] { playlistsList }
    func updatePlaylist(playlistID: String, name: String) async throws {}

    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [SpotifyPlaylistTrackItem] {
        await counter.enter()
        try await Task.sleep(nanoseconds: 20_000_000)
        await counter.recordPlaylist(playlistID)
        await counter.exit()
        return trackFactory(playlistID)
    }

    func currentUserSavedTracks(limit: Int, maxPages: Int) async throws -> SpotifySavedTracksResult {
        await counter.enter()
        try await Task.sleep(nanoseconds: 20_000_000)
        await counter.recordSavedTracks()
        await counter.exit()
        return savedTracksFactory()
    }

    func currentUserProfile() async throws -> SpotifyUserProfile {
        SpotifyUserProfile(id: "u", displayName: nil, country: "US")
    }
    func artist(id: String, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyArtistDetail {
        SpotifyArtistDetail(id: id, name: id, imageURL: nil, followersTotal: nil, genres: [], uri: "spotify:artist:\(id)")
    }
    func artistCached(id: String, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyAPIClient.CachedResponse<SpotifyArtistDetail> {
        SpotifyAPIClient.CachedResponse(value: try await artist(id: id, cacheMode: cacheMode), isStale: false)
    }
    func artistAlbumsCached(id: String, includeGroups: String, limit: Int, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyAPIClient.CachedResponse<[SpotifyArtistAlbum]> {
        SpotifyAPIClient.CachedResponse(value: [], isStale: false)
    }
    func artistAlbumsPage(id: String, includeGroups: String, limit: Int, offset: Int, nextURL: URL?, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyAPIClient.SpotifyArtistAlbumsPage {
        SpotifyAPIClient.SpotifyArtistAlbumsPage(items: [], next: nil)
    }
    func search(query: String, limit: Int) async throws -> SpotifySearchResults {
        SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
    }
    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [SpotifyTrack] { [] }
}
