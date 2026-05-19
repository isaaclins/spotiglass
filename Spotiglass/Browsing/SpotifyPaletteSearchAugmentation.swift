import Foundation

/// Pure helpers for command-palette Spotify search (artist-scoped track merge).
enum SpotifyPaletteSearchAugmentation {
    /// Whether to run a second `artist:"…"` track search using Spotify’s top artist hit.
    /// - Parameters:
    ///   - primaryTrackCount: Track count from the primary multi-type search; when already at or above ``sufficientPrimaryTracksThreshold``, skip the extra request.
    ///   - sufficientPrimaryTracksThreshold: Matches the default multi-type search track `limit` (10 max; Spotiglass caps palette search there).
    static func shouldFetchArtistScopedTracks(
        trimmedUserQuery: String,
        topArtistName: String,
        primaryTrackCount: Int = 0,
        sufficientPrimaryTracksThreshold: Int = 6
    ) -> Bool {
        guard primaryTrackCount < sufficientPrimaryTracksThreshold else { return false }
        let q = trimmedUserQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = topArtistName.lowercased()
        guard q.count >= 2, !name.isEmpty else { return false }
        if name.contains(q) { return true }
        let firstToken = name.split(separator: " ").first.map(String.init) ?? ""
        guard firstToken.count >= 3, q.contains(firstToken) else { return false }
        return true
    }

    /// Keeps `primary` order; appends tracks from `extra` not already present (by track id).
    static func mergeTracksPreservingOrder(primary: [SpotifyTrack], extra: [SpotifyTrack]) -> [SpotifyTrack] {
        var seen = Set(primary.map(\.id))
        var out = primary
        for track in extra where !seen.contains(track.id) {
            seen.insert(track.id)
            out.append(track)
        }
        return out
    }
}
