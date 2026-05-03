import Foundation

extension PlaybackNowPlaying {
    /// LRCLIB expects a single artist string; matches Spotify’s multi-artist display.
    var lrcLibArtistQuery: String {
        artistText
    }

    var lrcLibAlbumQuery: String {
        albumName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var lrcLibDurationSeconds: Int {
        max(1, durationMilliseconds / 1_000)
    }

    /// Spotify track id from `spotify:track:…` URI, or `nil`.
    var spotifyTrackIDForLyrics: String? {
        guard let uri, uri.hasPrefix("spotify:track:") else {
            return nil
        }
        return uri.split(separator: ":").last.map(String.init)
    }
}

enum FetchedLyrics: Equatable {
    case instrumental
    case synced([SyncedLyricLine])
    case unsyncedPlain([String])
}

struct LrcLibClient: Sendable {
    enum Failure: Error, Equatable {
        case invalidURL
        case http(Int)
        case decoding
        case noLyrics
    }

    private let session: URLSession
    private let baseURL: URL

    init(session: URLSession = .shared, baseURL: URL = URL(string: "https://lrclib.net")!) {
        self.session = session
        self.baseURL = baseURL
    }

    /// Fetches from `/api/get-cached`, then `/api/get` if the cached miss has no usable lyrics.
    func fetchLyrics(for track: PlaybackNowPlaying) async throws -> FetchedLyrics {
        if let cached = try await get(endpoint: "get-cached", track: track),
           let lyrics = mapResponse(cached) {
            return lyrics
        }
        if let full = try await get(endpoint: "get", track: track),
           let lyrics = mapResponse(full) {
            return lyrics
        }
        throw Failure.noLyrics
    }

    private struct LrcLibResponseDTO: Decodable {
        let instrumental: Bool?
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    private func mapResponse(_ dto: LrcLibResponseDTO) -> FetchedLyrics? {
        if dto.instrumental == true {
            return .instrumental
        }
        if let raw = dto.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let lines = LrcLineParser.parseSyncedLines(raw)
            if !lines.isEmpty {
                return .synced(lines)
            }
        }
        if let raw = dto.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let plainLines = raw
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !plainLines.isEmpty {
                return .unsyncedPlain(plainLines)
            }
        }
        return nil
    }

    private func get(endpoint: String, track: PlaybackNowPlaying) async throws -> LrcLibResponseDTO? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/\(endpoint)"),
            resolvingAgainstBaseURL: false
        ) else {
            throw Failure.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "track_name", value: track.name),
            URLQueryItem(name: "artist_name", value: track.lrcLibArtistQuery),
            URLQueryItem(name: "album_name", value: track.lrcLibAlbumQuery),
            URLQueryItem(name: "duration", value: String(track.lrcLibDurationSeconds))
        ]
        guard let url = components.url else {
            throw Failure.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue(AppMetadata.spotiglassHTTPUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 45

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.http(-1)
        }
        if http.statusCode == 404 {
            return nil
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw Failure.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(LrcLibResponseDTO.self, from: data)
        } catch {
            throw Failure.decoding
        }
    }
}
