import AppKit
import SwiftUI

struct PlaylistBrowserView: View {
    @StateObject var viewModel: PlaylistBrowserViewModel
    @StateObject var playbackViewModel: PlaybackSessionViewModel
    @StateObject var queueViewModel: QueueViewModel
    @StateObject var lyricsViewModel = ImmersiveLyricsViewModel()
    @EnvironmentObject var pinnedStore: PinnedItemsStore
    @EnvironmentObject var lyricsOverlay: LyricsOverlayController
    @AppStorage("queue.panel.visible") var isQueueVisible = false
    /// Best-effort scroll anchor when the playlist `List` is torn down for lyrics (playback URI match, else last row `onAppear`).
    @State var detailLastVisibleTrackID: String?
    /// When lyrics opens we snapshot here; when the playlist list remounts, `ScrollViewReader` scrolls to this id then clears it.
    @State var pendingPlaylistListScrollRestoreID: String?
    /// Drives only the **playlist** sidebar (leading column). Queue visibility is separate — see `PlaylistBrowserDetailWithQueueSplit` below.
    @State var playlistColumnVisibility: NavigationSplitViewVisibility = .doubleColumn
    /// Disconnecting clears the session and costs a full OAuth round trip to undo, and the
    /// control sits next to Refresh, so it asks first.
    @State var isConfirmingDisconnect = false
    /// Drives the narrow-window mutual-exclusion rule: when this drops below
    /// ``SpotiglassDesign/dualSidebarComfortableMinWidth`` the playlist sidebar and queue panel can no
    /// longer coexist (opening one closes the other; resizing wide→narrow auto-closes the LRU one).
    @State var browserContentWidth: CGFloat = 2000
    @State var browserWidthSampler = BrowserWidthSampler()
    @State var lastBrowserWidthCommitTime: CFAbsoluteTime = 0
    /// Cached previous selection so pinned-track activations can revert the
    /// list highlight to whatever was selected before the click.
    @State var lastNonPinnedSelection: SidebarSelection?
    @State var libraryRowOrder: [String] = [
        LibrarySidebarOrder.homeToken
    ]
    /// User ID whose persisted Library row order has already been loaded into
    /// ``libraryRowOrder``. Guards the one-time seed per bound account so
    /// later syncs do not clobber in-session reorders with the disk copy.
    @State var libraryRowOrderSeededUserID: String?
    @State var unifiedRefreshFocus: UnifiedRefreshFocus = .mainContent
    /// Which side the user most recently OPENED (closed → open transition). Used to pick the loser
    /// when the window shrinks below ``SpotiglassDesign/dualSidebarComfortableMinWidth`` with both
    /// sides still visible. Defaults to `.playlist` so the first narrow-resize tiebreaker closes the
    /// queue panel (the explicitly opt-in overlay) and keeps the primary nav sidebar.
    @State var lastOpenedSidebar: SidebarKind = .playlist
    let commander: WebPlaybackViewCommander
    let playbackCoordinator: SpotifyPlaybackWebViewCoordinator
    @ObservedObject var commandPaletteManager: CommandPaletteManager
    let spotifySearchClient: SpotifyAPIClient
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

