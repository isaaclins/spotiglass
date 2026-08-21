import Foundation

extension PlaylistBrowserViewModel {
    /// Prefer catalog search, then use the supported per-album track route when search returns no
    /// tracks for this artist. The album fallback is capped to a small number of releases so an artist
    /// load stays bounded.
    func resolveArtistTracks(
        artistId: String,
        artist: SpotifyArtistDetail,
        albums: [SpotifyArtistAlbum],
        market: String?
    ) async throws -> [SpotifyTrack] {
        do {
            let sanitizedName = artist.name.replacingOccurrences(of: "\"", with: "")
            let query = "artist:\"\(sanitizedName)\""
            let results = try await api.search(query: query, limit: 10)
            let matching = results.tracks.filter { $0.artistRefs.contains { $0.id == artistId } }
            if !matching.isEmpty {
                return Array(matching.prefix(10))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Non-fatal: try album-derived tracks.
        }

        let selectedAlbums = Self.albumsForTrackFallback(
            from: albums,
            maxCount: ArtistAlbumFallbackStrategy.maxAlbumRequests
        )
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

        var collected: [SpotifyTrack] = []
        var seenTrackIdentityKeys: Set<String> = []
        var lastFailure: Error?
        for album in selectedAlbums {
            try Task.checkCancellation()
            do {
                let tracks = try await api.albumTracksFirstPage(
                    albumID: album.id,
                    market: market,
                    limit: 10
                )
                artistFetchMetrics.albumFallbackTrackRequests += 1
                artistFetchMetrics.albumFallbackPagesFetched += 1
                Self.appendUniqueFallbackTracks(
                    from: tracks,
                    albumArtworkFallback: albumImagesByID[album.id],
                    into: &collected,
                    seen: &seenTrackIdentityKeys,
                    limit: 10
                )
                if collected.count >= 10 {
                    return collected
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = error
                artistFetchMetrics.albumFallbackBudgetStops += 1
            }
        }

        if collected.isEmpty, let lastFailure {
            throw lastFailure
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
            let identityKeys = PinnedItem.trackIdentityKeys(for: track)
            guard !identityKeys.isEmpty, seen.isDisjoint(with: identityKeys) else { continue }
            seen.formUnion(identityKeys)
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
}
