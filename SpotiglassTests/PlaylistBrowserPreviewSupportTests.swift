import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserPreviewSupportTests: XCTestCase {
    func testPreviewBrowsingAPIRoundTrip() async throws {
        let api = PreviewBrowsingAPI()
        let profile = try await api.currentUserProfile()
        XCTAssertEqual(profile.id, "preview")

        let playlists = try await api.currentUserPlaylists(limit: 10)
        XCTAssertEqual(playlists.count, 1)

        let tracks = try await api.playlistTracks(playlistID: "playlist", limit: 50, maxPages: 1)
        XCTAssertEqual(tracks.count, 1)

        let saved = try await api.currentUserSavedTracks(limit: 50, maxPages: 1)
        XCTAssertEqual(saved.totalAvailable, 0)

        do {
            _ = try await api.artist(id: "a", cacheMode: .freshOnly)
            XCTFail("expected artist load to throw")
        } catch {
            XCTAssertTrue(error is SpotifyAPIError)
        }
    }

    func testPreviewCacheAndTokenProvider() async throws {
        let cache = PreviewBrowsingCache()
        XCTAssertNil(try cache.loadPlaylistsBundle(now: Date()))
        try cache.savePlaylists([], cachedAt: Date())
        XCTAssertNil(try cache.loadTracks(playlistID: "p", snapshotID: "s", now: Date(), maxAge: 60))
        XCTAssertNil(try cache.loadTracksIgnoringAge(playlistID: "p", snapshotID: "s"))
        try cache.saveTracks([], playlistID: "p", snapshotID: "s", cachedAt: Date())
        try cache.invalidateTracks(playlistID: "p")

        let tokens = PreviewPlaybackTokenProvider()
        let access = try await tokens.accessToken()
        let playback = try await tokens.playbackAccessToken()
        let refreshed = try await tokens.refreshedPlaybackAccessToken()
        let refreshAuth = try await tokens.refreshAccessTokenAfterUnauthorized()
        XCTAssertEqual(access, "preview-token")
        XCTAssertEqual(playback, "preview-token")
        XCTAssertEqual(refreshed, "preview-token")
        XCTAssertEqual(refreshAuth, "preview-token")
    }

    func testPreviewBrowsingAPISurface() async throws {
        let api = PreviewBrowsingAPI()
        _ = try await api.search(query: "q", limit: 5)
        _ = try await api.albumTracks(albumID: "a", market: "US", limit: 10)
        _ = try await api.albums(ids: ["a"], market: "US")
        _ = try await api.artistTopTracks(id: "a", market: "US")
        _ = try await api.artistAlbums(id: "a", includeGroups: "album", limit: 5, cacheMode: .freshOnly)
        _ = try await api.artistAlbumsCached(id: "a", includeGroups: "album", limit: 5, cacheMode: .freshOnly)
        _ = try await api.artistAlbumsPage(
            id: "a",
            includeGroups: "album",
            limit: 5,
            offset: 0,
            nextURL: nil,
            cacheMode: .freshOnly
        )
        do {
            _ = try await api.artistCached(id: "a", cacheMode: .freshOnly)
            XCTFail("expected artistCached to throw")
        } catch {
            XCTAssertTrue(error is SpotifyAPIError)
        }
    }
}
