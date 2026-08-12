import SwiftUI

/// Command palette wiring extracted from ``PlaylistBrowserView`` for isolated unit tests.
@MainActor
enum PlaylistBrowserCommandPaletteConfiguration {
    struct Dependencies {
        var viewModel: PlaylistBrowserViewModel
        var playbackViewModel: PlaybackSessionViewModel
        var queueViewModel: QueueViewModel
        var commandPaletteManager: CommandPaletteManager
        var pinnedStore: PinnedItemsStore
        var spotifySearchClient: SpotifyAPIClient
        var signOut: () -> Void
        var syncUnifiedRefreshRouting: () -> Void
    }

    static func apply(
        to manager: CommandPaletteManager,
        dependencies: Dependencies,
        queueVisible: Binding<Bool>,
        lyricsPresented: Binding<Bool>
    ) {
        dependencies.syncUnifiedRefreshRouting()
        let includeThisPlaylist = dependencies.viewModel.isCommandPaletteContextSearchEligible
        manager.viewModel.setAvailableSearchCategories(
            CommandPaletteSearchCategory.footerOrder(includeThisPlaylist: includeThisPlaylist),
            refreshIfFilterInvalidated: true
        )

        manager.isSignedIn = true
        manager.signOut = dependencies.signOut
        let browserVM = dependencies.viewModel
        let queueVM = dependencies.queueViewModel
        manager.unifiedRefresh = {
            Task { @MainActor in
                dependencies.syncUnifiedRefreshRouting()
                await browserVM.performUnifiedRefresh { await queueVM.refreshQueue() }
            }
        }
        manager.selectNextPlaylist = { [weak viewModel = dependencies.viewModel] in
            await viewModel?.selectNextPlaylist()
        }
        manager.selectPreviousPlaylist = { [weak viewModel = dependencies.viewModel] in
            await viewModel?.selectPreviousPlaylist()
        }
        manager.connectPlayback = { [weak playback = dependencies.playbackViewModel] in
            playback?.start(recoveryCause: .manualReconnect)
        }
        manager.playbackTogglePrerequisite = { [weak playback = dependencies.playbackViewModel] in
            playback?.isPlaybackTransportReady ?? false
        }
        manager.togglePlayback = { [weak playback = dependencies.playbackViewModel] in
            await playback?.togglePlayPause()
        }
        manager.nextTrack = { [weak playback = dependencies.playbackViewModel] in
            await playback?.next()
        }
        manager.previousTrack = { [weak playback = dependencies.playbackViewModel] in
            await playback?.previous()
        }
        manager.disconnectPlayback = { [weak playback = dependencies.playbackViewModel] in
            await playback?.disconnect()
        }
        manager.toggleShuffle = { [weak queue = dependencies.queueViewModel] in
            await queue?.toggleShuffle()
        }
        manager.cycleRepeat = { [weak playback = dependencies.playbackViewModel] in
            await playback?.cycleRepeat()
        }
        manager.playURI = { [weak playback = dependencies.playbackViewModel] uri in
            await playback?.play(uri: uri)
        }
        manager.openPlaylist = { [weak viewModel = dependencies.viewModel] playlistID in
            await viewModel?.selectPlaylist(id: playlistID, origin: .reset)
        }
        manager.openArtist = { [weak viewModel = dependencies.viewModel] artistID in
            await viewModel?.selectArtist(id: artistID, origin: .reset, displayName: nil)
        }
        // The Search view owns no API client; it borrows the browser's search
        // client. `/v1/search` caps `limit` at 10 per type, so depth comes from offset.
        let searchClient = dependencies.spotifySearchClient
        browserVM.catalogSearch.searchProvider = { query, offset in
            try await searchClient.search(query: query, limit: CatalogSearchViewModel.pageSize, offset: offset)
        }
        manager.openSearch = { [weak viewModel = dependencies.viewModel] in
            guard let viewModel else { return }
            Task { @MainActor in
                await viewModel.selectSidebar(.search)
            }
        }
        // Palette handoff: the fast keyboard layer passes its query and scope to
        // the browsable surface instead of competing with it.
        manager.viewModel.showAllResults = { [weak viewModel = dependencies.viewModel] query, category in
            guard let viewModel else { return }
            viewModel.catalogSearch.applyHandoff(query: query, paletteCategory: category)
            Task { @MainActor in
                await viewModel.selectSidebar(.search)
            }
        }
        manager.toggleQueue = {
            queueVisible.wrappedValue.toggle()
        }
        manager.toggleLyrics = {
            lyricsPresented.wrappedValue.toggle()
        }
        manager.filterByArtist = { [weak manager] name in
            manager?.viewModel.applyExternalQuery(name)
        }
        manager.prefetchAllPlaylists = { [weak viewModel = dependencies.viewModel] in
            Task { @MainActor in
                await viewModel?.toggleBulkPlaylistTrackPrefetch()
            }
        }
        let pinnedStore = dependencies.pinnedStore
        manager.spotifySearch = { query, category in
            try await paletteSearch(
                query: query,
                category: category,
                spotifySearchClient: dependencies.spotifySearchClient,
                commandPaletteManager: manager,
                viewModel: dependencies.viewModel,
                queueViewModel: dependencies.queueViewModel,
                isPinnedByID: { pinnedStore.isPinned(id: $0) },
                pin: { pinnedStore.pin($0) },
                unpin: { pinnedStore.unpin(id: $0) }
            )
        }
        manager.localSpotifySearch = { [weak manager] query in
            guard let manager else { return CommandPaletteSearchResults() }
            let environment = makeEnvironment(
                commandPaletteManager: manager,
                queueViewModel: dependencies.queueViewModel,
                isPinnedByID: { pinnedStore.isPinned(id: $0) },
                pin: { pinnedStore.pin($0) },
                unpin: { pinnedStore.unpin(id: $0) }
            )
            return PlaylistBrowserPaletteSearchBuilder.localSearch(
                query: query,
                environment: environment,
                loadedContextTracks: dependencies.viewModel.loadedContextTracksForPalette,
                visiblePlaylists: dependencies.viewModel.visiblePlaylists,
                currentUserSpotifyID: dependencies.viewModel.currentUserSpotifyID
            )
        }
    }

