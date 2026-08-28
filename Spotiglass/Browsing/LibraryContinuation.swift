import Foundation

/// Tracks from one of the user's playlists, retaining the playlist boundary used
/// by the continuation ranker for co-occurrence and shared-playlist signals.
struct LibraryContinuationPlaylist: Codable, Equatable, Identifiable {
    let id: String
    let tracks: [SpotifyTrack]
}

/// The already-collected material used to build a library continuation. This is
/// deliberately a value type: ranking never reaches into an API, cache, or view
/// model, so the result is deterministic and straightforward to test.
struct LibraryContinuationLibrary: Codable, Equatable {
    let savedTracks: [SpotifyTrack]
    let playlists: [LibraryContinuationPlaylist]
    let topTracks: [SpotifyTrack]
    let topArtists: [SpotifyArtist]
    let followedArtists: [SpotifyArtist]
    /// Optional artist-top-track data is only useful as a ranking signal for a
    /// track that is already in ``savedTracks``, a playlist, or ``topTracks``.
    /// The collector enforces that boundary before persisting this value.
    let artistTopTracks: [SpotifyTrack]
    /// Artist IDs for which ``artistTopTracks`` was collected. The aggregate
    /// cache is shared by all seeds, so this scope prevents breadth data from
    /// one seed being reused for another seed's ranking.
    let artistTopTrackArtistIDs: [String]

    init(
        savedTracks: [SpotifyTrack] = [],
        playlists: [LibraryContinuationPlaylist] = [],
        topTracks: [SpotifyTrack] = [],
        topArtists: [SpotifyArtist] = [],
        followedArtists: [SpotifyArtist] = [],
        artistTopTracks: [SpotifyTrack] = [],
        artistTopTrackArtistIDs: [String] = []
    ) {
        self.savedTracks = savedTracks
        self.playlists = playlists
        self.topTracks = topTracks
        self.topArtists = topArtists
        self.followedArtists = followedArtists
        self.artistTopTracks = artistTopTracks
        self.artistTopTrackArtistIDs = artistTopTrackArtistIDs
    }

    private enum CodingKeys: String, CodingKey {
        case savedTracks
        case playlists
        case topTracks
        case topArtists
        case followedArtists
        case artistTopTracks
        case artistTopTrackArtistIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        savedTracks = try container.decodeIfPresent([SpotifyTrack].self, forKey: .savedTracks) ?? []
        playlists = try container.decodeIfPresent([LibraryContinuationPlaylist].self, forKey: .playlists) ?? []
        topTracks = try container.decodeIfPresent([SpotifyTrack].self, forKey: .topTracks) ?? []
        topArtists = try container.decodeIfPresent([SpotifyArtist].self, forKey: .topArtists) ?? []
        followedArtists = try container.decodeIfPresent([SpotifyArtist].self, forKey: .followedArtists) ?? []
        artistTopTracks = try container.decodeIfPresent([SpotifyTrack].self, forKey: .artistTopTracks) ?? []
        artistTopTrackArtistIDs = try container.decodeIfPresent([String].self, forKey: .artistTopTrackArtistIDs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(savedTracks, forKey: .savedTracks)
        try container.encode(playlists, forKey: .playlists)
        try container.encode(topTracks, forKey: .topTracks)
        try container.encode(topArtists, forKey: .topArtists)
        try container.encode(followedArtists, forKey: .followedArtists)
        try container.encode(artistTopTracks, forKey: .artistTopTracks)
        try container.encode(artistTopTrackArtistIDs, forKey: .artistTopTrackArtistIDs)
    }
}

/// On-disk aggregate index for the library sources above. Playlist and Liked
/// Songs caches remain the source of truth for browsing; this index only avoids
/// crawling every source again when the context-menu action is used repeatedly.
struct LibraryContinuationCacheEntry: Codable, Equatable {
    let library: LibraryContinuationLibrary
    let cachedAt: Date

    func isValid(now: Date = Date(), maxAge: TimeInterval = 900) -> Bool {
        now.timeIntervalSince(cachedAt) <= maxAge
    }
}

/// Pure, synchronous ranking for "More from your library".
///
/// Candidates are restricted to playable Spotify tracks already present in the
/// collected library. The rank bands mirror the product promise:
///
/// 1. another track by a seed artist;
/// 2. an artist that co-occurs with a seed artist in one of the user's playlists;
/// 3. another track from a playlist containing the seed track; and
/// 4. top-track/top-artist/followed-artist signals, then remaining library tracks.
///
/// No network, cache, random source, or view-model state is consulted here.
enum LibraryContinuationRanking {
    static let defaultLimit = 20

    private struct Candidate {
        let track: SpotifyTrack
        let band: Int
        let cooccurrenceCount: Int
        let sharedPlaylistCount: Int
        let topTrackRank: Int?
        let topArtistRank: Int?
        let followedArtistRank: Int?
        let artistTopTrackRank: Int?
        let encounter: Int
    }

