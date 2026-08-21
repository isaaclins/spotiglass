import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserLikedSongsCoverageTests: XCTestCase {
    func testLateCachedLikedSongsProfileCannotOverwritePlaylistDetail() async {
        let profileGate = ProfileLookupGate()
        let profileControl = ProfileLookupControl(
            gate: profileGate,
            profile: SpotifyUserProfile(id: "u", displayName: "Cached User", country: "US")
        )
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "playlist-b", name: "Playlist B")
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlist])],
            trackResults: [playlist.id: [.success([PlaylistBrowsingTestFixtures.track(id: "playlist-track")])]],
            profileHandler: { try await profileControl.nextProfile() }
        )
        let cache = MockBrowsingCache(
            cachedTracks: [
                SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID: [PlaylistBrowsingTestFixtures.track(id: "liked-cached")]
            ]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache)

        await viewModel.load()
        let likedTask = Task { await viewModel.selectSidebar(.likedSongs) }
        await profileGate.waitUntilBlocked()

        await viewModel.selectPlaylist(id: playlist.id)
        let playlistDetail = viewModel.detailState

        await profileGate.resolve(())
        await likedTask.value

        XCTAssertEqual(viewModel.sidebarSelection, .playlist(playlist.id))
        XCTAssertEqual(viewModel.detailState, playlistDetail)
        XCTAssertEqual(
            PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.title),
            ["Track playlist-track"]
        )
    }

    func testLateStaleLikedSongsProfileCannotOverwritePlaylistDetail() async {
        let profileGate = ProfileLookupGate()
        let profileControl = ProfileLookupControl(
            gate: profileGate,
            profile: SpotifyUserProfile(id: "u", displayName: "Stale User", country: "US")
        )
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "playlist-b", name: "Playlist B")
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlist])],
            trackResults: [playlist.id: [.success([PlaylistBrowsingTestFixtures.track(id: "playlist-track")])]],
            profileHandler: { try await profileControl.nextProfile() }
        )
        let cache = MockBrowsingCache(
            cachedTracks: [
                SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID: [PlaylistBrowsingTestFixtures.track(id: "liked-stale")]
            ],
            expiredTrackIDs: [SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache)

        await viewModel.load()
        let likedTask = Task { await viewModel.selectSidebar(.likedSongs) }
        await profileGate.waitUntilBlocked()

        await viewModel.selectPlaylist(id: playlist.id)
        let playlistDetail = viewModel.detailState

        await profileGate.resolve(())
        await likedTask.value

        XCTAssertEqual(viewModel.sidebarSelection, .playlist(playlist.id))
        XCTAssertEqual(viewModel.detailState, playlistDetail)
        XCTAssertEqual(
            PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.title),
            ["Track playlist-track"]
        )
    }

    func testLateFreshLikedSongsProfileCannotOverwriteAlbumDetail() async {
        let profileGate = ProfileLookupGate()
        let profileControl = ProfileLookupControl(
            gate: profileGate,
            profile: SpotifyUserProfile(id: "u", displayName: "Fresh User", country: "US")
        )
        let albumTrack = PlaylistBrowsingTestFixtures.fallbackTrack(
            id: "album-track",
            name: "Album Track",
            artistId: "artist-b"
        )
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            albumTracksHandler: { _, _, _ in [albumTrack] },
            savedTracksResult: .success(
                SpotifySavedTracksResult(
                    tracks: [PlaylistBrowsingTestFixtures.track(id: "liked-fresh")],
                    totalAvailable: 1
                )
            ),
            profileHandler: { try await profileControl.nextProfile() }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        let likedTask = Task { await viewModel.selectSidebar(.likedSongs) }
        await profileGate.waitUntilBlocked()

        await viewModel.selectAlbum(
            id: "album-b",
            displayTitle: "Album B",
            displaySubtitle: "Artist B",
            artworkURL: nil
        )
        let albumDetail = viewModel.detailState

        await profileGate.resolve(())
        await likedTask.value

        XCTAssertEqual(viewModel.detailState, albumDetail)
        XCTAssertEqual(
            PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.title),
            ["Album Track"]
        )
    }

    func testLateFreshEmptyLikedSongsProfileCannotOverwritePlaylistDetail() async {
        let profileGate = ProfileLookupGate()
        let profileControl = ProfileLookupControl(
            gate: profileGate,
            profile: SpotifyUserProfile(id: "u", displayName: "Fresh User", country: "US")
        )
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "playlist-b", name: "Playlist B")
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlist])],
            trackResults: [playlist.id: [.success([PlaylistBrowsingTestFixtures.track(id: "playlist-track")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [], totalAvailable: 0)),
            profileHandler: { try await profileControl.nextProfile() }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        let likedTask = Task { await viewModel.selectSidebar(.likedSongs) }
        await profileGate.waitUntilBlocked()

        await viewModel.selectPlaylist(id: playlist.id)
        let playlistDetail = viewModel.detailState

        await profileGate.resolve(())
        await likedTask.value

        XCTAssertEqual(viewModel.sidebarSelection, .playlist(playlist.id))
        XCTAssertEqual(viewModel.detailState, playlistDetail)
        XCTAssertEqual(
            PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.title),
            ["Track playlist-track"]
        )
    }

    func testLateFreshLikedSongsProfileFailureCannotOverwriteAlbumDetail() async {
        let profileGate = ProfileLookupGate()
        let profileControl = ProfileLookupControl(
            gate: profileGate,
            profile: SpotifyUserProfile(id: "u", displayName: "Fresh User", country: "US")
        )
        let albumTrack = PlaylistBrowsingTestFixtures.fallbackTrack(
            id: "album-track",
            name: "Album Track",
            artistId: "artist-b"
        )
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            albumTracksHandler: { _, _, _ in [albumTrack] },
            savedTracksResult: .success(
                SpotifySavedTracksResult(
                    tracks: [PlaylistBrowsingTestFixtures.track(id: "liked-fresh")],
                    totalAvailable: 1
                )
            ),
            profileHandler: { try await profileControl.nextProfile() }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        let likedTask = Task { await viewModel.selectSidebar(.likedSongs) }
        await profileGate.waitUntilBlocked()

        await viewModel.selectAlbum(
            id: "album-b",
            displayTitle: "Album B",
            displaySubtitle: "Artist B",
            artworkURL: nil
        )
        let albumDetail = viewModel.detailState

        await profileControl.setDelayedFailure()
        await profileGate.resolve(())
        await likedTask.value

        XCTAssertEqual(viewModel.detailState, albumDetail)
        XCTAssertEqual(
            PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).map(\.title),
            ["Album Track"]
        )
    }

    func testEmptyLikedSongsShowsEmptyState() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [], totalAvailable: 0))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)
        guard case .empty(let message) = viewModel.detailState else {
            return XCTFail("Expected empty liked songs, got \(viewModel.detailState)")
        }
        XCTAssertTrue(message.contains("no liked songs"))
    }

    func testLikedSongsRevalidationFailureWithoutCacheShowsError() async {
        struct Sample: Error {}
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            savedTracksResult: .failure(Sample())
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)
        guard case .error = viewModel.detailState else {
            return XCTFail("Expected error state, got \(viewModel.detailState)")
        }
    }

    func testLikedSongsRevalidationFailureWithStaleDetailShowsStaleCache() async {
        struct Sample: Error {}
        let liked = PlaylistBrowsingTestFixtures.track(id: "cached-liked")
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            savedTracksResult: .failure(Sample())
        )
        let cache = MockBrowsingCache(
            cachedTracks: [SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID: [liked]],
            expiredTrackIDs: [SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache)
        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)
        guard case .staleCache = viewModel.detailState else {
            return XCTFail("Expected stale cache after revalidation failure, got \(viewModel.detailState)")
        }
        XCTAssertTrue(PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).contains { $0.title.contains("cached-liked") })
    }

    func testLikedSongsUsesProfileDisplayNameWhenPresent() async {
        let liked = PlaylistBrowsingTestFixtures.track(id: "liked-one")
        let api = ProfileAwareMockBrowsingAPI(
            profile: SpotifyUserProfile(id: "u", displayName: "Taylor", country: "US"),
            playlists: [PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")],
            savedTracks: SpotifySavedTracksResult(tracks: [liked], totalAvailable: 1)
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)
        guard case let .loaded(.playlist(detail)) = viewModel.detailState else {
            return XCTFail("Expected loaded playlist detail")
        }
        XCTAssertEqual(detail.playlist.owner, "Taylor")
    }

    func testLikedSongsEpisodeArtworkIsUsed() async {
        let artwork = URL(string: "https://cdn.example/episode.jpg")!
        let episodeItem = SpotifyPlaylistTrackItem(
            id: "ep-1",
            content: .episode(SpotifyEpisode(
                id: "ep-1",
                name: "Episode",
                showName: "Show",
                artworkURL: artwork,
                durationMilliseconds: 60_000,
                isPlayable: true,
                uri: "spotify:episode:ep-1"
            ))
        )
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [episodeItem], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)
        guard case let .loaded(.playlist(detail)) = viewModel.detailState else {
            return XCTFail("Expected loaded detail")
        }
        XCTAssertEqual(detail.playlist.artworkURL, artwork)
    }
}

