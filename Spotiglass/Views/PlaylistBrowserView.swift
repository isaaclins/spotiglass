import AppKit
import SwiftUI

struct PlaylistBrowserView: View {
    @StateObject private var viewModel: PlaylistBrowserViewModel
    @StateObject private var playbackViewModel: PlaybackSessionViewModel
    @StateObject private var queueViewModel: QueueViewModel
    @AppStorage("queue.panel.visible") private var isQueueVisible = false
    /// Drives only the **playlist** sidebar (leading column). Queue visibility is separate — see `detailWithQueueSplit` below.
    @State private var playlistColumnVisibility: NavigationSplitViewVisibility = .doubleColumn
    private let commander: WebPlaybackViewCommander
    private let playbackCoordinator: SpotifyPlaybackWebViewCoordinator
    @ObservedObject private var commandPaletteManager: CommandPaletteManager
    private let spotifySearchClient: SpotifyAPIClient
    let signOut: () -> Void

    init(
        viewModel: PlaylistBrowserViewModel,
        playbackTokenProvider: PlaybackAccessTokenProviding,
        searchTokenProvider: SpotifyAccessTokenProviding,
        commandPaletteManager: CommandPaletteManager,
        signOut: @escaping () -> Void
    ) {
        let commander = WebPlaybackViewCommander()
        let playbackAPI = SpotifyPlaybackAPI(tokenProvider: playbackTokenProvider)
        let playbackViewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: commander
        )
        let queueViewModel = QueueViewModel(
            playbackAPI: playbackAPI,
            playbackSession: playbackViewModel
        )
        let playbackCoordinator = SpotifyPlaybackWebViewCoordinator(
            tokenBridge: PlaybackTokenBridge(provider: playbackTokenProvider)
        )
        playbackCoordinator.onEvent = { [weak playbackViewModel] event in
            playbackViewModel?.handle(event)
        }

