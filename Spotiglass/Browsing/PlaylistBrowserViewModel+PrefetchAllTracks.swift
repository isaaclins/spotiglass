import Foundation

extension PlaylistBrowserViewModel {
    /// Max concurrent `/v1/playlists/{id}/items` (or `/me/tracks`) requests during a bulk prefetch.
    /// Spotify rate-limits aggressively (HTTP 429); 3 is conservative and matches the user-approved plan.
    static let prefetchAllPlaylistsConcurrency = 3

    /// Clamp range for a `Retry-After` cooldown received from Spotify mid-prefetch.
    static let prefetchAllPlaylistsRetryAfterBounds: ClosedRange<TimeInterval> = 1...30

    /// How long the terminal "Loaded N playlists" header lingers in the palette
    /// after a run completes before `prefetchProgress` is cleared.
    static let prefetchAllPlaylistsTerminalLingerSeconds: UInt64 = 2

    /// Entry point for the "Load all your songs into Spotiglass" command. Toggles
    /// the run: invoking while a run is in flight cancels it; otherwise starts a
    /// new one.
    func toggleBulkPlaylistTrackPrefetch() async {
        if let task = prefetchAllPlaylistsTask {
            task.cancel()
            prefetchAllPlaylistsTask = nil
            if var progress = prefetchAllPlaylistsProgress {
                progress.phase = .cancelled
                prefetchAllPlaylistsProgress = progress
            }
            scheduleTerminalProgressClear()
            return
        }
        let task = Task { [weak self] in
            await self?.runBulkPlaylistTrackPrefetch()
            return ()
        }
        prefetchAllPlaylistsTask = task
        await task.value
    }

    /// Core prefetch loop. Public for tests; production callers should use
    /// `toggleBulkPlaylistTrackPrefetch()`.
    func runBulkPlaylistTrackPrefetch() async {
        await loadIfNeeded()

        let worklist = buildPrefetchWorklist()
        guard !worklist.isEmpty else {
            prefetchAllPlaylistsProgress = PrefetchAllPlaylistsProgress(
                phase: .finished, total: 0, completed: 0, skipped: 0, failed: 0
            )
            scheduleTerminalProgressClear()
            prefetchAllPlaylistsTask = nil
            return
        }

        prefetchAllPlaylistsProgress = PrefetchAllPlaylistsProgress(
            phase: .running, total: worklist.count, completed: 0, skipped: 0, failed: 0
        )

        let concurrency = min(Self.prefetchAllPlaylistsConcurrency, worklist.count)
        var cursor = 0

        await withTaskGroup(of: PrefetchItemOutcome.self) { group in
            let initial = min(concurrency, worklist.count)
            for _ in 0..<initial {
                let item = worklist[cursor]
                cursor += 1
                group.addTask { [weak self] in
                    await self?.processPrefetchItem(item) ?? .failed
                }
            }

            while let outcome = await group.next() {
                if Task.isCancelled { break }
                tally(outcome: outcome)
                if cursor < worklist.count {
                    let item = worklist[cursor]
                    cursor += 1
                    group.addTask { [weak self] in
                        await self?.processPrefetchItem(item) ?? .failed
                    }
                }
            }

            if Task.isCancelled {
                group.cancelAll()
                // Drain remaining outcomes so the group exits cleanly without
                // dangling tasks; do not count them — the run is cancelled.
                while await group.next() != nil {}
            }
        }

        if Task.isCancelled {
            if var progress = prefetchAllPlaylistsProgress {
                progress.phase = .cancelled
                prefetchAllPlaylistsProgress = progress
            }
        } else {
            if var progress = prefetchAllPlaylistsProgress {
                progress.phase = .finished
                prefetchAllPlaylistsProgress = progress
            }
        }
        scheduleTerminalProgressClear()
        prefetchAllPlaylistsTask = nil
    }

    private func tally(outcome: PrefetchItemOutcome) {
        guard var progress = prefetchAllPlaylistsProgress else { return }
        switch outcome {
        case .completed: progress.completed += 1
        case .skipped:   progress.skipped += 1
        case .failed:    progress.failed += 1
        case .cancelled: break
        }
        prefetchAllPlaylistsProgress = progress
    }

    /// Single-item worker; safe to run off the main actor (only the API + cache touches happen here).
    private func processPrefetchItem(_ item: PrefetchWorkItem) async -> PrefetchItemOutcome {
        if Task.isCancelled { return .cancelled }

        switch item {
        case let .playlist(summary):
            if isPlaylistTrackCacheFresh(playlistID: summary.id, snapshotID: summary.snapshotID) {
                return .skipped
            }
            return await fetchAndCachePlaylistTracks(summary: summary, retryRemaining: 1)

        case .likedSongs:
            let id = SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
            let snap = SpotiglassSidebarLibrary.likedSongsCacheSnapshotID
            if isPlaylistTrackCacheFresh(playlistID: id, snapshotID: snap) {
                return .skipped
            }
            return await fetchAndCacheLikedSongs(retryRemaining: 1)
        }
    }

