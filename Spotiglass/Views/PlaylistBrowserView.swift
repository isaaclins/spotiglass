import AppKit
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

/// Holds the latest measured browser width without `@State` updates so resize drags do not thrash SwiftUI.
private final class BrowserWidthSampler {
    var latestWidth: CGFloat = 2000
}

/// Which column owns ⌘R / toolbar refresh when the queue panel is visible.
private enum UnifiedRefreshFocus: Hashable {
    case mainContent
    case queuePanel
}

/// Identifies which side panel a user just opened so the narrow-window mutual-exclusion rule
/// can keep the most-recently-opened side and close the other.
private enum SidebarKind {
    case playlist
    case queue
}

private enum LibrarySidebarRow: Equatable, Identifiable {
    case home
    case likedSongs
    case pinned(PinnedItem)

    var id: String {
        switch self {
        case .home:
            return LibrarySidebarOrder.homeToken
        case .likedSongs:
            return LibrarySidebarOrder.likedSongsToken
        case let .pinned(item):
            return LibrarySidebarOrder.pinnedToken(for: item.id)
        }
    }
}

struct PlaylistBrowserView: View {
    @StateObject private var viewModel: PlaylistBrowserViewModel
    @StateObject private var playbackViewModel: PlaybackSessionViewModel
    @StateObject private var queueViewModel: QueueViewModel
    @StateObject private var lyricsViewModel = ImmersiveLyricsViewModel()
    @EnvironmentObject private var pinnedStore: PinnedItemsStore
    @EnvironmentObject private var lyricsOverlay: LyricsOverlayController
    @AppStorage("queue.panel.visible") private var isQueueVisible = false
    /// Best-effort scroll anchor when the playlist `List` is torn down for lyrics (playback URI match, else last row `onAppear`).
    @State private var detailLastVisibleTrackID: String?
    /// When lyrics opens we snapshot here; when the playlist list remounts, `ScrollViewReader` scrolls to this id then clears it.
    @State private var pendingPlaylistListScrollRestoreID: String?
    /// Drives only the **playlist** sidebar (leading column). Queue visibility is separate — see `detailWithQueueSplit` below.
    @State private var playlistColumnVisibility: NavigationSplitViewVisibility = .doubleColumn
    /// Drives the narrow-window mutual-exclusion rule: when this drops below
    /// ``SpotiglassDesign/dualSidebarComfortableMinWidth`` the playlist sidebar and queue panel can no
    /// longer coexist (opening one closes the other; resizing wide→narrow auto-closes the LRU one).
    @State private var browserContentWidth: CGFloat = 2000
    @State private var browserWidthSampler = BrowserWidthSampler()
    @State private var lastBrowserWidthCommitTime: CFAbsoluteTime = 0
    /// Cached previous selection so pinned-track activations can revert the
    /// list highlight to whatever was selected before the click.
    @State private var lastNonPinnedSelection: SidebarSelection?
    @State private var libraryRowOrder: [String] = [
        LibrarySidebarOrder.homeToken,
        LibrarySidebarOrder.likedSongsToken
    ]
    @State private var libraryDropInsertionIndex: Int?
    @State private var libraryRowFramesByToken: [String: CGRect] = [:]
    @ObservedObject private var dragPreviewState = PinnedDragPreviewState.shared
    @State private var unifiedRefreshFocus: UnifiedRefreshFocus = .mainContent
    /// Which side the user most recently OPENED (closed → open transition). Used to pick the loser
    /// when the window shrinks below ``SpotiglassDesign/dualSidebarComfortableMinWidth`` with both
    /// sides still visible. Defaults to `.playlist` so the first narrow-resize tiebreaker closes the
    /// queue panel (the explicitly opt-in overlay) and keeps the primary nav sidebar.
    @State private var lastOpenedSidebar: SidebarKind = .playlist
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
        spotifySearchClient = SpotifyAPIClient(tokenProvider: searchTokenProvider, getResponseCache: .shared)
        self.commander = commander
        self.playbackCoordinator = playbackCoordinator
        self.signOut = signOut
    }

    private var isLyricsPresentedBinding: Binding<Bool> {
        Binding(
            get: { lyricsOverlay.isPresented },
            set: { newValue in
                if newValue, !lyricsOverlay.isPresented {
                    pendingPlaylistListScrollRestoreID = anchorTrackIDForPlaylistListScrollRestore()
                }
                lyricsOverlay.isPresented = newValue
            }
        )
    }

    /// Prefer the visible playlist row that matches the current Spotify URI; otherwise last `TrackListRow.onAppear` id.
    private func anchorTrackIDForPlaylistListScrollRestore() -> String? {
        guard let content = viewModel.detailState.currentValue else { return detailLastVisibleTrackID }
        switch content {
        case let .playlist(detail):
            if let uri = currentPlaybackURI,
               let row = detail.tracks.first(where: { $0.playableURI == uri }) {
                return row.id
            }
        case let .artist(detail):
            if let uri = currentPlaybackURI,
               let row = detail.tracks.first(where: { $0.playableURI == uri }) {
                return row.id
            }
        }
        return detailLastVisibleTrackID
    }

    /// Now playing track used to prefetch LRCLIB lyrics before the lyrics overlay opens (only while transport is playing).
    private var lyricsPrefetchTrack: PlaybackNowPlaying? {
        switch playbackViewModel.connectionState {
        case let .playing(np):
            return np
        case .paused, .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            return nil
        }
    }

    /// Stable while the current item is under halfway; becomes non-nil once past 50% so a `.task(id:)` can preload the next track’s lyrics once.
    private var lyricsHalfwayNextPreloadTaskKey: String? {
        guard let np = lyricsPrefetchTrack,
              np.durationMilliseconds > 0,
              np.spotifyTrackIDForLyrics != nil
        else { return nil }
        guard np.positionMilliseconds * 2 >= np.durationMilliseconds else { return nil }
        let nextURI = queueViewModel.upcomingItems.first?.uri ?? ""
        return "\(np.uri ?? "")|\(nextURI)"
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $playlistColumnVisibility) {
                playlistSidebar
                    .background(.background)
                    .toolbar(removing: lyricsOverlay.isPresented ? .sidebarToggle : nil)
                    .navigationSplitViewColumnWidth(
                        min: SpotiglassDesign.playlistSidebarMinWidth,
                        ideal: SpotiglassDesign.sidebarWidth
                    )
            } detail: {
                detailWithQueueSplit
            }
            PlaybackControlsView(
                viewModel: playbackViewModel,
                isLyricsPresented: isLyricsPresentedBinding,
                openArtist: { target in
                    openArtistFromTapTarget(target)
                }
            )
        }
        .animation(.easeOut(duration: 0.22), value: lyricsOverlay.isPresented)
        .animation(.easeOut(duration: 0.2), value: viewModel.canNavigateBack)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { _, newWidth in
            commitBrowserContentWidthIfNeeded(newWidth)
        }
        .task(id: lyricsPrefetchTrack?.uri) {
            guard let track = lyricsPrefetchTrack, track.spotifyTrackIDForLyrics != nil else { return }
            await Task(priority: .userInitiated) {
                await lyricsViewModel.preload(track: track)
            }.value
        }
        .task(id: lyricsHalfwayNextPreloadTaskKey) {
            guard lyricsHalfwayNextPreloadTaskKey != nil,
                  let current = lyricsPrefetchTrack,
                  current.durationMilliseconds > 0,
                  current.spotifyTrackIDForLyrics != nil,
                  current.positionMilliseconds * 2 >= current.durationMilliseconds
            else { return }
            await Task(priority: .userInitiated) {
                await queueViewModel.prefetchQueueForLyricsOverlay()
                guard let nextPlayback = queueViewModel.upcomingItems.first?.playbackNowPlayingForLyricsPrefetch(),
                      let nextID = nextPlayback.spotifyTrackIDForLyrics
                else { return }
                guard nextID != current.spotifyTrackIDForLyrics else { return }
                await lyricsViewModel.preload(track: nextPlayback)
            }.value
        }
        .background(.background)
        .background {
            HiddenPlaybackWebView(commander: commander, coordinator: playbackCoordinator)
                .frame(width: 1, height: 1)
                .opacity(0.01)
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                NavigationToolbarChrome(viewModel: viewModel)
            }
            if lyricsOverlay.isPresented {
                ToolbarItemGroup(placement: .automatic) {
                    Button {
                        lyricsOverlay.dismiss()
                    } label: {
                        Label("Close lyrics", systemImage: "xmark.circle")
                    }
                    .accessibilityHint("Closes the immersive lyrics overlay.")
                }
                ToolbarItem(placement: .primaryAction) {
                    unifiedRefreshToolbarButton
                }
            } else {
                ToolbarItemGroup(placement: .automatic) {
                    Button {
                        isQueueVisible.toggle()
                    } label: {
                        Label("Queue", systemImage: "list.bullet.indent")
                    }
                    .accessibilityHint("Shows or hides the playback queue.")

                    Button {
                        signOut()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                    .accessibilityHint("Disconnects Spotify and returns to the sign-in screen.")
                }
                ToolbarItem(placement: .primaryAction) {
                    unifiedRefreshToolbarButton
                }
            }
        }
        .task {
            await viewModel.loadIfNeeded()
        }
        .task {
            playbackViewModel.start(recoveryCause: .startupTask)
        }
        .task {
            await bindPinnedStoreToCurrentUser()
        }
        .onAppear {
            unifiedRefreshFocus = .mainContent
            syncUnifiedRefreshRoutingToViewModel()
            lyricsOverlay.attach(
                playback: playbackViewModel,
                queue: queueViewModel,
                lyrics: lyricsViewModel,
                navigateToArtist: { target in
                    lyricsOverlay.dismiss()
                    openArtistFromTapTarget(target, origin: .reset)
                },
                navigateToAlbum: { album, artistSubtitle, artworkURL in
                    lyricsOverlay.dismiss()
                    openAlbumFromTapTarget(album, artistSubtitle: artistSubtitle, artworkURL: artworkURL, origin: .reset)
                }
            )
            bindCommandPalette(queueVisible: $isQueueVisible, lyricsPresented: isLyricsPresentedBinding)
            commandPaletteManager.dismissLyricsOverlayIfPresented = { [lyricsOverlay] in
                guard lyricsOverlay.isPresented else { return false }
                lyricsOverlay.dismiss()
                return true
            }
            queueViewModel.setAppActive(NSApplication.shared.isActive)
            queueViewModel.setPanelVisible(isQueueVisible)
            NotificationCenter.default.post(name: .spotiglassPlaybackSurfaceAppeared, object: nil)
        }
        .onDisappear {
            commandPaletteManager.dismissLyricsOverlayIfPresented = nil
            lyricsOverlay.detach()
        }
        .onChange(of: viewModel.sidebarSelection) { _, _ in
            bindCommandPalette(queueVisible: $isQueueVisible, lyricsPresented: isLyricsPresentedBinding)
        }
        .onChange(of: viewModel.detailState) { _, _ in
            bindCommandPalette(queueVisible: $isQueueVisible, lyricsPresented: isLyricsPresentedBinding)
        }
        .onChange(of: pinnedStore.items) { _, _ in
            syncLibraryRowOrder()
            bindCommandPalette(queueVisible: $isQueueVisible, lyricsPresented: isLyricsPresentedBinding)
        }
        .onChange(of: isQueueVisible) { _, visible in
            queueViewModel.setPanelVisible(visible)
            browserContentWidth = browserWidthSampler.latestWidth
            lastBrowserWidthCommitTime = CFAbsoluteTimeGetCurrent()
            if !visible {
                unifiedRefreshFocus = .mainContent
            }
            syncUnifiedRefreshRoutingToViewModel()

            if visible {
                lastOpenedSidebar = .queue
                if isMutualExclusionWidth, playlistColumnVisibility != .detailOnly {
                    playlistColumnVisibility = .detailOnly
                }
            }
        }
        .onChange(of: playlistColumnVisibility) { _, newValue in
            if newValue != .detailOnly {
                lastOpenedSidebar = .playlist
                if isMutualExclusionWidth, isQueueVisible {
                    isQueueVisible = false
                }
            }
        }
        .onChange(of: unifiedRefreshFocus) { _, _ in
            syncUnifiedRefreshRoutingToViewModel()
        }
        .onChange(of: lyricsOverlay.isPresented) { _, _ in
            syncUnifiedRefreshRoutingToViewModel()
        }
        .onChange(of: playbackViewModel.sdkNextTracks) { _, _ in
            queueViewModel.handleSdkQueueSnapshotChanged()
        }
        .onChange(of: playbackViewModel.repeatMode) { _, _ in
            queueViewModel.syncFromPlaybackSession()
        }
        .onChange(of: queueRelevantPlaybackKey) { _, _ in
            queueViewModel.handlePlaybackStateChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            queueViewModel.setAppActive(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            queueViewModel.setAppActive(false)
        }
    }

    private var unifiedRefreshToolbarButton: some View {
        Button {
            Task { await performUnifiedToolbarRefresh() }
        } label: {
            refreshToolbarLabelIconAndText
        }
        .buttonStyle(.borderless)
        .disabled(isUnifiedRefreshBusy)
        .accessibilityHint(
            "Reloads the sidebar library, the open playlist or artist, or the queue when the queue panel is focused. Shortcut: ⌘R."
        )
    }

    /// Icon + “Refresh” label; horizontal padding keeps the borderless primary-action item clear of the toolbar edge.
    private var refreshToolbarLabelIconAndText: some View {
        refreshToolbarLabelCore
            .padding(.horizontal, SpotiglassDesign.spacingM)
    }

    private var refreshToolbarLabelCore: some View {
        HStack(spacing: SpotiglassDesign.spacingXS) {
            Group {
                if isUnifiedRefreshBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.body.weight(.medium))
                }
            }
            .frame(width: 16, height: 16)
            Text("Refresh")
        }
    }

    private var isUnifiedRefreshBusy: Bool {
        if lyricsOverlay.isPresented {
            return isPlaylistOrDetailRefreshing
        }
        if isQueueVisible, unifiedRefreshFocus == .queuePanel {
            return viewModel.isUnifiedQueueRefreshActive
        }
        return isPlaylistOrDetailRefreshing
    }

    private var isPlaylistOrDetailRefreshing: Bool {
        if case .refreshing = viewModel.playlistState { return true }
        if case .refreshing = viewModel.detailState { return true }
        return false
    }

    private func syncUnifiedRefreshRoutingToViewModel() {
        viewModel.refreshRoutingLyricsPresented = lyricsOverlay.isPresented
        viewModel.refreshRoutingQueuePanelVisible = isQueueVisible
        viewModel.refreshRoutingQueuePanelFocused = unifiedRefreshFocus == .queuePanel
    }

    private func performUnifiedToolbarRefresh() async {
        syncUnifiedRefreshRoutingToViewModel()
        await viewModel.performUnifiedRefresh { await queueViewModel.refreshQueue() }
    }

    /// True when the window is narrow enough that the playlist sidebar and queue panel must be
    /// mutually exclusive (opening one closes the other) so neither side ever clips off-screen.
    private var isMutualExclusionWidth: Bool {
        Self.mutualExclusionWidth(for: browserContentWidth)
    }

    private static func mutualExclusionWidth(for width: CGFloat) -> Bool {
        width < SpotiglassDesign.dualSidebarComfortableMinWidth
    }

    /// Coalesces high-frequency geometry callbacks during window resize so `NavigationSplitView` column constraints are not rewritten every frame.
    /// When the threshold is crossed wide→narrow with both sides open, also auto-closes the LRU side.
    private func commitBrowserContentWidthIfNeeded(_ newWidth: CGFloat) {
        browserWidthSampler.latestWidth = newWidth
        let now = CFAbsoluteTimeGetCurrent()
        let narrowNew = Self.mutualExclusionWidth(for: newWidth)
        let narrowCommitted = Self.mutualExclusionWidth(for: browserContentWidth)
        let crossedMeaningfulBreakpoint = narrowNew != narrowCommitted
        let throttleElapsed = now - lastBrowserWidthCommitTime >= 0.06
        let largeDrift = abs(newWidth - browserContentWidth) > 120
        guard crossedMeaningfulBreakpoint || throttleElapsed || largeDrift else {
            return
        }
        lastBrowserWidthCommitTime = now
        browserContentWidth = newWidth

        if narrowNew, !narrowCommitted,
           isQueueVisible, playlistColumnVisibility != .detailOnly {
            if lastOpenedSidebar == .queue {
                playlistColumnVisibility = .detailOnly
            } else {
                isQueueVisible = false
            }
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

    private var likedSongsStubRow: PlaylistRowViewModel {
        PlaylistRowViewModel(likedSongsOwnerDisplay: "You", totalTrackCount: nil, artworkURL: nil)
    }

    private var visiblePinnedLibraryItems: [PinnedItem] {
        pinnedStore.items.filter { $0.id != PinnedItem.likedSongsID }
    }

    private var libraryRows: [LibrarySidebarRow] {
        let pinnedByToken = Dictionary(uniqueKeysWithValues: visiblePinnedLibraryItems.map {
            (LibrarySidebarOrder.pinnedToken(for: $0.id), $0)
        })
        return libraryRowOrder.compactMap { token in
            switch token {
            case LibrarySidebarOrder.homeToken:
                return .home
            case LibrarySidebarOrder.likedSongsToken:
                return .likedSongs
            default:
                guard let item = pinnedByToken[token] else { return nil }
                return .pinned(item)
            }
        }
    }

    private var playlistSidebar: some View {
        ScrollViewReader { proxy in
            List(selection: $viewModel.sidebarSelection) {
                Section {
                    libraryLeadingDropSlot
                    ForEach(Array(libraryRows.enumerated()), id: \.element.id) { index, row in
                        libraryRowSlot(row, at: index)
                    }
                    libraryTrailingDropSlot
                } header: {
                    Text("Library")
                }
                Section {
                    Group {
                        playlistsSectionContent
                    }
                    .acceptsPinnedDropOut(store: pinnedStore)
                } header: {
                    playlistsSectionHeader
                }
            }
            .onChange(of: viewModel.sidebarSelection) { oldValue, newValue in
                handleSidebarSelectionChange(oldValue: oldValue, newValue: newValue)
            }
            .onChange(of: playbackViewModel.activePlaylistID) { _, newActiveID in
                guard let newActiveID else { return }
                proxy.scrollTo(newActiveID, anchor: .center)
            }
            .onAppear {
                syncLibraryRowOrder()
            }
            .onPreferenceChange(LibraryRowFramePreferenceKey.self) { libraryRowFramesByToken = $0 }
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
            .tint(SpotiglassDesign.controlAccent)
            .coordinateSpace(name: "libraryDropArea")
        }
    }

    @ViewBuilder
    private func libraryRowSlot(_ row: LibrarySidebarRow, at index: Int) -> some View {
        let rowSelection = sidebarSelectionTag(for: row)
        VStack(spacing: 0) {
            if libraryDropInsertionIndex == index {
                PinnedDropSkeletonRow(item: dragPreviewState.activeItem)
            }
            switch row {
            case .home:
                homeSidebarRow
            case .likedSongs:
                likedSongsSidebarRow
            case let .pinned(item):
                pinnedLibraryRow(item)
            }
        }
        .tag(rowSelection)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.sidebarSelection = rowSelection
        }
        .onDrop(
            of: LibraryPinnedItemDropDelegate.acceptedTypeIdentifiers,
            delegate: LibraryPinnedItemDropDelegate(
                updateInsertionIndex: { location in
                    libraryDropInsertionIndex = nearestLibraryInsertionIndex(forY: location.y)
                },
                clearInsertionIndex: {
                    libraryDropInsertionIndex = nil
                },
                performPinnedDrop: { transfer, location in
                    let targetIndex = nearestLibraryInsertionIndex(forY: location.y)
                    return handlePinnedTransferDrop([transfer], at: targetIndex)
                },
                performLibraryRowDrop: { transfer, location in
                    let targetIndex = nearestLibraryInsertionIndex(forY: location.y)
                    return handleLibraryTransferDrop([transfer], at: targetIndex)
                },
                clearDragPreview: {
                    dragPreviewState.endDrag()
                }
            )
        )
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: LibraryRowFramePreferenceKey.self,
                    value: [row.id: geo.frame(in: .named("libraryDropArea"))]
                )
            }
        }
    }

    private func sidebarSelectionTag(for row: LibrarySidebarRow) -> SidebarSelection {
        switch row {
        case .home:
            return .home
        case .likedSongs:
            return .likedSongs
        case let .pinned(item):
            return .pinnedItem(item.id)
        }
    }

    private var libraryLeadingDropSlot: some View {
        Color.clear
            .frame(height: 8)
            .contentShape(Rectangle())
            .onDrop(
                of: LibraryPinnedItemDropDelegate.acceptedTypeIdentifiers,
                delegate: LibraryPinnedItemDropDelegate(
                    updateInsertionIndex: { _ in
                        libraryDropInsertionIndex = 0
                    },
                    clearInsertionIndex: {
                        if libraryDropInsertionIndex == 0 {
                            libraryDropInsertionIndex = nil
                        }
                    },
                    performPinnedDrop: { transfer, _ in
                        return handlePinnedTransferDrop([transfer], at: 0)
                    },
                    performLibraryRowDrop: { transfer, _ in
                        return handleLibraryTransferDrop([transfer], at: 0)
                    },
                    clearDragPreview: {
                        dragPreviewState.endDrag()
                    }
                )
            )
            .listRowInsets(EdgeInsets())
    }

    private var libraryTrailingDropSlot: some View {
        VStack(spacing: 0) {
            if libraryDropInsertionIndex == libraryRows.count {
                PinnedDropSkeletonRow(item: dragPreviewState.activeItem)
            }
            Color.clear
                .frame(height: 12)
        }
        .contentShape(Rectangle())
        .onDrop(
            of: LibraryPinnedItemDropDelegate.acceptedTypeIdentifiers,
            delegate: LibraryPinnedItemDropDelegate(
                updateInsertionIndex: { location in
                    libraryDropInsertionIndex = nearestLibraryInsertionIndex(forY: location.y)
                },
                clearInsertionIndex: {
                    libraryDropInsertionIndex = nil
                },
                performPinnedDrop: { transfer, location in
                    let targetIndex = nearestLibraryInsertionIndex(forY: location.y)
                    return handlePinnedTransferDrop([transfer], at: targetIndex)
                },
                performLibraryRowDrop: { transfer, location in
                    let targetIndex = nearestLibraryInsertionIndex(forY: location.y)
                    return handleLibraryTransferDrop([transfer], at: targetIndex)
                },
                clearDragPreview: {
                    dragPreviewState.endDrag()
                }
            )
        )
        .listRowInsets(EdgeInsets())
    }

    private func nearestLibraryInsertionIndex(forY y: CGFloat) -> Int {
        guard !libraryRows.isEmpty else { return 0 }
        let framesInOrder = libraryRows.compactMap { libraryRowFramesByToken[$0.id] }
        guard !framesInOrder.isEmpty else { return 0 }
        for (index, frame) in framesInOrder.enumerated() {
            if y < frame.midY {
                return index
            }
        }
        return framesInOrder.count
    }

    private var homeSidebarRow: some View {
        Label("Home", systemImage: "house")
            .onDrag({
                LibrarySidebarRowTransfer(rowToken: LibrarySidebarOrder.homeToken).itemProvider()
            })
    }

    @ViewBuilder
    private var likedSongsSidebarRow: some View {
        PlaylistListRow(
            playlist: likedSongsStubRow,
            isActive: playbackViewModel.activePlaylistID == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID,
            isPlaying: isCurrentlyPlaying,
            isListSelected: viewModel.sidebarSelection == .likedSongs,
            isPinned: false
        )
        .id(SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID)
        .onDrag({
            LibrarySidebarRowTransfer(rowToken: LibrarySidebarOrder.likedSongsToken).itemProvider()
        })
    }

    @ViewBuilder
    private func pinnedLibraryRow(_ item: PinnedItem) -> some View {
        PinnedRowView(
            item: item,
            isSelected: viewModel.sidebarSelection == .pinnedItem(item.id),
            onUnpin: { pinnedStore.unpin(id: item.id) }
        )
        .onDrag(
            {
                PinnedItemTransfer(
                    item: item,
                    originScopeID: PinnedItemTransfer.pinnedSidebarScopeID
                ).itemProvider()
            },
            preview: {
                PinnedItemDragPill(item: item)
            }
        )
        .contextMenu {
            Button("Unpin") { pinnedStore.unpin(id: item.id) }
        }
    }

    private func syncLibraryRowOrder() {
        if pinnedStore.isPinned(id: PinnedItem.likedSongsID) {
            pinnedStore.unpin(id: PinnedItem.likedSongsID)
        }
        libraryRowOrder = LibrarySidebarOrder.normalizedOrder(
            existing: libraryRowOrder,
            pinnedItemIDs: visiblePinnedLibraryItems.map(\.id)
        )
    }

    private func handleLibraryTransferDrop(_ transfers: [LibrarySidebarRowTransfer], at insertionIndex: Int) -> Bool {
        defer {
            libraryDropInsertionIndex = nil
            dragPreviewState.endDrag()
        }
        guard let transfer = transfers.first else { return false }
        let moved = LibrarySidebarOrder.moved(
            order: libraryRowOrder,
            movingToken: transfer.rowToken,
            toInsertionIndex: insertionIndex
        )
        guard moved != libraryRowOrder else { return false }
        libraryRowOrder = moved
        return true
    }

    private func handlePinnedTransferDrop(_ transfers: [PinnedItemTransfer], at insertionIndex: Int) -> Bool {
        defer {
            libraryDropInsertionIndex = nil
            dragPreviewState.endDrag()
        }
        guard let transfer = transfers.first else { return false }
        let sourceToken = LibrarySidebarOrder.pinnedToken(for: transfer.item.id)
        let targetPinnedIndex = LibrarySidebarOrder.pinnedInsertionIndex(
            order: libraryRowOrder,
            movingPinnedToken: transfer.isFromPinnedSidebar ? sourceToken : nil,
            toInsertionIndex: insertionIndex
        )

        if transfer.isFromPinnedSidebar {
            let movedRows = LibrarySidebarOrder.moved(
                order: libraryRowOrder,
                movingToken: sourceToken,
                toInsertionIndex: insertionIndex
            )
            guard movedRows != libraryRowOrder else { return false }
            pinnedStore.reorder(itemID: transfer.item.id, toInsertionIndex: targetPinnedIndex)
            libraryRowOrder = movedRows
        } else {
            guard pinnedStore.pin(transfer.item, at: targetPinnedIndex) else { return false }
            syncLibraryRowOrder()
        }
        return true
    }

    private func handleSidebarSelectionChange(oldValue: SidebarSelection?, newValue: SidebarSelection?) {
        guard oldValue != newValue else { return }
        if case let .pinnedItem(id) = newValue, let item = pinnedStore.items.first(where: { $0.id == id }) {
            Task { await activatePinnedItem(item, previousSelection: oldValue) }
            return
        }
        // Track the last non-pinned selection so pinned-track clicks can
        // restore it cleanly.
        if case .pinnedItem = newValue {
            // Item not found (stale); fall through.
        } else {
            lastNonPinnedSelection = newValue
        }
        Task { await viewModel.selectSidebar(newValue) }
    }

    @MainActor
    private func activatePinnedItem(_ item: PinnedItem, previousSelection: SidebarSelection?) async {
        if item.isStale {
            // Surface a notice but keep the row pinned; nothing to load.
            viewModel.sidebarSelection = previousSelection ?? lastNonPinnedSelection
            return
        }
        switch item.kind {
        case .playlist:
            guard let spotifyID = item.spotifyID else { return }
            if viewModel.sidebarSelection == .playlist(spotifyID) {
                return
            }
            // Defer to the playlist loader by switching the sidebar selection.
            // Wait one tick so the binding is stable before the new onChange fires.
            viewModel.sidebarSelection = .playlist(spotifyID)
        case .artist:
            guard let spotifyID = item.spotifyID else { return }
            await viewModel.selectArtist(id: spotifyID, origin: .reset, displayName: item.title)
            viewModel.sidebarSelection = .pinnedItem(item.id)
        case .album:
            guard let spotifyID = item.spotifyID else { return }
            await viewModel.selectAlbum(
                id: spotifyID,
                displayTitle: item.title,
                displaySubtitle: item.subtitle,
                artworkURL: item.artworkURL,
                origin: .reset
            )
            viewModel.sidebarSelection = .pinnedItem(item.id)
        case .likedSongs:
            viewModel.sidebarSelection = .likedSongs
        case .track:
            if let uri = item.spotifyURI {
                await playbackViewModel.play(uri: uri)
            }
            viewModel.sidebarSelection = previousSelection ?? lastNonPinnedSelection
        }
    }

    private var playlistsSectionHeader: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            Text("Playlists")
                .font(.title3.weight(.semibold))
            switch viewModel.playlistState {
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
    }

    @ViewBuilder
    private var playlistsSectionContent: some View {
        switch viewModel.playlistState {
        case .loading:
            ProgressView("Loading playlists...")
        case let .loaded(playlists), let .refreshing(playlists), let .staleCache(playlists, _):
            ForEach(playlists) { playlist in
                playlistSidebarRow(playlist: playlist)
            }
        case let .empty(message):
            EmptyStateView(title: "No playlists", message: message)
        case let .error(error):
            ErrorStateView(error: error)
        }
    }

    @ViewBuilder
    private func playlistSidebarRow(playlist: PlaylistRowViewModel) -> some View {
        let pinned = pinnedStore.isPinned(spotifyID: playlist.id, kind: .playlist)
        let summary = playlistSummaryFromRow(playlist)
        PlaylistListRow(
            playlist: playlist,
            isActive: playlist.id == playbackViewModel.activePlaylistID,
            isPlaying: isCurrentlyPlaying,
            isListSelected: viewModel.sidebarSelection == .playlist(playlist.id),
            isPinned: pinned
        )
        .tag(SidebarSelection.playlist(playlist.id))
        .id(playlist.id)
        .onDrag(
            {
                PinnedItemTransfer(
                    item: .playlist(summary),
                    originScopeID: "sidebarPlaylists"
                ).itemProvider()
            },
            preview: {
                PinnedItemDragPill(item: .playlist(summary))
            }
        )
        .contextMenu {
            if pinned {
                Button("Unpin") {
                    pinnedStore.unpin(id: PinnedItem.id(forKind: .playlist, spotifyID: playlist.id))
                }
            } else {
                Button("Pin to Sidebar") {
                    pinnedStore.pin(.playlist(summary))
                }
            }
        }
    }

    /// Reconstructs a lightweight ``SpotifyPlaylistSummary`` from the visible
    /// row view-model so the pinned-item snapshot is fully populated even
    /// when the underlying summary cache has aged out. Field defaults match
    /// what `PinnedRowView` actually displays.
    private func playlistSummaryFromRow(_ row: PlaylistRowViewModel) -> SpotifyPlaylistSummary {
        SpotifyPlaylistSummary(
            id: row.id,
            name: row.title,
            description: nil,
            ownerName: row.owner,
            imageURL: row.artworkURL,
            trackCount: 0,
            isPublic: nil,
            isCollaborative: false,
            snapshotID: row.snapshotID
        )
    }

    @ViewBuilder
    private var detailWithQueueSplit: some View {
        // Use `HStack` instead of `HSplitView` so the queue animates in from the **screen trailing**
        // edge. `HSplitView` drives NSSplitView divider motion from the leading pane, which reads as
        // “slides in from the left” even with `.move(edge: .trailing)` on the second column.
        HStack(spacing: 0) {
            playlistDetail
                .background(.background)
                .frame(minWidth: SpotiglassDesign.detailColumnMinWidth)
                .layoutPriority(1)
                .onHover { hovering in
                    if hovering { unifiedRefreshFocus = .mainContent }
                }
            if isQueueVisible {
                queuePanelColumn
                    .transition(
                        .asymmetric(
                            insertion: .offset(x: SpotiglassDesign.sidebarWidth).combined(with: .opacity),
                            removal: .offset(x: SpotiglassDesign.sidebarWidth).combined(with: .opacity)
                        )
                    )
                    .onHover { hovering in
                        if hovering { unifiedRefreshFocus = .queuePanel }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.38, dampingFraction: 0.84), value: isQueueVisible)
        .acceptsPinnedDropOut(store: pinnedStore)
    }

    @ViewBuilder
    private var queuePanelColumn: some View {
        QueuePanelView(
            queueViewModel: queueViewModel,
            playbackViewModel: playbackViewModel,
            openArtist: { target in
                openArtistFromTapTarget(target)
            }
        )
            .background(.background)
            .frame(
                minWidth: SpotiglassDesign.queuePanelMinWidth,
                idealWidth: SpotiglassDesign.sidebarWidth,
                maxWidth: SpotiglassDesign.queuePanelMaxWidth
            )
    }

    private var playlistDetail: some View {
        VStack(spacing: 0) {
            switch viewModel.detailState {
            case .loading:
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .loaded(content), let .refreshing(content), let .staleCache(content, _):
                Group {
                    if lyricsOverlay.isPresented {
                        // Tears down the heavy track `List` while lyrics cover the window (saves resize/layout work).
                        // Scroll is restored via `pendingPlaylistListScrollRestoreID` + `ScrollViewReader` when lyrics closes.
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityHidden(true)
                    } else {
                        switch content {
                        case let .playlist(detail):
                            PlaylistDetailContent(
                                detail: detail,
                                pendingScrollRestoreTrackID: $pendingPlaylistListScrollRestoreID,
                                onTrackEnteredViewportApproximation: { detailLastVisibleTrackID = $0 },
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
                                    Task { await viewModel.selectArtist(id: artistID, origin: .extend, displayName: nil) }
                                }
                            )
                        case let .artist(detail):
                            ArtistDetailContent(
                                detail: detail,
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
                                openAlbum: { album in
                                    Task {
                                        await viewModel.selectAlbum(
                                            id: album.id,
                                            displayTitle: album.title,
                                            displaySubtitle: detail.artist.name,
                                            artworkURL: album.artworkURL,
                                            origin: .extend
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
                                    Task { await viewModel.selectArtist(id: artistID, origin: .extend, displayName: nil) }
                                },
                                loadMoreAlbums: {
                                    Task { await viewModel.loadMoreArtistAlbums() }
                                }
                            )
                        }
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
                EmptyStateView(title: "No tracks", message: message)
            case let .error(error):
                ErrorStateView(error: error)
            }
        }
        .acceptsPinnedDropOut(store: pinnedStore)
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

    /// Resolves the signed-in Spotify user ID once (best-effort) and binds the
    /// pinned-items store to it so per-account pins load from disk and future
    /// mutations persist into the right file.
    private func bindPinnedStoreToCurrentUser() async {
        if pinnedStore.boundUserID != nil { return }
        let profile = try? await spotifySearchClient.currentUserProfile()
        pinnedStore.bind(userID: profile?.id)
    }

    private func openArtistFromTapTarget(_ target: ArtistTapTarget, origin: BrowserNavigationOrigin = .extend) {
        Task {
            if let id = target.id {
                await viewModel.selectArtist(id: id, origin: origin, displayName: target.name)
                return
            }
            guard let resolvedID = try? await resolveArtistID(forName: target.name) else { return }
            await viewModel.selectArtist(id: resolvedID, origin: origin, displayName: target.name)
        }
    }

    private func openAlbumFromTapTarget(
        _ album: AlbumTapTarget,
        artistSubtitle: String,
        artworkURL: URL?,
        origin: BrowserNavigationOrigin = .extend
    ) {
        Task {
            if let id = album.id {
                await viewModel.selectAlbum(
                    id: id,
                    displayTitle: album.name,
                    displaySubtitle: artistSubtitle,
                    artworkURL: artworkURL,
                    origin: origin
                )
                return
            }
            do {
                guard let resolvedID = try await resolveAlbumID(name: album.name, artistHint: artistSubtitle) else { return }
                await viewModel.selectAlbum(
                    id: resolvedID,
                    displayTitle: album.name,
                    displaySubtitle: artistSubtitle,
                    artworkURL: artworkURL,
                    origin: origin
                )
            } catch {
                return
            }
        }
    }

    private func resolveAlbumID(name: String, artistHint: String) async throws -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "")
        let firstArtist = artistHint.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let query: String
        if firstArtist.isEmpty {
            query = "album:\"\(escaped)\""
        } else {
            let artistEsc = firstArtist.replacingOccurrences(of: "\"", with: "")
            query = "album:\"\(escaped)\" artist:\"\(artistEsc)\""
        }
        let results = try await spotifySearchClient.search(query: query, limit: 10)
        guard !results.albums.isEmpty else { return nil }
        let normalizedQuery = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if let exact = results.albums.first(where: {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalizedQuery
        }) {
            return exact.id
        }
        return results.albums.first?.id
    }

    private func resolveArtistID(forName name: String) async throws -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "")
        let results = try await spotifySearchClient.search(query: "artist:\"\(escaped)\"", limit: 5)
        guard !results.artists.isEmpty else { return nil }
        let normalizedQuery = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if let exact = results.artists.first(where: {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalizedQuery
        }) {
            return exact.id
        }
        return results.artists.first?.id
    }

    private func bindCommandPalette(queueVisible: Binding<Bool>, lyricsPresented: Binding<Bool>) {
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

        func paletteOriginPlaylistID() -> String? {
            guard let sel = viewModel?.sidebarSelection else { return nil }
            switch sel {
            case let .playlist(id):
                return id
            case .likedSongs:
                return nil
            case .home, .pinnedItem:
                return nil
            }
        }

        func inPlaylistMatches(from rows: [TrackRowViewModel]) -> [CommandPaletteItem] {
            guard !trimmed.isEmpty else { return [] }
            let originPID = paletteOriginPlaylistID()
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
                let pinPayload = row.pinnedTrackItem(originPlaylistID: originPID)
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
            let originPID = paletteOriginPlaylistID()
            let pinPayload = PinnedItem.track(track, originPlaylistID: originPID)
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
                    description: nil,
                    ownerName: row.owner,
                    imageURL: row.artworkURL,
                    trackCount: 0,
                    isPublic: nil,
                    isCollaborative: false,
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

private struct PlaylistListRow: View {
    let playlist: PlaylistRowViewModel
    var isActive: Bool = false
    var isPlaying: Bool = false
    /// Sidebar list row is the current `List` selection (drives heart vs heart.fill for Liked Songs).
    var isListSelected: Bool = false
    /// Source-side indicator: this row is also pinned in the pinned area.
    var isPinned: Bool = false

    private var isLikedSongsRow: Bool {
        playlist.id == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
    }

    private let artworkSize: CGFloat = 46

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Group {
                if isLikedSongsRow {
                    RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                        .fill(.secondary.opacity(0.16))
                        .frame(width: artworkSize, height: artworkSize)
                        .overlay {
                            Image(systemName: isListSelected ? "heart.fill" : "heart")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(isListSelected ? SpotiglassDesign.controlAccent : .secondary)
                                .symbolRenderingMode(.monochrome)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                        }
                } else {
                    ArtworkView(url: playlist.artworkURL, size: artworkSize)
                }
            }
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
            .overlay(alignment: .topTrailing) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .padding(2)
                        .accessibilityLabel("Pinned to sidebar")
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
        .accessibilityLabel("\(playlist.title), by \(playlist.owner), \(playlist.trackCountText)\(isActive ? ", now playing" : "")\(isPinned ? ", pinned" : "")")
    }
}

private struct PlaylistDetailContent: View {
    let detail: PlaylistDetailViewModel
    @Binding var pendingScrollRestoreTrackID: String?
    let onTrackEnteredViewportApproximation: (String) -> Void
    let playURI: (String) -> Void
    let currentPlaybackURI: String?
    let isPlaying: Bool
    let togglePlayPause: () -> Void
    let hasPlaybackDevice: Bool
    let addToQueue: (String) async -> Void
    let openArtist: (String) -> Void

    @EnvironmentObject private var pinnedStore: PinnedItemsStore

    private var tracksSurfaceKey: String { "pl:\(detail.playlist.id)" }

    private var originPlaylistIDForTracks: String? {
        detail.playlist.id == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID ? nil : detail.playlist.id
    }

    private var headerPinnedItem: PinnedItem {
        if detail.playlist.id == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID {
            .likedSongs(ownerDisplay: detail.playlist.owner, artworkURL: detail.playlist.artworkURL)
        } else {
            .playlist(
                SpotifyPlaylistSummary(
                    id: detail.playlist.id,
                    name: detail.playlist.title,
                    description: nil,
                    ownerName: detail.playlist.owner,
                    imageURL: detail.playlist.artworkURL,
                    trackCount: 0,
                    isPublic: nil,
                    isCollaborative: false,
                    snapshotID: detail.playlist.snapshotID
                )
            )
        }
    }

    private var isHeaderPinned: Bool {
        pinnedStore.isPinned(id: headerPinnedItem.id)
    }

    private var supportsHeaderPinning: Bool {
        detail.playlist.id != SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBlock

            Divider()

            if detail.tracks.isEmpty {
                EmptyStateView(title: "No tracks", message: "This playlist is empty.")
            } else {
                VirtualizedTrackList(
                    tracks: detail.tracks,
                    rowBuilder: { track in
                        TrackListRow(
                            trackNumber: track.listPosition,
                            track: track,
                            playURI: playURI,
                            togglePlayPause: togglePlayPause,
                            isCurrent: track.playableURI != nil && track.playableURI == currentPlaybackURI,
                            isPlaying: isPlaying,
                            hasPlaybackDevice: hasPlaybackDevice,
                            addToQueue: addToQueue,
                            openArtist: openArtist,
                            tracksSurfaceID: tracksSurfaceKey,
                            originPlaylistID: originPlaylistIDForTracks
                        )
                    },
                    pendingScrollRestoreTrackID: $pendingScrollRestoreTrackID,
                    onFirstVisibleTrackChanged: onTrackEnteredViewportApproximation
                )
                .acceptsPinnedDropOut(store: pinnedStore)
            }
        }
    }

    private var headerBlock: some View {
        HStack(alignment: .center, spacing: SpotiglassDesign.spacingL) {
            Group {
                if detail.playlist.id == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID {
                    RoundedRectangle(cornerRadius: SpotiglassDesign.cornerM, style: .continuous)
                        .fill(.secondary.opacity(0.16))
                        .frame(width: 104, height: 104)
                        .overlay {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundStyle(SpotiglassDesign.controlAccent)
                                .symbolRenderingMode(.monochrome)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: SpotiglassDesign.cornerM, style: .continuous)
                                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                        }
                        .overlay(alignment: .topTrailing) {
                            if isHeaderPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(5)
                                    .background(Circle().fill(Color.black.opacity(0.55)))
                                    .padding(4)
                            }
                        }
                } else {
                    ArtworkView(url: detail.playlist.artworkURL, size: 104)
                        .overlay(alignment: .topTrailing) {
                            if isHeaderPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(5)
                                    .background(Circle().fill(Color.black.opacity(0.55)))
                                    .padding(4)
                            }
                        }
                }
            }

            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
                Text(detail.playlist.title)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(2)

                Text("\(detail.playlist.owner) • \(detail.playlist.trackCountText)")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(SpotiglassDesign.spacingL)
        .modifier(LibraryHeaderPinningModifier(
            supportsHeaderPinning: supportsHeaderPinning,
            headerPinnedItem: headerPinnedItem,
            tracksSurfaceKey: tracksSurfaceKey,
            isHeaderPinned: isHeaderPinned,
            pinnedStore: pinnedStore
        ))
    }
}

