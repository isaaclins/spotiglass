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

private struct SpotifyConnectDeviceDTO: Decodable {
    let id: String
    let isActive: Bool
    let isRestricted: Bool
    let name: String
    let type: String
    let volumePercent: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case isActive = "is_active"
        case isRestricted = "is_restricted"
        case name, type
        case volumePercent = "volume_percent"
    }

    func domainModel() -> SpotifyConnectDevice {
        SpotifyConnectDevice(
            deviceID: id,
            isActive: isActive,
            isRestricted: isRestricted,
            name: name,
            type: type,
            volumePercent: volumePercent
        )
    }
}

private struct SpotifyPlayerSnapshotDTO: Decodable {
    let shuffleState: Bool
    let repeatState: String
    let device: SpotifyConnectDeviceDTO?
    let isPlaying: Bool

    enum CodingKeys: String, CodingKey {
        case shuffleState = "shuffle_state"
        case repeatState = "repeat_state"
        case device
        case isPlaying = "is_playing"
    }

    func domainModel() -> SpotifyPlayerSnapshot {
        SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(
                shuffle: shuffleState,
                repeatMode: SpotifyRepeatMode(rawValue: repeatState) ?? .off
            ),
            activeDevice: device?.domainModel(),
            isPlaying: isPlaying
        )
    }
}

private struct SpotifyDevicesListDTO: Decodable {
    let devices: [SpotifyConnectDeviceDTO]

    func domainModels() -> [SpotifyConnectDevice] {
        devices.map { $0.domainModel() }
    }
}

private struct SpotifyQueueResponseDTO: Decodable {
    // `currently_playing` is deliberately not decoded: the now-playing track
    // comes from the Web Playback SDK, and the queue endpoint's copy of it was
    // only ever stored, never read.
    let queue: [SpotifyQueueUnionDTO]

    enum CodingKeys: String, CodingKey {
        case queue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        queue = try container.decodeIfPresent([SpotifyQueueUnionDTO].self, forKey: .queue) ?? []
    }

    func domainModel() -> SpotifyQueueResponse {
        let queued = queue.compactMap(\.domainModel)
        return SpotifyQueueResponse(queue: queued)
    }
}

protocol SpotifyPlaybackControlling {
    func transferPlayback(to deviceID: String, play: Bool) async throws
    func play(uri: String, deviceID: String) async throws
    func play(contextURI: String, deviceID: String) async throws
    func play(uris: [String], deviceID: String) async throws
    func play(uris: [String], offsetURI: String, deviceID: String) async throws
    func seek(to milliseconds: Int, deviceID: String) async throws
    func next(deviceID: String) async throws
    func previous(deviceID: String) async throws
    func fetchQueue() async throws -> SpotifyQueueResponse
    func addToQueue(uri: String, deviceID: String) async throws
    /// `nil` when Spotify returns **204** (no active player).
    func fetchPlayerSnapshot() async throws -> SpotifyPlayerSnapshot?
    func fetchAvailableDevices() async throws -> [SpotifyConnectDevice]
    func setShuffle(enabled: Bool, deviceID: String) async throws
    func setRepeat(mode: SpotifyRepeatMode, deviceID: String) async throws
}

extension SpotifyPlaybackControlling {
    func play(uri: String, deviceID: String) async throws {
        try await play(uris: [uri], deviceID: deviceID)
    }
}

