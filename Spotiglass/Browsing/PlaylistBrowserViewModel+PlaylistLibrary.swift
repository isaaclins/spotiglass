import Foundation

extension PlaylistBrowserViewModel {
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    func load() async {
        if let bundle = try? cache.loadPlaylistsBundle(now: now()), !bundle.playlists.isEmpty {
            apply(playlists: bundle.playlists, state: .loaded(bundle.playlists.map(PlaylistRowViewModel.init)), preserveSelection: true)
            if bundle.age >= playlistListAutoRefreshMinInterval {
                await refreshPlaylists(trigger: .automatic)
            } else {
                if let sidebarSelection {
                    detailSession += 1
                    let session = detailSession
                    await scheduleDetailLoad(for: sidebarSelection, refreshCachedData: true, session: session)
                }
            }
            return
        }

        playlistState = .loading
        await refreshPlaylists(trigger: .automatic)
    }

    func refreshPlaylists(trigger: PlaylistRefreshTrigger = .automatic) async {
        let existingRows = playlistState.currentValue
        if let existingRows, !existingRows.isEmpty {
            playlistState = .refreshing(existingRows)
        }

        do {
            let playlists = try await fetchPlaylistsForRefresh(trigger: trigger)
            try? cache.savePlaylists(playlists, cachedAt: now())
            if playlists.isEmpty {
                playlistsByID = [:]
                sidebarSelection = nil
                playlistState = .empty("Your Spotify library has no playlists yet.")
                detailState = .empty("Create or follow a playlist in Spotify, then refresh.")
                return
            }
            let selectionBefore = sidebarSelection
            let playlistIDBefore: String? = {
                if case let .playlist(id) = selectionBefore { return id }
                return nil
            }()
            let snapshotBeforeRefresh = playlistIDBefore.flatMap { playlistsByID[$0]?.snapshotID }

            apply(playlists: playlists, state: .loaded(playlists.map(PlaylistRowViewModel.init)), preserveSelection: true)

            guard let selectionAfter = sidebarSelection else { return }

            let shouldScheduleDetailReload: Bool = {
                switch selectionAfter {
                case .likedSongs:
                    return false
                case .home, .pinnedItem:
                    return selectionBefore != selectionAfter
                case let .playlist(idAfter):
                    if case let .playlist(idBefore) = selectionBefore, idBefore == idAfter {
                        let newSnap = playlistsByID[idAfter]?.snapshotID
                        return newSnap != snapshotBeforeRefresh
                    }
                    return true
                }
            }()

            if shouldScheduleDetailReload {
                detailSession += 1
                let session = detailSession
                await scheduleDetailLoad(for: selectionAfter, refreshCachedData: true, session: session)
            }
        } catch {
            let displayError = Self.displayError(for: error)
            if let existingRows, !existingRows.isEmpty {
                playlistState = .staleCache(existingRows, displayError)
            } else {
                playlistState = .error(displayError)
            }
        }
    }

    private func fetchPlaylistsForRefresh(trigger: PlaylistRefreshTrigger) async throws -> [SpotifyPlaylistSummary] {
        if let inFlightPlaylistListRefreshTask {
            return try await inFlightPlaylistListRefreshTask.value
        }

        if trigger == .userInitiated,
           let lastManualPlaylistRefreshAt,
           now().timeIntervalSince(lastManualPlaylistRefreshAt) < manualPlaylistRefreshCooldown,
           let cached = currentPlaylistSummariesFromLoadedState(),
           !cached.isEmpty {
            return cached
        }

        if trigger == .userInitiated {
            lastManualPlaylistRefreshAt = now()
        }

        playlistListRefreshGeneration += 1
        let generation = playlistListRefreshGeneration
        let task = Task { [api] in
            try await api.currentUserPlaylists(limit: 50)
        }
        inFlightPlaylistListRefreshTask = task
        do {
            let playlists = try await task.value
            if generation == playlistListRefreshGeneration {
                inFlightPlaylistListRefreshTask = nil
            }
            return playlists
        } catch {
            if generation == playlistListRefreshGeneration {
                inFlightPlaylistListRefreshTask = nil
            }
            throw error
        }
    }

    private func currentPlaylistSummariesFromLoadedState() -> [SpotifyPlaylistSummary]? {
        guard let rows = playlistState.currentValue, !rows.isEmpty else { return nil }
        let ordered = rows.compactMap { playlistsByID[$0.id] }
        return ordered.isEmpty ? nil : ordered
    }

    private func apply(
        playlists: [SpotifyPlaylistSummary],
        state: BrowsingLoadState<[PlaylistRowViewModel]>,
        preserveSelection: Bool
    ) {
        playlistsByID = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        playlistState = state

        if preserveSelection, let selection = sidebarSelection {
            switch selection {
            case let .playlist(id) where playlistsByID[id] != nil:
                return
            case .likedSongs, .home, .pinnedItem:
                return
            case .playlist:
                break
            }
        }

        if case let .playlist(missingID) = sidebarSelection, playlistsByID[missingID] == nil {
            detailState = .error(BrowsingDisplayError(
                title: SpotiglassL10n.string("error.browsing.playlistUnavailable.title"),
                message: SpotiglassL10n.string("error.browsing.playlistUnavailable.deleted"),
                canRetry: true
            ))
        }
        sidebarSelection = playlists.first.map { .playlist($0.id) }
    }
}
