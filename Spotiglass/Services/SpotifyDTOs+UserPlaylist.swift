import Foundation

struct SpotifyUserProfileDTO: Decodable {
    let id: String
    let displayName: String?
    let country: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case country
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? "unknown-user"
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        country = try container.decodeIfPresent(String.self, forKey: .country)
    }

    func domainModel() -> SpotifyUserProfile {
        SpotifyUserProfile(
            id: id,
            displayName: displayName,
            country: country
        )
    }
}

struct SpotifyPlaylistDTO: Decodable {
    let id: String
    let name: String
    let owner: SpotifyOwnerDTO
    let images: [SpotifyImageDTO]
    let items: SpotifyPlaylistTracksReferenceDTO
    let snapshotID: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case owner
        case images
        case items
        case tracks
        case snapshotID = "snapshot_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? "unknown-playlist"
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled playlist"
        owner = try container.decodeIfPresent(SpotifyOwnerDTO.self, forKey: .owner) ?? SpotifyOwnerDTO(id: "unknown-owner", displayName: nil)
        images = try container.decodeIfPresent([SpotifyImageDTO].self, forKey: .images) ?? []
        // The February 2026 Web API rename moved playlist track summary from `tracks`
        // to `items`. Legacy responses (Extended Quota Mode apps) still emit `tracks`,
        // so we accept either to keep the client compatible across deployment modes.
        let itemsReference = try container.decodeIfPresent(SpotifyPlaylistTracksReferenceDTO.self, forKey: .items)
        let tracksReference = try container.decodeIfPresent(SpotifyPlaylistTracksReferenceDTO.self, forKey: .tracks)
        items = itemsReference ?? tracksReference ?? SpotifyPlaylistTracksReferenceDTO(total: 0)
        snapshotID = try container.decodeIfPresent(String.self, forKey: .snapshotID) ?? id
    }

    func domainModel() -> SpotifyPlaylistSummary {
        SpotifyPlaylistSummary(
            id: id,
            name: name,
            ownerName: owner.displayName ?? owner.id,
            imageURL: images.largestImageURL,
            trackCount: items.total,
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
    let isLocal: Bool?
    let item: SpotifyPlaylistPlayableDTO?

    enum CodingKeys: String, CodingKey {
        case isLocal = "is_local"
        case item
        case track
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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

