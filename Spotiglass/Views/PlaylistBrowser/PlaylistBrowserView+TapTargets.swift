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
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "")
        let firstArtist = artistHint.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let query: String
        if firstArtist.isEmpty {
            query = "album:\"\(escaped)\""
        } else {
            let artistEsc = firstArtist.replacingOccurrences(of: "\"", with: "")
            query = "album:\"\(escaped)\" artist:\"\(artistEsc)\""
        }
        let results = try await spotifySearchClient.search(query: query, limit: 10)
        guard !results.albums.isEmpty else { return nil }
        let normalizedQuery = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if let exact = results.albums.first(where: {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalizedQuery
        }) {
            return exact.id
        }
        return results.albums.first?.id
    }

    func resolveArtistID(forName name: String) async throws -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "")
        let results = try await spotifySearchClient.search(query: "artist:\"\(escaped)\"", limit: 5)
        guard !results.artists.isEmpty else { return nil }
        let normalizedQuery = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if let exact = results.artists.first(where: {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalizedQuery
        }) {
            return exact.id
        }
        return results.artists.first?.id
    }
}
