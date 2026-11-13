import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserLikedSongsCoverageTests: XCTestCase {
    func testLateCachedLikedSongsProfileCannotOverwritePlaylistDetail() async {
        let profileGate = ProfileLookupGate()
        let profileControl = ProfileLookupControl(
            gate: profileGate,
            profile: MusicUserProfile(id: "u", displayName: "Cached User", country: "US")
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
            profile: MusicUserProfile(id: "u", displayName: "Stale User", country: "US")
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
            profile: MusicUserProfile(id: "u", displayName: "Fresh User", country: "US")
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
                MusicSavedTracksResult(
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
            profile: MusicUserProfile(id: "u", displayName: "Fresh User", country: "US")
        )
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "playlist-b", name: "Playlist B")
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlist])],
            trackResults: [playlist.id: [.success([PlaylistBrowsingTestFixtures.track(id: "playlist-track")])]],
            savedTracksResult: .success(MusicSavedTracksResult(tracks: [], totalAvailable: 0)),
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
            profile: MusicUserProfile(id: "u", displayName: "Fresh User", country: "US")
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
                MusicSavedTracksResult(
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
            savedTracksResult: .success(MusicSavedTracksResult(tracks: [], totalAvailable: 0))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)
        guard case .empty(let message) = viewModel.detailState else {
            return XCTFail("Expected empty liked songs, got \(viewModel.detailState)")
        }
        XCTAssertTrue(message.string.contains("no liked songs"))
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
            profile: MusicUserProfile(id: "u", displayName: "Taylor", country: "US"),
            playlists: [PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")],
            savedTracks: MusicSavedTracksResult(tracks: [liked], totalAvailable: 1)
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
        let episodeItem = MusicPlaylistTrackItem(
            id: "ep-1",
            content: .episode(MusicEpisode(
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
            savedTracksResult: .success(MusicSavedTracksResult(tracks: [episodeItem], totalAvailable: 1))
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
    private let profile: MusicUserProfile
    private var callCount = 0
    private var delayedFailure = false

    init(gate: ProfileLookupGate, profile: MusicUserProfile) {
        self.gate = gate
        self.profile = profile
    }

    func nextProfile() async throws -> MusicUserProfile {
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

private final class ProfileAwareMockBrowsingAPI: MusicBrowsingProvider {
    let profile: MusicUserProfile
    let playlists: [MusicPlaylistSummary]
    let savedTracks: MusicSavedTracksResult

    init(profile: MusicUserProfile, playlists: [MusicPlaylistSummary], savedTracks: MusicSavedTracksResult) {
        self.profile = profile
        self.playlists = playlists
        self.savedTracks = savedTracks
    }

    func currentUserProfile() async throws -> MusicUserProfile { profile }
    func updatePlaylist(playlistID: String, name: String) async throws {}
    func currentUserPlaylists(limit: Int) async throws -> [MusicPlaylistSummary] { playlists }
    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [MusicPlaylistTrackItem] { [] }
    func currentUserSavedTracks(limit: Int, maxPages: Int?) async throws -> MusicSavedTracksResult { savedTracks }
    func artist(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicArtistDetail {
        MusicArtistDetail(id: id, name: id, imageURL: nil, followersTotal: nil, genres: [], uri: "spotify:artist:\(id)")
    }
    func artistCached(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicCachedResponse<MusicArtistDetail> {
        MusicCachedResponse(value: try await artist(id: id, cacheMode: cacheMode), isStale: false)
    }
    func search(query: String, limit: Int) async throws -> MusicSearchResults {
        MusicSearchResults(tracks: [], artists: [], albums: [], playlists: [])
    }
    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [MusicTrack] { [] }
    func artistAlbumsCached(id: String, includeGroups: [MusicArtistAlbumGroup], limit: Int, cacheMode: MusicRequestCacheMode) async throws -> MusicCachedResponse<[MusicArtistAlbum]> {
        MusicCachedResponse(value: [], isStale: false)
    }
    func artistAlbumsPage(id: String, includeGroups: [MusicArtistAlbumGroup], limit: Int, offset: Int, nextURL: URL?, cacheMode: MusicRequestCacheMode) async throws -> MusicArtistAlbumsPage {
        MusicArtistAlbumsPage(items: [], next: nil)
    }
}
