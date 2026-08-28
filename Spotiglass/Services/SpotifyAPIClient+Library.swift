import Foundation

extension SpotifyAPIClient {
    /// Spotify caps playlist item mutations at 100 URIs per request.
    static let playlistTracksMutationBatchSize = 100
    /// `PUT/DELETE /v1/me/tracks` accepts up to 50 IDs per call (query-string mode).
    static let savedTracksMutationBatchSize = 50

    // MARK: - Saved Tracks ("Liked Songs")

    /// Saves the given catalog tracks to the user's Liked Songs, chunked at 50 IDs per request.
    func saveTracks(ids: [String]) async throws {
        let unique = uniqueOrderedIDs(ids)
        guard !unique.isEmpty else { return }
        for chunk in unique.chunked(into: Self.savedTracksMutationBatchSize) {
            try await sendVoidWrite(
                method: "PUT",
                path: "/v1/me/tracks",
                queryItems: [URLQueryItem(name: "ids", value: chunk.joined(separator: ","))],
                jsonBody: nil
            )
        }
    }

    /// Removes the given catalog tracks from the user's Liked Songs.
    func removeSavedTracks(ids: [String]) async throws {
        let unique = uniqueOrderedIDs(ids)
        guard !unique.isEmpty else { return }
        for chunk in unique.chunked(into: Self.savedTracksMutationBatchSize) {
            try await sendVoidWrite(
                method: "DELETE",
                path: "/v1/me/tracks",
                queryItems: [URLQueryItem(name: "ids", value: chunk.joined(separator: ","))],
                jsonBody: nil
            )
        }
    }

    /// Returns whether each catalog track is in the user's Liked Songs. Spotify
    /// accepts at most 50 IDs per `/contains` request.
    func savedTrackStatuses(ids: [String]) async throws -> [Bool] {
        let unique = uniqueOrderedIDs(ids)
        guard !unique.isEmpty else { return [] }
        var statuses: [Bool] = []
        for chunk in unique.chunked(into: Self.savedTracksMutationBatchSize) {
            let result: [Bool] = try await send(
                path: "/v1/me/tracks/contains",
                queryItems: [URLQueryItem(name: "ids", value: chunk.joined(separator: ","))]
            )
            statuses.append(contentsOf: result)
        }
        return statuses
    }

    // MARK: - Playlist track membership

    /// Appends the given tracks to a playlist, batched into ≤100-URI chunks.
    func addTracksToPlaylist(playlistID: String, uris: [String]) async throws {
        let ordered = orderedURIs(uris)
        guard !ordered.isEmpty, !playlistID.isEmpty else { return }
        for chunk in ordered.chunked(into: Self.playlistTracksMutationBatchSize) {
            let body: [String: Any] = ["uris": chunk]
            try await sendVoidWrite(
                method: "POST",
                path: "/v1/playlists/\(playlistID)/items",
                queryItems: [],
                jsonBody: body
            )
        }
    }

    /// Removes the exact playlist positions supplied for each URI, batched into
    /// requests of at most 100 positions. A snapshot protects the mutation from
    /// deleting the wrong occurrence after the playlist changes.
    func removeTracksFromPlaylist(
        playlistID: String,
        items: [SpotifyPlaylistTrackRemoval],
        snapshotID: String? = nil
    ) async throws {
        let removals = normalisedTrackRemovals(items)
        guard !removals.isEmpty, !playlistID.isEmpty else { return }
        var currentSnapshotID = snapshotID
        for chunk in removals.chunkedByPositionCount(maximum: Self.playlistTracksMutationBatchSize) {
            var body: [String: Any] = [
                "items": chunk.map { [
                    "uri": $0.uri,
                    "positions": $0.positions
                ] }
            ]
            if let currentSnapshotID, !currentSnapshotID.isEmpty {
                body["snapshot_id"] = currentSnapshotID
            }
            let responseData = try await sendDataWrite(
                method: "DELETE",
                path: "/v1/playlists/\(playlistID)/items",
                queryItems: [],
                jsonBody: body
            )
            if let response = try? decoder.decode(SpotifyPlaylistMutationResponse.self, from: responseData),
               let nextSnapshotID = response.snapshotID,
               !nextSnapshotID.isEmpty {
                currentSnapshotID = nextSnapshotID
            }
        }
    }

    // MARK: - Create playlist

