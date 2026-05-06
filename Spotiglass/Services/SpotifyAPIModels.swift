import Foundation

struct SpotifyPagingDTO<Item: Decodable>: Decodable {
    let href: String?
    let limit: Int
    let next: URL?
    let offset: Int
    let previous: URL?
    let total: Int
    let items: [Item]

    enum CodingKeys: String, CodingKey {
        case href
        case limit
        case next
        case offset
        case previous
        case total
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        href = try container.decodeIfPresent(String.self, forKey: .href)
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? 0
        next = try container.decodeIfPresent(URL.self, forKey: .next)
        offset = try container.decodeIfPresent(Int.self, forKey: .offset) ?? 0
        previous = try container.decodeIfPresent(URL.self, forKey: .previous)
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
        // Spotify sometimes embeds `null` entries in paging `items` (e.g. search playlists).
        // Decoding `[Item]` fails at those indices; optional elements decode as nil and are dropped.
        if let optionalItems = try container.decodeIfPresent([Item?].self, forKey: .items) {
            items = optionalItems.compactMap { $0 }
        } else {
            items = []
        }
    }
}

struct SpotifyUserProfileDTO: Decodable {
    let id: String
    let displayName: String?
    let images: [SpotifyImageDTO]?
    let country: String?
    let product: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case images
        case country
        case product
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? "unknown-user"
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        images = try container.decodeIfPresent([SpotifyImageDTO].self, forKey: .images) ?? []
        country = try container.decodeIfPresent(String.self, forKey: .country)
        product = try container.decodeIfPresent(String.self, forKey: .product)
    }

    func domainModel() -> SpotifyUserProfile {
        SpotifyUserProfile(
            id: id,
            displayName: displayName,
            imageURL: images?.largestImageURL,
            country: country,
            product: SpotifyProductTier(rawValue: product ?? "") ?? .unknown
        )
    }
}

struct SpotifyPlaylistDTO: Decodable {
    let id: String
    let name: String
    let description: String?
    let owner: SpotifyOwnerDTO
    let images: [SpotifyImageDTO]
    let items: SpotifyPlaylistTracksReferenceDTO
    let isPublic: Bool?
    let isCollaborative: Bool
    let snapshotID: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case owner
        case images
        case items
        case tracks
        case isPublic = "public"
        case isCollaborative = "collaborative"
        case snapshotID = "snapshot_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? "unknown-playlist"
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled playlist"
        description = try container.decodeIfPresent(String.self, forKey: .description)
        owner = try container.decodeIfPresent(SpotifyOwnerDTO.self, forKey: .owner) ?? SpotifyOwnerDTO(id: "unknown-owner", displayName: nil)
        images = try container.decodeIfPresent([SpotifyImageDTO].self, forKey: .images) ?? []
        // The February 2026 Web API rename moved playlist track summary from `tracks`
        // to `items`. Legacy responses (Extended Quota Mode apps) still emit `tracks`,
        // so we accept either to keep the client compatible across deployment modes.
        let itemsReference = try container.decodeIfPresent(SpotifyPlaylistTracksReferenceDTO.self, forKey: .items)
        let tracksReference = try container.decodeIfPresent(SpotifyPlaylistTracksReferenceDTO.self, forKey: .tracks)
        items = itemsReference ?? tracksReference ?? SpotifyPlaylistTracksReferenceDTO(total: 0)
        isPublic = try container.decodeIfPresent(Bool.self, forKey: .isPublic)
        isCollaborative = try container.decodeIfPresent(Bool.self, forKey: .isCollaborative) ?? false
        snapshotID = try container.decodeIfPresent(String.self, forKey: .snapshotID) ?? id
    }

    func domainModel() -> SpotifyPlaylistSummary {
        SpotifyPlaylistSummary(
            id: id,
            name: name,
            description: description?.nilIfEmpty,
            ownerName: owner.displayName ?? owner.id,
            imageURL: images.largestImageURL,
            trackCount: items.total,
            isPublic: isPublic,
            isCollaborative: isCollaborative,
            snapshotID: snapshotID
        )
    }
}

