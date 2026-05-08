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
            // Re-query in songs scope using the artist name as the search term.
            commandPaletteManager?.viewModel.applyExternalQuery(name)
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
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        func pinUnpinClosures(for pinnedItem: PinnedItem) -> (pin: (@MainActor () -> Void)?, unpin: (@MainActor () -> Void)?) {
            if pinnedStore.isPinned(id: pinnedItem.id) {
                let id = pinnedItem.id
                return (nil, { pinnedStore.unpin(id: id) })
            } else {
                let copy = pinnedItem
                return ({ pinnedStore.pin(copy) }, nil)
            }
        }

        func inPlaylistMatches(from rows: [TrackRowViewModel]) -> [CommandPaletteItem] {
            guard !trimmed.isEmpty else { return [] }
            var scored: [(CommandPaletteItem, Int)] = []
            for row in rows {
                guard let uri = row.playableURI else { continue }
                let keywords = [row.subtitle] + row.artistRefs.map(\.name)
                let probe = CommandPaletteItem(
                    id: "track-\(row.id)",
                    title: row.title,
                    subtitle: row.subtitle,
                    iconSystemName: "music.note",
                    section: .thisPlaylist,
                    keywords: keywords,
                    action: {}
                )
                let score = probe.score(for: trimmed)
                guard score < 100 else { continue }
                let pinPayload = row.pinnedTrackItem()
                let pinAction: (@MainActor () -> Void)?
                let unpinAction: (@MainActor () -> Void)?
                if let pinPayload {
                    if pinnedStore.isPinned(id: pinPayload.id) {
                        pinAction = nil
                        unpinAction = { pinnedStore.unpin(id: pinPayload.id) }
                    } else {
                        pinAction = { pinnedStore.pin(pinPayload) }
                        unpinAction = nil
                    }
                } else {
                    pinAction = nil
                    unpinAction = nil
                }
                let queueAction: (@MainActor () async -> Void)? = { [weak queueViewModel] in
                    await queueViewModel?.addToQueue(uri: uri)
                }
                let item = CommandPaletteItem(
                    id: "track-\(row.id)",
                    title: row.title,
                    subtitle: row.subtitle,
                    iconSystemName: "music.note",
                    trackArtworkURL: row.artworkURL,
                    section: .thisPlaylist,
                    keywords: keywords,
                    pinAction: pinAction,
                    unpinAction: unpinAction,
                    queueAction: queueAction,
                    isExplicit: row.badgeText == "Explicit",
                    action: {
                        commandPaletteManager.execute(
                            commandID: "playback.playURI",
                            args: ["uri": .string(uri)]
                        )
                    }
                )
                scored.append((item, score))
            }
            scored.sort { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0.title < rhs.0.title
            }
            return scored.map(\.0)
        }

        func trackPaletteItem(_ track: SpotifyTrack) -> CommandPaletteItem {
            let pinPayload = PinnedItem.track(track)
            let pinPair = pinUnpinClosures(for: pinPayload)
            let trackURI = track.uri
            let queueAction: (@MainActor () async -> Void)? = { [weak queueViewModel] in
                await queueViewModel?.addToQueue(uri: trackURI)
            }
            return CommandPaletteItem(
                id: "track-\(track.id)",
                title: track.name,
                subtitle: track.artists.joined(separator: ", "),
                iconSystemName: "music.note",
                trackArtworkURL: track.albumArtworkURL,
                section: .tracks,
                keywords: track.artists + [track.uri],
                pinAction: pinPair.pin,
                unpinAction: pinPair.unpin,
                queueAction: queueAction,
                isExplicit: track.isExplicit,
                action: {
                    commandPaletteManager.execute(
                        commandID: "playback.playURI",
                        args: ["uri": .string(track.uri)]
                    )
                }
            )
        }

        func localLibraryPlaylistMatches() -> [CommandPaletteItem] {
            guard let viewModel else { return [] }
            var libraryRows: [(item: CommandPaletteItem, score: Int)] = []
            for row in viewModel.visiblePlaylists {
                let summary = SpotifyPlaylistSummary(
                    id: row.id,
                    name: row.title,
                    ownerName: row.owner,
                    imageURL: row.artworkURL,
                    trackCount: 0,
                    snapshotID: row.snapshotID
                )
                let pinPayload = PinnedItem.playlist(summary)
                let pinPair = pinUnpinClosures(for: pinPayload)
                let item = CommandPaletteItem(
                    id: "playlist-\(row.id)",
                    title: row.title,
                    subtitle: "Your library • \(row.owner)",
                    iconSystemName: "music.note.list",
                    section: .myPlaylists,
                    keywords: [row.owner, row.title, row.id],
                    pinAction: pinPair.pin,
                    unpinAction: pinPair.unpin,
                    action: {
                        commandPaletteManager.execute(
                            commandID: "navigation.playlist.open",
                            args: ["playlistID": .string(row.id)]
                        )
                    }
                )
                let score = item.score(for: trimmed)
                guard score < 100 else { continue }
                libraryRows.append((item, score))
            }
            libraryRows.sort { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                return lhs.item.title < rhs.item.title
            }
            return libraryRows.map(\.item)
        }

        var mapped = CommandPaletteSearchResults()

        if category == .thisPlaylist {
            if let rows = viewModel?.loadedContextTracksForPalette {
                mapped.inPlaylistMatches = inPlaylistMatches(from: rows)
            }
            return mapped
        }

        mapped.myPlaylists = localLibraryPlaylistMatches()
        if category == .myPlaylists {
            return mapped
        }

        let paletteSearchLimit = 30
        let results = try await spotifySearchClient.search(query: query, limit: paletteSearchLimit)

        var mergedTracks = results.tracks
        if category == .all || category == .tracks,
           let firstArtist = results.artists.first,
           SpotifyPaletteSearchAugmentation.shouldFetchArtistScopedTracks(
               trimmedUserQuery: trimmed,
               topArtistName: firstArtist.name,
               primaryTrackCount: results.tracks.count
           ) {
            let sanitized = firstArtist.name.replacingOccurrences(of: "\"", with: "")
            let scopedQuery = "artist:\"\(sanitized)\""
            let scoped = try await spotifySearchClient.searchTracks(query: scopedQuery, limit: 50)
            mergedTracks = SpotifyPaletteSearchAugmentation.mergeTracksPreservingOrder(
                primary: mergedTracks,
                extra: scoped
            )
        }

        mapped.catalogPlaylists = results.playlists.map { playlist in
            let pinPayload = PinnedItem.playlist(playlist)
            let pinPair = pinUnpinClosures(for: pinPayload)
            return CommandPaletteItem(
                id: "playlist-\(playlist.id)",
                title: playlist.name,
                subtitle: "Playlist • \(playlist.ownerName)",
                iconSystemName: "music.note.list",
                section: .playlists,
                keywords: [playlist.ownerName, playlist.id],
                pinAction: pinPair.pin,
                unpinAction: pinPair.unpin,
                action: {
                    commandPaletteManager.execute(
                        commandID: "navigation.playlist.open",
                        args: ["playlistID": .string(playlist.id)]
                    )
                }
            )
        }

        if let viewModel {
            if let rows = viewModel.loadedContextTracksForPalette {
                mapped.inPlaylistMatches = inPlaylistMatches(from: rows)
            }
        }

        mapped.tracks = mergedTracks.map(trackPaletteItem)

        mapped.artists = results.artists.map { artist in
            let pinPayload = PinnedItem.artist(artist)
            let pinPair = pinUnpinClosures(for: pinPayload)
            return CommandPaletteItem(
                id: "artist-\(artist.id)",
                title: artist.name,
                subtitle: "Artist",
                iconSystemName: "person.wave.2",
                artistAvatarURL: artist.imageURL,
                section: .artists,
                keywords: [artist.uri],
                keepsPaletteOpen: false,
                pinAction: pinPair.pin,
                unpinAction: pinPair.unpin,
                action: {
                    commandPaletteManager.execute(
                        commandID: CommandPaletteCommandID.openArtist,
                        args: ["artistID": .string(artist.id)]
                    )
                }
            )
        }

        mapped.albums = results.albums.map { album in
            let pinPayload = PinnedItem.album(album)
            let pinPair = pinUnpinClosures(for: pinPayload)
            return CommandPaletteItem(
                id: "album-\(album.id)",
                title: album.name,
                subtitle: album.artists.joined(separator: ", "),
                iconSystemName: "opticaldisc",
                section: .albums,
                keywords: album.artists + [album.uri],
                pinAction: pinPair.pin,
                unpinAction: pinPair.unpin,
                action: {}
            )
        }

        return mapped
    }
}
