import Foundation

/// Resolves artist/album tap targets via Spotify search when IDs are missing.
enum PlaylistBrowserTapTargetResolver {
    static func resolveAlbumID(
        name: String,
        artistHint: String,
        search: (_ query: String, _ limit: Int) async throws -> SpotifySearchResults
    ) async throws -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "")
        let firstArtist =
            artistHint.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? ""
        let query: String
        if firstArtist.isEmpty {
            query = "album:\"\(escaped)\""
        } else {
            let artistEsc = firstArtist.replacingOccurrences(of: "\"", with: "")
            query = "album:\"\(escaped)\" artist:\"\(artistEsc)\""
        }
        let results = try await search(query, 10)
        guard !results.albums.isEmpty else { return nil }
        let normalizedQuery = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if let exact = results.albums.first(where: {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalizedQuery
        }) {
            return exact.id
        }
        return results.albums.first?.id
    }

    static func resolveArtistID(
        forName name: String,
        search: (_ query: String, _ limit: Int) async throws -> SpotifySearchResults
    ) async throws -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "")
        let results = try await search("artist:\"\(escaped)\"", 5)
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
