import Foundation

// MARK: - Queue response decoding (declared before `SpotifyPlaybackAPI` so the type is in scope for instance methods)

private enum SpotifyQueueUnionDTO: Decodable {
    case track(SpotifyTrackDTO)
    case episode(SpotifyEpisodeDTO)

    enum CodingKeys: String, CodingKey {
        case show
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.show) {
            self = .episode(try SpotifyEpisodeDTO(from: decoder))
        } else {
            self = .track(try SpotifyTrackDTO(from: decoder))
        }
    }

    var domainModel: SpotifyQueueTrackItem? {
        switch self {
        case let .track(dto):
            guard let track = dto.domainModel() else { return nil }
            return .track(track)
        case let .episode(dto):
            guard let episode = dto.domainModel() else { return nil }
            return .episode(episode)
        }
    }
}

private struct SpotifyPlayerTransportDTO: Decodable {
    let shuffleState: Bool
    let repeatState: String

    enum CodingKeys: String, CodingKey {
        case shuffleState = "shuffle_state"
        case repeatState = "repeat_state"
    }

    func domainModel() -> SpotifyPlayerTransport {
        SpotifyPlayerTransport(
            shuffle: shuffleState,
            repeatMode: SpotifyRepeatMode(rawValue: repeatState) ?? .off
        )
    }
}

private struct SpotifyQueueResponseDTO: Decodable {
    let currentlyPlaying: SpotifyQueueUnionDTO?
    let queue: [SpotifyQueueUnionDTO]

    enum CodingKeys: String, CodingKey {
        case currentlyPlaying = "currently_playing"
        case queue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentlyPlaying = try container.decodeIfPresent(SpotifyQueueUnionDTO.self, forKey: .currentlyPlaying)
        queue = try container.decodeIfPresent([SpotifyQueueUnionDTO].self, forKey: .queue) ?? []
    }

    func domainModel() -> SpotifyQueueResponse {
        let currentItem = currentlyPlaying?.domainModel
        let currentURI = currentItem.flatMap(Self.uri(for:))
        let queued = queue.compactMap(\.domainModel)
        let filteredQueue: [SpotifyQueueTrackItem]
        if let currentURI {
            filteredQueue = queued.filter { Self.uri(for: $0) != currentURI }
        } else {
            filteredQueue = queued
        }
        return SpotifyQueueResponse(currentlyPlaying: currentItem, queue: filteredQueue)
    }

    private static func uri(for item: SpotifyQueueTrackItem) -> String {
        switch item {
        case let .track(t): t.uri
        case let .episode(e): e.uri
        }
    }
}

protocol SpotifyPlaybackControlling {
    func transferPlayback(to deviceID: String, play: Bool) async throws
    func play(uri: String, deviceID: String) async throws
    func play(contextURI: String, deviceID: String) async throws
    func play(uris: [String], deviceID: String) async throws
    func pause(deviceID: String) async throws
    func resume(deviceID: String) async throws
    func seek(to milliseconds: Int, deviceID: String) async throws
    func next(deviceID: String) async throws
    func previous(deviceID: String) async throws
    func fetchQueue() async throws -> SpotifyQueueResponse
    func addToQueue(uri: String, deviceID: String) async throws
    /// `nil` when Spotify returns **204** (no active player).
    func fetchPlayerTransport() async throws -> SpotifyPlayerTransport?
    func setShuffle(enabled: Bool, deviceID: String) async throws
    func setRepeat(mode: SpotifyRepeatMode, deviceID: String) async throws
}