    /// Where you are, falling back to the app name at the root.
    private var windowTitle: String {
        viewModel.breadcrumbPath.last?.label ?? AppMetadata.displayName
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $playlistColumnVisibility) {
                PlaylistBrowserSidebar(
                    viewModel: viewModel,
                    playbackViewModel: playbackViewModel,
                    libraryRows: libraryRows,
                    pinnedBindingFailed: pinnedStore.didFailToBind,
                    retryPinnedBinding: {
                        Task { await bindPinnedStoreToCurrentUser() }
                    },
                    likedSongsStubRow: likedSongsStubRow,
                    playlistSummaryFromRow: playlistSummaryFromRow,
                    onLibraryAppear: { syncLibraryRowOrder() },
                    onSidebarListSelectionChange: { oldValue, newValue in
                        handleSidebarSelectionChange(oldValue: oldValue, newValue: newValue)
                    },
                    moveLibraryRows: { source, destination in
                        moveLibraryRows(fromOffsets: source, toOffset: destination)
                    },
                    pinDroppedTransfers: pinDroppedTransfers
                )
                .background(.background)
                .toolbar(removing: lyricsOverlay.isPresented ? .sidebarToggle : nil)
                .navigationSplitViewColumnWidth(
                    min: SpotiglassDesign.playlistSidebarMinWidth,
                    ideal: SpotiglassDesign.sidebarWidth
                )
            } detail: {
                PlaylistBrowserDetailWithQueueSplit(
                    unifiedRefreshFocus: $unifiedRefreshFocus,
                    isQueueVisible: isQueueVisible
                ) {
                    PlaylistBrowserMainDetailColumn(
                        viewModel: viewModel,
                        playbackViewModel: playbackViewModel,
                        queueViewModel: queueViewModel,
                        pendingPlaylistListScrollRestoreID: $pendingPlaylistListScrollRestoreID,
                        detailLastVisibleTrackID: $detailLastVisibleTrackID,
                        currentPlaybackURI: currentPlaybackURI,
                        isCurrentlyPlaying: isCurrentlyPlaying,
                        hasPlaybackDevice: hasPlaybackDevice
                    )
                } queueColumn: {
                    QueuePanelColumn(
                        queueViewModel: queueViewModel,
                        playbackViewModel: playbackViewModel,
                        openArtist: { openArtistFromTapTarget($0) }
                    )
                }
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
        .task(id: lyricsHalfwayNextPreloadTaskID) {
            guard let current = lyricsPrefetchTrack,
                  current.durationMilliseconds > 0,
                  current.spotifyTrackIDForLyrics != nil
            else { return }
            let halfMs = current.durationMilliseconds / 2
            let waitMs = max(0, halfMs - current.positionMilliseconds)
            if waitMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000)
            }
            guard !Task.isCancelled else { return }
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
        // An empty title left the window untitled: blank in the Window menu, in
        // Mission Control and to assistive tech, while the Settings window was
        // correctly named (#161). The title is the current location rather than
        // the app name, because the breadcrumb's home crumb already says
        // "Spotiglass" and repeating it in the titlebar reads as a mistake.
        .navigationTitle(windowTitle)
        .toolbar {
            // At the root there is no trail and nothing to go back to, so the
            // item would render as an empty capsule beside the window title.
            if viewModel.canNavigateBack || !viewModel.breadcrumbPath.isEmpty {
                ToolbarItem(placement: .navigation) {
                    NavigationToolbarChrome(viewModel: viewModel)
                }
            }
            if lyricsOverlay.isPresented {
                ToolbarItemGroup(placement: .automatic) {
                    Button {
                        lyricsOverlay.dismiss()
                    } label: {
                        Label(SpotiglassL10n.string("browser.closeLyrics"), systemImage: "xmark.circle")
                    }
                    .help(SpotiglassL10n.string("browser.closeLyrics"))
                    .accessibilityHint(SpotiglassL10n.string("browser.closeLyrics.hint"))
                }
                ToolbarItem(placement: .primaryAction) {
                    unifiedRefreshToolbarButton
                }
            } else {
                ToolbarItemGroup(placement: .automatic) {
                    Button {
                        isQueueVisible.toggle()
                    } label: {
                        Label(SpotiglassL10n.string("browser.queue"), systemImage: "list.bullet.indent")
                    }
                    .help(
                        isQueueVisible
                            ? SpotiglassL10n.string("tooltip.toolbar.queue.hide")
                            : SpotiglassL10n.string("tooltip.toolbar.queue.show")
                    )
                    .accessibilityHint(SpotiglassL10n.string("browser.queue.hint"))

                    Button {
                        isConfirmingDisconnect = true
                    } label: {
                        Label(SpotiglassL10n.string("browser.disconnect"), systemImage: "xmark.circle")
                    }
                    .help(SpotiglassL10n.string("browser.disconnect"))
                    .accessibilityHint(SpotiglassL10n.string("browser.disconnect.hint"))
                }
                ToolbarItem(placement: .primaryAction) {
                    unifiedRefreshToolbarButton
                }
            }
        }
        .alert(
            SpotiglassL10n.string("browser.disconnect.confirm.title"),
            isPresented: $isConfirmingDisconnect
        ) {
            Button(SpotiglassL10n.string("browser.disconnect.confirm.cancel"), role: .cancel) {}
            Button(SpotiglassL10n.string("browser.disconnect"), role: .destructive) {
                viewModel.clearForSignOut()
                signOut()
            }
        } message: {
            Text(SpotiglassL10n.string("browser.disconnect.confirm.message"))
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
            commandPaletteManager.canNavigateBack = viewModel.canNavigateBack
            syncTrackSelectionMenuState()
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
        .onChange(of: viewModel.prefetchAllPlaylistsProgress) { _, newValue in
            commandPaletteManager.viewModel.prefetchProgress = newValue
        }
        .onChange(of: viewModel.canNavigateBack) { _, newValue in
            commandPaletteManager.canNavigateBack = newValue
        }
        // The menu bar dims and re-titles its selection items from this, so it
        // has to follow both the selection and the pinned set (#132).
        .onChange(of: viewModel.selectedDetailTrackIDs) { _, _ in
            syncTrackSelectionMenuState()
        }
        .onChange(of: playbackViewModel.deviceID) { _, _ in
            syncTrackSelectionMenuState()
        }
        .onChange(of: playbackViewModel.connectionState) { _, _ in
            commandPaletteManager.canMutatePlaybackTransport = playbackViewModel.isTransportMutationReady
        }
        .onChange(of: playbackViewModel.isTransportStateKnown) { _, _ in
            commandPaletteManager.canMutatePlaybackTransport = playbackViewModel.isTransportMutationReady
        }
        .onChange(of: pinnedStore.items) { _, _ in
            syncTrackSelectionMenuState()
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
}