        _viewModel = StateObject(wrappedValue: viewModel)
        _playbackViewModel = StateObject(wrappedValue: playbackViewModel)
        _queueViewModel = StateObject(wrappedValue: queueViewModel)
        _commandPaletteManager = ObservedObject(wrappedValue: commandPaletteManager)
        spotifySearchClient = SpotifyAPIClient(tokenProvider: searchTokenProvider)
        self.commander = commander
        self.playbackCoordinator = playbackCoordinator
        self.signOut = signOut
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $playlistColumnVisibility) {
                playlistSidebar
                    .background(.background)
                    .navigationSplitViewColumnWidth(min: 280, ideal: SpotiglassDesign.sidebarWidth)
            } detail: {
                detailWithQueueSplit
            }
            PlaybackControlsView(viewModel: playbackViewModel)
        }
        .background(.background)
        .background {
            HiddenPlaybackWebView(commander: commander, coordinator: playbackCoordinator)
                .frame(width: 1, height: 1)
                .opacity(0.01)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    isQueueVisible.toggle()
                } label: {
                    Label("Queue", systemImage: "list.bullet.indent")
                }
                .accessibilityHint("Shows or hides the playback queue.")

                Button {
                    Task { await viewModel.refreshPlaylists() }
                } label: {
                    Label("Refresh Playlists", systemImage: "arrow.clockwise")
                }
                .accessibilityHint("Reloads playlists from Spotify and updates cached data.")

                Button {
                    signOut()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
                .accessibilityHint("Disconnects Spotify and returns to the sign-in screen.")
            }
        }
        .task {
            await viewModel.loadIfNeeded()
        }
        .task {
            playbackViewModel.start()
        }
        .onAppear {
            bindCommandPalette(queueVisible: $isQueueVisible)
            queueViewModel.setPanelVisible(isQueueVisible)
        }
        .onChange(of: viewModel.selectedPlaylistID) { _, _ in
            bindCommandPalette(queueVisible: $isQueueVisible)
        }
        .onChange(of: isQueueVisible) { _, visible in
            queueViewModel.setPanelVisible(visible)
        }
        .onChange(of: playbackViewModel.sdkNextTracks) { _, _ in
            queueViewModel.handleSdkQueueSnapshotChanged()
        }
        .onChange(of: queueRelevantPlaybackKey) { _, _ in
            queueViewModel.handlePlaybackStateChange()
        }
    }

    /// Playback identity without scrubber position ticks (avoids re-running queue hooks every progress frame).
    /// Includes playing vs paused so the queue refetches after transport changes (Spotify’s REST queue reflects play state).
    /// Track URI still identifies the current item when it advances.
    private var queueRelevantPlaybackKey: String {
        switch playbackViewModel.connectionState {
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case let .ready(deviceID):
            "ready:\(deviceID)"
        case let .transferring(deviceID):
            "transferring:\(deviceID)"
        case let .playing(item):
            "playing:\(item.uri ?? "")"
        case let .paused(.some(item)):
            "paused:\(item.uri ?? "")"
        case .paused(.none):
            "paused-empty"
        case let .unavailable(message):
            "unavailable:\(message)"
        case let .error(error):
            "error:\(error.title)"
        }
    }

    private var playlistSidebar: some View {
        VStack(spacing: 0) {
            header(title: "Playlists", state: viewModel.playlistState)

            switch viewModel.playlistState {
            case .loading:
                ProgressView("Loading playlists...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .loaded(playlists), let .refreshing(playlists), let .staleCache(playlists, _):
                playlistList(playlists)
            case let .empty(message):
                EmptyStateView(title: "No playlists", message: message) {
                    Task { await viewModel.refreshPlaylists() }
                }
            case let .error(error):
                ErrorStateView(error: error) {
                    Task { await viewModel.refreshPlaylists() }
                }
            }
        }
    }

    private func playlistList(_ playlists: [PlaylistRowViewModel]) -> some View {
        let activePlaylistID = playbackViewModel.activePlaylistID
        let isPlaying: Bool = {
            if case .playing = playbackViewModel.connectionState { return true }
            return false
        }()
        return ScrollViewReader { proxy in
            List(selection: $viewModel.selectedPlaylistID) {
                ForEach(playlists) { playlist in
                    PlaylistListRow(
                        playlist: playlist,
                        isActive: playlist.id == activePlaylistID,
                        isPlaying: isPlaying
                    )
                    .tag(playlist.id)
                    .id(playlist.id)
                }
            }
            .onChange(of: viewModel.selectedPlaylistID) { _, newValue in
                Task { await viewModel.selectPlaylist(id: newValue) }
            }
            .onChange(of: playbackViewModel.activePlaylistID) { _, newActiveID in
                guard let newActiveID else { return }
                // Instant scroll, no animation per spec.
                proxy.scrollTo(newActiveID, anchor: .center)
            }
            .overlay(alignment: .bottom) {
                if case let .staleCache(_, error) = viewModel.playlistState {
                    StaleCacheBanner(error: error)
                } else if case .refreshing = viewModel.playlistState {
                    ProgressView("Refreshing playlists...")
                        .controlSize(.small)
                        .padding(SpotiglassDesign.spacingS)
                        .background(.background, in: Capsule())
                        .padding(SpotiglassDesign.spacingM)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var detailWithQueueSplit: some View {
        // Use `HStack` instead of `HSplitView` so the queue animates in from the **screen trailing**
        // edge. `HSplitView` drives NSSplitView divider motion from the leading pane, which reads as
        // “slides in from the left” even with `.move(edge: .trailing)` on the second column.
        HStack(spacing: 0) {
            playlistDetail
                .background(.background)
                .frame(minWidth: 360)
                .layoutPriority(1)
            if isQueueVisible {
                queuePanelColumn
                    .transition(
                        .asymmetric(
                            insertion: .offset(x: SpotiglassDesign.sidebarWidth).combined(with: .opacity),
                            removal: .offset(x: SpotiglassDesign.sidebarWidth).combined(with: .opacity)
                        )
                    )
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.84), value: isQueueVisible)
    }

    @ViewBuilder
    private var queuePanelColumn: some View {
        QueuePanelView(viewModel: queueViewModel)
            .background(.background)
            .frame(minWidth: 280, idealWidth: SpotiglassDesign.sidebarWidth, maxWidth: 420)
    }

    private var playlistDetail: some View {
        VStack(spacing: 0) {
            switch viewModel.detailState {
            case .loading:
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .loaded(content), let .refreshing(content), let .staleCache(content, _):
                Group {
                    switch content {
                    case let .playlist(detail):
                        PlaylistDetailContent(
                            detail: detail,
                            refresh: {
                                Task { await viewModel.refreshSelectedPlaylist() }
                            },
                            playURI: { uri in
                                let playableURIs = detail.tracks.compactMap(\.playableURI)
                                let playlistID = detail.playlist.id
                                Task {
                                    await playbackViewModel.playFromPlaylist(
                                        clickedURI: uri,
                                        playableURIs: playableURIs,
                                        playlistID: playlistID
                                    )
                                }
                            },
                            currentPlaybackURI: currentPlaybackURI,
                            isPlaying: isCurrentlyPlaying,
                            togglePlayPause: {
                                Task { await playbackViewModel.togglePlayPause() }
                            },
                            hasPlaybackDevice: hasPlaybackDevice,
                            addToQueue: { uri in
                                await queueViewModel.addToQueue(uri: uri)
                            },
                            openArtist: { artistID in
                                Task { await viewModel.selectArtist(id: artistID) }
                            }
                        )
                    case let .artist(detail):
                        ArtistDetailContent(
                            detail: detail,
                            refresh: {
                                Task { await viewModel.refreshSelectedPlaylist() }
                            },
                            playTrack: { uri in
                                let playableURIs = detail.tracks.compactMap(\.playableURI)
                                Task {
                                    await playbackViewModel.playFromPlaylist(
                                        clickedURI: uri,
                                        playableURIs: playableURIs,
                                        playlistID: nil
                                    )
                                }
                            },
                            playAlbumContext: { albumURI in
                                Task { await playbackViewModel.play(contextURI: albumURI) }
                            },
                            currentPlaybackURI: currentPlaybackURI,
                            isPlaying: isCurrentlyPlaying,
                            togglePlayPause: {
                                Task { await playbackViewModel.togglePlayPause() }
                            },
                            hasPlaybackDevice: hasPlaybackDevice,
                            addToQueue: { uri in
                                await queueViewModel.addToQueue(uri: uri)
                            },
                            openArtist: { artistID in
                                Task { await viewModel.selectArtist(id: artistID) }
                            }
                        )
                    }
                }
                .overlay(alignment: .bottom) {
                    if case let .staleCache(_, error) = viewModel.detailState {
                        StaleCacheBanner(error: error)
                    } else if case .refreshing = viewModel.detailState {
                        ProgressView("Refreshing…")
                            .controlSize(.small)
                            .padding(SpotiglassDesign.spacingS)
                            .background(.background, in: Capsule())
                            .padding(SpotiglassDesign.spacingM)
                    }
                }
            case let .empty(message):
                EmptyStateView(title: "No tracks", message: message) {
                    Task { await viewModel.refreshSelectedPlaylist() }
                }
            case let .error(error):
                ErrorStateView(error: error) {
                    Task { await viewModel.refreshSelectedPlaylist() }
                }
            }
        }
    }

    private func header<Value: Equatable>(title: String, state: BrowsingLoadState<Value>) -> some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            Text(title)
                .font(.title2.weight(.semibold))

            switch state {
            case .staleCache:
                Text("Showing cached data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .refreshing:
                Text("Refreshing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SpotiglassDesign.spacingM)
    }

    private var currentPlaybackURI: String? {
        switch playbackViewModel.connectionState {
        case let .playing(nowPlaying):
            nowPlaying.uri
        case let .paused(nowPlaying):
            nowPlaying?.uri
        case .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            nil
        }
    }

    private var isCurrentlyPlaying: Bool {
        if case .playing = playbackViewModel.connectionState { return true }
        return false
    }

    private var hasPlaybackDevice: Bool {
        playbackViewModel.deviceID != nil
    }

    private func bindCommandPalette(queueVisible: Binding<Bool>) {
        commandPaletteManager.isSignedIn = true
        commandPaletteManager.signOut = signOut
        commandPaletteManager.refreshPlaylists = { [weak viewModel] in
            await viewModel?.refreshPlaylists()
        }
        commandPaletteManager.refreshTracks = { [weak viewModel] in
            await viewModel?.refreshSelectedPlaylist()
        }
        commandPaletteManager.selectNextPlaylist = { [weak viewModel] in
            await viewModel?.selectNextPlaylist()
        }
        commandPaletteManager.selectPreviousPlaylist = { [weak viewModel] in
            await viewModel?.selectPreviousPlaylist()
        }
        commandPaletteManager.connectPlayback = { [weak playbackViewModel] in
            playbackViewModel?.start()
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
            await viewModel?.selectPlaylist(id: playlistID)
        }
        commandPaletteManager.openArtist = { [weak viewModel] artistID in
            await viewModel?.selectArtist(id: artistID)
        }
        commandPaletteManager.toggleQueue = {
            queueVisible.wrappedValue.toggle()
        }
        commandPaletteManager.filterByArtist = { [weak commandPaletteManager] name in
            // Re-query in songs scope using the artist name as the search term.
            commandPaletteManager?.viewModel.applyExternalQuery(name)
        }
        commandPaletteManager.spotifySearch = { [spotifySearchClient, commandPaletteManager, weak viewModel] query in
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let results = try await spotifySearchClient.search(query: query, limit: 4)
            var mapped = CommandPaletteSearchResults()

            mapped.playlists = results.playlists.map { playlist in
                CommandPaletteItem(
                    id: "playlist-\(playlist.id)",
                    title: playlist.name,
                    subtitle: "Playlist • \(playlist.ownerName)",
                    iconSystemName: "music.note.list",
                    section: .playlists,
                    keywords: [playlist.ownerName, playlist.id]
                ) {
                    commandPaletteManager.execute(
                        commandID: "navigation.playlist.open",
                        args: ["playlistID": .string(playlist.id)]
                    )
                }
            }

            let apiPlaylistIDs = Set(results.playlists.map(\.id))
            if let viewModel {
                var libraryExtras: [(item: CommandPaletteItem, score: Int)] = []
                for row in viewModel.visiblePlaylists where !apiPlaylistIDs.contains(row.id) {
                    let item = CommandPaletteItem(
                        id: "playlist-\(row.id)",
                        title: row.title,
                        subtitle: "Playlist • \(row.owner)",
                        iconSystemName: "music.note.list",
                        section: .playlists,
                        keywords: [row.owner, row.title, row.id]
                    ) {
                        commandPaletteManager.execute(
                            commandID: "navigation.playlist.open",
                            args: ["playlistID": .string(row.id)]
                        )
                    }
                    let score = item.score(for: trimmed)
                    guard score < 100 else { continue }
                    libraryExtras.append((item, score))
                }
                libraryExtras.sort { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score < rhs.score }
                    return lhs.item.title < rhs.item.title
                }
                mapped.playlists.append(contentsOf: libraryExtras.map(\.item))
            }

            mapped.tracks = results.tracks.map { track in
                CommandPaletteItem(
                    id: "track-\(track.id)",
                    title: track.name,
                    subtitle: track.artists.joined(separator: ", "),
                    iconSystemName: "music.note",
                    section: .tracks,
                    keywords: track.artists + [track.uri]
                ) {
                    commandPaletteManager.execute(
                        commandID: "playback.playURI",
                        args: ["uri": .string(track.uri)]
                    )
                }
            }

            mapped.artists = results.artists.map { artist in
                CommandPaletteItem(
                    id: "artist-\(artist.id)",
                    title: artist.name,
                    subtitle: "Artist",
                    iconSystemName: "person.wave.2",
                    section: .artists,
                    keywords: [artist.uri],
                    keepsPaletteOpen: false
                ) {
                    commandPaletteManager.execute(
                        commandID: CommandPaletteCommandID.openArtist,
                        args: ["artistID": .string(artist.id)]
                    )
                }
            }

            mapped.albums = results.albums.map { album in
                CommandPaletteItem(
                    id: "album-\(album.id)",
                    title: album.name,
                    subtitle: album.artists.joined(separator: ", "),
                    iconSystemName: "opticaldisc",
                    section: .albums,
                    keywords: album.artists + [album.uri]
                ) {}
            }

            return mapped
        }
        commandPaletteManager.viewModel.refresh()
    }
}

private struct PlaylistListRow: View {
    let playlist: PlaylistRowViewModel
    var isActive: Bool = false
    var isPlaying: Bool = false

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            ArtworkView(url: playlist.artworkURL, size: 46)
                .overlay(alignment: .bottomTrailing) {
                    if isActive {
                        PlayingWaveformIcon(isPlaying: isPlaying)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.black.opacity(0.55))
                            )
                            .padding(3)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title)
                    .font(.headline)
                    .lineLimit(1)

                Text("\(playlist.owner) • \(playlist.trackCountText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, SpotiglassDesign.spacingXS)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(playlist.title), by \(playlist.owner), \(playlist.trackCountText)\(isActive ? ", now playing" : "")")
    }
}

private struct PlaylistDetailContent: View {
    let detail: PlaylistDetailViewModel
    let refresh: () -> Void
    let playURI: (String) -> Void
    let currentPlaybackURI: String?
    let isPlaying: Bool
    let togglePlayPause: () -> Void
    let hasPlaybackDevice: Bool
    let addToQueue: (String) async -> Void
    let openArtist: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: SpotiglassDesign.spacingL) {
                ArtworkView(url: detail.playlist.artworkURL, size: 104)

                VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
                    Text(detail.playlist.title)
                        .font(.largeTitle.weight(.semibold))
                        .lineLimit(2)

                    Text("\(detail.playlist.owner) • \(detail.playlist.trackCountText)")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: refresh) {
                    Label("Refresh Tracks", systemImage: "arrow.clockwise")
                }
                .accessibilityHint("Reloads tracks for the selected playlist.")
            }
            .padding(SpotiglassDesign.spacingL)

            Divider()

            if detail.tracks.isEmpty {
                EmptyStateView(title: "No tracks", message: "This playlist is empty.", retry: refresh)
            } else {
                List(Array(detail.tracks.enumerated()), id: \.element.id) { index, track in
                    TrackListRow(
                        trackNumber: index + 1,
                        track: track,
                        playURI: playURI,
                        togglePlayPause: togglePlayPause,
                        isCurrent: track.playableURI != nil && track.playableURI == currentPlaybackURI,
                        isPlaying: isPlaying,
                        hasPlaybackDevice: hasPlaybackDevice,
                        addToQueue: addToQueue,
                        openArtist: openArtist
                    )
                }
            }
        }
    }
}

