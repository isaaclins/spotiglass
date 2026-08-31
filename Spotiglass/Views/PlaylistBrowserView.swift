import AppKit
import SwiftUI

struct PlaylistBrowserView: View {
    @StateObject var viewModel: PlaylistBrowserViewModel
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    @StateObject var queueViewModel: QueueViewModel
    @StateObject var lyricsViewModel = ImmersiveLyricsViewModel()
    @EnvironmentObject var pinnedStore: PinnedItemsStore
    @EnvironmentObject var lyricsOverlay: LyricsOverlayController
    @Environment(\.spotiglassLocale) private var spotiglassLocale
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
    /// Shared prompt used when a track menu is opened outside playlist detail.
    @State var isPromptingNewPlaylist = false
    @State var newPlaylistName = ""
    @State var newPlaylistInitialRows: [TrackRowViewModel] = []
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
    @ObservedObject var commandPaletteManager: CommandPaletteManager
    let spotifySearchClient: SpotifyAPIClient
    let signOut: () -> Void

    private func requestCreatePlaylist(_ rows: [TrackRowViewModel]) {
        newPlaylistInitialRows = rows
        newPlaylistName = ""
        isPromptingNewPlaylist = true
    }

    private func requestLibraryContinuation(_ row: TrackRowViewModel) {
        Task { @MainActor in
            await viewModel.enqueueLibraryContinuation(from: row) { uris in
                await queueViewModel.addToQueue(uris: uris)
            }
        }
    }

    init(
        viewModel: PlaylistBrowserViewModel,
        playbackHost: SpotiglassPlaybackHost,
        searchTokenProvider: SpotifyAccessTokenProviding,
        commandPaletteManager: CommandPaletteManager,
        signOut: @escaping () -> Void
    ) {
        let playbackViewModel = playbackHost.playbackViewModel
        let queueViewModel = QueueViewModel(
            playbackAPI: playbackHost.playbackAPI,
            playbackSession: playbackViewModel
        )

        _viewModel = StateObject(wrappedValue: viewModel)
        _playbackViewModel = ObservedObject(wrappedValue: playbackViewModel)
        _queueViewModel = StateObject(wrappedValue: queueViewModel)
        _commandPaletteManager = ObservedObject(wrappedValue: commandPaletteManager)
        spotifySearchClient = SpotifyAPIClient(tokenProvider: searchTokenProvider, getResponseCache: .shared)
        self.signOut = signOut
    }

    /// Where you are, falling back to the app name at the root.
    private var windowTitle: String {
        BrowserToolbarPresentation.windowTitle(
            for: viewModel.breadcrumbPath,
            locale: spotiglassLocale
        )
    }

    // The browser body is split into sequential stages on purpose. As one
    // expression the modifier chain exceeded the Swift type-checker's budget on
    // CI's toolchain ("unable to type-check this expression in reasonable
    // time"). Each stage is type-checked independently, so keep new modifiers
    // grouped into the stage they belong to instead of extending one chain.
    private var browserSplitLayout: some View {
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
                        hasPlaybackDevice: hasPlaybackDevice,
                        onRequestCreatePlaylist: requestCreatePlaylist,
                        onRequestLibraryContinuation: requestLibraryContinuation
                    )
                } queueColumn: {
                    QueuePanelColumn(
                        browserViewModel: viewModel,
                        queueViewModel: queueViewModel,
                        playbackViewModel: playbackViewModel,
                        openArtist: { openArtistFromTapTarget($0) },
                        onRequestCreatePlaylist: requestCreatePlaylist,
                        onRequestLibraryContinuation: requestLibraryContinuation
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
    }

    private var browserChrome: some View {
        browserSplitLayout
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
        // An empty title left the window untitled: blank in the Window menu, in
        // Mission Control and to assistive tech, while the Settings window was
        // correctly named (#161). The title is the current location rather than
        // the app name, because the breadcrumb's home crumb already says
        // "Spotiglass" and repeating it in the titlebar reads as a mistake.
        .navigationTitle(windowTitle)
        .toolbar {
            if let progress = viewModel.prefetchAllPlaylistsProgress {
                ToolbarItem(placement: .automatic) {
                    PlaylistBrowserPrefetchProgressToolbarItem(progress: progress) {
                        Task { await viewModel.toggleBulkPlaylistTrackPrefetch() }
                    }
                }
            }
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
    }

    private var browserLifecycle: some View {
        browserChrome
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
    }

    private var browserCommandBindings: some View {
        browserLifecycle
        .onChange(of: viewModel.sidebarSelection) { _, _ in
            bindCommandPalette(queueVisible: $isQueueVisible, lyricsPresented: isLyricsPresentedBinding)
        }
        .onChange(of: viewModel.detailState) { _, _ in
            bindCommandPalette(queueVisible: $isQueueVisible, lyricsPresented: isLyricsPresentedBinding)
            syncTrackSelectionMenuState()
        }
        .onChange(of: viewModel.prefetchAllPlaylistsProgress) { _, newValue in
            commandPaletteManager.setPrefetchProgress(newValue)
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
            // Auth teardown detaches this scene before clearing account-bound
            // pins. Do not let that published clear rebind browser callbacks
            // after the palette has been reset.
            guard commandPaletteManager.isSignedIn else { return }
            syncTrackSelectionMenuState()
            syncLibraryRowOrder()
            bindCommandPalette(queueVisible: $isQueueVisible, lyricsPresented: isLyricsPresentedBinding)
        }
    }

    var body: some View {
        browserCommandBindings
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
        .alert(SpotiglassL10n.string("playlist.detail.newPlaylist.title"), isPresented: $isPromptingNewPlaylist) {
            TextField(SpotiglassL10n.string("playlist.detail.newPlaylist.field"), text: $newPlaylistName)
            Button(SpotiglassL10n.string("playlist.detail.newPlaylist.cancel"), role: .cancel) {
                newPlaylistInitialRows = []
                newPlaylistName = ""
            }
            Button(SpotiglassL10n.string("playlist.detail.newPlaylist.create")) {
                let rows = newPlaylistInitialRows
                let name = newPlaylistName
                newPlaylistInitialRows = []
                newPlaylistName = ""
                Task { await viewModel.createPlaylistWithRows(name: name, rows: rows) }
            }
            .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text(newPlaylistInitialRows.isEmpty
                 ? SpotiglassL10n.string("playlist.detail.newPlaylist.empty")
                 : SpotiglassL10n.format(
                    "playlist.detail.newPlaylist.withTracks",
                    Int64(newPlaylistInitialRows.count)
                   ))
        }
    }
}
