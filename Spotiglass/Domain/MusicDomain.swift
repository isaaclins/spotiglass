import Foundation

// Service-neutral library models used by browsing UI and playback context.
//
// Every music service maps its own wire format into these types. Spotify's
// decoding lives in `Services/SpotifyDTOs+*.swift` (`*DTO`) and maps here via
// `domainModel()`. A later Apple Music provider maps MusicKit items the same way.
//
// `id` is the service's own identifier and `uri` is a playback reference that
// should only be interpreted by the owning service (for Spotify a
// `spotify:track:...` URI). Not there yet: several browsing view models, views
// and pins still check for the `spotify:track:` prefix (see "Music providers"
// in docs/architecture.md).
//
// The type names changed from `Spotify*` to `Music*`, but the Codable shape did
// not: playlist and track caches written by earlier builds keep decoding.

struct MusicUserProfile: Codable, Equatable {
    let id: String
    let displayName: String?
    let country: String?
}

struct MusicPlaylistSummary: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let ownerID: String
    let ownerName: String
    let imageURL: URL?
    let trackCount: Int?
    let snapshotID: String
}

struct MusicPlaylistTrackItem: Codable, Equatable, Identifiable {
    let id: String
    let content: MusicPlaylistItemContent
}

/// One or more exact positions for a URI in a playlist mutation.
struct MusicPlaylistTrackRemoval: Equatable {
    let uri: String
    let positions: [Int]
}

/// Paged result from `GET /v1/me/tracks` (Liked Songs). `totalAvailable` is Spotify's total; `tracks` is complete unless a caller explicitly caps pagination.
struct MusicSavedTracksResult: Equatable {
    let tracks: [MusicPlaylistTrackItem]
    let totalAvailable: Int
}

enum MusicPlaylistItemContent: Codable, Equatable {
    case track(MusicTrack)
    case episode(MusicEpisode)
    case localTrack(MusicLocalTrack)
    case unavailable(reason: String)
}

struct MusicArtistRef: Codable, Equatable, Identifiable {
    let id: String
    let name: String
}

struct MusicTrack: Equatable, Identifiable {
    let id: String
    let name: String
    let artists: [String]
    /// Present when Spotify returned artist IDs (playlist/search tracks). Used for tappable artist links.
    let artistRefs: [MusicArtistRef]
    let albumArtworkURL: URL?
    let albumName: String?
    let albumID: String?
    let durationMilliseconds: Int
    let isExplicit: Bool
    let isPlayable: Bool?
    let linkedFromID: String?
    let uri: String

    init(
        id: String,
        name: String,
        artists: [String],
        artistRefs: [MusicArtistRef] = [],
        albumArtworkURL: URL?,
        albumName: String? = nil,
        albumID: String? = nil,
        durationMilliseconds: Int,
        isExplicit: Bool,
        isPlayable: Bool?,
        linkedFromID: String?,
        uri: String
    ) {
        self.id = id
        self.name = name
        self.artists = artists
        self.artistRefs = artistRefs
        self.albumArtworkURL = albumArtworkURL
        self.albumName = albumName
        self.albumID = albumID
        self.durationMilliseconds = durationMilliseconds
        self.isExplicit = isExplicit
        self.isPlayable = isPlayable
        self.linkedFromID = linkedFromID
        self.uri = uri
    }
}

extension MusicTrack: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case artists
        case artistRefs
        case albumArtworkURL
        case albumName
        case albumID
        case durationMilliseconds
        case isExplicit
        case isPlayable
        case linkedFromID
        case uri
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        artists = try c.decode([String].self, forKey: .artists)
        artistRefs = try c.decodeIfPresent([MusicArtistRef].self, forKey: .artistRefs) ?? []
        albumArtworkURL = try c.decodeIfPresent(URL.self, forKey: .albumArtworkURL)
        albumName = try c.decodeIfPresent(String.self, forKey: .albumName)
        albumID = try c.decodeIfPresent(String.self, forKey: .albumID)
        durationMilliseconds = try c.decode(Int.self, forKey: .durationMilliseconds)
        isExplicit = try c.decode(Bool.self, forKey: .isExplicit)
        isPlayable = try c.decodeIfPresent(Bool.self, forKey: .isPlayable)
        linkedFromID = try c.decodeIfPresent(String.self, forKey: .linkedFromID)
        uri = try c.decode(String.self, forKey: .uri)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(artists, forKey: .artists)
        try c.encode(artistRefs, forKey: .artistRefs)
        try c.encodeIfPresent(albumArtworkURL, forKey: .albumArtworkURL)
        try c.encodeIfPresent(albumName, forKey: .albumName)
        try c.encodeIfPresent(albumID, forKey: .albumID)
        try c.encode(durationMilliseconds, forKey: .durationMilliseconds)
        try c.encode(isExplicit, forKey: .isExplicit)
        try c.encodeIfPresent(isPlayable, forKey: .isPlayable)
        try c.encodeIfPresent(linkedFromID, forKey: .linkedFromID)
        try c.encode(uri, forKey: .uri)
    }
}

struct MusicArtistDetail: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let imageURL: URL?
    let followersTotal: Int?
    let genres: [String]
    let uri: String
}

enum MusicArtistAlbumGroup: String, Codable, Equatable, CaseIterable {
    case album
    case single
    case compilation
    case appearsOn = "appears_on"
}

/// How far back "top" items (most played tracks and artists) look.
enum MusicTopItemsTimeRange: String, Equatable {
    /// Roughly the last four weeks.
    case shortTerm = "short_term"
    /// Roughly the last six months.
    case mediumTerm = "medium_term"
    /// Several years.
    case longTerm = "long_term"
}

struct MusicArtistAlbum: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let imageURL: URL?
    let releaseYear: String?
    let totalTracks: Int
    let group: MusicArtistAlbumGroup
    let uri: String
}

struct MusicArtist: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let imageURL: URL?
    let uri: String
}

struct MusicAlbum: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let artists: [String]
    let imageURL: URL?
    let uri: String
}

struct MusicSearchPaging: Codable, Equatable {
    let total: Int
    let next: URL?
}

struct MusicSearchResults: Codable, Equatable {
    let tracks: [MusicTrack]
    let artists: [MusicArtist]
    let albums: [MusicAlbum]
    let playlists: [MusicPlaylistSummary]
    let tracksPaging: MusicSearchPaging?
    let artistsPaging: MusicSearchPaging?
    let albumsPaging: MusicSearchPaging?
    let playlistsPaging: MusicSearchPaging?

    init(
        tracks: [MusicTrack],
        artists: [MusicArtist],
        albums: [MusicAlbum],
        playlists: [MusicPlaylistSummary],
        tracksPaging: MusicSearchPaging? = nil,
        artistsPaging: MusicSearchPaging? = nil,
        albumsPaging: MusicSearchPaging? = nil,
        playlistsPaging: MusicSearchPaging? = nil
    ) {
        self.tracks = tracks
        self.artists = artists
        self.albums = albums
        self.playlists = playlists
        self.tracksPaging = tracksPaging
        self.artistsPaging = artistsPaging
        self.albumsPaging = albumsPaging
        self.playlistsPaging = playlistsPaging
    }
}

struct MusicEpisode: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let showName: String?
    let artworkURL: URL?
    let durationMilliseconds: Int
    let isPlayable: Bool?
    let uri: String
}

struct MusicLocalTrack: Codable, Equatable {
    let name: String
    let artists: [String]
    let durationMilliseconds: Int
    let uri: String
}
