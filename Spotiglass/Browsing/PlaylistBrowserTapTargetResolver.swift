import Foundation

/// Resolves artist/album tap targets via the catalog search when IDs are missing.
enum PlaylistBrowserTapTargetResolver {
    static func resolveAlbumID(
        name: String,
        artistHint: String,
        search: (_ query: String, _ limit: Int) async throws -> MusicSearchResults
    ) async throws -> String? {
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

    /// The artist a credit's text names, for a tap target the service gave no ID (#637).
    ///
    /// Only an artist whose name matches exactly counts: the whole credit first (an artist can be
    /// called "Simon & Garfunkel"), then each name in it in order ("Bad Bunny & RaiNao" opens
    /// Bad Bunny). A search lists other artists too, so with no exact match this answers `nil`
    /// and nothing opens, instead of the first hit, who may not be on the song at all.
    /// The query is the name alone: Apple Music reads Spotify's `artist:"…"` filter as words.
    static func resolveArtistID(
        forName name: String,
        search: (_ query: String, _ limit: Int) async throws -> MusicSearchResults
    ) async throws -> String? {
        for candidate in creditNames(name) {
            let results = try await search(candidate, 10)
            let wanted = folded(candidate)
            if let exact = results.artists.first(where: { folded($0.name) == wanted }) {
                return exact.id
            }
        }
        return nil
    }

    /// The whole credit, then each artist named in it, in order and without repeats.
    static func creditNames(_ credit: String) -> [String] {
        let trimmed = credit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var parts = [trimmed]
        for separator in creditSeparators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        var seen = Set<String>()
        return ([trimmed] + parts)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(folded($0)).inserted }
    }

    /// How services join several artists in one credit. Words like "and" are left out: they
    /// are part of many artists' own names.
    private static let creditSeparators = [
        ",", "&", " x ", " X ", " feat. ", " Feat. ", " ft. ", " Ft. ", " featuring ", " Featuring ", " with ", " / ",
    ]

    private static func folded(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
