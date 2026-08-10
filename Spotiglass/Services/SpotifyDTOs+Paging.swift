import Foundation

struct SpotifyPagingDTO<Item: Decodable>: Decodable {
    let limit: Int
    let next: URL?
    let offset: Int
    let total: Int
    let items: [Item]

    enum CodingKeys: String, CodingKey {
        case limit
        case next
        case offset
        case total
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? 0
        next = try container.decodeIfPresent(URL.self, forKey: .next)
        offset = try container.decodeIfPresent(Int.self, forKey: .offset) ?? 0
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
