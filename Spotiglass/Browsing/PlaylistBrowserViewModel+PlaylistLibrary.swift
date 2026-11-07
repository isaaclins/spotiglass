import Foundation

extension PlaylistBrowserViewModel {
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    func load() async {
        if let bundle = try? cache.loadPlaylistsBundle(now: now()),
           !bundle.playlists.isEmpty,
           let cachedPlaylists = try? validatedPlaylistSummaries(bundle.playlists),
           !cachedPlaylists.isEmpty {
            apply(playlists: cachedPlaylists, state: .loaded(cachedPlaylists.map(PlaylistRowViewModel.init)), preserveSelection: true)
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
            let playlists = try validatedPlaylistSummaries(
                try await fetchPlaylistsForRefresh(trigger: trigger)
            )
            try? cache.savePlaylists(playlists, cachedAt: now())
            invalidateLibraryContinuationCache()
            if playlists.isEmpty {
                playlistsByID = [:]
                playlistState = .empty(SpotiglassL10n.format("browser.empty.noPlaylists", MusicServiceSelection.current.displayName))
                if case let .playlist(id) = sidebarSelection,
                   knownPlaylistSummariesByID[id] != nil {
                    return
                }
                await selectHomeIfNoDetailIsShown()
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
                case .home, .search, .pinnedItem:
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
            await selectHomeIfNoDetailIsShown()
        }
    }

    /// The Home feed is independent of the playlist library. On the initial
    /// route, keep it available even when the library has no usable response.
    private func selectHomeIfNoDetailIsShown() async {
        guard detailState.currentValue == nil,
              sidebarSelection == nil || sidebarSelection == .home else {
            return
        }
        await selectSidebar(.home)
    }

    private func fetchPlaylistsForRefresh(trigger: PlaylistRefreshTrigger) async throws -> [MusicPlaylistSummary] {
        if let inFlightPlaylistListRefreshTask {
            let (playlists, profile) = try await inFlightPlaylistListRefreshTask.value
            currentUserSpotifyID = profile.id
            return playlists
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
            async let playlists = api.currentUserPlaylists(limit: 50)
            async let profile = api.currentUserProfile()
            return try await (playlists, profile)
        }
        inFlightPlaylistListRefreshTask = task
        do {
            let (playlists, profile) = try await task.value
            currentUserSpotifyID = profile.id
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

    private func currentPlaylistSummariesFromLoadedState() -> [MusicPlaylistSummary]? {
        guard let rows = playlistState.currentValue, !rows.isEmpty else { return nil }
        let ordered = rows.compactMap { playlistsByID[$0.id] }
        return ordered.isEmpty ? nil : ordered
    }

    /// A transport failure must stay an error state, never become a synthetic
    /// playlist row. This also rejects error-shaped objects accepted by the
    /// permissive Spotify DTO fallback before they reach disk or SwiftUI.
    private func validatedPlaylistSummaries(_ playlists: [MusicPlaylistSummary]) throws -> [MusicPlaylistSummary] {
        let forbiddenMessage = SpotiglassL10n.string("error.spotify.forbidden")
        let accessDeniedMessage = SpotiglassL10n.string("error.browsing.accessDenied.message")
        let invalid = playlists.contains { playlist in
            let name = playlist.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty
                || playlist.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || playlist.id == "unknown-playlist"
                || name == forbiddenMessage
                || name == accessDeniedMessage
        }
        guard !invalid else {
            throw SpotifyAPIError.decoding("Playlist response contained an error item.")
        }
        return playlists
    }

    private func apply(
        playlists: [MusicPlaylistSummary],
        state: BrowsingLoadState<[PlaylistRowViewModel]>,
        preserveSelection: Bool
    ) {
        let shownCounts = playlistsByID.compactMapValues(\.trackCount)
        playlistsByID = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        playlistState = state
        loadMissingPlaylistTrackCounts(shownCounts: shownCounts)

        if preserveSelection, let selection = sidebarSelection {
            switch selection {
            case let .playlist(id) where playlistsByID[id] != nil || knownPlaylistSummariesByID[id] != nil:
                return
            case .likedSongs, .home, .search, .pinnedItem:
                return
            case .playlist:
                break
            }
        }

        if case let .playlist(missingID) = sidebarSelection,
           playlistsByID[missingID] == nil,
           knownPlaylistSummariesByID[missingID] == nil {
            detailState = .error(BrowsingDisplayError(
                title: SpotiglassL10n.string("error.browsing.playlistUnavailable.title"),
                message: SpotiglassL10n.string("error.browsing.playlistUnavailable.deleted"),
                canRetry: true
            ))
        }
        // Default landing surface is Home, not the first playlist.
        sidebarSelection = .home
    }

    /// Playlists asked for per batch: the rows at the top fill in first, and one MusicKit
    /// library query stays small.
    static let playlistTrackCountBatchSize = 25

    /// Asks the provider for the counts the listing came without, after the sidebar is on
    /// screen, and patches each batch into the rows as it arrives. A newer listing cancels it.
    /// Rows that showed a count before this listing keep it until the fresh one arrives, so a
    /// refresh doesn't blank them; one the provider can't count any more goes back to none.
    private func loadMissingPlaylistTrackCounts(shownCounts: [String: Int]) {
        playlistTrackCountTask?.cancel()
        let missing = (playlistState.currentValue ?? [])
            .filter { $0.trackCount == nil && $0.id != SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID }
            .map(\.id)
        guard !missing.isEmpty else {
            playlistTrackCountTask = nil
            return
        }
        let awaiting = Set(missing)
        playlistTrackCountStandIns = awaiting
        applyPlaylistTrackCounts(shownCounts.filter { awaiting.contains($0.key) })
        playlistTrackCountTask = Task { [weak self, api] in
            var answered = Set<String>()
            for start in stride(from: 0, to: missing.count, by: Self.playlistTrackCountBatchSize) {
                guard !Task.isCancelled else { return }
                let batch = Array(missing[start..<min(missing.count, start + Self.playlistTrackCountBatchSize)])
                let counts = await api.playlistTrackCounts(playlistIDs: batch)
                guard !Task.isCancelled, let self else { return }
                answered.formUnion(counts.keys)
                self.applyPlaylistTrackCounts(counts)
            }
            guard !Task.isCancelled, let self else { return }
            let unanswered = Dictionary(uniqueKeysWithValues: awaiting.subtracting(answered).map { ($0, Int?.none) })
            self.applyPlaylistTrackCounts(unanswered)
            self.playlistTrackCountStandIns = []
        }
    }

    /// Writes `counts` into the rows and the open playlist's header. A row gets a count when it
    /// has none, or when its count is a stand-in from before the listing
    /// (`playlistTrackCountStandIns`); a `nil` count takes a stand-in away.
    private func applyPlaylistTrackCounts(_ counts: [String: Int?]) {
        var patchedIDs = Set<String>()
        for (id, count) in counts {
            guard let summary = playlistsByID[id],
                  summary.trackCount != count,
                  summary.trackCount == nil || playlistTrackCountStandIns.contains(id) else { continue }
            playlistsByID[id] = MusicPlaylistSummary(
                id: summary.id,
                name: summary.name,
                ownerID: summary.ownerID,
                ownerName: summary.ownerName,
                imageURL: summary.imageURL,
                trackCount: count,
                snapshotID: summary.snapshotID
            )
            patchedIDs.insert(id)
        }
        guard !patchedIDs.isEmpty else { return }
        if case let .playlist(detail)? = detailState.currentValue,
           patchedIDs.contains(detail.playlist.id),
           let summary = playlistsByID[detail.playlist.id] {
            let counted = PlaylistDetailViewModel(playlist: PlaylistRowViewModel(summary), tracks: detail.tracks)
            switch detailState {
            case .loading, .empty, .error:
                break
            case .loaded:
                detailState = .loaded(.playlist(counted))
            case .refreshing:
                detailState = .refreshing(.playlist(counted))
            case let .staleCache(_, displayError):
                detailState = .staleCache(.playlist(counted), displayError)
            }
        }
        guard let rows = playlistState.currentValue else { return }
        let patched = rows.map { row in
            guard patchedIDs.contains(row.id), let summary = playlistsByID[row.id] else { return row }
            return PlaylistRowViewModel(summary)
        }
        switch playlistState {
        case .loading, .empty, .error:
            return
        case .loaded:
            playlistState = .loaded(patched)
        case .refreshing:
            playlistState = .refreshing(patched)
        case let .staleCache(_, displayError):
            playlistState = .staleCache(patched, displayError)
        }
    }
}
