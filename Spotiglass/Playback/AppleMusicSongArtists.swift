import Foundation

/// The artists of queued Apple Music songs, with their IDs (#637).
///
/// MusicKit hands queue entries back without the song's `artists`, only its credit text
/// ("Bad Bunny & RaiNao"). Without IDs a click on the artist had to search for that text and
/// opened whoever the search listed first. This loads each song's own artists once, in the
/// background, so the player bar and the queue show every artist as a link to exactly that
/// artist. A read that finds none or fails is remembered as none, so a song is asked for once.
@MainActor
final class AppleMusicSongArtists {
    typealias Load = @MainActor () async -> [MusicArtistRef]

    /// Songs remembered at most; the oldest go first. A queue rarely holds more songs whose
    /// artists were asked for.
    static let capacity = 500

    private var known: [String: [MusicArtistRef]] = [:]
    private var order: [String] = []
    private var loading: Set<String> = []

    /// The song's artists when they are known, else `nil` and `load` starts reading them. The
    /// session reads the player once a second, so the next read shows them.
    func artists(ofSong songID: String, load: @escaping Load) -> [MusicArtistRef]? {
        if let refs = known[songID] { return refs }
        guard !loading.contains(songID) else { return nil }
        loading.insert(songID)
        Task { @MainActor [weak self] in
            let refs = await load()
            guard let self else { return }
            self.loading.remove(songID)
            self.remember(refs, for: songID)
        }
        return nil
    }

    /// `track` with its song's artists when it came without them and they are known.
    func filling(_ track: MusicTrack, songID: String, load: @escaping Load) -> MusicTrack {
        guard track.artistRefs.isEmpty,
              let refs = artists(ofSong: songID, load: load),
              !refs.isEmpty
        else { return track }
        return MusicTrack(
            id: track.id,
            name: track.name,
            artists: track.artists,
            artistRefs: refs,
            albumArtworkURL: track.albumArtworkURL,
            albumName: track.albumName,
            albumID: track.albumID,
            durationMilliseconds: track.durationMilliseconds,
            isExplicit: track.isExplicit,
            isPlayable: track.isPlayable,
            linkedFromID: track.linkedFromID,
            uri: track.uri
        )
    }

    private func remember(_ refs: [MusicArtistRef], for songID: String) {
        if known.updateValue(refs, forKey: songID) == nil {
            order.append(songID)
        }
        while order.count > Self.capacity {
            known.removeValue(forKey: order.removeFirst())
        }
    }
}
