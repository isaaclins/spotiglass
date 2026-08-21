import Foundation

// App-facing Spotify library models used by browsing UI and playback context.
// Wire-format decoding lives in `Services/SpotifyAPIModels.swift` (`*DTO`) and maps here via `domainModel()`.

struct SpotifyUserProfile: Codable, Equatable {
    let id: String
    let displayName: String?
    let country: String?
}

struct SpotifyPlaylistSummary: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let ownerID: String
    let ownerName: String
    let imageURL: URL?
    let trackCount: Int?
    let snapshotID: String
}

struct SpotifyPlaylistTrackItem: Codable, Equatable, Identifiable {
    let id: String
    let content: SpotifyPlaylistItemContent
}

/// One or more exact positions for a URI in a playlist mutation.
struct SpotifyPlaylistTrackRemoval: Equatable {
    let uri: String
    let positions: [Int]
}

/// Paged result from `GET /v1/me/tracks` (Liked Songs). `totalAvailable` is Spotify's total; `tracks` is complete unless a caller explicitly caps pagination.
struct SpotifySavedTracksResult: Equatable {
    let tracks: [SpotifyPlaylistTrackItem]
    let totalAvailable: Int
}

enum SpotifyPlaylistItemContent: Codable, Equatable {
    case track(SpotifyTrack)
    case episode(SpotifyEpisode)
    case localTrack(SpotifyLocalTrack)
    case unavailable(reason: String)
}

struct SpotifyArtistRef: Codable, Equatable, Identifiable {
    let id: String
    let name: String
}

struct SpotifyTrack: Equatable, Identifiable {
    let id: String
    let name: String
    let artists: [String]
    /// Present when Spotify returned artist IDs (playlist/search tracks). Used for tappable artist links.
    let artistRefs: [SpotifyArtistRef]
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
        artistRefs: [SpotifyArtistRef] = [],
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

extension SpotifyTrack: Codable {
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
        artistRefs = try c.decodeIfPresent([SpotifyArtistRef].self, forKey: .artistRefs) ?? []
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

struct SpotifyArtistDetail: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let imageURL: URL?
    let followersTotal: Int?
    let genres: [String]
    let uri: String
}

enum SpotifyArtistAlbumGroup: String, Codable, Equatable {
    case album
    case single
    case compilation
    case appearsOn = "appears_on"
}

struct SpotifyArtistAlbum: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let imageURL: URL?
    let releaseYear: String?
    let totalTracks: Int
    let group: SpotifyArtistAlbumGroup
    let uri: String
}

struct SpotifyArtist: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let imageURL: URL?
    let uri: String
}

struct SpotifyAlbum: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let artists: [String]
    let imageURL: URL?
    let uri: String
}

struct SpotifySearchResults: Codable, Equatable {
    let tracks: [SpotifyTrack]
    let artists: [SpotifyArtist]
    let albums: [SpotifyAlbum]
    let playlists: [SpotifyPlaylistSummary]
}

struct SpotifyEpisode: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let showName: String?
    let artworkURL: URL?
    let durationMilliseconds: Int
    let isPlayable: Bool?
    let uri: String
}

struct SpotifyLocalTrack: Codable, Equatable {
    let name: String
    let artists: [String]
    let durationMilliseconds: Int
    let uri: String
}
