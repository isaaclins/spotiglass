import Foundation

#if DEBUG
    import SwiftUI
#endif

/// Preview-only browsing API used by ``PlaylistBrowserView`` canvas; exercised in unit tests for coverage.
struct PreviewBrowsingAPI: SpotifyBrowsingAPI {
    func currentUserProfile() async throws -> SpotifyUserProfile {
        SpotifyUserProfile(id: "preview", displayName: nil, country: "US")
    }

    func artist(id: String, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyArtistDetail {
        throw SpotifyAPIError.invalidRequest("Preview does not load artists.")
    }

    func artistCached(id: String, cacheMode: SpotifyRequestCacheMode) async throws
        -> SpotifyAPIClient.CachedResponse<SpotifyArtistDetail>
    {
        let value = try await artist(id: id, cacheMode: cacheMode)
        return SpotifyAPIClient.CachedResponse(value: value, isStale: false)
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

    func artistAlbums(id _: String, includeGroups _: String, limit _: Int, cacheMode _: SpotifyRequestCacheMode)
        async throws -> [SpotifyArtistAlbum]
    {
        []
    }

    func artistAlbumsCached(
        id: String,
        includeGroups: String,
        limit: Int,
        cacheMode: SpotifyRequestCacheMode
    ) async throws -> SpotifyAPIClient.CachedResponse<[SpotifyArtistAlbum]> {
        let albums = try await artistAlbums(id: id, includeGroups: includeGroups, limit: limit, cacheMode: cacheMode)
        return SpotifyAPIClient.CachedResponse(value: albums, isStale: false)
    }

    func artistAlbumsPage(
        id: String,
        includeGroups: String,
        limit: Int,
        offset: Int,
        nextURL: URL?,
        cacheMode: SpotifyRequestCacheMode
    ) async throws -> SpotifyAPIClient.SpotifyArtistAlbumsPage {
        SpotifyAPIClient.SpotifyArtistAlbumsPage(items: [], next: nil)
    }

    func updatePlaylist(playlistID: String, name: String) async throws {}

    func currentUserPlaylists(limit: Int) async throws -> [SpotifyPlaylistSummary] {
        [
            SpotifyPlaylistSummary(
                id: "playlist",
                name: "Preview Playlist",
                ownerID: "preview-user",
                ownerName: "Isaac",
                imageURL: nil,
                trackCount: 2,
                snapshotID: "snapshot"
            )
        ]
    }

    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [SpotifyPlaylistTrackItem] {
        [
            SpotifyPlaylistTrackItem(
                id: "track",
                content: .track(
                    SpotifyTrack(
                        id: "track",
                        name: "Preview Track",
                        artists: ["Artist"],
                        albumArtworkURL: nil,
                        durationMilliseconds: 181_000,
                        isExplicit: false,
                        isPlayable: true,
                        linkedFromID: nil,
                        uri: "spotify:track:track"
                    )
                )
            )
        ]
    }

    func currentUserSavedTracks(limit: Int, maxPages: Int) async throws -> SpotifySavedTracksResult {
        SpotifySavedTracksResult(tracks: [], totalAvailable: 0)
    }
}

struct PreviewBrowsingCache: SpotifyBrowsingCache {
    func loadPlaylistsBundle(now: Date) throws -> (playlists: [SpotifyPlaylistSummary], age: TimeInterval)? { nil }
    func savePlaylists(_ playlists: [SpotifyPlaylistSummary], cachedAt: Date) throws {}
    func loadTracks(playlistID: String, snapshotID: String, now: Date, maxAge: TimeInterval) throws
        -> [SpotifyPlaylistTrackItem]?
    { nil }
    func loadTracksIgnoringAge(playlistID: String, snapshotID: String) throws -> [SpotifyPlaylistTrackItem]? { nil }
    func saveTracks(_ tracks: [SpotifyPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws
    {}
    func invalidateTracks(playlistID: String) throws {}
}

@MainActor
final class PreviewPlaybackTokenProvider: PlaybackAccessTokenProviding, SpotifyAccessTokenProviding {
    func playbackAccessToken() async throws -> String { "preview-token" }
    func refreshedPlaybackAccessToken() async throws -> String { "preview-token" }
    func accessToken() async throws -> String { "preview-token" }
    func refreshAccessTokenAfterUnauthorized() async throws -> String { "preview-token" }
}

#if DEBUG
    #Preview {
        PlaylistBrowserView(
            viewModel: PlaylistBrowserViewModel(
                api: PreviewBrowsingAPI(),
                cache: PreviewBrowsingCache()
            ),
            playbackTokenProvider: PreviewPlaybackTokenProvider(),
            searchTokenProvider: PreviewPlaybackTokenProvider(),
            commandPaletteManager: CommandPaletteManager(),
            signOut: {}
        )
        .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
        .environmentObject(LyricsOverlayController())
    }
#endif
