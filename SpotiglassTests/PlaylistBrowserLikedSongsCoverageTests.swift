import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserLikedSongsCoverageTests: XCTestCase {
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
    func artistTopTracks(id: String, market: String?) async throws -> [SpotifyTrack] { [] }
    func search(query: String, limit: Int) async throws -> SpotifySearchResults {
        SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
    }
    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [SpotifyTrack] { [] }
    func albums(ids: [String], market: String?) async throws -> [SpotifyBatchedAlbum] { [] }
    func artistAlbumsCached(id: String, includeGroups: String, limit: Int, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyAPIClient.CachedResponse<[SpotifyArtistAlbum]> {
        SpotifyAPIClient.CachedResponse(value: [], isStale: false)
    }
    func artistAlbumsPage(id: String, includeGroups: String, limit: Int, offset: Int, nextURL: URL?, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyAPIClient.SpotifyArtistAlbumsPage {
        SpotifyAPIClient.SpotifyArtistAlbumsPage(items: [], next: nil)
    }
}