/// Coalesces concurrent `GET /v1/me/player` calls into one in-flight URLSession task.
private actor PlayerSnapshotFetchCoalescer {
    private var inFlight: Task<SpotifyPlayerSnapshot?, Error>?

    func fetch(
        _ operation: @Sendable @escaping () async throws -> SpotifyPlayerSnapshot?
    ) async throws -> SpotifyPlayerSnapshot? {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await operation() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}

struct SpotifyPlaybackAPI: SpotifyPlaybackControlling {
    private static let maxQueuedURIs = 100
    private static let maxGETRetryAttempts = 3
    private let baseURL: URL
    private let tokenProvider: PlaybackAccessTokenProviding
    private let httpClient: HTTPClient
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let playerSnapshotFetchCoalescer = PlayerSnapshotFetchCoalescer()

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

    func play(contextURI: String, deviceID: String) async throws {
        let body = PlayContextRequest(contextURI: contextURI)
        try await send(path: "/v1/me/player/play", method: "PUT", body: body, queryItems: [URLQueryItem(name: "device_id", value: deviceID)])
    }

    func play(uris: [String], deviceID: String) async throws {
        // Explicitly reset track position to 0ms when starting a new URI list.
        // Without this, Spotify can occasionally resume at the previous
        // playback offset when switching tracks on the same device.
        try await sendURIPlay(uris: uris, offsetURI: nil, deviceID: deviceID)
    }

    func play(uris: [String], offsetURI: String, deviceID: String) async throws {
        try await sendURIPlay(uris: uris, offsetURI: offsetURI, deviceID: deviceID)
    }

    private func sendURIPlay(uris: [String], offsetURI: String?, deviceID: String) async throws {
        let sanitizedURIs = Array(uris.prefix(Self.maxQueuedURIs))
        guard !sanitizedURIs.isEmpty else {
            throw SpotifyAPIError.invalidRequest("At least one Spotify URI is required to start playback.")
        }
        let body = PlayURIRequest(
            uris: sanitizedURIs,
            offset: offsetURI.map { ["uri": $0] },
            positionMilliseconds: 0
        )
        try await send(path: "/v1/me/player/play", method: "PUT", body: body, queryItems: [URLQueryItem(name: "device_id", value: deviceID)])
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

    func fetchPlayerSnapshot() async throws -> SpotifyPlayerSnapshot? {
        try await playerSnapshotFetchCoalescer.fetch { [self] in
            try await fetchPlayerSnapshotUncoalesced()
        }
    }

    private func fetchPlayerSnapshotUncoalesced() async throws -> SpotifyPlayerSnapshot? {
        let (data, response) = try await performGET(path: "/v1/me/player", queryItems: [])
        if response.statusCode == 204 {
            return nil
        }
        guard (200..<300).contains(response.statusCode) else {
            throw mapPlaybackError(statusCode: response.statusCode, data: data, response: response)
        }
        let dto = try decoder.decode(SpotifyPlayerSnapshotDTO.self, from: data)
        return dto.domainModel()
    }

    func fetchAvailableDevices() async throws -> [SpotifyConnectDevice] {
        let data = try await get(path: "/v1/me/player/devices", queryItems: [])
        let dto = try decoder.decode(SpotifyDevicesListDTO.self, from: data)
        return dto.domainModels()
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
        let (data, response) = try await performGET(path: path, queryItems: queryItems)
        guard (200..<300).contains(response.statusCode) else {
            throw mapPlaybackError(statusCode: response.statusCode, data: data, response: response)
        }
        return data
    }

    private func performGET(path: String, queryItems: [URLQueryItem]) async throws -> (Data, HTTPURLResponse) {
        let accessToken = try await tokenProvider.playbackAccessToken()
        var components = URLComponents(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        return try await performGETWithRetry(request: request, path: path)
    }

    private func performGETWithRetry(request: URLRequest, path: String) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await httpClient.data(for: request)
                if shouldRetryGET(statusCode: response.statusCode, path: path, attempt: attempt) {
                    let retryAfter = retryAfterSeconds(fromRawHeader: response.value(forHTTPHeaderField: "Retry-After"))
                    let delay = retryDelaySeconds(retryAfter: retryAfter, attempt: attempt)
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                return (data, response)
            } catch {
                guard shouldRetryGET(error: error, path: path, attempt: attempt) else {
                    throw error
                }
                let delay = retryDelaySeconds(retryAfter: nil, attempt: attempt)
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func shouldRetryGET(statusCode: Int, path: String, attempt: Int) -> Bool {
        guard attempt < Self.maxGETRetryAttempts else { return false }
        guard shouldRetryGETPath(path) else { return false }
        return statusCode == 429 || (500...599).contains(statusCode)
    }

    private func shouldRetryGET(error: Error, path: String, attempt: Int) -> Bool {
        guard attempt < Self.maxGETRetryAttempts else { return false }
        guard shouldRetryGETPath(path) else { return false }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private func shouldRetryGETPath(_ path: String) -> Bool {
        path == "/v1/me/player" || path == "/v1/me/player/devices"
    }

    private func retryDelaySeconds(retryAfter: TimeInterval?, attempt: Int) -> TimeInterval {
        let baseDelay: TimeInterval
        if let retryAfter, retryAfter > 0 {
            baseDelay = min(retryAfter, 8)
        } else {
            baseDelay = min(pow(2, Double(attempt - 1)), 4)
        }
        let jitter = Double.random(in: 0...0.35)
        return baseDelay + jitter
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
        var bodyPreview = ""
        if Body.self != EmptyBody.self {
            let bodyData = try encoder.encode(body)
            request.httpBody = bodyData
            bodyPreview = String(data: bodyData, encoding: .utf8) ?? "<binary>"
        }

        let queryString = queryItems.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        SpotiglassLog.info(.api, "Spotify \(method) \(path)\(queryString.isEmpty ? "" : "?\(queryString)") body=\(bodyPreview)")
        let (data, response) = try await httpClient.data(for: request)
        SpotiglassLog.info(.api, "Spotify \(method) \(path) -> status=\(response.statusCode)")
        guard (200..<300).contains(response.statusCode) || response.statusCode == 204 else {
            throw mapPlaybackError(statusCode: response.statusCode, data: data, response: response)
        }
    }

    private func mapPlaybackError(statusCode: Int, data: Data, response: HTTPURLResponse) -> SpotifyAPIError {
        let message = try? JSONDecoder().decode(SpotifyAPIErrorResponse.self, from: data).error.message
        switch statusCode {
        case 401:
            return .unauthorized
        case 403:
            return .forbidden(message: message ?? "Spotify Premium is required for Web Playback SDK playback.", details: nil)
        case 404:
            return .notFound(message: message)
        case 429:
            return .rateLimited(retryAfter: retryAfterSeconds(from: response))
        default:
            return .server(statusCode: statusCode, message: message, details: nil)
        }
    }

    private func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        retryAfterSeconds(fromRawHeader: response.value(forHTTPHeaderField: "Retry-After"))
    }

    private func retryAfterSeconds(fromRawHeader rawHeader: String?) -> TimeInterval? {
        guard let rawHeader else { return nil }
        let trimmed = rawHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(trimmed) {
            return max(seconds, 0)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else {
            return nil
        }
        return max(0, date.timeIntervalSinceNow)
    }
}

private struct TransferPlaybackRequest: Encodable {
    let deviceIDs: [String]
    let play: Bool

    enum CodingKeys: String, CodingKey {
        case deviceIDs = "device_ids"
        case play
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceIDs, forKey: .deviceIDs)
        try c.encode(play, forKey: .play)
    }
}

private struct PlayContextRequest: Encodable {
    let contextURI: String

    enum CodingKeys: String, CodingKey {
        case contextURI = "context_uri"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(contextURI, forKey: .contextURI)
    }
}

private struct PlayURIRequest: Encodable {
    let uris: [String]
    let offset: [String: String]?
    let positionMilliseconds: Int

    enum CodingKeys: String, CodingKey {
        case uris
        case offset
        case positionMilliseconds = "position_ms"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uris, forKey: .uris)
        try c.encodeIfPresent(offset, forKey: .offset)
        try c.encode(positionMilliseconds, forKey: .positionMilliseconds)
    }
}

private struct EmptyBody: Encodable {}
