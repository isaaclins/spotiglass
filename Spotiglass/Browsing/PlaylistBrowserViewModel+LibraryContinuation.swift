import Foundation

private enum LibraryContinuationPolicy {
    static let cacheMaxAge: TimeInterval = 15 * 60
    static let queueLength = LibraryContinuationRanking.defaultLimit
    static let minimumUsefulLength = 3
    static let followedArtistPageLimit = 2
}

extension PlaylistBrowserViewModel {
    /// Invalidates both the persisted aggregate and any continuation already
    /// collecting it, so a mutation cannot be overwritten by an old result.
    func invalidateLibraryContinuationCache() {
        libraryContinuationGeneration += 1
        try? cache.invalidateLibraryContinuationIndex()
    }

    /// Collects the user's available library material, ranks a continuation,
    /// and hands the ordered URIs to the playback queue. The queue closure is
    /// injected so this browser model never owns playback state or performs
    /// network work from the pure ranking function.
    func enqueueLibraryContinuation(
        from row: TrackRowViewModel,
        enqueue: @escaping ([String]) async -> QueueEnqueueResult
    ) async {
        guard !Task.isCancelled else { return }
        guard let seed = row.spotifyTrackForPinning() else {
            trackMutationToast = SpotiglassL10n.string("library.continuation.unavailable")
            return
        }
        let generation = libraryContinuationGeneration

        guard let library = try? await collectLibraryContinuation(seed: seed, generation: generation) else {
            // Cancellation is intentionally silent: a cancelled menu action must
            // not rank, enqueue, or publish a misleading partial result.
            return
        }
        guard generation == libraryContinuationGeneration, !Task.isCancelled else { return }
        let continuation = LibraryContinuationRanking.rank(
            seed: seed,
            library: library,
            limit: LibraryContinuationPolicy.queueLength
        )
        guard !continuation.isEmpty else {
            trackMutationToast = SpotiglassL10n.string("library.continuation.empty")
            return
        }

        guard generation == libraryContinuationGeneration, !Task.isCancelled else { return }
        let result = await enqueue(continuation.map(\.uri))
        guard generation == libraryContinuationGeneration, !Task.isCancelled else { return }
        guard result.enqueued > 0 else {
            // QueueViewModel normally publishes its own detailed playback error.
            // Keep a localized browser message as a visible fallback for queue
            // implementations that cannot provide one.
            trackMutationToast = SpotiglassL10n.string("library.continuation.queueFailed")
            return
        }
        if result.enqueued < result.requested {
            trackMutationToast = SpotiglassL10n.format(
                "library.continuation.partial",
                Int64(result.enqueued),
                Int64(result.requested)
            )
        } else if continuation.count < LibraryContinuationPolicy.minimumUsefulLength {
            trackMutationToast = SpotiglassL10n.format(
                "library.continuation.short",
                Int64(continuation.count)
            )
        } else {
            trackMutationToast = SpotiglassL10n.format(
                "library.continuation.added",
                Int64(result.enqueued)
            )
        }
    }

    private func collectLibraryContinuation(
        seed: SpotifyTrack,
        generation: Int
    ) async throws -> LibraryContinuationLibrary {
        try checkLibraryContinuationIsCurrent(generation)
        if let cached = try? cache.loadLibraryContinuationIndex(
            now: now(),
            maxAge: LibraryContinuationPolicy.cacheMaxAge
        ), canUseCachedAggregate(cached, for: seed) {
            return cached
        }
        let stale = try? cache.loadLibraryContinuationIndexIgnoringAge()

        var playlists: [LibraryContinuationPlaylist] = []
        for summary in try await continuationPlaylistSummaries() {
            try checkLibraryContinuationIsCurrent(generation)
            let tracks = try await continuationTracks(for: summary, stale: stale)
            try checkLibraryContinuationIsCurrent(generation)
            if !tracks.isEmpty || hasCachedPlaylistTracks(for: summary) {
                playlists.append(
                    LibraryContinuationPlaylist(
                        id: summary.id,
                        tracks: tracks
                    )
                )
            }
        }

        try checkLibraryContinuationIsCurrent(generation)
        let savedTracks = try await continuationSavedTracks(stale: stale)
        try checkLibraryContinuationIsCurrent(generation)
        let topTracks = try await continuationTopTracks(stale: stale)
        try checkLibraryContinuationIsCurrent(generation)
        let topArtists = try await continuationTopArtists(stale: stale)
        try checkLibraryContinuationIsCurrent(generation)
        let followedArtists = try await continuationFollowedArtists(stale: stale)
        try checkLibraryContinuationIsCurrent(generation)
        let artistTopTrackCollection = try await continuationArtistTopTracks(
            seed: seed,
            stale: stale,
            generation: generation
        )

        try checkLibraryContinuationIsCurrent(generation)
        let collected = LibraryContinuationLibrary(
            savedTracks: savedTracks,
            playlists: playlists,
            topTracks: topTracks,
            topArtists: topArtists,
            followedArtists: followedArtists,
            artistTopTracks: artistTopTrackCollection.tracks,
            artistTopTrackArtistIDs: artistTopTrackCollection.artistIDs
        )
        try checkLibraryContinuationIsCurrent(generation)
        if hasTracks(collected) {
            // Even a stale aggregate can have been refreshed from per-source
            // caches, so keep the combined result for the next invocation.
            try? cache.saveLibraryContinuationIndex(collected, cachedAt: now())
            return collected
        }
        // A transient failure across every endpoint should not throw away a
        // previously usable index. It is still honest because the ranker will
        // return only tracks present in that cached index.
        if let stale { return stale }
        // Cache an empty, successfully attempted collection too. This prevents
        // an actually empty library from triggering a full crawl on every menu
        // invocation; mutations and playlist refreshes invalidate this entry.
        try? cache.saveLibraryContinuationIndex(collected, cachedAt: now())
        return collected
    }

