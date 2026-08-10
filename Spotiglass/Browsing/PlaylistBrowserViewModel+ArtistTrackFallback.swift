import Foundation

extension PlaylistBrowserViewModel {
    /// Prefer Spotify top-tracks; when forbidden/unavailable (common for Web API dev-mode apps), fall back to
    /// search then album-derived tracks. The album fallback issues **one** batched `GET /v1/albums?ids=...`
    /// call covering up to `strategy.maxAlbumRequests` IDs, plus at most one single-album recovery if the
    /// batched response was missing tracks for an album we still need. Long-retry 429s short-circuit the
    /// album fallback entirely so we don't cascade rate-limit pain into more outbound calls.
    func resolveArtistTracks(
        artistId: String,
        artist: SpotifyArtistDetail,
        albums: [SpotifyArtistAlbum],
        market: String?
    ) async -> [SpotifyTrack] {
        let probeKey = ArtistTopTracksProbeKey(artistID: artistId, market: market)
        var fallbackBudgetMode: AlbumFallbackBudgetMode = .healthy
        if artistFallbackCooldown.shouldProbeTopTracks(for: probeKey, now: now()) {
            do {
                let top = try await api.artistTopTracks(id: artistId, market: market)
                artistFallbackCooldown.registerTopTracksProbeSuccess(for: probeKey)
                if !top.isEmpty {
                    return top
                }
            } catch {
                fallbackBudgetMode = artistFallbackCooldown.registerTopTracksProbeFailure(
                    error, for: probeKey, now: now())
                // Non-fatal: continue with fallbacks (403 Forbidden on `/top-tracks` is expected for dev-mode apps).
            }
        }

        do {
            let sanitizedName = artist.name.replacingOccurrences(of: "\"", with: "")
            let query = "artist:\"\(sanitizedName)\""
            let results = try await api.search(query: query, limit: 10)
            let matching = results.tracks.filter { $0.artistRefs.contains { $0.id == artistId } }
            if !matching.isEmpty {
                return Array(matching.prefix(10))
            }
        } catch {
            // Non-fatal: try album-derived list.
        }

        if fallbackBudgetMode == .skipped {
            // 429 with a long retry-after: skip the album fallback entirely instead of stacking another
            // outbound call onto a back-off window.
            artistFetchMetrics.albumFallbackBudgetStops += 1
            return []
        }

        let strategy = ArtistAlbumFallbackStrategy(rateLimited: fallbackBudgetMode == .rateLimitedReduced)
        let selectedAlbums = Self.albumsForTrackFallback(from: albums, maxCount: strategy.maxAlbumRequests)
        artistFetchMetrics.albumFallbackAlbumAttempts = selectedAlbums.count
        artistFetchMetrics.albumFallbackUniqueAlbums = Set(selectedAlbums.map { $0.id }).count
        guard !selectedAlbums.isEmpty else {
            return []
        }

        var albumImagesByID: [String: URL] = [:]
        for album in selectedAlbums {
            if let url = album.imageURL {
                albumImagesByID[album.id] = url
            }
        }
        let ids = selectedAlbums.map(\.id)
        var collected: [SpotifyTrack] = []
        if artistFallbackCooldown.shouldSkipBatchedAlbumsFallback(for: probeKey, now: now()) {
            artistFetchMetrics.albumFallbackBudgetStops += 1
            return collected
        }
        let batchSignature = Self.artistAlbumBatchSignature(artistID: artistId, market: market, ids: ids)
        if artistFallbackCooldown.shouldSkipFailedAlbumBatch(signature: batchSignature, now: now()) {
            artistFetchMetrics.albumFallbackBudgetStops += 1
            return collected
        }

        let batchedAlbums: [String: SpotifyBatchedAlbum]
        do {
            let response = try await api.albums(ids: ids, market: market)
            artistFetchMetrics.albumFallbackBatchedCalls += 1
            batchedAlbums = Dictionary(uniqueKeysWithValues: response.map { ($0.id, $0) })
        } catch {
            if case SpotifyAPIError.rateLimited(let retryAfter) = error {
                let until = artistFallbackCooldown.registerBatchedAlbumsRateLimit(
                    for: probeKey, retryAfter: retryAfter, now: now())
                artistFallbackCooldown.recordFailedAlbumBatchCooldown(signature: batchSignature, until: until)
            }
            artistFetchMetrics.albumFallbackBudgetStops += 1
            return []
        }

        var seenNames: Set<String> = []
        for album in selectedAlbums {
            guard let entry = batchedAlbums[album.id] else { continue }
            Self.appendUniqueFallbackTracks(
                from: entry.tracks,
                albumArtworkFallback: albumImagesByID[album.id],
                into: &collected,
                seen: &seenNames,
                limit: 10
            )
            if collected.count >= 10 {
                return collected
            }
        }

        if collected.count < 10, strategy.maxRecoveryCalls > 0 {
            let recoveryCandidate = selectedAlbums.first { album in
                guard !artistFallbackCooldown.hasAttemptedAlbumRecovery(albumID: album.id) else { return false }
                guard let entry = batchedAlbums[album.id] else { return false }
                return entry.tracksAvailable == false
            }
            if let recoveryCandidate {
                do {
                    artistFallbackCooldown.markAlbumRecoveryAttempted(albumID: recoveryCandidate.id)
                    let recovered = try await api.albumTracksFirstPage(
                        albumID: recoveryCandidate.id,
                        market: market,
                        limit: 10
                    )
                    artistFetchMetrics.albumFallbackRecoveryCalls += 1
                    artistFetchMetrics.albumFallbackPagesFetched = 1
                    Self.appendUniqueFallbackTracks(
                        from: recovered,
                        albumArtworkFallback: albumImagesByID[recoveryCandidate.id],
                        into: &collected,
                        seen: &seenNames,
                        limit: 10
                    )
                } catch {
                    artistFetchMetrics.albumFallbackBudgetStops += 1
                }
            }
        }

        return collected
    }