struct SpotifyPlaybackAPI: SpotifyPlaybackControlling {
    private static let maxQueuedURIs = 100
    private let baseURL: URL
    private let tokenProvider: PlaybackAccessTokenProviding
    private let httpClient: HTTPClient
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        baseURL: URL = URL(string: "https://api.spotify.com")!,
        tokenProvider: PlaybackAccessTokenProviding,
        httpClient: HTTPClient = URLSession.shared
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.httpClient = httpClient
    }

    func transferPlayback(to deviceID: String, play: Bool) async throws {
        let body = TransferPlaybackRequest(deviceIDs: [deviceID], play: play)
        try await send(path: "/v1/me/player", method: "PUT", body: body, queryItems: [])
    }

    func play(uri: String, deviceID: String) async throws {
        // Explicitly reset track position to 0ms when starting a new URI.
        // Without this, Spotify can occasionally resume at the previous
        // playback offset when switching tracks on the same device.
        let body = PlayURIRequest(uris: [uri], positionMilliseconds: 0)
        try await send(path: "/v1/me/player/play", method: "PUT", body: body, queryItems: [URLQueryItem(name: "device_id", value: deviceID)])
    }

    func play(contextURI: String, deviceID: String) async throws {
        let body = PlayContextRequest(contextURI: contextURI)
        try await send(path: "/v1/me/player/play", method: "PUT", body: body, queryItems: [URLQueryItem(name: "device_id", value: deviceID)])
    }

    func play(uris: [String], deviceID: String) async throws {
        let sanitizedURIs = Array(uris.prefix(Self.maxQueuedURIs))
        guard !sanitizedURIs.isEmpty else {
            throw SpotifyAPIError.invalidRequest("At least one Spotify URI is required to start playback.")
        }
        let body = PlayURIRequest(uris: sanitizedURIs, positionMilliseconds: 0)
        try await send(path: "/v1/me/player/play", method: "PUT", body: body, queryItems: [URLQueryItem(name: "device_id", value: deviceID)])
    }

    func pause(deviceID: String) async throws {
        try await send(path: "/v1/me/player/pause", method: "PUT", body: EmptyBody(), queryItems: [URLQueryItem(name: "device_id", value: deviceID)])
    }

    func resume(deviceID: String) async throws {
        try await send(path: "/v1/me/player/play", method: "PUT", body: EmptyBody(), queryItems: [URLQueryItem(name: "device_id", value: deviceID)])
    }

    func seek(to milliseconds: Int, deviceID: String) async throws {
        try await send(
            path: "/v1/me/player/seek",
            method: "PUT",
            body: EmptyBody(),
            queryItems: [
                URLQueryItem(name: "position_ms", value: String(milliseconds)),
                URLQueryItem(name: "device_id", value: deviceID)
            ]
        )
    }

    func next(deviceID: String) async throws {
        try await send(path: "/v1/me/player/next", method: "POST", body: EmptyBody(), queryItems: [URLQueryItem(name: "device_id", value: deviceID)])
    }

    func previous(deviceID: String) async throws {
        try await send(path: "/v1/me/player/previous", method: "POST", body: EmptyBody(), queryItems: [URLQueryItem(name: "device_id", value: deviceID)])
    }

    func fetchQueue() async throws -> SpotifyQueueResponse {
        let data = try await get(path: "/v1/me/player/queue", queryItems: [])
        let dto = try decoder.decode(SpotifyQueueResponseDTO.self, from: data)
        return dto.domainModel()
    }

    func addToQueue(uri: String, deviceID: String) async throws {
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "uri", value: uri),
            URLQueryItem(name: "device_id", value: deviceID)
        ]
        try await send(path: "/v1/me/player/queue", method: "POST", body: EmptyBody(), queryItems: queryItems)
    }

    func fetchPlayerTransport() async throws -> SpotifyPlayerTransport? {
        let accessToken = try await tokenProvider.playbackAccessToken()
        let components = URLComponents(url: baseURL.appendingPathComponent("/v1/me/player".trimmingCharacters(in: CharacterSet(charactersIn: "/"))), resolvingAgainstBaseURL: false)!
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await httpClient.data(for: request)
        if response.statusCode == 204 {
            return nil
        }
        guard (200..<300).contains(response.statusCode) else {
            throw mapPlaybackError(statusCode: response.statusCode, data: data)
        }
        let dto = try decoder.decode(SpotifyPlayerTransportDTO.self, from: data)
        return dto.domainModel()
    }

    func setShuffle(enabled: Bool, deviceID: String) async throws {
        try await send(
            path: "/v1/me/player/shuffle",
            method: "PUT",
            body: EmptyBody(),
            queryItems: [
                URLQueryItem(name: "state", value: enabled ? "true" : "false"),
                URLQueryItem(name: "device_id", value: deviceID)
            ]
        )
    }

    func setRepeat(mode: SpotifyRepeatMode, deviceID: String) async throws {
        try await send(
            path: "/v1/me/player/repeat",
            method: "PUT",
            body: EmptyBody(),
            queryItems: [
                URLQueryItem(name: "state", value: mode.rawValue),
                URLQueryItem(name: "device_id", value: deviceID)
            ]
        )
    }

    private func get(path: String, queryItems: [URLQueryItem]) async throws -> Data {
        let accessToken = try await tokenProvider.playbackAccessToken()
        var components = URLComponents(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await httpClient.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw mapPlaybackError(statusCode: response.statusCode, data: data)
        }
        return data
    }

    private func send<Body: Encodable>(
        path: String,
        method: String,
        body: Body,
        queryItems: [URLQueryItem]
    ) async throws {
        let accessToken = try await tokenProvider.playbackAccessToken()
        var components = URLComponents(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if Body.self != EmptyBody.self {
            request.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await httpClient.data(for: request)
        guard (200..<300).contains(response.statusCode) || response.statusCode == 204 else {
            throw mapPlaybackError(statusCode: response.statusCode, data: data)
        }
    }

    private func mapPlaybackError(statusCode: Int, data: Data) -> SpotifyAPIError {
        let message = try? JSONDecoder().decode(SpotifyAPIErrorResponse.self, from: data).error.message
        switch statusCode {
        case 401:
            return .unauthorized
        case 403:
            return .forbidden(message: message ?? "Spotify Premium is required for Web Playback SDK playback.", details: nil)
        case 404:
            return .notFound(message: message)
        case 429:
            return .rateLimited(retryAfter: nil)
        default:
            return .server(statusCode: statusCode, message: message, details: nil)
        }
    }
}

private struct TransferPlaybackRequest: Encodable {
    let deviceIDs: [String]
    let play: Bool

    enum CodingKeys: String, CodingKey {
        case deviceIDs = "device_ids"
        case play
    }
}

private struct PlayContextRequest: Encodable {
    let contextURI: String

    enum CodingKeys: String, CodingKey {
        case contextURI = "context_uri"
    }
}

private struct PlayURIRequest: Encodable {
    let uris: [String]
    let positionMilliseconds: Int

    enum CodingKeys: String, CodingKey {
        case uris
        case positionMilliseconds = "position_ms"
    }
}

private struct EmptyBody: Encodable {}
