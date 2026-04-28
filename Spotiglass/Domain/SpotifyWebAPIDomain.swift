import Foundation

struct SpotifyUserProfile: Codable, Equatable {
    let id: String
    let displayName: String?
    let imageURL: URL?
    let country: String?
    let product: SpotifyProductTier
}

enum SpotifyProductTier: String, Codable, Equatable {
    case premium
    case free
    case open
    case unknown
}

struct SpotifyPlaylistSummary: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let ownerName: String
    let imageURL: URL?
    let trackCount: Int
    let isPublic: Bool?
    let isCollaborative: Bool
    let snapshotID: String
}

struct SpotifyPlaylistTrackItem: Codable, Equatable, Identifiable {
    let id: String
    let addedAt: Date?
    let content: SpotifyPlaylistItemContent
}

enum SpotifyPlaylistItemContent: Codable, Equatable {
    case track(SpotifyTrack)
    case episode(SpotifyEpisode)
    case localTrack(SpotifyLocalTrack)
    case unavailable(reason: String)
}

struct SpotifyTrack: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let artists: [String]
    let albumArtworkURL: URL?
    let durationMilliseconds: Int
    let isExplicit: Bool
    let isPlayable: Bool?
    let linkedFromID: String?
    let uri: String
}

struct SpotifyEpisode: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let showName: String?
    let artworkURL: URL?
    let durationMilliseconds: Int
    let isExplicit: Bool
    let isPlayable: Bool?
    let uri: String
}

struct SpotifyLocalTrack: Codable, Equatable {
    let name: String
    let artists: [String]
    let albumName: String?
    let durationMilliseconds: Int
    let uri: String
}