    /// Appends up to `limit - collected.count` deduped tracks from `source` into `collected`,
    /// patching `albumArtworkURL` from the album row when the embedded track was missing artwork.
    static func appendUniqueFallbackTracks(
        from source: [SpotifyTrack],
        albumArtworkFallback: URL?,
        into collected: inout [SpotifyTrack],
        seen: inout Set<String>,
        limit: Int
    ) {
        for track in source {
            if collected.count >= limit { return }
            let key = track.name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let withArt: SpotifyTrack
            if track.albumArtworkURL == nil, let url = albumArtworkFallback {
                withArt = SpotifyTrack(
                    id: track.id,
                    name: track.name,
                    artists: track.artists,
                    artistRefs: track.artistRefs,
                    albumArtworkURL: url,
                    albumName: track.albumName,
                    albumID: track.albumID,
                    durationMilliseconds: track.durationMilliseconds,
                    isExplicit: track.isExplicit,
                    isPlayable: track.isPlayable,
                    linkedFromID: track.linkedFromID,
                    uri: track.uri
                )
            } else {
                withArt = track
            }
            collected.append(withArt)
        }
    }

    /// Latest album and single releases first (by four-digit year when present).
    static func albumsForTrackFallback(from albums: [SpotifyArtistAlbum], maxCount: Int = 6) -> [SpotifyArtistAlbum] {
        let deduped = Self.dedupeAlbums(albums).filter { $0.group == .album || $0.group == .single }
        let sorted = deduped.sorted { lhs, rhs in
            let ly = Int(lhs.releaseYear ?? "") ?? 0
            let ry = Int(rhs.releaseYear ?? "") ?? 0
            if ly != ry {
                return ly > ry
            }
            if lhs.totalTracks != rhs.totalTracks {
                return lhs.totalTracks < rhs.totalTracks
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return Array(sorted.prefix(max(0, maxCount)))
    }

    static func artistAlbumBatchSignature(artistID: String, market: String?, ids: [String]) -> String {
        let normalizedMarket: String = {
            let trimmed = market?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? "from_token" : trimmed!
        }()
        return "\(artistID)|\(normalizedMarket)|\(ids.sorted().joined(separator: ","))"
    }
}
