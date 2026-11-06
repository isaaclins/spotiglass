import Foundation

#if DEBUG
import SwiftUI
#endif

/// Preview-only browsing API used by ``PlaylistBrowserView`` canvas; exercised in unit tests for coverage.
struct PreviewBrowsingAPI: MusicBrowsingProvider {
    func currentUserProfile() async throws -> MusicUserProfile {
        MusicUserProfile(id: "preview", displayName: nil, country: "US")
    }

    func artist(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicArtistDetail {
        throw SpotifyAPIError.invalidRequest("Preview does not load artists.")
    }

    func artistCached(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicCachedResponse<MusicArtistDetail> {
        let value = try await artist(id: id, cacheMode: cacheMode)
        return MusicCachedResponse(value: value, isStale: false)
    }

    func search(query: String, limit: Int) async throws -> MusicSearchResults {
        MusicSearchResults(tracks: [], artists: [], albums: [], playlists: [])
    }

    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [MusicTrack] {
        []
    }

    func artistAlbums(id _: String, includeGroups _: String, limit _: Int, cacheMode _: MusicRequestCacheMode) async throws -> [MusicArtistAlbum] {
        []
    }

    func artistAlbumsCached(
        id: String,
        includeGroups: String,
        limit: Int,
        cacheMode: MusicRequestCacheMode
    ) async throws -> MusicCachedResponse<[MusicArtistAlbum]> {
        let albums = try await artistAlbums(id: id, includeGroups: includeGroups, limit: limit, cacheMode: cacheMode)
        return MusicCachedResponse(value: albums, isStale: false)
    }

    func artistAlbumsPage(
        id: String,
        includeGroups: String,
        limit: Int,
        offset: Int,
        nextURL: URL?,
        cacheMode: MusicRequestCacheMode
    ) async throws -> MusicArtistAlbumsPage {
        MusicArtistAlbumsPage(items: [], next: nil)
    }

    func updatePlaylist(playlistID: String, name: String) async throws {}

    func currentUserPlaylists(limit: Int) async throws -> [MusicPlaylistSummary] {
        [
            MusicPlaylistSummary(
                id: "playlist",
                name: "Preview Playlist",
                ownerID: "preview-user",
                ownerName: "Isaac",
                imageURL: nil,
                trackCount: 2,
                snapshotID: "snapshot"
            ),
        ]
    }

    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [MusicPlaylistTrackItem] {
        [
            MusicPlaylistTrackItem(
                id: "track",
                content: .track(
                    MusicTrack(
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
            ),
        ]
    }

    func currentUserSavedTracks(limit: Int, maxPages: Int?) async throws -> MusicSavedTracksResult {
        MusicSavedTracksResult(tracks: [], totalAvailable: 0)
    }
}

struct PreviewBrowsingCache: SpotifyBrowsingCache {
    func loadPlaylistsBundle(now: Date) throws -> (playlists: [MusicPlaylistSummary], age: TimeInterval)? { nil }
    func savePlaylists(_ playlists: [MusicPlaylistSummary], cachedAt: Date) throws {}
    func loadTracks(playlistID: String, snapshotID: String, now: Date, maxAge: TimeInterval) throws -> [MusicPlaylistTrackItem]? { nil }
    func loadTracksIgnoringAge(playlistID: String, snapshotID: String) throws -> [MusicPlaylistTrackItem]? { nil }
    func saveTracks(_ tracks: [MusicPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws {}
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
    let tokens = PreviewPlaybackTokenProvider()
    let playbackHost = SpotiglassPlaybackHost(tokenProvider: tokens)
    return PlaylistBrowserView(
        viewModel: PlaylistBrowserViewModel(
            api: PreviewBrowsingAPI(),
            cache: PreviewBrowsingCache()
        ),
        playbackHost: playbackHost,
        searchTokenProvider: tokens,
        commandPaletteManager: CommandPaletteManager(),
        signOut: {}
    )
    .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
    .environmentObject(LyricsOverlayController())
}
#endif
