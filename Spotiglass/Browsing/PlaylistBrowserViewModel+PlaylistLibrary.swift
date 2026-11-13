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
            // Counts saved with the list are shown, but counted again like any listing's, so
            // the provider's rules for how long a count holds still apply.
            let savedCounts = api.listsPlaylistsWithoutTrackCounts ? cachedPlaylists.compactMap { summary in
                summary.trackCount.map { (summary.id, $0) }
            } : []
            let listed = api.listsPlaylistsWithoutTrackCounts ? cachedPlaylists.map { $0.with(trackCount: nil) } : cachedPlaylists
            apply(
                playlists: listed,
                state: .loaded(listed.map(PlaylistRowViewModel.init)),
                preserveSelection: true,
                shownCounts: Dictionary(savedCounts, uniquingKeysWith: { first, _ in first })
            )
            if bundle.age >= playlistListAutoRefreshMinInterval {
                await refreshPlaylists(trigger: .automatic)
            } else {
                // Learned alongside the detail load, not in front of it: the ID only decides
                // the owner line and the rename item.
                async let currentUser: Void = loadCurrentUserIfUnknown()
                if let sidebarSelection {
                    detailSession += 1
                    let session = detailSession
                    await scheduleDetailLoad(for: sidebarSelection, refreshCachedData: true, session: session)
                }
                await currentUser
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
                playlistState = .empty(LocalizedText.noPlaylists(on: MusicServiceSelection.current))
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

    /// A fresh playlist cache skips the `me/playlists` refresh, which is also where the current
    /// user is learned. Without it, own playlists read as someone else's (owner shown, no
    /// rename). That happened on every browser rebuilt within the refresh window, e.g. after
    /// a language switch (#400). Failing here only leaves the ID unknown, as before.
    private func loadCurrentUserIfUnknown() async {
        guard currentUserID?.isEmpty ?? true else { return }
        guard let profile = try? await api.currentUserProfile(), !profile.id.isEmpty else { return }
        currentUserID = profile.id
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
            currentUserID = profile.id
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
            currentUserID = profile.id
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
        preserveSelection: Bool,
        shownCounts savedCounts: [String: Int] = [:]
    ) {
        let shownCounts = playlistsByID.compactMapValues(\.trackCount).merging(savedCounts) { shown, _ in shown }
        playlistsByID = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        playlistTrackCountEdits = playlistTrackCountEdits.filter { playlistsByID[$0.key] != nil }
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

    /// The sidebar's playlists in the order it shows them, for saving the list after an edit:
    /// the next launch shows the saved order, and a dictionary's order changes from run to run.
    func playlistsInSidebarOrder() -> [MusicPlaylistSummary] {
        let shown = (playlistState.currentValue ?? []).compactMap { playlistsByID[$0.id] }
        let shownIDs = Set(shown.map(\.id))
        return shown + playlistsByID.values.filter { !shownIDs.contains($0.id) }.sorted { $0.id < $1.id }
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
        guard api.listsPlaylistsWithoutTrackCounts else {
            playlistTrackCountTask = nil
            playlistTrackCountStandIns = []
            return
        }
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
        startPlaylistTrackCountRun(missing)
    }

    /// Counts every playlist in the sidebar again after songs or an album left the library:
    /// Music takes them out of each playlist they were in. Rows keep their count until the new
    /// one arrives. Only for providers with their own library edits (Apple Music).
    func recountPlaylistTracksAfterLibraryRemoval() {
        guard api.listsPlaylistsWithoutTrackCounts else { return }
        playlistTrackCountTask?.cancel()
        let ids = (playlistState.currentValue ?? [])
            .map(\.id)
            .filter { $0 != SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID }
        // The removed songs left every playlist they were in, so kept track lists are out of
        // date too (#442).
        for id in ids { invalidateTracksCache(playlistID: id) }
        guard !ids.isEmpty else { return }
        playlistTrackCountStandIns = Set(ids)
        startPlaylistTrackCountRun(ids)
    }

    /// Asks the provider for these playlists' counts a batch at a time; each one in
    /// `playlistTrackCountStandIns` gets the fresh count, or none when the provider has none.
    /// A count read while its playlist was edited is dropped: the edit counts it again
    /// (`countPlaylistTracks(of:)`).
    private func startPlaylistTrackCountRun(_ ids: [String]) {
        let awaiting = Set(ids)
        playlistTrackCountTask = Task { [weak self, api] in
            var answered = Set<String>()
            for start in stride(from: 0, to: ids.count, by: Self.playlistTrackCountBatchSize) {
                guard !Task.isCancelled, let editsBefore = self?.playlistTrackCountEdits else { return }
                let batch = Array(ids[start..<min(ids.count, start + Self.playlistTrackCountBatchSize)])
                var counts = await api.playlistTrackCounts(playlistIDs: batch)
                guard !Task.isCancelled, let self else { return }
                for id in batch where self.playlistTrackCountEdits[id] != editsBefore[id] {
                    counts[id] = nil
                    answered.insert(id)
                }
                answered.formUnion(counts.keys)
                self.applyPlaylistTrackCounts(counts)
            }
            guard !Task.isCancelled, let self else { return }
            let unanswered = Dictionary(uniqueKeysWithValues: awaiting.subtracting(answered).map { ($0, Int?.none) })
            self.applyPlaylistTrackCounts(unanswered)
            self.playlistTrackCountStandIns = []
        }
    }

    /// Counts one playlist again after an edit made from Spotiglass; the provider counts it with
    /// the edit. Its count replaces the row's, unless another edit came first (that one asks
    /// again).
    func countPlaylistTracks(of playlistID: String) {
        guard api.listsPlaylistsWithoutTrackCounts else { return }
        let edits = playlistTrackCountEdits[playlistID]
        Task { [weak self, api] in
            let counts = await api.playlistTrackCounts(playlistIDs: [playlistID])
            guard let self, self.playlistTrackCountEdits[playlistID] == edits, let count = counts[playlistID] else { return }
            self.applyPlaylistTrackCounts([playlistID: count], replacing: [playlistID])
        }
    }

    /// Writes `counts` into the rows and the open playlist's header. A row gets a count when it
    /// has none, when its count is a stand-in from before the listing
    /// (`playlistTrackCountStandIns`), or when it is in `replacing`; a `nil` count takes a
    /// stand-in away.
    private func applyPlaylistTrackCounts(_ counts: [String: Int?], replacing: Set<String> = []) {
        var patchedIDs = Set<String>()
        for (id, count) in counts {
            guard let summary = playlistsByID[id],
                  summary.trackCount != count,
                  summary.trackCount == nil || playlistTrackCountStandIns.contains(id) || replacing.contains(id) else { continue }
            playlistsByID[id] = summary.with(trackCount: count)
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

extension LocalizedText {
    /// "No playlists on <service>", naming the service whose library came back empty rather than
    /// whichever is selected when it is shown, in the language of the moment (#548).
    static func noPlaylists(on service: MusicService) -> LocalizedText {
        LocalizedText(SpotiglassL10n.format("browser.empty.noPlaylists", service.displayName))
    }
}