    static func rank(
        seed: SpotifyTrack,
        library: LibraryContinuationLibrary,
        limit: Int = Self.defaultLimit
    ) -> [SpotifyTrack] {
        let requestedLimit = max(0, limit)
        guard requestedLimit > 0, isPlayable(seed) else { return [] }

        let seedIdentity = trackIdentityKeys(seed)
        let seedArtistKeys = artistKeys(for: seed)
        var seedArtistPlaylistIDs: Set<String> = []
        var seedTrackPlaylistIDs: Set<String> = []
        var playlistIDsByTrackIdentity: [String: Set<String>] = [:]
        for playlist in library.playlists {
            for track in playlist.tracks {
                let trackArtistKeys = artistKeys(for: track)
                if !trackArtistKeys.isDisjoint(with: seedArtistKeys) {
                    seedArtistPlaylistIDs.insert(playlist.id)
                }
                let identityKeys = trackIdentityKeys(track)
                if !identityKeys.isDisjoint(with: seedIdentity) {
                    seedTrackPlaylistIDs.insert(playlist.id)
                }
                for identityKey in identityKeys {
                    playlistIDsByTrackIdentity[identityKey, default: []].insert(playlist.id)
                }
            }
        }

        var cooccurringPlaylistIDsByArtist: [String: Set<String>] = [:]
        for playlist in library.playlists where seedArtistPlaylistIDs.contains(playlist.id) {
            for track in playlist.tracks {
                for artistKey in artistKeys(for: track) where !seedArtistKeys.contains(artistKey) {
                    cooccurringPlaylistIDsByArtist[artistKey, default: []].insert(playlist.id)
                }
            }
        }

        let ownedTracks = library.savedTracks + library.playlists.flatMap(\.tracks)
        let ownedIdentity = Set(ownedTracks.flatMap(trackIdentityKeys))
        let topTrackIdentity = Set(library.topTracks.flatMap(trackIdentityKeys))
        let knownLibraryIdentity = ownedIdentity.union(topTrackIdentity)
        let artistTopTracksInLibrary = library.artistTopTracks.filter { track in
            let identity = trackIdentityKeys(track)
            return !identity.isDisjoint(with: knownLibraryIdentity)
        }
        let sourceTracks = ownedTracks + library.topTracks + artistTopTracksInLibrary

        var candidatesByKey: [String: SpotifyTrack] = [:]
        var encounterByKey: [String: Int] = [:]
        var candidateKeyByIdentity: [String: String] = [:]
        var encounter = 0
        for track in sourceTracks {
            let identityKeys = trackIdentityKeys(track)
            guard isPlayable(track), identityKeys.isDisjoint(with: seedIdentity) else { continue }

            let matchingKeys = Set(identityKeys.compactMap { candidateKeyByIdentity[$0] })
            let key: String
            if let existingKey = matchingKeys.min(by: {
                let lhsEncounter = encounterByKey[$0] ?? Int.max
                let rhsEncounter = encounterByKey[$1] ?? Int.max
                return lhsEncounter == rhsEncounter ? $0 < $1 : lhsEncounter < rhsEncounter
            }) {
                key = existingKey
            } else {
                let baseKey = "track:\(canonicalTrackKey(track))"
                var newKey = baseKey
                while candidatesByKey[newKey] != nil {
                    newKey = "\(baseKey)#\(encounter)"
                }
                key = newKey
                candidatesByKey[key] = track
                encounterByKey[key] = encounter
                encounter += 1
            }

            if let existing = candidatesByKey[key], existing.artistRefs.isEmpty, !track.artistRefs.isEmpty {
                candidatesByKey[key] = track
            }
            for identityKey in identityKeys {
                candidateKeyByIdentity[identityKey] = key
            }
        }

        var rankedCandidates: [Candidate] = []
        rankedCandidates.reserveCapacity(candidatesByKey.count)
        for (key, track) in candidatesByKey {
            let candidateArtistKeys = artistKeys(for: track)
            let sameArtist = !candidateArtistKeys.isDisjoint(with: seedArtistKeys)
            let cooccurrenceIDs = Set(
                candidateArtistKeys.reduce(into: Set<String>()) { result, artistKey in
                    result.formUnion(cooccurringPlaylistIDsByArtist[artistKey] ?? [])
                }
            )
            var sharedPlaylistIDs: Set<String> = []
            for identityKey in trackIdentityKeys(track) {
                sharedPlaylistIDs.formUnion(playlistIDsByTrackIdentity[identityKey] ?? [])
            }
            let sharedPlaylistCount = sharedPlaylistIDs.intersection(seedTrackPlaylistIDs).count
            let band: Int
            if sameArtist {
                band = 0
            } else if !cooccurrenceIDs.isEmpty {
                band = 1
            } else if sharedPlaylistCount > 0 {
                band = 2
            } else {
                band = 3
            }

            rankedCandidates.append(
                Candidate(
                    track: track,
                    band: band,
                    cooccurrenceCount: cooccurrenceIDs.count,
                    sharedPlaylistCount: sharedPlaylistCount,
                    topTrackRank: firstTrackIndex(track, in: library.topTracks),
                    topArtistRank: firstArtistIndex(candidateArtistKeys, in: library.topArtists),
                    followedArtistRank: firstArtistIndex(candidateArtistKeys, in: library.followedArtists),
                    artistTopTrackRank: firstTrackIndex(track, in: library.artistTopTracks),
                    encounter: encounterByKey[key] ?? Int.max
                )
            )
        }

        rankedCandidates.sort(by: { (lhs: Candidate, rhs: Candidate) in
            if lhs.band != rhs.band { return lhs.band < rhs.band }
            switch lhs.band {
            case 0:
                if rankValue(lhs.topTrackRank) != rankValue(rhs.topTrackRank) {
                    return rankValue(lhs.topTrackRank) < rankValue(rhs.topTrackRank)
                }
            case 1:
                if lhs.cooccurrenceCount != rhs.cooccurrenceCount {
                    return lhs.cooccurrenceCount > rhs.cooccurrenceCount
                }
                if lhs.sharedPlaylistCount != rhs.sharedPlaylistCount {
                    return lhs.sharedPlaylistCount > rhs.sharedPlaylistCount
                }
            case 2:
                if lhs.sharedPlaylistCount != rhs.sharedPlaylistCount {
                    return lhs.sharedPlaylistCount > rhs.sharedPlaylistCount
                }
            default:
                break
            }

            let lhsSignal = signalRanks(for: lhs)
            let rhsSignal = signalRanks(for: rhs)
            if lhsSignal != rhsSignal {
                for (lhsValue, rhsValue) in zip(lhsSignal, rhsSignal) {
                    if lhsValue != rhsValue { return lhsValue < rhsValue }
                }
                return lhsSignal.count < rhsSignal.count
            }
            if lhs.encounter != rhs.encounter { return lhs.encounter < rhs.encounter }
            return lhs.track.id < rhs.track.id
        })

        return rankedCandidates.prefix(requestedLimit).map(\.track)
    }

