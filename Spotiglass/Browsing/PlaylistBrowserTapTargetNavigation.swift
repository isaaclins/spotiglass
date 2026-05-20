import Foundation

/// Tap-target navigation helpers extracted from ``PlaylistBrowserView`` for unit testing.
enum PlaylistBrowserTapTargetNavigation {
    static func openArtist(
        _ target: ArtistTapTarget,
        origin: BrowserNavigationOrigin,
        selectArtist: @MainActor (String, BrowserNavigationOrigin, String?) async -> Void,
        resolveArtistID: (String) async throws -> String?
    ) async {
        if let id = target.id {
            await selectArtist(id, origin, target.name)
            return
        }
        guard let resolvedID = try? await resolveArtistID(target.name) else { return }
        await selectArtist(resolvedID, origin, target.name)
    }

    static func openAlbum(
        _ album: AlbumTapTarget,
        artistSubtitle: String,
        artworkURL: URL?,
        origin: BrowserNavigationOrigin,
        selectAlbum: @MainActor (String, String, String, URL?, BrowserNavigationOrigin) async -> Void,
        resolveAlbumID: (String, String) async throws -> String?
    ) async {
        if let id = album.id {
            await selectAlbum(id, album.name, artistSubtitle, artworkURL, origin)
            return
        }
        do {
            guard let resolvedID = try await resolveAlbumID(album.name, artistSubtitle) else { return }
            await selectAlbum(resolvedID, album.name, artistSubtitle, artworkURL, origin)
        } catch {
            return
        }
    }
}
