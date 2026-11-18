import Foundation

/// The catalog reads Autoplay needs (#613). ``MusicKitContentSource`` makes them; tests answer
/// them from sample artists.
protocol AppleMusicAutoplayCatalog: Sendable {
    /// Catalog artists for a name, the catalog's best match first.
    func autoplayArtistMatches(named name: String, limit: Int) async throws -> [AppleMusicAutoplayArtistMatch]
    /// The catalog artists with these IDs, with their top songs, and with their similar artists
    /// when `includeSimilar` is set. At most ``AppleMusicAutoplaySource/catalogBatchLimit`` IDs.
    func autoplayArtists(ids: [String], includeSimilar: Bool) async throws -> [AppleMusicAutoplayCatalogArtist]
}

/// A catalog artist a name search found.
struct AppleMusicAutoplayArtistMatch: Equatable {
    let id: String
    let name: String
}

/// What the catalog says about one artist.
struct AppleMusicAutoplayCatalogArtist: Equatable {
    let id: String
    /// Catalog IDs of similar artists, most similar first; empty when not asked for.
    let similarArtistIDs: [String]
    let topSongs: [MusicTrack]
}

/// Autoplay suggestions for Apple Music (#613), from the catalog's artist relationships:
/// each recent artist's similar artists (`Artist.similarArtists`, the Apple Music API's
/// `similar-artists` view) and their top songs (`Artist.topSongs`). That finds songs the
/// listener may not have saved, in the style of the recent queue, and every song it suggests
/// can be queued one by one at the end.
///
/// A song's station (`Song.station`) would match the style too, but a station plays as a
/// stream: MusicKit doesn't list its songs, so they can't go into the queue one at a time
/// after the listener's own songs.
@MainActor
final class AppleMusicAutoplaySource: QueueAutoplaySource {
    /// What the catalog says about one artist.
    struct ArtistProfile: Equatable {
        /// Catalog IDs of similar artists, most similar first.
        let similarArtistIDs: [String]
        let topSongs: [MusicTrack]
    }

    /// How many of the recent artists are looked at, the most weighted first.
    static let seedArtistLimit = 6
    /// How many similar artists of each recent artist contribute songs.
    static let similarArtistLimit = 8
    /// How many top songs of each artist are candidates.
    static let topSongLimit = 10
    /// A recent artist's own songs count less than a similar artist's, so the queue moves on
    /// to new artists instead of playing one artist's hits.
    static let ownSongsFactor = 0.6
    /// The catalog takes up to 25 IDs per request.
    static let catalogBatchLimit = 25

    private let catalog: any AppleMusicAutoplayCatalog

    init(catalog: any AppleMusicAutoplayCatalog = MusicKitContentSource()) {
        self.catalog = catalog
    }

    /// Catalog artist ID by normalized name; `nil` when the catalog has no such artist.
    private var catalogArtistIDByName: [String: String?] = [:]
    private var profiles: [String: ArtistProfile] = [:]
    private var topSongsByArtistID: [String: [MusicTrack]] = [:]

    func candidates(for seeds: [QueueAutoplaySeed]) async throws -> [QueueAutoplayCandidate] {
        let weights = Self.artistWeights(seeds)
        var weightByArtistID: [(id: String, weight: Double)] = []
        for artist in weights.prefix(Self.seedArtistLimit) {
            try Task.checkCancellation()
            guard let id = try await catalogArtistID(name: artist.name, hint: artist.idHint) else { continue }
            if let index = weightByArtistID.firstIndex(where: { $0.id == id }) {
                weightByArtistID[index].weight += artist.weight
            } else {
                weightByArtistID.append((id, artist.weight))
            }
        }
        try await loadProfiles(weightByArtistID.map(\.id))
        let similarIDs = weightByArtistID.flatMap { profiles[$0.id]?.similarArtistIDs.prefix(Self.similarArtistLimit) ?? [] }
        try await loadTopSongs(similarIDs)
        return Self.score(
            seedArtists: weightByArtistID,
            profiles: profiles,
            topSongsByArtistID: topSongsByArtistID
        )
    }

    // MARK: - Pure parts

    struct WeightedArtist: Equatable {
        let name: String
        /// The service's artist ID when it is a catalog ID (numeric).
        var idHint: String?
        var weight: Double
    }