    private func checkLibraryContinuationIsCurrent(_ generation: Int) throws {
        guard generation == libraryContinuationGeneration else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func canUseCachedAggregate(
        _ library: LibraryContinuationLibrary,
        for seed: SpotifyTrack
    ) -> Bool {
        let seedArtistIDs = Set(seedArtistIDs(for: seed))
        guard !library.artistTopTracks.isEmpty || !library.artistTopTrackArtistIDs.isEmpty else {
            // No breadth data was collected (for example, a track with no
            // artist IDs), so the core library index is still reusable.
            return true
        }
        return !seedArtistIDs.isEmpty
            && seedArtistIDs == Set(library.artistTopTrackArtistIDs)
    }

    private func seedArtistIDs(for seed: SpotifyTrack) -> [String] {
        var artistIDs: [String] = []
        var seen: Set<String> = []
        for rawID in seed.artistRefs.map(\.id) {
            let artistID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artistID.isEmpty, seen.insert(artistID).inserted else { continue }
            artistIDs.append(artistID)
        }
        return artistIDs
    }

    private func continuationPlaylistSummaries() async throws -> [SpotifyPlaylistSummary] {
        let loadedSummaries = orderedPlaylistSummaries(
            visible: visiblePlaylists.compactMap { playlistsByID[$0.id] },
            remaining: playlistsByID.values
        )
        if !loadedSummaries.isEmpty {
            return loadedSummaries
        }

        if let cached = try? cache.loadPlaylistsBundle(now: now()), !cached.playlists.isEmpty {
            return orderedPlaylistSummaries(visible: cached.playlists, remaining: [])
        }

        do {
            let fetched = try await api.currentUserPlaylists(limit: 50)
            try? cache.savePlaylists(fetched, cachedAt: now())
            return orderedPlaylistSummaries(visible: fetched, remaining: [])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return []
        }
    }

    private func orderedPlaylistSummaries(
        visible: [SpotifyPlaylistSummary],
        remaining: some Collection<SpotifyPlaylistSummary>
    ) -> [SpotifyPlaylistSummary] {
        var ordered: [SpotifyPlaylistSummary] = []
        var seen: Set<String> = []
        for summary in visible where seen.insert(summary.id).inserted {
            ordered.append(summary)
        }
        for summary in remaining.sorted(by: { $0.id < $1.id }) where seen.insert(summary.id).inserted {
            ordered.append(summary)
        }
        return ordered
    }

    private func continuationTracks(
        for summary: SpotifyPlaylistSummary,
        stale: LibraryContinuationLibrary?
    ) async throws -> [SpotifyTrack] {
        try Task.checkCancellation()
        if let cached = try? cache.loadTracksIgnoringAge(
            playlistID: summary.id,
            snapshotID: summary.snapshotID
        ) {
            return cached.compactMap(\.continuationTrack)
        }

        if case .playlist(let detail) = detailState.currentValue,
            detail.playlist.id == summary.id
        {
            return detail.tracks.compactMap { $0.spotifyTrackForPinning() }
        }

        do {
            let fetched = try await api.playlistTracks(
                playlistID: summary.id,
                limit: 50,
                maxPages: 200
            )
            try? cache.saveTracks(
                fetched,
                playlistID: summary.id,
                snapshotID: summary.snapshotID,
                cachedAt: now()
            )
            return fetched.compactMap(\.continuationTrack)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return stale?.playlists.first(where: { $0.id == summary.id })?.tracks ?? []
        }
    }

    private func hasCachedPlaylistTracks(for summary: SpotifyPlaylistSummary) -> Bool {
        (try? cache.loadTracksIgnoringAge(
            playlistID: summary.id,
            snapshotID: summary.snapshotID
        )) != nil
    }

    private func continuationSavedTracks(stale: LibraryContinuationLibrary?) async throws -> [SpotifyTrack] {
        try Task.checkCancellation()
        let playlistID = SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
        let snapshotID = SpotiglassSidebarLibrary.likedSongsCacheSnapshotID
        if let cached = try? cache.loadTracksIgnoringAge(
            playlistID: playlistID,
            snapshotID: snapshotID
        ) {
            return cached.compactMap(\.continuationTrack)
        }

        do {
            let result = try await api.currentUserSavedTracks(limit: 50, maxPages: nil)
            try? cache.saveTracks(
                result.tracks,
                playlistID: playlistID,
                snapshotID: snapshotID,
                cachedAt: now()
            )
            return result.tracks.compactMap(\.continuationTrack)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return stale?.savedTracks ?? []
        }
    }

    private func continuationTopTracks(
        stale: LibraryContinuationLibrary?
    ) async throws -> [SpotifyTrack] {
        try Task.checkCancellation()
        if !homeTopTrackData.isEmpty {
            return homeTopTrackData
        }
        if let staleTracks = stale?.topTracks, !staleTracks.isEmpty {
            return staleTracks
        }
        do {
            return try await api.topTracks(
                limit: 50,
                timeRange: "short_term",
                cacheMode: .freshOnly
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return []
        }
    }

    private func continuationTopArtists(
        stale: LibraryContinuationLibrary?
    ) async throws -> [SpotifyArtist] {
        try Task.checkCancellation()
        if let staleArtists = stale?.topArtists, !staleArtists.isEmpty {
            return staleArtists
        }
        do {
            return try await api.topArtists(
                limit: 50,
                timeRange: "short_term",
                cacheMode: .freshOnly
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return []
        }
    }

    private func continuationFollowedArtists(
        stale: LibraryContinuationLibrary?
    ) async throws -> [SpotifyArtist] {
        try Task.checkCancellation()
        if let staleArtists = stale?.followedArtists, !staleArtists.isEmpty {
            return staleArtists
        }
        do {
            return try await api.followedArtists(
                limit: 50,
                maxPages: LibraryContinuationPolicy.followedArtistPageLimit
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return []
        }
    }

    private func continuationArtistTopTracks(
        seed: SpotifyTrack,
        stale: LibraryContinuationLibrary?,
        generation: Int
    ) async throws -> (tracks: [SpotifyTrack], artistIDs: [String]) {
        try checkLibraryContinuationIsCurrent(generation)
        let artistIDs = seedArtistIDs(for: seed)
        guard !artistIDs.isEmpty else { return ([], []) }

        if let stale,
           Set(stale.artistTopTrackArtistIDs) == Set(artistIDs)
        {
            return (stale.artistTopTracks, stale.artistTopTrackArtistIDs)
        }

        var tracks: [SpotifyTrack] = []
        var loadedArtistIDs: [String] = []
        var seenKeys: Set<String> = []
        for artistID in artistIDs {
            try checkLibraryContinuationIsCurrent(generation)
            do {
                let fetched = try await api.artistTopTracks(
                    id: artistID,
                    market: nil,
                    cacheMode: .freshOnly
                )
                try checkLibraryContinuationIsCurrent(generation)
                loadedArtistIDs.append(artistID)
                for track in fetched {
                    let key: String
                    if let linkedFromID = track.linkedFromID?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !linkedFromID.isEmpty
                    {
                        key = linkedFromID
                    } else {
                        key = SpotifyPlayableURI.canonical(track.uri) ?? track.id
                    }
                    guard seenKeys.insert(key).inserted else { continue }
                    tracks.append(track)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One artist's optional breadth data should not prevent the
                // other credited artists from contributing a signal. The
                // failed ID is left out of the cache scope so it is retried.
                continue
            }
        }
        return (tracks, loadedArtistIDs)
    }

    private func hasTracks(_ library: LibraryContinuationLibrary) -> Bool {
        !library.savedTracks.isEmpty
            || library.playlists.contains { !$0.tracks.isEmpty }
            || !library.topTracks.isEmpty
    }
}
