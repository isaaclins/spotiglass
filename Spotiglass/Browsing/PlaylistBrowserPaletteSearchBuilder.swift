import Foundation

/// Dependencies for building command-palette search rows from playlist browser state.
@MainActor
struct PlaylistBrowserPaletteSearchEnvironment {
    var isPinnedByID: (String) -> Bool
    var pin: (PinnedItem) -> Void
    var unpin: (String) -> Void
    var playURI: (String) -> Void
    var openPlaylist: (String) -> Void
    var openArtist: (String) -> Void
    var openAlbum: (String, String, String, URL?) -> Void
    var addToQueue: (String) async -> Void
}

/// Extracted from ``PlaylistBrowserView`` so palette search mapping is unit-testable.
@MainActor
enum PlaylistBrowserPaletteSearchBuilder {
    static func search(
        query: String,
        category: CommandPaletteSearchCategory,
        spotifySearchClient: SpotifyAPIClient,
        environment: PlaylistBrowserPaletteSearchEnvironment,
        loadedContextTracks: [TrackRowViewModel]?,
        visiblePlaylists: [PlaylistRowViewModel],
        currentUserSpotifyID: String?
    ) async throws -> CommandPaletteSearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        func pinUnpinClosures(for pinnedItem: PinnedItem) -> (pin: (@MainActor () -> Void)?, unpin: (@MainActor () -> Void)?) {
            if environment.isPinnedByID(pinnedItem.id) {
                let id = pinnedItem.id
                return (nil, { environment.unpin(id) })
            }
            let copy = pinnedItem
            return ({ environment.pin(copy) }, nil)
        }

        var mapped = CommandPaletteSearchResults()

        if category == .thisPlaylist {
            if let rows = loadedContextTracks {
                mapped.inPlaylistMatches = inPlaylistMatches(
                    from: rows,
                    trimmedQuery: trimmed,
                    environment: environment
                )
            }
            return mapped
        }

        mapped.myPlaylists = localLibraryPlaylistMatches(
            visiblePlaylists: visiblePlaylists,
            trimmedQuery: trimmed,
            environment: environment,
            currentUserSpotifyID: currentUserSpotifyID
        )
        if category == .myPlaylists {
            return mapped
        }

        // Single round-trip: the primary multi-type search already returns the artist's top
        // tracks and the palette ranks the artist itself to the top, so the old sequential
        // `artist:"…"` augmentation call (which roughly doubled search latency) isn't worth it.
        let paletteSearchLimit = 30
        let results = try await spotifySearchClient.search(query: query, limit: paletteSearchLimit)

        mapped.catalogPlaylists = results.playlists.map { playlist in
            let pinPayload = PinnedItem.playlist(playlist)
            let pinPair = pinUnpinClosures(for: pinPayload)
            return CommandPaletteItem(
                id: "playlist-\(playlist.id)",
                title: playlist.name,
                subtitle: PlaylistOwnerDisplay.palettePlaylistSubtitle(
                    ownerName: playlist.ownerName,
                    ownerID: playlist.ownerID,
                    currentUserID: currentUserSpotifyID
                ),
                iconSystemName: "music.note.list",
                section: .playlists,
                keywords: [playlist.ownerName, playlist.id],
                pinAction: pinPair.pin,
                unpinAction: pinPair.unpin,
                action: { environment.openPlaylist(playlist.id) }
            )
        }

        if let rows = loadedContextTracks {
            mapped.inPlaylistMatches = inPlaylistMatches(
                from: rows,
                trimmedQuery: trimmed,
                environment: environment
            )
        }

        mapped.tracks = results.tracks.map { track in
            trackPaletteItem(track, environment: environment, pinUnpinClosures: pinUnpinClosures)
        }

        mapped.artists = results.artists.map { artist in
            let pinPayload = PinnedItem.artist(artist)
            let pinPair = pinUnpinClosures(for: pinPayload)
            return CommandPaletteItem(
                id: "artist-\(artist.id)",
                title: artist.name,
                subtitle: SpotiglassL10n.string("browser.palette.subtitle.artist"),
                iconSystemName: "person.wave.2",
                artistAvatarURL: artist.imageURL,
                section: .artists,
                keywords: [artist.uri],
                keepsPaletteOpen: false,
                pinAction: pinPair.pin,
                unpinAction: pinPair.unpin,
                action: { environment.openArtist(artist.id) }
            )
        }

        mapped.albums = results.albums.map { album in
            let pinPayload = PinnedItem.album(album)
            let pinPair = pinUnpinClosures(for: pinPayload)
            let artistSubtitle = album.artists.joined(separator: ", ")
            return CommandPaletteItem(
                id: "album-\(album.id)",
                title: album.name,
                subtitle: artistSubtitle,
                iconSystemName: "opticaldisc",
                section: .albums,
                keywords: album.artists + [album.uri],
                pinAction: pinPair.pin,
                unpinAction: pinPair.unpin,
                action: { environment.openAlbum(album.id, album.name, artistSubtitle, album.imageURL) }
            )
        }

