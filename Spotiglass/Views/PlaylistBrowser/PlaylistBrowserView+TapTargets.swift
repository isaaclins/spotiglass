import SwiftUI

extension PlaylistBrowserView {
    func openArtistFromTapTarget(_ target: ArtistTapTarget, origin: BrowserNavigationOrigin = .extend) {
        Task {
            if let id = target.id {
                await viewModel.selectArtist(id: id, origin: origin, displayName: target.name)
                return
            }
            guard let resolvedID = try? await resolveArtistID(forName: target.name) else { return }
            await viewModel.selectArtist(id: resolvedID, origin: origin, displayName: target.name)
        }
    }

    func openAlbumFromTapTarget(
        _ album: AlbumTapTarget,
        artistSubtitle: String,
        artworkURL: URL?,
        origin: BrowserNavigationOrigin = .extend
    ) {
        Task {
            if let id = album.id {
                await viewModel.selectAlbum(
                    id: id,
                    displayTitle: album.name,
                    displaySubtitle: artistSubtitle,
                    artworkURL: artworkURL,
                    origin: origin
                )
                return
            }
            do {
                guard let resolvedID = try await resolveAlbumID(name: album.name, artistHint: artistSubtitle) else { return }
                await viewModel.selectAlbum(
                    id: resolvedID,
                    displayTitle: album.name,
                    displaySubtitle: artistSubtitle,
                    artworkURL: artworkURL,
                    origin: origin
                )
            } catch {
                return
            }
        }
    }

    func resolveAlbumID(name: String, artistHint: String) async throws -> String? {
        try await PlaylistBrowserTapTargetResolver.resolveAlbumID(name: name, artistHint: artistHint) { query, limit in
            try await spotifySearchClient.search(query: query, limit: limit)
        }
    }

    func resolveArtistID(forName name: String) async throws -> String? {
        try await PlaylistBrowserTapTargetResolver.resolveArtistID(forName: name) { query, limit in
            try await spotifySearchClient.search(query: query, limit: limit)
        }
    }
}
