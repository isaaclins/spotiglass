import Foundation

extension SpotifyAPIClient {
    /// Spotify caps `POST /v1/playlists/{id}/tracks` and `DELETE` at 100 URIs per request.
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

    // MARK: - Playlist track membership

    /// Appends the given tracks to a playlist, batched into ≤100-URI chunks.
    func addTracksToPlaylist(playlistID: String, uris: [String]) async throws {
        let unique = uniqueOrderedURIs(uris)
        guard !unique.isEmpty, !playlistID.isEmpty else { return }
        for chunk in unique.chunked(into: Self.playlistTracksMutationBatchSize) {
            let body: [String: Any] = ["uris": chunk]
            try await sendVoidWrite(
                method: "POST",
                path: "/v1/playlists/\(playlistID)/tracks",
                queryItems: [],
                jsonBody: body
            )
        }
    }

    /// Removes all occurrences of the given URIs from a playlist, batched.
    func removeTracksFromPlaylist(playlistID: String, uris: [String]) async throws {
        let unique = uniqueOrderedURIs(uris)
        guard !unique.isEmpty, !playlistID.isEmpty else { return }
        for chunk in unique.chunked(into: Self.playlistTracksMutationBatchSize) {
            let body: [String: Any] = [
                "tracks": chunk.map { ["uri": $0] }
            ]
            try await sendVoidWrite(
                method: "DELETE",
                path: "/v1/playlists/\(playlistID)/tracks",
                queryItems: [],
                jsonBody: body
            )
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
            path: "/v1/users/\(userID)/playlists",
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

    private func uniqueOrderedURIs(_ uris: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        out.reserveCapacity(uris.count)
        for uri in uris {
            let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    /// Issues a writing (POST/PUT/DELETE) request that returns no decodable body.
    private func sendVoidWrite(
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
            case 400: throw SpotifyAPIError.badRequest(message: message, details: nil)
            case 403: throw SpotifyAPIError.forbidden(message: message, details: nil)
            case 404: throw SpotifyAPIError.notFound(message: message)
            default:  throw SpotifyAPIError.server(statusCode: response.statusCode, message: message, details: nil)
            }
        }
        return data
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