    private func isPlaylistTrackCacheFresh(playlistID: String, snapshotID: String) -> Bool {
        // Recently revalidated under the same snapshot — coalesce with the detail loader.
        if let last = lastTracksRevalidationByID[playlistID],
           last.snapshotID == snapshotID,
           now().timeIntervalSince(last.at) < tracksRevalidateMinInterval {
            return true
        }
        if let fresh = try? cache.loadTracks(
            playlistID: playlistID, snapshotID: snapshotID, now: now(), maxAge: maxCacheAge
        ), !fresh.isEmpty {
            return true
        }
        return false
    }

    private func fetchAndCachePlaylistTracks(
        summary: SpotifyPlaylistSummary, retryRemaining: Int
    ) async -> PrefetchItemOutcome {
        do {
            // Mirror the limits used by the per-playlist detail loader so we don't regress the
            // legacy `limit=100 → HTTP 400` issue called out in the inline comment there.
            let tracks = try await api.playlistTracks(playlistID: summary.id, limit: 50, maxPages: 200)
            try? cache.saveTracks(tracks, playlistID: summary.id, snapshotID: summary.snapshotID, cachedAt: now())
            invalidateLibraryContinuationCache()
            lastTracksRevalidationByID[summary.id] = (summary.snapshotID, now())
            return .completed
        } catch is CancellationError {
            return .cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            return .cancelled
        } catch let apiError as SpotifyAPIError {
            if case let .rateLimited(retryAfter) = apiError, retryRemaining > 0 {
                let delay = (retryAfter ?? 5).clamped(to: Self.prefetchAllPlaylistsRetryAfterBounds)
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return .cancelled
                }
                return await fetchAndCachePlaylistTracks(summary: summary, retryRemaining: retryRemaining - 1)
            }
            return .failed
        } catch {
            return .failed
        }
    }

    private func fetchAndCacheLikedSongs(retryRemaining: Int) async -> PrefetchItemOutcome {
        do {
            let result = try await api.currentUserSavedTracks(limit: 50, maxPages: nil)
            try? cache.saveTracks(
                result.tracks,
                playlistID: SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID,
                snapshotID: SpotiglassSidebarLibrary.likedSongsCacheSnapshotID,
                cachedAt: now()
            )
            invalidateLibraryContinuationCache()
            lastTracksRevalidationByID[SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID] =
                (SpotiglassSidebarLibrary.likedSongsCacheSnapshotID, now())
            lastLikedSongsRevalidationAt = now()
            return .completed
        } catch is CancellationError {
            return .cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            return .cancelled
        } catch let apiError as SpotifyAPIError {
            if case let .rateLimited(retryAfter) = apiError, retryRemaining > 0 {
                let delay = (retryAfter ?? 5).clamped(to: Self.prefetchAllPlaylistsRetryAfterBounds)
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return .cancelled
                }
                return await fetchAndCacheLikedSongs(retryRemaining: retryRemaining - 1)
            }
            return .failed
        } catch {
            return .failed
        }
    }

    private func buildPrefetchWorklist() -> [PrefetchWorkItem] {
        let summaries: [SpotifyPlaylistSummary]
        if let rows = playlistState.currentValue {
            summaries = rows.compactMap { playlistsByID[$0.id] }
        } else {
            summaries = Array(playlistsByID.values)
        }
        var items: [PrefetchWorkItem] = summaries.map { .playlist($0) }
        items.append(.likedSongs)
        return items
    }

    private func scheduleTerminalProgressClear() {
        let snapshot = prefetchAllPlaylistsProgress
        guard snapshot?.isTerminal == true else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.prefetchAllPlaylistsTerminalLingerSeconds * 1_000_000_000)
            await MainActor.run {
                guard let self else { return }
                // Only clear if the snapshot we observed is still the published one (a new run may have started).
                if self.prefetchAllPlaylistsProgress == snapshot {
                    self.prefetchAllPlaylistsProgress = nil
                }
            }
        }
    }
}

// MARK: - Worklist + outcome types

enum PrefetchWorkItem: Equatable {
    case playlist(SpotifyPlaylistSummary)
    case likedSongs
}

enum PrefetchItemOutcome: Equatable {
    case completed
    case skipped
    case failed
    case cancelled
}

private extension TimeInterval {
    func clamped(to range: ClosedRange<TimeInterval>) -> TimeInterval {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