private actor ProfileLookupGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            waiter = continuation
            let waiters = blockedWaiters
            blockedWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilBlocked() async {
        if waiter != nil {
            return
        }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func resolve(_ value: Void) {
        waiter?.resume()
        waiter = nil
    }
}

private struct ProfileLookupFailure: Error {}

private actor ProfileLookupControl {
    private let gate: ProfileLookupGate
    private let profile: SpotifyUserProfile
    private var callCount = 0
    private var delayedFailure = false

    init(gate: ProfileLookupGate, profile: SpotifyUserProfile) {
        self.gate = gate
        self.profile = profile
    }

    func nextProfile() async throws -> SpotifyUserProfile {
        callCount += 1
        if callCount == 2 {
            await gate.wait()
            if delayedFailure {
                throw ProfileLookupFailure()
            }
        }
        return profile
    }

    func setDelayedFailure() {
        delayedFailure = true
    }
}

private final class ProfileAwareMockBrowsingAPI: SpotifyBrowsingAPI {
    let profile: SpotifyUserProfile
    let playlists: [SpotifyPlaylistSummary]
    let savedTracks: SpotifySavedTracksResult

    init(profile: SpotifyUserProfile, playlists: [SpotifyPlaylistSummary], savedTracks: SpotifySavedTracksResult) {
        self.profile = profile
        self.playlists = playlists
        self.savedTracks = savedTracks
    }

