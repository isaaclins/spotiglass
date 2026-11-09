import SwiftUI

extension PlaylistBrowserView {
    /// Artist and album links in the player bar and the queue stay usable next to the lyrics.
    /// Following one closes the lyrics first, even when it leads to the page already under
    /// them (#438).
    func openArtistFromTapTarget(_ target: ArtistTapTarget, origin: BrowserNavigationOrigin = .extend) {
        lyricsOverlay.dismiss()
        Task {
            await PlaylistBrowserTapTargetNavigation.openArtist(
                target,
                origin: origin,
                selectArtist: { id, origin, displayName in
                    await viewModel.selectArtist(id: id, origin: origin, displayName: displayName)
                },
                resolveArtistID: { name in
                    try await resolveArtistID(forName: name)
                }
            )
        }
    }

    func openAlbumFromTapTarget(
        _ album: AlbumTapTarget,
        artistSubtitle: String,
        artworkURL: URL?,
        origin: BrowserNavigationOrigin = .extend
    ) {
        lyricsOverlay.dismiss()
        Task {
            await PlaylistBrowserTapTargetNavigation.openAlbum(
                album,
                artistSubtitle: artistSubtitle,
                artworkURL: artworkURL,
                origin: origin,
                selectAlbum: { id, title, subtitle, artwork, origin in
                    await viewModel.selectAlbum(
                        id: id,
                        displayTitle: title,
                        displaySubtitle: subtitle,
                        artworkURL: artwork,
                        origin: origin
                    )
                },
                resolveAlbumID: { name, hint in
                    try await resolveAlbumID(name: name, artistHint: hint)
                }
            )
        }
    }

    func resolveAlbumID(name: String, artistHint: String) async throws -> String? {
        try await PlaylistBrowserTapTargetResolver.resolveAlbumID(name: name, artistHint: artistHint) { query, limit in
            try await catalogProvider.search(query: query, limit: limit)
        }
    }

    func resolveArtistID(forName name: String) async throws -> String? {
        try await PlaylistBrowserTapTargetResolver.resolveArtistID(forName: name) { query, limit in
            try await catalogProvider.search(query: query, limit: limit)
        }
    }
}
