import Foundation

enum SpotifyPlaylistPlayableDTO: Decodable {
    case track(SpotifyTrackDTO)
    case episode(SpotifyEpisodeDTO)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? "track"
        switch type {
        case "track":
            self = .track(try SpotifyTrackDTO(from: decoder))
        case "episode":
            self = .episode(try SpotifyEpisodeDTO(from: decoder))
        default:
            self = .track(try SpotifyTrackDTO(from: decoder))
        }
    }
}

struct SpotifyTrackDTO: Decodable {
    let id: String?
    let name: String
    let artists: [SpotifyArtistDTO]
    let album: SpotifyAlbumDTO?
    let durationMilliseconds: Int
    let isExplicit: Bool
    let isPlayable: Bool?
    let linkedFrom: SpotifyLinkedFromDTO?
    let uri: String
    let isLocal: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case artists
        case album
        case durationMilliseconds = "duration_ms"
        case isExplicit = "explicit"
        case isPlayable = "is_playable"
        case linkedFrom = "linked_from"
        case uri
        case isLocal = "is_local"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Unknown track"
        artists = try container.decodeIfPresent([SpotifyArtistDTO].self, forKey: .artists) ?? []
        album = try container.decodeIfPresent(SpotifyAlbumDTO.self, forKey: .album)
        durationMilliseconds = try container.decodeIfPresent(Int.self, forKey: .durationMilliseconds) ?? 0
        isExplicit = try container.decodeIfPresent(Bool.self, forKey: .isExplicit) ?? false
        isPlayable = try container.decodeIfPresent(Bool.self, forKey: .isPlayable)
        linkedFrom = try container.decodeIfPresent(SpotifyLinkedFromDTO.self, forKey: .linkedFrom)
        uri =
            try container.decodeIfPresent(String.self, forKey: .uri) ?? id.map { "spotify:track:\($0)" }
            ?? "spotify:track:unavailable"
        isLocal = try container.decodeIfPresent(Bool.self, forKey: .isLocal)
    }

    func domainModel() -> SpotifyTrack? {
        guard let id else { return nil }
        let artistRefs: [SpotifyArtistRef] = artists.compactMap { dto in
            guard let artistID = dto.id else { return nil }
            return SpotifyArtistRef(id: artistID, name: dto.name)
        }
        return SpotifyTrack(
            id: id,
            name: name,
            artists: artists.map(\.name),
            artistRefs: artistRefs,
            albumArtworkURL: album?.images.largestImageURL,
            albumName: album?.name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty },
            albumID: album?.id,
            durationMilliseconds: durationMilliseconds,
            isExplicit: isExplicit,
            isPlayable: isPlayable,
            linkedFromID: linkedFrom?.id,
            uri: uri
        )
    }

    func localDomainModel() -> SpotifyLocalTrack {
        SpotifyLocalTrack(
            name: name,
            artists: artists.map(\.name),
            durationMilliseconds: durationMilliseconds,
            uri: uri
        )
    }
}

struct SpotifyEpisodeDTO: Decodable {
    let id: String?
    let name: String
    let show: SpotifyShowDTO?
    let images: [SpotifyImageDTO]?
    let durationMilliseconds: Int
    let isPlayable: Bool?
    let uri: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case show
        case images
        case durationMilliseconds = "duration_ms"
        case isPlayable = "is_playable"
        case uri
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Unknown episode"
        show = try container.decodeIfPresent(SpotifyShowDTO.self, forKey: .show)
        images = try container.decodeIfPresent([SpotifyImageDTO].self, forKey: .images) ?? []
        durationMilliseconds = try container.decodeIfPresent(Int.self, forKey: .durationMilliseconds) ?? 0
        isPlayable = try container.decodeIfPresent(Bool.self, forKey: .isPlayable)
        uri =
            try container.decodeIfPresent(String.self, forKey: .uri) ?? id.map { "spotify:episode:\($0)" }
            ?? "spotify:episode:unavailable"
    }

    func domainModel() -> SpotifyEpisode? {
        guard let id else { return nil }
        return SpotifyEpisode(
            id: id,
            name: name,
            showName: show?.name,
            artworkURL: images?.largestImageURL,
            durationMilliseconds: durationMilliseconds,
            isPlayable: isPlayable,
            uri: uri
        )
    }
}

struct SpotifyArtistDTO: Decodable {
    let id: String?
    let name: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Unknown artist"
    }
}

struct SpotifyAlbumDTO: Decodable {
    let id: String?
    let name: String?
    let images: [SpotifyImageDTO]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case images
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        images = try container.decodeIfPresent([SpotifyImageDTO].self, forKey: .images) ?? []
    }
}

struct SpotifyLinkedFromDTO: Decodable {
    let id: String?

    enum CodingKeys: String, CodingKey {
        case id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
    }
}

struct SpotifyShowDTO: Decodable {
    let name: String

    enum CodingKeys: String, CodingKey {
        case name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Podcast"
    }
}
