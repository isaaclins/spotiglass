import Foundation
import MusicKit

/// A song as the Apple Music API names it in a playlist's track list.
struct AppleMusicCloudSong: Equatable, Sendable {
    enum Kind: String, Sendable {
        case catalog = "songs"
        case library = "library-songs"
    }

    let id: String
    let kind: Kind
}

/// The two ratings Apple Music has. Love is what the Music app calls Favorite.
enum AppleMusicRating: Int, Sendable {
    case love = 1
    case dislike = -1
}

/// One editable playlist in the user's iCloud Music Library.
struct AppleMusicCloudPlaylist: Equatable, Sendable {
    let id: String
    let name: String
}

/// The library edits the Apple Music API offers. `MusicDataRequestCloudLibrary` is the live one.
protocol AppleMusicCloudLibrary: Sendable {
    func addToLibrary(songCatalogIDs: [String], albumCatalogIDs: [String]) async throws
    /// Creates an empty playlist and returns its cloud library ID (`p.…`).
    func createPlaylist(name: String) async throws -> String
    func addToPlaylist(cloudPlaylistID: String, songs: [AppleMusicCloudSong]) async throws
    /// `nil` clears the rating.
    func setRating(_ rating: AppleMusicRating?, songID: String, isLibraryID: Bool) async throws
    /// Every playlist the user can edit, with its cloud library ID.
    func editablePlaylists() async throws -> [AppleMusicCloudPlaylist]
    func playlistTracks(cloudPlaylistID: String) async throws -> [Song]
}

/// The Apple Music API through `MusicDataRequest`, which signs each request with the developer
/// token and the user token by itself. Requests are built by `AppleMusicCloudRequests` and sent
/// through `send`, so tests check them without a network.
struct MusicDataRequestCloudLibrary: AppleMusicCloudLibrary {
    typealias Send = @Sendable (URLRequest) async throws -> Data

    /// Upper bound for pages of library playlists, 100 each; only stops a runaway.
    static let maxPlaylistPages = 50
    static let maxPlaylistTrackPages = 20

    let send: Send

    init(send: @escaping Send = MusicDataRequestCloudLibrary.musicDataRequest) {
        self.send = send
    }

    @Sendable static func musicDataRequest(_ request: URLRequest) async throws -> Data {
        do {
            return try await MusicDataRequest(urlRequest: request).response().data
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            SpotiglassLog.error(
                .api,
                "Apple Music \(request.httpMethod ?? "GET") \(request.url?.path ?? "") failed: \(error)"
            )
            throw AppleMusicLibraryEditError.requestFailed
        }
    }

    func addToLibrary(songCatalogIDs: [String], albumCatalogIDs: [String]) async throws {
        guard let request = AppleMusicCloudRequests.addToLibrary(songs: songCatalogIDs, albums: albumCatalogIDs) else { return }
        _ = try await send(request)
    }

    func createPlaylist(name: String) async throws -> String {
        let data = try await send(AppleMusicCloudRequests.createPlaylist(name: name))
        guard let id = try JSONDecoder().decode(ResourceList.self, from: data).data.first?.id else {
            throw AppleMusicLibraryEditError.requestFailed
        }
        return id
    }

    func addToPlaylist(cloudPlaylistID: String, songs: [AppleMusicCloudSong]) async throws {
        guard !songs.isEmpty else { return }
        _ = try await send(AppleMusicCloudRequests.addToPlaylist(cloudPlaylistID: cloudPlaylistID, songs: songs))
    }

    func setRating(_ rating: AppleMusicRating?, songID: String, isLibraryID: Bool) async throws {
        _ = try await send(AppleMusicCloudRequests.rating(rating, songID: songID, isLibraryID: isLibraryID))
    }

    func editablePlaylists() async throws -> [AppleMusicCloudPlaylist] {
        var playlists: [AppleMusicCloudPlaylist] = []
        var next: String? = AppleMusicCloudRequests.libraryPlaylistsPath
        var pages = 0
        while let path = next, pages < Self.maxPlaylistPages {
            try Task.checkCancellation()
            let page = try JSONDecoder().decode(ResourceList.self, from: try await send(AppleMusicCloudRequests.get(path)))
            playlists += page.data.compactMap { resource in
                guard resource.attributes?.canEdit == true, let name = resource.attributes?.name else { return nil }
                return AppleMusicCloudPlaylist(id: resource.id, name: name)
            }
            next = page.next
            pages += 1
        }
        return playlists
    }