private struct EmptyStateView: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: SpotiglassDesign.spacingM) {
            Text(title)
                .font(.title3.weight(.semibold))

            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            // Retry is intentionally not bound to a keyboard shortcut here:
            // both the sidebar and detail panes can be in their own empty/error
            // state at the same time, and binding ⌘R to multiple Retry buttons
            // makes the shortcut ambiguous. The toolbar's Refresh Playlists
            // (⌘R) and Refresh Tracks (⌘T) buttons remain authoritative.
            Button("Retry", action: retry)
        }
        .padding(SpotiglassDesign.spacingL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

private struct ErrorStateView: View {
    let error: BrowsingDisplayError
    let retry: () -> Void
    @State private var isShowingDiagnosticAlert = false

    var body: some View {
        VStack(spacing: SpotiglassDesign.spacingM) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(error.title)
                .font(.title3.weight(.semibold))

            Text(error.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if error.canRetry {
                Button("Retry", action: retry)
            }
        }
        .padding(SpotiglassDesign.spacingL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .onAppear {
            isShowingDiagnosticAlert = error.diagnosticDetails != nil
        }
        .onChange(of: error.id) { _, _ in
            isShowingDiagnosticAlert = error.diagnosticDetails != nil
        }
        .alert(error.title, isPresented: $isShowingDiagnosticAlert) {
            if let diagnosticDetails = error.diagnosticDetails {
                Button("Copy Error") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnosticDetails, forType: .string)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(error.diagnosticDetails ?? error.message)
        }
    }
}

private struct StaleCacheBanner: View {
    let error: BrowsingDisplayError?

    var body: some View {
        Text(error?.message ?? "Showing cached data while Spotify refreshes.")
            .font(.caption)
            .padding(SpotiglassDesign.spacingS)
            .background(.background, in: Capsule())
            .padding(SpotiglassDesign.spacingM)
    }
}

#Preview {
    PlaylistBrowserView(
        viewModel: PlaylistBrowserViewModel(
            api: PreviewBrowsingAPI(),
            cache: PreviewBrowsingCache()
        ),
        playbackTokenProvider: PreviewPlaybackTokenProvider(),
        searchTokenProvider: PreviewPlaybackTokenProvider(),
        commandPaletteManager: CommandPaletteManager(),
        signOut: {}
    )
}

private struct PreviewBrowsingAPI: SpotifyBrowsingAPI {
    func currentUserProfile() async throws -> SpotifyUserProfile {
        SpotifyUserProfile(id: "preview", displayName: nil, imageURL: nil, country: "US", product: .premium)
    }

    func artist(id: String) async throws -> SpotifyArtistDetail {
        throw SpotifyAPIError.invalidRequest("Preview does not load artists.")
    }

    func artistTopTracks(id: String, market: String?) async throws -> [SpotifyTrack] {
        []
    }

    func search(query: String, limit: Int) async throws -> SpotifySearchResults {
        SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
    }

    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [SpotifyTrack] {
        []
    }

    func artistAlbums(id: String, includeGroups: String, limit: Int) async throws -> [SpotifyArtistAlbum] {
        []
    }

    func currentUserPlaylists(limit: Int) async throws -> [SpotifyPlaylistSummary] {
        [
            SpotifyPlaylistSummary(id: "playlist", name: "Preview Playlist", description: nil, ownerName: "Isaac", imageURL: nil, trackCount: 2, isPublic: nil, isCollaborative: false, snapshotID: "snapshot")
        ]
    }

    func playlistTracks(playlistID: String, limit: Int) async throws -> [SpotifyPlaylistTrackItem] {
        [
            SpotifyPlaylistTrackItem(id: "track", addedAt: nil, content: .track(SpotifyTrack(id: "track", name: "Preview Track", artists: ["Artist"], albumArtworkURL: nil, durationMilliseconds: 181_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:track")))
        ]
    }
}

private struct PreviewBrowsingCache: SpotifyBrowsingCache {
    func loadPlaylists(now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistSummary]? { nil }
    func loadPlaylistsBundle(now: Date) throws -> (playlists: [SpotifyPlaylistSummary], age: TimeInterval)? { nil }
    func savePlaylists(_ playlists: [SpotifyPlaylistSummary], cachedAt: Date) throws {}
    func loadTracks(playlistID: String, snapshotID: String, now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistTrackItem]? { nil }
    func saveTracks(_ tracks: [SpotifyPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws {}
    func invalidateTracks(playlistID: String) throws {}
}

@MainActor
private final class PreviewPlaybackTokenProvider: PlaybackAccessTokenProviding {
    func playbackAccessToken() async throws -> String { "preview-token" }
    func refreshedPlaybackAccessToken() async throws -> String { "preview-token" }
}

extension PreviewPlaybackTokenProvider: SpotifyAccessTokenProviding {
    func accessToken() async throws -> String { "preview-token" }
    func refreshAccessTokenAfterUnauthorized() async throws -> String { "preview-token" }
}
