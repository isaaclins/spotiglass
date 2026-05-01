import Foundation

protocol SpotifyPlaybackControlling {
    func transferPlayback(to deviceID: String, play: Bool) async throws
    func play(uri: String, deviceID: String) async throws
    func play(uris: [String], deviceID: String) async throws
    func pause(deviceID: String) async throws
    func resume(deviceID: String) async throws
    func seek(to milliseconds: Int, deviceID: String) async throws
    func next(deviceID: String) async throws
    func previous(deviceID: String) async throws
}

struct SpotifyPlaybackAPI: SpotifyPlaybackControlling {
    private static let maxQueuedURIs = 100
    private let baseURL: URL
    private let tokenProvider: PlaybackAccessTokenProviding
    private let httpClient: HTTPClient
    private let encoder = JSONEncoder()

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
            return .server(statusCode: statusCode, message: message)
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

private struct PlayURIRequest: Encodable {
    let uris: [String]
    let positionMilliseconds: Int

    enum CodingKeys: String, CodingKey {
        case uris
        case positionMilliseconds = "position_ms"
    }
}

private struct EmptyBody: Encodable {}