    /// Builds the action environment (play / open / pin / queue closures) shared by both the
    /// network-backed ``paletteSearch`` and the synchronous local-first ``localSearch``.
    static func makeEnvironment(
        commandPaletteManager: CommandPaletteManager,
        queueViewModel: QueueViewModel,
        isPinnedByID: @escaping (String) -> Bool,
        pin: @escaping (PinnedItem) -> Void,
        unpin: @escaping (String) -> Void
    ) -> PlaylistBrowserPaletteSearchEnvironment {
        PlaylistBrowserPaletteSearchEnvironment(
            isPinnedByID: isPinnedByID,
            pin: pin,
            unpin: unpin,
            playURI: { uri in
                commandPaletteManager.execute(
                    commandID: "playback.playURI",
                    args: ["uri": .string(uri)]
                )
            },
            openPlaylist: { playlistID in
                commandPaletteManager.execute(
                    commandID: "navigation.playlist.open",
                    args: ["playlistID": .string(playlistID)]
                )
            },
            openArtist: { artistID in
                commandPaletteManager.execute(
                    commandID: CommandPaletteCommandID.openArtist,
                    args: ["artistID": .string(artistID)]
                )
            },
            addToQueue: { uri in
                await queueViewModel.addToQueue(uri: uri)
            }
        )
    }

    static func paletteSearch(
        query: String,
        category: CommandPaletteSearchCategory,
        spotifySearchClient: SpotifyAPIClient,
        commandPaletteManager: CommandPaletteManager,
        viewModel: PlaylistBrowserViewModel,
        queueViewModel: QueueViewModel,
        isPinnedByID: @escaping (String) -> Bool,
        pin: @escaping (PinnedItem) -> Void,
        unpin: @escaping (String) -> Void
    ) async throws -> CommandPaletteSearchResults {
        let environment = makeEnvironment(
            commandPaletteManager: commandPaletteManager,
            queueViewModel: queueViewModel,
            isPinnedByID: isPinnedByID,
            pin: pin,
            unpin: unpin
        )
        return try await PlaylistBrowserPaletteSearchBuilder.search(
            query: query,
            category: category,
            spotifySearchClient: spotifySearchClient,
            environment: environment,
            loadedContextTracks: viewModel.loadedContextTracksForPalette,
            visiblePlaylists: viewModel.visiblePlaylists,
            currentUserSpotifyID: viewModel.currentUserSpotifyID
        )
    }
}