    /// Creates an empty playlist owned by the given user and returns it as a
    /// summary suitable for inserting into the sidebar.
    func createPlaylist(
        userID: String,
        name: String,
        isPublic: Bool = false
    ) async throws -> SpotifyPlaylistSummary {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Playlist name is required.")
        }
        guard !userID.isEmpty else {
            throw SpotifyAPIError.invalidRequest("User ID is required to create a playlist.")
        }
        let body: [String: Any] = [
            "name": trimmedName,
            "public": isPublic
        ]
        let data = try await sendDataWrite(
            method: "POST",
            path: "/v1/me/playlists",
            queryItems: [],
            jsonBody: body
        )
        let dto = try decoder.decode(SpotifyPlaylistDTO.self, from: data)
        return dto.domainModel()
    }

    // MARK: - Internals

    private func uniqueOrderedIDs(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        out.reserveCapacity(ids.count)
        for id in ids {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    /// Deduplicates removals and orders every position from the end of the
    /// playlist backwards.
    ///
    /// Ordering is not cosmetic. A removal larger than one batch is sent as
    /// several requests, and each request shifts every position after the ones
    /// it deleted. Descending order means a batch only ever removes positions
    /// later than the ones still queued, so the remaining positions stay valid
    /// against the snapshot returned by the previous batch. Ascending order
    /// would make every batch after the first delete the wrong occurrences,
    /// which is the exact failure this endpoint change exists to prevent.
    private func normalisedTrackRemovals(_ removals: [SpotifyPlaylistTrackRemoval]) -> [SpotifyPlaylistTrackRemoval] {
        var positionsByURI: [String: Set<Int>] = [:]
        for removal in removals {
            let uri = removal.uri.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uri.isEmpty else { continue }
            for position in removal.positions where position >= 0 {
                positionsByURI[uri, default: []].insert(position)
            }
        }

        let descendingPairs = positionsByURI
            .flatMap { uri, positions in positions.map { (uri: uri, position: $0) } }
            .sorted { $0.position > $1.position }

        return descendingPairs.map { SpotifyPlaylistTrackRemoval(uri: $0.uri, positions: [$0.position]) }
    }

    private func orderedURIs(_ uris: [String]) -> [String] {
        uris.compactMap { uri in
            let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Issues a writing (POST/PUT/DELETE) request that returns no decodable body.
    func sendVoidWrite(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        jsonBody: Any?
    ) async throws {
        _ = try await sendDataWrite(
            method: method,
            path: path,
            queryItems: queryItems,
            jsonBody: jsonBody
        )
    }

    /// Issues a writing request and returns the raw response body. Single
    /// 401-retry-with-fresh-token and 429-cooldown semantics mirror `send`.
    private func sendDataWrite(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        jsonBody: Any?
    ) async throws -> Data {
        let accessToken = try await tokenProvider.accessToken()
        let request = try makeWriteRequest(
            method: method,
            path: path,
            queryItems: queryItems,
            jsonBody: jsonBody,
            accessToken: accessToken
        )
        return try await performWrite(request: request, didRetryAuth: false, rateRetryCount: 0)
    }

    private func makeWriteRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        jsonBody: Any?,
        accessToken: String
    ) throws -> URLRequest {
        // Reuse the GET request builder for path/query encoding, then mutate
        // method + body so write helpers don't duplicate URL-component logic.
        var request = try makeRequest(path: path, queryItems: queryItems, accessToken: accessToken)
        request.httpMethod = method
        if let body = jsonBody {
            let data = try JSONSerialization.data(withJSONObject: body, options: [])
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func performWrite(
        request: URLRequest,
        didRetryAuth: Bool,
        rateRetryCount: Int
    ) async throws -> Data {
        let (data, response) = try await httpClient.data(for: request)
        if response.statusCode == 401 && !didRetryAuth {
            let refreshedToken = try await tokenProvider.refreshAccessTokenAfterUnauthorized()
            var refreshed = request
            refreshed.setValue("Bearer \(refreshedToken)", forHTTPHeaderField: "Authorization")
            return try await performWrite(request: refreshed, didRetryAuth: true, rateRetryCount: rateRetryCount)
        }
        if response.statusCode == 429, rateRetryCount < 2 {
            let retryAfter = (response.allHeaderFields["Retry-After"] as? String).flatMap(TimeInterval.init) ?? 1.0
            let clamped = min(retryAfter, Self.inlineRateLimitRetryCeiling)
            try await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
            return try await performWrite(
                request: request,
                didRetryAuth: didRetryAuth,
                rateRetryCount: rateRetryCount + 1
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? decoder.decode(SpotifyAPIErrorResponse.self, from: data).error.message)
            switch response.statusCode {
            case 401: throw SpotifyAPIError.unauthorized
            case 400: throw SpotifyAPIError.badRequest(message: message, details: nil)
            case 403: throw SpotifyAPIError.forbidden(message: message, details: nil)
            case 404: throw SpotifyAPIError.notFound(message: message)
            default:  throw SpotifyAPIError.server(statusCode: response.statusCode, message: message, details: nil)
            }
        }
        return data
    }
}

private struct SpotifyPlaylistMutationResponse: Decodable {
    let snapshotID: String?

    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id"
    }
}

private extension Array where Element == SpotifyPlaylistTrackRemoval {
    /// Splits a position-descending list into requests of at most `maximum`
    /// positions, merging entries that share a URI inside a single request.
    /// Merging is safe within one request because Spotify applies it against a
    /// single snapshot; merging across requests is not, so batch boundaries
    /// always follow the descending order.
    func chunkedByPositionCount(maximum: Int) -> [[Element]] {
        guard maximum > 0 else { return [self] }
        var batches: [[Element]] = []
        var current: [Element] = []
        var currentPositionCount = 0

        func flush() {
            guard !current.isEmpty else { return }
            batches.append(current)
            current = []
            currentPositionCount = 0
        }

        for removal in self {
            for position in removal.positions {
                if currentPositionCount == maximum {
                    flush()
                }
                if let index = current.firstIndex(where: { $0.uri == removal.uri }) {
                    current[index] = SpotifyPlaylistTrackRemoval(
                        uri: removal.uri,
                        positions: current[index].positions + [position]
                    )
                } else {
                    current.append(SpotifyPlaylistTrackRemoval(uri: removal.uri, positions: [position]))
                }
                currentPositionCount += 1
            }
        }
        flush()
        return batches
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