    private static func signalRanks(for candidate: Candidate) -> [Int] {
        [
            rankValue(candidate.topTrackRank),
            rankValue(candidate.topArtistRank),
            rankValue(candidate.followedArtistRank),
            rankValue(candidate.artistTopTrackRank),
        ]
    }

    private static func rankValue(_ value: Int?) -> Int {
        value ?? Int.max
    }

    private static func firstTrackIndex(_ candidate: SpotifyTrack, in tracks: [SpotifyTrack]) -> Int? {
        let candidateIdentity = trackIdentityKeys(candidate)
        return tracks.firstIndex { !trackIdentityKeys($0).isDisjoint(with: candidateIdentity) }
    }

    private static func firstArtistIndex(_ candidateKeys: Set<String>, in artists: [SpotifyArtist]) -> Int? {
        artists.firstIndex { !artistKeys(for: $0).isDisjoint(with: candidateKeys) }
    }

    private static func isPlayable(_ track: SpotifyTrack) -> Bool {
        guard track.isPlayable != false,
            !track.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let uri = SpotifyPlayableURI.canonical(track.uri),
            uri.hasPrefix("spotify:track:")
        else { return false }
        return !uri.dropFirst("spotify:track:".count).isEmpty
    }

    private static func canonicalTrackKey(_ track: SpotifyTrack) -> String {
        if let linkedFromID = track.linkedFromID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !linkedFromID.isEmpty
        {
            return linkedFromID
        }
        let id = track.id.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? (SpotifyPlayableURI.canonical(track.uri) ?? "unknown") : id
    }

    private static func trackIdentityKeys(_ track: SpotifyTrack) -> Set<String> {
        var keys: Set<String> = []
        let id = track.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { keys.insert("id:\(id)") }
        if let linkedFromID = track.linkedFromID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !linkedFromID.isEmpty
        {
            keys.insert("id:\(linkedFromID)")
        }
        if let uri = SpotifyPlayableURI.canonical(track.uri), !uri.isEmpty {
            keys.insert("uri:\(uri)")
        }
        return keys
    }

    private static func artistKeys(for track: SpotifyTrack) -> Set<String> {
        var keys: Set<String> = []
        for ref in track.artistRefs {
            let id = ref.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { keys.insert("id:\(id)") }
            if let nameKey = normalizedArtistName(ref.name) { keys.insert("name:\(nameKey)") }
        }
        for name in track.artists {
            if let nameKey = normalizedArtistName(name) { keys.insert("name:\(nameKey)") }
        }
        return keys
    }

    private static func artistKeys(for artist: SpotifyArtist) -> Set<String> {
        var keys: Set<String> = []
        let id = artist.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { keys.insert("id:\(id)") }
        if let nameKey = normalizedArtistName(artist.name) { keys.insert("name:\(nameKey)") }
        return keys
    }

    private static func normalizedArtistName(_ name: String) -> String? {
        let normalized =
            name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return normalized.isEmpty ? nil : normalized
    }
}

extension SpotifyPlaylistTrackItem {
    /// Returns the catalog track represented by a playlist item. Episodes,
    /// local files, and unavailable entries are intentionally outside the
    /// continuation candidate set.
    var continuationTrack: SpotifyTrack? {
        guard case .track(let track) = content else { return nil }
        return track
    }
}
