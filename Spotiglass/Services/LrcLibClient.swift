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

enum FetchedLyrics: Equatable, Codable {
    case instrumental
    case synced([SyncedLyricLine])
    case unsyncedPlain([String])
}

struct LrcLibClient: Sendable {
    enum FetchMode: Sendable {
        /// Preferred in production: call `get-cached` first and only call `get` when needed.
        case sequentialCachedFirst
        /// Optional pressure mode for experiments; calls both endpoints concurrently.
        case parallel
    }

    enum Failure: Error, Equatable {
        case invalidURL
        case http(Int)
        case rateLimited(retryAfter: TimeInterval?)
        case decoding
        case noLyrics
    }

    private let session: URLSession
    private let baseURL: URL
    private let fetchMode: FetchMode

    init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://lrclib.net")!,
        fetchMode: FetchMode = .sequentialCachedFirst
    ) {
        self.session = session
        self.baseURL = baseURL
        self.fetchMode = fetchMode
    }

    /// Fetches `/api/get-cached` first, then falls back to `/api/get` only when
    /// the cached endpoint has no usable lyrics payload.
    func fetchLyrics(for track: PlaybackNowPlaying) async throws -> FetchedLyrics {
        switch fetchMode {
        case .sequentialCachedFirst:
            return try await fetchLyricsSequentialCachedFirst(for: track)
        case .parallel:
            return try await fetchLyricsParallel(for: track)
        }
    }

    private func fetchLyricsSequentialCachedFirst(for track: PlaybackNowPlaying) async throws -> FetchedLyrics {
        do {
            let cachedResponse = try await get(endpoint: "get-cached", track: track)
            if let cachedResponse, let lyrics = mapResponse(cachedResponse) {
                return lyrics
            }
        } catch let failure as Failure {
            switch failure {
            case .noLyrics:
                break // cached miss/unusable -> try full
            case .decoding:
                break // cached decode issue -> try full
            case let .http(code) where code >= 500:
                break // transient server-side cached error -> try full
            case .rateLimited:
                throw failure // under pressure, do not escalate to full endpoint
            case .invalidURL, .http:
                throw failure
            }
        }

        let fullResponse = try await get(endpoint: "get", track: track)
        if let fullResponse, let lyrics = mapResponse(fullResponse) {
            return lyrics
        }
        throw Failure.noLyrics
    }

    private func fetchLyricsParallel(for track: PlaybackNowPlaying) async throws -> FetchedLyrics {
        async let cachedResult = getResult(endpoint: "get-cached", track: track)
        async let fullResult = getResult(endpoint: "get", track: track)
        let cached = try await cachedResult
        let full = try await fullResult
        for response in [cached, full] {
            switch response {
            case let .success(dto?):
                if let lyrics = mapResponse(dto) { return lyrics }
            case .success(nil):
                continue
            case let .failure(error):
                if case let .rateLimited(retryAfter) = error {
                    throw Failure.rateLimited(retryAfter: retryAfter)
                }
            }
        }
        for response in [cached, full] {
            if case let .failure(error) = response {
                throw error
            }
        }
        throw Failure.noLyrics
    }

    private func getResult(
        endpoint: String,
        track: PlaybackNowPlaying
    ) async throws -> Result<LrcLibResponseDTO?, Failure> {
        do {
            return .success(try await get(endpoint: endpoint, track: track))
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            throw error
        }
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
        if http.statusCode == 429 {
            let retryAfter = parseRetryAfterSeconds(from: http)
            throw Failure.rateLimited(retryAfter: retryAfter)
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

    private func parseRetryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(raw) {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}