private struct LibraryHeaderPinningModifier: ViewModifier {
    let supportsHeaderPinning: Bool
    let headerPinnedItem: PinnedItem
    let tracksSurfaceKey: String
    let isHeaderPinned: Bool
    let pinnedStore: PinnedItemsStore

    @ViewBuilder
    func body(content: Content) -> some View {
        if supportsHeaderPinning {
            content
                .onDrag(
                    {
                        PinnedItemTransfer(
                            item: headerPinnedItem,
                            originScopeID: tracksSurfaceKey
                        ).itemProvider()
                    },
                    preview: {
                        PinnedItemDragPill(item: headerPinnedItem)
                    }
                )
                .contextMenu {
                    if isHeaderPinned {
                        Button("Unpin from Sidebar") {
                            pinnedStore.unpin(id: headerPinnedItem.id)
                        }
                    } else {
                        Button("Pin to Sidebar") {
                            pinnedStore.pin(headerPinnedItem)
                        }
                    }
                }
        } else {
            content
        }
    }
}

private struct EmptyStateView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: SpotiglassDesign.spacingM) {
            Text(title)
                .font(.title3.weight(.semibold))

            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(SpotiglassDesign.spacingL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

private struct ErrorStateView: View {
    let error: BrowsingDisplayError
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

private struct LibraryPinnedItemDropDelegate: DropDelegate {
    static let acceptedTypeIdentifiers: [String] = [
        UTType.spotiglassPinnedItem.identifier,
        UTType.spotiglassLibrarySidebarRow.identifier,
        UTType.plainText.identifier,
        "public.utf8-plain-text",
        UTType.text.identifier
    ]

    let updateInsertionIndex: (CGPoint) -> Void
    let clearInsertionIndex: () -> Void
    let performPinnedDrop: (PinnedItemTransfer, CGPoint) -> Bool
    let performLibraryRowDrop: (LibrarySidebarRowTransfer, CGPoint) -> Bool
    let clearDragPreview: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        let hasPinned = !info.itemProviders(for: [UTType.spotiglassPinnedItem]).isEmpty
        let hasLibraryRow = !info.itemProviders(for: [UTType.spotiglassLibrarySidebarRow]).isEmpty
        let hasPlainText = !info.itemProviders(for: [UTType.plainText]).isEmpty
        let hasText = !info.itemProviders(for: [UTType.text]).isEmpty
        return hasPinned || hasLibraryRow || hasPlainText || hasText
    }

    func dropEntered(info: DropInfo) {
        updateInsertionIndex(info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateInsertionIndex(info.location)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        clearInsertionIndex()
    }

    func performDrop(info: DropInfo) -> Bool {
        let location = info.location
        clearInsertionIndex()
        if let provider = info.itemProviders(for: [UTType.spotiglassPinnedItem]).first {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.spotiglassPinnedItem.identifier) { data, _ in
                guard let data,
                      let transfer = try? JSONDecoder().decode(PinnedItemTransfer.self, from: data)
                else {
                    Task { @MainActor in clearDragPreview() }
                    return
                }
                Task { @MainActor in
                    if !performPinnedDrop(transfer, location) {
                        clearDragPreview()
                    }
                }
            }
            return true
        }
        if let provider = info.itemProviders(for: [UTType.spotiglassLibrarySidebarRow]).first {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.spotiglassLibrarySidebarRow.identifier) { data, _ in
                guard let data,
                      let transfer = try? JSONDecoder().decode(LibrarySidebarRowTransfer.self, from: data)
                else {
                    Task { @MainActor in clearDragPreview() }
                    return
                }
                Task { @MainActor in
                    if !performLibraryRowDrop(transfer, location) {
                        clearDragPreview()
                    }
                }
            }
            return true
        }
        if let provider = info.itemProviders(for: [UTType.plainText]).first {
            let candidates = [UTType.plainText.identifier, "public.utf8-plain-text", UTType.text.identifier]
            for typeIdentifier in candidates {
                if !provider.hasItemConformingToTypeIdentifier(typeIdentifier) { continue }
                provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                    guard let data else {
                        Task { @MainActor in clearDragPreview() }
                        return
                    }
                    if let transfer = try? JSONDecoder().decode(PinnedItemTransfer.self, from: data) {
                        Task { @MainActor in
                            if !performPinnedDrop(transfer, location) {
                                clearDragPreview()
                            }
                        }
                        return
                    }
                    if let transfer = try? JSONDecoder().decode(LibrarySidebarRowTransfer.self, from: data) {
                        Task { @MainActor in
                            if !performLibraryRowDrop(transfer, location) {
                                clearDragPreview()
                            }
                        }
                        return
                    }
                    Task { @MainActor in clearDragPreview() }
                }
                return true
            }
        }
        clearDragPreview()
        return false
    }
}

