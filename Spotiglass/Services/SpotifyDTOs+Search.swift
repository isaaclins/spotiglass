import Foundation

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

// MARK: - Artist detail (GET /v1/artists/{id}, albums)

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