struct SpotifyPlaylistTracksReferenceDTO: Decodable {
    let total: Int

    enum CodingKeys: String, CodingKey {
        case total
    }

    init(total: Int) {
        self.total = total
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
    }
}

struct SpotifyOwnerDTO: Decodable {
    let id: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }

    init(id: String, displayName: String?) {
        self.id = id
        self.displayName = displayName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? "unknown-owner"
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    }
}

struct SpotifyImageDTO: Decodable {
    let url: URL?
    let height: Int?
    let width: Int?

    enum CodingKeys: String, CodingKey {
        case url
        case height
        case width
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
    }
}

struct SpotifyPlaylistTrackItemDTO: Decodable {
    let addedAt: Date?
    let isLocal: Bool?
    let item: SpotifyPlaylistPlayableDTO?

    enum CodingKeys: String, CodingKey {
        case addedAt = "added_at"
        case isLocal = "is_local"
        case item
        case track
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt)
        isLocal = try container.decodeIfPresent(Bool.self, forKey: .isLocal)
        // The February 2026 Web API rename moved each playlist entry's playable from
        // `track` to `item`. The deprecated `track` field is still emitted for
        // compatibility, so we prefer the new `item` and fall back to `track`.
        let itemPayload = try container.decodeIfPresent(SpotifyPlaylistPlayableDTO.self, forKey: .item)
        let trackPayload = try container.decodeIfPresent(SpotifyPlaylistPlayableDTO.self, forKey: .track)
        item = itemPayload ?? trackPayload
    }

    func domainModel(position: Int) -> SpotifyPlaylistTrackItem {
        let content: SpotifyPlaylistItemContent
        switch item {
        case let .track(track):
            if isLocal == true || track.isLocal == true {
                content = .localTrack(track.localDomainModel())
            } else if let domainTrack = track.domainModel() {
                content = .track(domainTrack)
            } else {
                content = .unavailable(reason: "Track is unavailable.")
            }
        case let .episode(episode):
            if let domainEpisode = episode.domainModel() {
                content = .episode(domainEpisode)
            } else {
                content = .unavailable(reason: "Episode is unavailable.")
            }
        case .none:
            content = .unavailable(reason: "Playlist item has no playable content.")
        }

        return SpotifyPlaylistTrackItem(
            id: itemID(position: position, content: content),
            addedAt: addedAt,
            content: content
        )
    }

    /// Playlist rows must be uniquely identifiable for SwiftUI (`List`/`ForEach`). The same catalog
    /// track or episode can appear multiple times in one playlist, so the Spotify id alone is not unique.
    private func itemID(position: Int, content: SpotifyPlaylistItemContent) -> String {
        switch content {
        case let .track(track):
            return "\(track.id):\(position)"
        case let .episode(episode):
            return "\(episode.id):\(position)"
        case let .localTrack(track):
            return "local:\(track.uri):\(position)"
        case .unavailable:
            return "unavailable:\(position)"
        }
    }
}

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
        uri = try container.decodeIfPresent(String.self, forKey: .uri) ?? id.map { "spotify:track:\($0)" } ?? "spotify:track:unavailable"
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
            albumName: album?.name,
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
    let isExplicit: Bool
    let isPlayable: Bool?
    let uri: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case show
        case images
        case durationMilliseconds = "duration_ms"
        case isExplicit = "explicit"
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
        isExplicit = try container.decodeIfPresent(Bool.self, forKey: .isExplicit) ?? false
        isPlayable = try container.decodeIfPresent(Bool.self, forKey: .isPlayable)
        uri = try container.decodeIfPresent(String.self, forKey: .uri) ?? id.map { "spotify:episode:\($0)" } ?? "spotify:episode:unavailable"
    }

    func domainModel() -> SpotifyEpisode? {
        guard let id else { return nil }
        return SpotifyEpisode(
            id: id,
            name: name,
            showName: show?.name,
            artworkURL: images?.largestImageURL,
            durationMilliseconds: durationMilliseconds,
            isExplicit: isExplicit,
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

private extension Array where Element == SpotifyImageDTO {
    var largestImageURL: URL? {
        sorted { lhs, rhs in
            (lhs.width ?? lhs.height ?? 0) > (rhs.width ?? rhs.height ?? 0)
        }
        .first?
        .url
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

struct SpotifySearchResponseDTO: Decodable {
    let tracks: SpotifyPagingDTO<SpotifyTrackDTO>?
    let artists: SpotifyPagingDTO<SpotifySearchArtistDTO>?
    let albums: SpotifyPagingDTO<SpotifySearchAlbumDTO>?
    let playlists: SpotifyPagingDTO<SpotifyPlaylistDTO>?

    func domainModel() -> SpotifySearchResults {
        SpotifySearchResults(
            tracks: (tracks?.items ?? []).compactMap { $0.domainModel() },
            artists: (artists?.items ?? []).map { $0.domainModel() },
            albums: (albums?.items ?? []).map { $0.domainModel() },
            playlists: (playlists?.items ?? []).map { $0.domainModel() }
        )
    }
}

struct SpotifySearchArtistDTO: Decodable {
    let id: String?
    let name: String
    let images: [SpotifyImageDTO]?
    let uri: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case images
        case uri
    }

    func domainModel() -> SpotifyArtist {
        let resolvedID = id ?? "unknown-artist"
        return SpotifyArtist(
            id: resolvedID,
            name: name,
            imageURL: images?.largestImageURL,
            uri: uri ?? "spotify:artist:\(resolvedID)"
        )
    }
}

struct SpotifySearchAlbumDTO: Decodable {
    let id: String?
    let name: String
    let artists: [SpotifyArtistDTO]
    let images: [SpotifyImageDTO]?
    let uri: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case artists
        case images
        case uri
    }

    func domainModel() -> SpotifyAlbum {
        let resolvedID = id ?? "unknown-album"
        return SpotifyAlbum(
            id: resolvedID,
            name: name,
            artists: artists.map(\.name),
            imageURL: images?.largestImageURL,
            uri: uri ?? "spotify:album:\(resolvedID)"
        )
    }
}

// MARK: - Artist detail (GET /v1/artists/{id}, top-tracks, albums)

struct SpotifyFollowersDTO: Decodable {
    let total: Int?
}

struct SpotifyArtistDetailDTO: Decodable {
    let id: String?
    let name: String?
    let images: [SpotifyImageDTO]?
    let followers: SpotifyFollowersDTO?
    let genres: [String]?
    let uri: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case images
        case followers
        case genres
        case uri
    }

    func domainModel() -> SpotifyArtistDetail {
        let resolvedID = id ?? "unknown-artist"
        return SpotifyArtistDetail(
            id: resolvedID,
            name: name ?? "Artist",
            imageURL: images?.largestImageURL,
            followersTotal: followers?.total,
            genres: genres ?? [],
            uri: uri ?? "spotify:artist:\(resolvedID)"
        )
    }
}

struct SpotifyTopTracksResponseDTO: Decodable {
    let tracks: [SpotifyTrackDTO]
}

struct SpotifyArtistAlbumDTO: Decodable {
    let id: String?
    let name: String?
    let images: [SpotifyImageDTO]?
    let releaseDate: String?
    let totalTracks: Int?
    let uri: String?
    let albumGroup: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case images
        case releaseDate = "release_date"
        case totalTracks = "total_tracks"
        case uri
        case albumGroup = "album_group"
    }

    func domainModel() -> SpotifyArtistAlbum? {
        guard let id else { return nil }
        let resolvedName = name ?? "Album"
        let groupRaw = albumGroup ?? "album"
        let group = SpotifyArtistAlbumGroup(rawValue: groupRaw) ?? .album
        let year: String?
        if let releaseDate {
            year = String(releaseDate.prefix(4))
        } else {
            year = nil
        }
        return SpotifyArtistAlbum(
            id: id,
            name: resolvedName,
            imageURL: images?.largestImageURL,
            releaseYear: year,
            totalTracks: totalTracks ?? 0,
            group: group,
            uri: uri ?? "spotify:album:\(id)"
        )
    }
}