    func currentUserProfile() async throws -> SpotifyUserProfile { profile }
    func updatePlaylist(playlistID: String, name: String) async throws {}
    func currentUserPlaylists(limit: Int) async throws -> [SpotifyPlaylistSummary] { playlists }
    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [SpotifyPlaylistTrackItem] { [] }
    func currentUserSavedTracks(limit: Int, maxPages: Int) async throws -> SpotifySavedTracksResult { savedTracks }
    func artist(id: String, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyArtistDetail {
        SpotifyArtistDetail(id: id, name: id, imageURL: nil, followersTotal: nil, genres: [], uri: "spotify:artist:\(id)")
    }
    func artistCached(id: String, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyAPIClient.CachedResponse<SpotifyArtistDetail> {
        SpotifyAPIClient.CachedResponse(value: try await artist(id: id, cacheMode: cacheMode), isStale: false)
    }
    func search(query: String, limit: Int) async throws -> SpotifySearchResults {
        SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
    }
    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [SpotifyTrack] { [] }
    func artistAlbumsCached(id: String, includeGroups: String, limit: Int, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyAPIClient.CachedResponse<[SpotifyArtistAlbum]> {
        SpotifyAPIClient.CachedResponse(value: [], isStale: false)
    }
    func artistAlbumsPage(id: String, includeGroups: String, limit: Int, offset: Int, nextURL: URL?, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyAPIClient.SpotifyArtistAlbumsPage {
        SpotifyAPIClient.SpotifyArtistAlbumsPage(items: [], next: nil)
    }
}