    /// The recent queue's artists, most weighted first; each song's weight goes to its first
    /// artist, who leads the song.
    static func artistWeights(_ seeds: [QueueAutoplaySeed]) -> [WeightedArtist] {
        var artists: [WeightedArtist] = []
        for seed in seeds {
            guard let name = seed.artists.first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                continue
            }
            let key = QueueAutoplayIdentity.normalized(name)
            let hint = seed.artistIDs.first.flatMap { isCatalogID($0) ? $0 : nil }
            if let index = artists.firstIndex(where: { QueueAutoplayIdentity.normalized($0.name) == key }) {
                artists[index].weight += seed.weight
                if artists[index].idHint == nil { artists[index].idHint = hint }
            } else {
                artists.append(WeightedArtist(name: name, idHint: hint, weight: seed.weight))
            }
        }
        return artists.enumerated()
            .sorted { $0.element.weight != $1.element.weight ? $0.element.weight > $1.element.weight : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Each song's score is the sum over the recent artists that lead to it: a similar
    /// artist's songs score by how similar the artist is and how high the song charts, the
    /// recent artist's own songs a bit less (``ownSongsFactor``).
    static func score(
        seedArtists: [(id: String, weight: Double)],
        profiles: [String: ArtistProfile],
        topSongsByArtistID: [String: [MusicTrack]]
    ) -> [QueueAutoplayCandidate] {
        var scoreByURI: [String: Double] = [:]
        var trackByURI: [String: MusicTrack] = [:]
        var order: [String] = []
        func add(_ songs: [MusicTrack], weight: Double) {
            for (position, track) in songs.prefix(topSongLimit).enumerated() {
                let songScore = weight / (1 + 0.15 * Double(position))
                if trackByURI[track.uri] == nil {
                    trackByURI[track.uri] = track
                    order.append(track.uri)
                }
                scoreByURI[track.uri, default: 0] += songScore
            }
        }
        for seed in seedArtists {
            guard let profile = profiles[seed.id] else { continue }
            add(profile.topSongs, weight: seed.weight * ownSongsFactor)
            for (rank, similarID) in profile.similarArtistIDs.prefix(similarArtistLimit).enumerated() {
                let similarity = max(0.3, 1 - 0.08 * Double(rank))
                add(topSongsByArtistID[similarID] ?? profiles[similarID]?.topSongs ?? [], weight: seed.weight * similarity)
            }
        }
        return order.compactMap { uri in
            trackByURI[uri].map { QueueAutoplayCandidate(track: $0, score: scoreByURI[uri] ?? 0) }
        }
    }

    static func isCatalogID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy(\.isNumber)
    }

    // MARK: - Catalog reads

    private func catalogArtistID(name: String, hint: String?) async throws -> String? {
        if let hint { return hint }
        let key = QueueAutoplayIdentity.normalized(name)
        if let cached = catalogArtistIDByName[key] { return cached }
        let matches = try await catalog.autoplayArtistMatches(named: name, limit: 5)
        let match = matches.first { QueueAutoplayIdentity.normalized($0.name) == key } ?? matches.first
        catalogArtistIDByName[key] = .some(match?.id)
        return match?.id
    }

    private func loadProfiles(_ ids: [String]) async throws {
        let missing = Array(Set(ids.filter { profiles[$0] == nil })).sorted()
        for batch in Self.batches(missing) {
            try Task.checkCancellation()
            for artist in try await catalog.autoplayArtists(ids: batch, includeSimilar: true) {
                let songs = Array(artist.topSongs.prefix(Self.topSongLimit))
                profiles[artist.id] = ArtistProfile(similarArtistIDs: artist.similarArtistIDs, topSongs: songs)
                topSongsByArtistID[artist.id] = songs
            }
            // An artist the catalog didn't return has nothing to suggest; don't ask again.
            for id in batch where profiles[id] == nil {
                profiles[id] = ArtistProfile(similarArtistIDs: [], topSongs: [])
            }
        }
    }

    private func loadTopSongs(_ ids: [String]) async throws {
        var missing: [String] = []
        for id in ids where topSongsByArtistID[id] == nil && !missing.contains(id) {
            missing.append(id)
        }
        for batch in Self.batches(missing) {
            try Task.checkCancellation()
            for artist in try await catalog.autoplayArtists(ids: batch, includeSimilar: false) {
                topSongsByArtistID[artist.id] = Array(artist.topSongs.prefix(Self.topSongLimit))
            }
            for id in batch where topSongsByArtistID[id] == nil {
                topSongsByArtistID[id] = []
            }
        }
    }

    static func batches(_ ids: [String]) -> [[String]] {
        stride(from: 0, to: ids.count, by: catalogBatchLimit).map {
            Array(ids[$0..<min($0 + catalogBatchLimit, ids.count)])
        }
    }
}
