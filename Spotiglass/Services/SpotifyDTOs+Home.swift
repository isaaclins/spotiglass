import Foundation

/// `GET /v1/me/player/recently-played` response. Each play history object wraps a
/// full track object plus the timestamp/context; the home feed only needs the track.
struct SpotifyRecentlyPlayedResponseDTO: Decodable {
    let items: [Item]

    struct Item: Decodable {
        let track: SpotifyTrackDTO?

        enum CodingKeys: String, CodingKey {
            case track
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            track = try container.decodeIfPresent(SpotifyTrackDTO.self, forKey: .track)
        }
    }

    enum CodingKeys: String, CodingKey {
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
    }
}