    func playlistTracks(cloudPlaylistID: String) async throws -> [Song] {
        var songs: [Song] = []
        var next: String? = AppleMusicCloudRequests.playlistTracksPath(cloudPlaylistID)
        var pages = 0
        while let path = next, pages < Self.maxPlaylistTrackPages {
            try Task.checkCancellation()
            let data: Data
            do {
                data = try await send(AppleMusicCloudRequests.get(path))
            } catch AppleMusicLibraryEditError.requestFailed where pages == 0 {
                // A new, empty playlist answers 404 for its tracks.
                return []
            }
            let page = try JSONDecoder().decode(SongPage.self, from: data)
            songs += page.data
            next = page.next
            pages += 1
        }
        return songs
    }

    private struct ResourceList: Decodable {
        struct Resource: Decodable {
            struct Attributes: Decodable {
                let name: String?
                let canEdit: Bool?
            }

            let id: String
            let attributes: Attributes?
        }

        let data: [Resource]
        let next: String?
    }

    private struct SongPage: Decodable {
        let data: [Song]
        let next: String?
    }
}

/// The Apple Music API requests behind library edits, as plain `URLRequest`s.
enum AppleMusicCloudRequests {
    static let baseURL = URL(string: "https://api.music.apple.com")!
    static let libraryPlaylistsPath = "/v1/me/library/playlists?limit=100"

    static func playlistTracksPath(_ cloudPlaylistID: String) -> String {
        "/v1/me/library/playlists/\(pathComponent(cloudPlaylistID))/tracks?limit=100"
    }

    /// `POST /v1/me/library?ids[songs]=…&ids[albums]=…`; `nil` when there is nothing to add.
    static func addToLibrary(songs: [String], albums: [String]) -> URLRequest? {
        guard !songs.isEmpty || !albums.isEmpty else { return nil }
        var components = URLComponents(url: baseURL.appendingPathComponent("/v1/me/library"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if !songs.isEmpty { items.append(URLQueryItem(name: "ids[songs]", value: songs.joined(separator: ","))) }
        if !albums.isEmpty { items.append(URLQueryItem(name: "ids[albums]", value: albums.joined(separator: ","))) }
        components.queryItems = items
        return request(components.url!, method: "POST")
    }

    static func createPlaylist(name: String) -> URLRequest {
        let body: [String: Any] = ["attributes": ["name": name, "description": ""]]
        return request(baseURL.appendingPathComponent("/v1/me/library/playlists"), method: "POST", json: body)
    }

    static func addToPlaylist(cloudPlaylistID: String, songs: [AppleMusicCloudSong]) -> URLRequest {
        let body: [String: Any] = ["data": songs.map { ["id": $0.id, "type": $0.kind.rawValue] }]
        return request(
            baseURL.appendingPathComponent("/v1/me/library/playlists/\(pathComponent(cloudPlaylistID))/tracks"),
            method: "POST",
            json: body
        )
    }

    /// `PUT` sets a rating, `DELETE` clears it.
    static func rating(_ rating: AppleMusicRating?, songID: String, isLibraryID: Bool) -> URLRequest {
        let url = baseURL.appendingPathComponent(
            "/v1/me/ratings/\(isLibraryID ? "library-songs" : "songs")/\(pathComponent(songID))"
        )
        guard let rating else { return request(url, method: "DELETE") }
        return request(url, method: "PUT", json: ["type": "rating", "attributes": ["value": rating.rawValue]])
    }

    /// A `GET` for a path the API returned (`next`) or built above, always on the API's host.
    static func get(_ path: String) -> URLRequest {
        request(URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL, method: "GET")
    }

    private static func pathComponent(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-_"))) ?? id
    }

    private static func request(_ url: URL, method: String, json: [String: Any]? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        }
        return request
    }
}