private struct LibraryRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String : CGRect], nextValue: () -> [String : CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct LibrarySidebarRowTransfer: Codable, Equatable, Hashable, Transferable {
    let rowToken: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .spotiglassLibrarySidebarRow)
    }

    /// macOS drag source provider used by `onDrop`/`DropDelegate` targets.
    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let encoded = (try? JSONEncoder().encode(self)) ?? Data()
        if let jsonString = String(data: encoded, encoding: .utf8) {
            provider.registerObject(jsonString as NSString, visibility: .all)
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.spotiglassLibrarySidebarRow.identifier,
            visibility: .all
        ) { completion in
            completion(encoded, nil)
            return nil
        }
        return provider
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
    .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
    .environmentObject(LyricsOverlayController())
}

private struct PreviewBrowsingAPI: SpotifyBrowsingAPI {
    func currentUserProfile() async throws -> SpotifyUserProfile {
        SpotifyUserProfile(id: "preview", displayName: nil, imageURL: nil, country: "US", product: .premium)
    }

    func artist(id: String) async throws -> SpotifyArtistDetail {
        throw SpotifyAPIError.invalidRequest("Preview does not load artists.")
    }

    func artist(id: String, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyArtistDetail {
        try await artist(id: id)
    }

    func artistCached(id: String, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyAPIClient.CachedResponse<SpotifyArtistDetail> {
        let value = try await artist(id: id)
        return SpotifyAPIClient.CachedResponse(value: value, isStale: false)
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

    func albums(ids: [String], market: String?) async throws -> [SpotifyBatchedAlbum] {
        []
    }

    func artistAlbums(id: String, includeGroups: String, limit: Int, cacheMode: SpotifyRequestCacheMode) async throws -> [SpotifyArtistAlbum] {
        []
    }

    func artistAlbumsCached(
        id: String,
        includeGroups: String,
        limit: Int,
        cacheMode: SpotifyRequestCacheMode
    ) async throws -> SpotifyAPIClient.CachedResponse<[SpotifyArtistAlbum]> {
        let albums = try await artistAlbums(id: id, includeGroups: includeGroups, limit: limit, cacheMode: cacheMode)
        return SpotifyAPIClient.CachedResponse(value: albums, isStale: false)
    }

    func artistAlbumsPage(
        id: String,
        includeGroups: String,
        limit: Int,
        offset: Int,
        nextURL: URL?,
        cacheMode: SpotifyRequestCacheMode
    ) async throws -> SpotifyAPIClient.SpotifyArtistAlbumsPage {
        SpotifyAPIClient.SpotifyArtistAlbumsPage(items: [], next: nil)
    }

    func currentUserPlaylists(limit: Int) async throws -> [SpotifyPlaylistSummary] {
        [
            SpotifyPlaylistSummary(id: "playlist", name: "Preview Playlist", description: nil, ownerName: "Isaac", imageURL: nil, trackCount: 2, isPublic: nil, isCollaborative: false, snapshotID: "snapshot")
        ]
    }

    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [SpotifyPlaylistTrackItem] {
        [
            SpotifyPlaylistTrackItem(id: "track", addedAt: nil, content: .track(SpotifyTrack(id: "track", name: "Preview Track", artists: ["Artist"], albumArtworkURL: nil, durationMilliseconds: 181_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:track")))
        ]
    }

    func currentUserSavedTracks(limit: Int, maxPages: Int) async throws -> SpotifySavedTracksResult {
        SpotifySavedTracksResult(tracks: [], totalAvailable: 0)
    }
}

private struct PreviewBrowsingCache: SpotifyBrowsingCache {
    func loadPlaylists(now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistSummary]? { nil }
    func loadPlaylistsBundle(now: Date) throws -> (playlists: [SpotifyPlaylistSummary], age: TimeInterval)? { nil }
    func savePlaylists(_ playlists: [SpotifyPlaylistSummary], cachedAt: Date) throws {}
    func loadTracks(playlistID: String, snapshotID: String, now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistTrackItem]? { nil }
    func loadTracksIgnoringAge(playlistID: String, snapshotID: String) throws -> [SpotifyPlaylistTrackItem]? { nil }
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
