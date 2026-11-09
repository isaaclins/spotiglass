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
    /// Creates a playlist with these songs in one request and returns its cloud library ID
    /// (`p.…`). One request, so a failure leaves no empty playlist behind.
    func createPlaylist(name: String, songs: [AppleMusicCloudSong]) async throws -> String
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

    func createPlaylist(name: String, songs: [AppleMusicCloudSong]) async throws -> String {
        let data = try await send(AppleMusicCloudRequests.createPlaylist(name: name, songs: songs))
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

    /// The songs go into the same request (`relationships.tracks`), so the playlist is created
    /// with them or not at all.
    static func createPlaylist(name: String, songs: [AppleMusicCloudSong] = []) -> URLRequest {
        var body: [String: Any] = ["attributes": ["name": name, "description": ""]]
        if !songs.isEmpty {
            body["relationships"] = ["tracks": ["data": songs.map { ["id": $0.id, "type": $0.kind.rawValue] }]]
        }
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

// MARK: - Playlist covers (#444)

/// A library playlist's cover as the Apple Music API describes it.
///
/// A playlist without a cover of its own gets one Apple generates: a colour gradient with the
/// playlist's name printed in its corner. MusicKit's local library hands that out like any other
/// cover (a `musicKit://` URL with nothing to tell them apart), so a sidebar full of them looks
/// like a wall of tiny text. The Apple Music API does tell: generated covers are served from
/// `/image/thumb/gen/`.
struct AppleMusicPlaylistCover: Equatable, Sendable {
    let name: String
    /// The playlist's catalog ID (`pl.u-…`), which only shared playlists have.
    let globalID: String?
    let isGenerated: Bool

    static func isGenerated(artworkURL: String?) -> Bool {
        guard let artworkURL else { return true }
        return artworkURL.contains("/image/thumb/gen/")
    }

    /// One page of `/v1/me/library/playlists`, and the path of the next one.
    static func page(from data: Data) throws -> (covers: [AppleMusicPlaylistCover], next: String?) {
        let page = try JSONDecoder().decode(Page.self, from: data)
        let covers = page.data.compactMap { resource -> AppleMusicPlaylistCover? in
            guard let name = resource.attributes?.name else { return nil }
            return AppleMusicPlaylistCover(
                name: name,
                globalID: resource.attributes?.playParams?.globalId,
                isGenerated: isGenerated(artworkURL: resource.attributes?.artwork?.url)
            )
        }
        return (covers, page.next)
    }

    /// The IDs of the library playlists whose cover is a generated one.
    ///
    /// The API names library playlists by their cloud ID (`p.…`), MusicKit on the Mac by the
    /// Music app's persistent ID, and nothing links the two. So a playlist with a catalog ID
    /// (a shared one) is matched by that ID only, and one without by name among the cloud
    /// playlists that have none either. It only counts as generated when every match is: two
    /// playlists with one name, one with a real cover, keep the cover rather than risk hiding a
    /// real one, and so does a playlist the API doesn't list (yet).
    static func generatedPlaylistIDs(
        _ playlists: [(id: String, name: String, globalID: String?)],
        covers: [AppleMusicPlaylistCover]
    ) -> Set<String> {
        let byGlobalID = Dictionary(
            covers.compactMap { cover in cover.globalID.map { ($0, cover.isGenerated) } },
            uniquingKeysWith: { $0 && $1 }
        )
        let byName = Dictionary(
            covers.filter { $0.globalID == nil }.map { ($0.name, $0.isGenerated) },
            uniquingKeysWith: { $0 && $1 }
        )
        return Set(playlists.compactMap { playlist in
            let generated = if let globalID = playlist.globalID {
                byGlobalID[globalID] ?? false
            } else {
                byName[playlist.name] ?? false
            }
            return generated ? playlist.id : nil
        })
    }

    private struct Page: Decodable {
        struct Resource: Decodable {
            struct Attributes: Decodable {
                struct Artwork: Decodable { let url: String? }
                struct PlayParams: Decodable { let globalId: String? }
                let name: String?
                let artwork: Artwork?
                let playParams: PlayParams?
            }

            let attributes: Attributes?
        }

        let data: [Resource]
        let next: String?
    }
}
