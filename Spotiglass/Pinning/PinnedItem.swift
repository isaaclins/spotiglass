import Foundation

/// Kind of Spotify entity (or virtual entity) that can live in the pinned area
/// of the sidebar.
enum PinnedItemKind: String, Codable, Equatable, CaseIterable {
    case playlist
    case artist
    case album
    case track
    case likedSongs
}

/// One pinned row. Tracks pinned from a playlist remember the originating
/// playlist so that follow-up actions can refer back to it; everything else
/// stores the bare metadata needed to render and act on the row even while
/// offline.
struct PinnedItem: Identifiable, Equatable, Codable, Hashable {
    let id: String
    let kind: PinnedItemKind
    var title: String
    var subtitle: String
    var artworkURL: URL?
    /// `spotify:<kind>:<id>` for real Spotify entities; `nil` for virtual rows
    /// like Liked Songs which have no list-level URI.
    let spotifyURI: String?
    var isStale: Bool
    /// Snapshot metadata retained for playlist pins so public playlists can be
    /// loaded even when they are not in the signed-in library.
    let playlistOwnerID: String?
    let playlistTrackCount: Int?
    let playlistSnapshotID: String?

    init(
        id: String,
        kind: PinnedItemKind,
        title: String,
        subtitle: String,
        artworkURL: URL?,
        spotifyURI: String?,
        isStale: Bool,
        playlistOwnerID: String? = nil,
        playlistTrackCount: Int? = nil,
        playlistSnapshotID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.spotifyURI = spotifyURI
        self.isStale = isStale
        self.playlistOwnerID = playlistOwnerID
        self.playlistTrackCount = playlistTrackCount
        self.playlistSnapshotID = playlistSnapshotID
    }

    /// ID for the Liked Songs virtual row. Stable across processes / accounts;
    /// duplicated only when the same row is pinned for the same account.
    static let likedSongsID = "likedSongs"

    /// Stable identifier formula for Spotify-backed pins.
    static func id(forKind kind: PinnedItemKind, spotifyID: String) -> String {
        "\(kind.rawValue):\(spotifyID)"
    }
}

extension PinnedItem {
    static func playlist(_ playlist: SpotifyPlaylistSummary) -> PinnedItem {
        PinnedItem(
            id: id(forKind: .playlist, spotifyID: playlist.id),
            kind: .playlist,
            title: playlist.name,
            subtitle: playlist.ownerName,
            artworkURL: playlist.imageURL,
            spotifyURI: "spotify:playlist:\(playlist.id)",
            isStale: false,
            playlistOwnerID: playlist.ownerID,
            playlistTrackCount: playlist.trackCount,
            playlistSnapshotID: playlist.snapshotID
        )
    }

    static func artist(_ artist: SpotifyArtistDetail) -> PinnedItem {
        PinnedItem(
            id: id(forKind: .artist, spotifyID: artist.id),
            kind: .artist,
            title: artist.name,
            subtitle: SpotiglassL10n.string("browser.palette.subtitle.artist"),
            artworkURL: artist.imageURL,
            spotifyURI: artist.uri,
            isStale: false
        )
    }

    /// Convenience for palette artist hits where we only have the lighter ``SpotifyArtist``.
    static func artist(_ artist: SpotifyArtist) -> PinnedItem {
        PinnedItem(
            id: id(forKind: .artist, spotifyID: artist.id),
            kind: .artist,
            title: artist.name,
            subtitle: SpotiglassL10n.string("browser.palette.subtitle.artist"),
            artworkURL: artist.imageURL,
            spotifyURI: artist.uri,
            isStale: false
        )
    }

    static func album(_ album: SpotifyArtistAlbum) -> PinnedItem {
        PinnedItem(
            id: id(forKind: .album, spotifyID: album.id),
            kind: .album,
            title: album.name,
            subtitle: album.releaseYear ?? SpotiglassL10n.string("pin.album.default"),
            artworkURL: album.imageURL,
            spotifyURI: album.uri,
            isStale: false
        )
    }

    static func album(_ album: SpotifyAlbum) -> PinnedItem {
        PinnedItem(
            id: id(forKind: .album, spotifyID: album.id),
            kind: .album,
            title: album.name,
            subtitle: album.artists.joined(separator: ", "),
            artworkURL: album.imageURL,
            spotifyURI: album.uri,
            isStale: false
        )
    }

    static func track(_ track: SpotifyTrack) -> PinnedItem {
        let canonicalID = canonicalTrackID(for: track) ?? track.id
        return PinnedItem(
            id: id(forKind: .track, spotifyID: canonicalID),
            kind: .track,
            title: track.name,
            subtitle: track.artists.joined(separator: ", "),
            artworkURL: track.albumArtworkURL,
            spotifyURI: track.uri,
            isStale: false
        )
    }

