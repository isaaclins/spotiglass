import SwiftUI

extension PlaylistBrowserView {
    func bindCommandPalette(queueVisible: Binding<Bool>, lyricsPresented: Binding<Bool>) {
        syncUnifiedRefreshRoutingToViewModel()
        let includeThisPlaylist = viewModel.isCommandPaletteContextSearchEligible
        commandPaletteManager.viewModel.setAvailableSearchCategories(
            CommandPaletteSearchCategory.footerOrder(includeThisPlaylist: includeThisPlaylist),
            refreshIfFilterInvalidated: true
        )

        commandPaletteManager.isSignedIn = true
        commandPaletteManager.signOut = signOut
        let browserVM = viewModel
        let queueVM = queueViewModel
        commandPaletteManager.unifiedRefresh = {
            Task { @MainActor in
                syncUnifiedRefreshRoutingToViewModel()
                await browserVM.performUnifiedRefresh { await queueVM.refreshQueue() }
            }
        }
        commandPaletteManager.selectNextPlaylist = { [weak viewModel] in
            await viewModel?.selectNextPlaylist()
        }
        commandPaletteManager.selectPreviousPlaylist = { [weak viewModel] in
            await viewModel?.selectPreviousPlaylist()
        }
        commandPaletteManager.connectPlayback = { [weak playbackViewModel] in
            playbackViewModel?.start(recoveryCause: .manualReconnect)
        }
        commandPaletteManager.playbackTogglePrerequisite = { [weak playbackViewModel] in
            playbackViewModel?.isPlaybackTransportReady ?? false
        }
        commandPaletteManager.togglePlayback = { [weak playbackViewModel] in
            await playbackViewModel?.togglePlayPause()
        }
        commandPaletteManager.nextTrack = { [weak playbackViewModel] in
            await playbackViewModel?.next()
        }
        commandPaletteManager.previousTrack = { [weak playbackViewModel] in
            await playbackViewModel?.previous()
        }
        commandPaletteManager.disconnectPlayback = { [weak playbackViewModel] in
            await playbackViewModel?.disconnect()
        }
        commandPaletteManager.playURI = { [weak playbackViewModel] uri in
            await playbackViewModel?.play(uri: uri)
        }
        commandPaletteManager.openPlaylist = { [weak viewModel] playlistID in
            await viewModel?.selectPlaylist(id: playlistID, origin: .reset)
        }
        commandPaletteManager.openArtist = { [weak viewModel] artistID in
            await viewModel?.selectArtist(id: artistID, origin: .reset, displayName: nil)
        }
        commandPaletteManager.toggleQueue = {
            queueVisible.wrappedValue.toggle()
        }
        commandPaletteManager.toggleLyrics = {
            lyricsPresented.wrappedValue.toggle()
        }
        commandPaletteManager.filterByArtist = { [weak commandPaletteManager] name in
            commandPaletteManager?.viewModel.applyExternalQuery(name)
        }
        commandPaletteManager.prefetchAllPlaylists = { [weak viewModel] in
            Task { @MainActor in
                await viewModel?.toggleBulkPlaylistTrackPrefetch()
            }
        }
        commandPaletteManager.spotifySearch = { [self, spotifySearchClient, commandPaletteManager, weak viewModel, weak queueVM] query, category in
            try await self.spotifyPaletteSearch(
                query: query,
                category: category,
                spotifySearchClient: spotifySearchClient,
                commandPaletteManager: commandPaletteManager,
                viewModel: viewModel,
                queueViewModel: queueVM
            )
        }
    }
}

extension PlaylistBrowserView {
    @MainActor
    fileprivate func spotifyPaletteSearch(
        query: String,
        category: CommandPaletteSearchCategory,
        spotifySearchClient: SpotifyAPIClient,
        commandPaletteManager: CommandPaletteManager,
        viewModel: PlaylistBrowserViewModel?,
        queueViewModel: QueueViewModel?
    ) async throws -> CommandPaletteSearchResults {
        let environment = PlaylistBrowserPaletteSearchEnvironment(
            isPinnedByID: { [pinnedStore] id in pinnedStore.isPinned(id: id) },
            pin: { [pinnedStore] item in pinnedStore.pin(item) },
            unpin: { [pinnedStore] id in pinnedStore.unpin(id: id) },
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
                await queueViewModel?.addToQueue(uri: uri)
            }
        )
        return try await PlaylistBrowserPaletteSearchBuilder.search(
            query: query,
            category: category,
            spotifySearchClient: spotifySearchClient,
            environment: environment,
            loadedContextTracks: viewModel?.loadedContextTracksForPalette,
            visiblePlaylists: viewModel?.visiblePlaylists ?? []
        )
    }
}