        return mapped
    }

    /// Synchronous, network-free matches from data already in memory (open-playlist tracks +
    /// library playlists). Drives the palette's local-first instant render before the catalog
    /// search returns. Mirrors the local portions ``search(query:category:…)`` produces.
    static func localSearch(
        query: String,
        environment: PlaylistBrowserPaletteSearchEnvironment,
        loadedContextTracks: [TrackRowViewModel]?,
        visiblePlaylists: [PlaylistRowViewModel],
        currentUserSpotifyID: String?
    ) -> CommandPaletteSearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var mapped = CommandPaletteSearchResults()
        if let rows = loadedContextTracks {
            mapped.inPlaylistMatches = inPlaylistMatches(
                from: rows,
                trimmedQuery: trimmed,
                environment: environment
            )
        }
        mapped.myPlaylists = localLibraryPlaylistMatches(
            visiblePlaylists: visiblePlaylists,
            trimmedQuery: trimmed,
            environment: environment,
            currentUserSpotifyID: currentUserSpotifyID
        )
        return mapped
    }

    static func inPlaylistMatches(
        from rows: [TrackRowViewModel],
        trimmedQuery: String,
        environment: PlaylistBrowserPaletteSearchEnvironment
    ) -> [CommandPaletteItem] {
        guard !trimmedQuery.isEmpty else { return [] }
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
            let score = probe.score(for: trimmedQuery)
            guard score < 100 else { continue }
            let pinPayload = row.pinnedTrackItem()
            let pinAction: (@MainActor () -> Void)?
            let unpinAction: (@MainActor () -> Void)?
            if let pinPayload {
                if environment.isPinnedByID(pinPayload.id) {
                    pinAction = nil
                    unpinAction = { environment.unpin(pinPayload.id) }
                } else {
                    pinAction = { environment.pin(pinPayload) }
                    unpinAction = nil
                }
            } else {
                pinAction = nil
                unpinAction = nil
            }
            let queueAction: (@MainActor () async -> Void)? = {
                await environment.addToQueue(uri)
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
                action: { environment.playURI(uri) }
            )
            scored.append((item, score))
        }
        scored.sort { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.0.title < rhs.0.title
        }
        return scored.map(\.0)
    }

    static func localLibraryPlaylistMatches(
        visiblePlaylists: [PlaylistRowViewModel],
        trimmedQuery: String,
        environment: PlaylistBrowserPaletteSearchEnvironment,
        currentUserSpotifyID: String?
    ) -> [CommandPaletteItem] {
        var libraryRows: [(item: CommandPaletteItem, score: Int)] = []
        for row in visiblePlaylists {
            let summary = SpotifyPlaylistSummary(
                id: row.id,
                name: row.title,
                ownerID: row.ownerID,
                ownerName: row.owner,
                imageURL: row.artworkURL,
                trackCount: row.trackCount,
                snapshotID: row.snapshotID
            )
            let pinPayload = PinnedItem.playlist(summary)
            let pinPair: (pin: (@MainActor () -> Void)?, unpin: (@MainActor () -> Void)?)
            if environment.isPinnedByID(pinPayload.id) {
                pinPair = (nil, { environment.unpin(pinPayload.id) })
            } else {
                let copy = pinPayload
                pinPair = ({ environment.pin(copy) }, nil)
            }
            let item = CommandPaletteItem(
                id: "playlist-\(row.id)",
                title: row.title,
                subtitle: row.ownerTracksLine(currentUserID: currentUserSpotifyID),
                iconSystemName: "music.note.list",
                section: .myPlaylists,
                keywords: [row.owner, row.title, row.id],
                pinAction: pinPair.pin,
                unpinAction: pinPair.unpin,
                action: { environment.openPlaylist(row.id) }
            )
            let score = item.score(for: trimmedQuery)
            guard score < 100 else { continue }
            libraryRows.append((item, score))
        }
        libraryRows.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return lhs.item.title < rhs.item.title
        }
        return libraryRows.map(\.item)
    }

    private static func trackPaletteItem(
        _ track: SpotifyTrack,
        environment: PlaylistBrowserPaletteSearchEnvironment,
        pinUnpinClosures: (PinnedItem) -> (pin: (@MainActor () -> Void)?, unpin: (@MainActor () -> Void)?)
    ) -> CommandPaletteItem {
        let pinPayload = PinnedItem.track(track)
        let pinPair = pinUnpinClosures(pinPayload)
        let trackURI = track.uri
        let queueAction: (@MainActor () async -> Void)? = {
            await environment.addToQueue(trackURI)
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
            action: { environment.playURI(track.uri) }
        )
    }
}