    static func likedSongs(ownerDisplay: String, artworkURL: URL?) -> PinnedItem {
        PinnedItem(
            id: PinnedItem.likedSongsID,
            kind: .likedSongs,
            title: SpotiglassL10n.string("pin.likedSongs"),
            subtitle: ownerDisplay,
            artworkURL: artworkURL,
            spotifyURI: nil,
            isStale: false
        )
    }

    /// Virtual Liked Songs metadata is persisted with pins, but its localized
    /// title and fallback owner must be resolved when the row renders.
    func localizedTitle(locale: Locale = SpotiglassL10n.locale) -> String {
        guard kind == .likedSongs else { return title }
        return SpotiglassL10n.string("pin.likedSongs", locale: locale)
    }

    func localizedSubtitle(locale: Locale = SpotiglassL10n.locale) -> String {
        guard kind == .likedSongs else { return subtitle }
        let englishFallback = SpotiglassL10n.string(
            "browser.likedSongs.owner.you",
            locale: Locale(identifier: "en")
        )
        guard subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || subtitle == englishFallback else {
            return subtitle
        }
        return SpotiglassL10n.string("browser.likedSongs.owner.you", locale: locale)
    }
}

extension PinnedItem {
    /// Spotify-side identifier for `kind` items (`nil` for the virtual Liked
    /// Songs row, which has no Spotify entity backing the list itself).
    var spotifyID: String? {
        if id == PinnedItem.likedSongsID { return nil }
        let prefix = "\(kind.rawValue):"
        guard id.hasPrefix(prefix) else { return nil }
        return String(id.dropFirst(prefix.count))
    }

    /// Reconstructs the summary captured when a playlist was pinned. Older pins
    /// have no snapshot fields, so the playlist ID is a safe cache namespace.
    var playlistSummary: SpotifyPlaylistSummary? {
        guard kind == .playlist, let spotifyID else { return nil }
        return SpotifyPlaylistSummary(
            id: spotifyID,
            name: title,
            ownerID: playlistOwnerID ?? "",
            ownerName: subtitle,
            imageURL: artworkURL,
            trackCount: playlistTrackCount,
            snapshotID: playlistSnapshotID ?? spotifyID
        )
    }

    /// Canonical track identity shared by row pinning, pin state, and fallback
    /// deduplication. A URI key is retained alongside the ID so either Spotify
    /// representation recognizes the same track.
    static func trackIdentityKeys(for track: SpotifyTrack) -> Set<String> {
        var keys = Set<String>()
        if let id = canonicalTrackID(for: track) {
            keys.insert("id:\(id)")
        }
        if let uri = canonicalTrackURI(track.uri) {
            keys.insert("uri:\(uri)")
        }
        return keys
    }

    static func canonicalTrackID(for track: SpotifyTrack) -> String? {
        if let uriID = canonicalTrackID(fromSpotifyURI: track.uri) {
            return uriID
        }
        let id = track.id.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    static func canonicalTrackID(fromSpotifyURI uri: String?) -> String? {
        guard let uri = canonicalTrackURI(uri) else { return nil }
        let prefix = "spotify:track:"
        let id = String(uri.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    static func canonicalTrackURI(_ uri: String?) -> String? {
        guard let uri else { return nil }
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("spotify:track:") else { return nil }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Rewrites pins written before playlist rows separated their occurrence ID
    /// from the canonical Spotify track ID. A canonical pin already passes
    /// through unchanged.
    func migratedLegacyTrackPin() -> PinnedItem {
        guard kind == .track,
              let canonicalID = PinnedItem.canonicalTrackID(fromSpotifyURI: spotifyURI)
                ?? legacyTrackID
        else { return self }
        let canonicalPinID = PinnedItem.id(forKind: .track, spotifyID: canonicalID)
        guard id != canonicalPinID else { return self }
        return PinnedItem(
            id: canonicalPinID,
            kind: kind,
            title: title,
            subtitle: subtitle,
            artworkURL: artworkURL,
            spotifyURI: spotifyURI,
            isStale: isStale,
            playlistOwnerID: playlistOwnerID,
            playlistTrackCount: playlistTrackCount,
            playlistSnapshotID: playlistSnapshotID
        )
    }

    static func migrateLegacyTrackPins(_ items: [PinnedItem]) -> [PinnedItem] {
        var seenIDs = Set<String>()
        var migrated: [PinnedItem] = []
        for item in items {
            let normalized = item.migratedLegacyTrackPin()
            guard seenIDs.insert(normalized.id).inserted else { continue }
            migrated.append(normalized)
        }
        return migrated
    }

    private var legacyTrackID: String? {
        guard kind == .track, let spotifyID else { return nil }
        let pieces = spotifyID.split(separator: ":")
        guard let first = pieces.first else { return nil }
        return pieces.count > 1 ? pieces.dropLast().joined(separator: ":") : String(first)
    }
}
