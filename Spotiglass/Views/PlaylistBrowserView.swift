import AppKit
import SwiftUI

struct PlaylistBrowserView: View {
    @StateObject var viewModel: PlaylistBrowserViewModel
    /// Not observed, and neither are the queue and the lyrics: observing them re-ran this whole
    /// body, and with it the sidebar, the detail column and every visible row, on each
    /// play/pause and each new track (#422). The bar and ``BrowserPlaybackReactions`` observe the
    /// player; the rows read their own playing state.
    let playbackViewModel: PlaybackSessionViewModel
    @StateObject private var queueViewModelHolder: UnobservedStateObject<QueueViewModel>
    @StateObject private var lyricsViewModelHolder = UnobservedStateObject(ImmersiveLyricsViewModel())
    var queueViewModel: QueueViewModel { queueViewModelHolder.object }
    var lyricsViewModel: ImmersiveLyricsViewModel { lyricsViewModelHolder.object }
    /// The player's device, kept here because Play, Shuffle and Add to Queue depend on it.
    @State var playbackDeviceID: String?
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
    /// The window widened past the sidebar's collapse width while the queue was open but not
    /// enough for all three columns, so the sidebar stayed collapsed; it comes back once they
    /// fit, or at the next widening after the queue closed (``BrowserWidthCommitPolicy/sidebarOnWidening(_:sidebarCollapsed:heldForQueue:isQueueVisible:isNarrow:)``).
    @State var isSidebarHeldForQueue = false
    /// Only written to, so not observed (#422).
    let commandPaletteManager: CommandPaletteManager
    /// Catalog search and profile lookups for the command palette, Search view
    /// and tap targets. Separate from the view model's provider so palette
    /// searches never share its request state.
    let catalogProvider: any MusicBrowsingProvider
    let signOut: () -> Void
    /// Whether the transport bar drives real playback. A service that can't play here (Apple
    /// Music without a subscription) shows a calm placeholder and never starts a player.
    let playbackMode: BrowserPlaybackMode
    /// `false` hides Disconnect (toolbar, palette): Apple Music access is a system permission,
    /// and signing out of it lives in Settings › Account (#373).
    let canDisconnect: Bool
    /// The added service the window shows once Disconnect removes this one, or `nil` when this is
    /// the only service and Disconnect goes back to its sign-in screen. The alert says which.
    let disconnectSwitchesTo: MusicService?
    /// Drawn above the sidebar list: the service switcher (#373).
    let sidebarHeader: AnyView?

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
        catalogProvider: any MusicBrowsingProvider,
        commandPaletteManager: CommandPaletteManager,
        signOut: @escaping () -> Void,
        playbackMode: BrowserPlaybackMode = .live,
        canDisconnect: Bool = true,
        disconnectSwitchesTo: MusicService? = nil,
        sidebarHeader: AnyView? = nil
    ) {
        let playbackViewModel = playbackHost.playbackViewModel
        let queueViewModel = QueueViewModel(
            provider: playbackHost.playbackProvider,
            playbackSession: playbackViewModel
        )

        _viewModel = StateObject(wrappedValue: viewModel)
        self.playbackViewModel = playbackViewModel
        _queueViewModelHolder = StateObject(wrappedValue: UnobservedStateObject(queueViewModel))
        _playbackDeviceID = State(initialValue: playbackViewModel.deviceID)
        self.commandPaletteManager = commandPaletteManager
        self.catalogProvider = catalogProvider
        self.signOut = signOut
        self.playbackMode = playbackMode
        self.canDisconnect = canDisconnect
        self.disconnectSwitchesTo = disconnectSwitchesTo
        self.sidebarHeader = sidebarHeader
    }

    /// Disconnect only removes Spotify when another service is added; the window then shows that
    /// service instead of Spotify's sign-in screen (#397).
    static func disconnectConfirmationMessage(switchingTo next: MusicService?) -> String {
        guard let next else { return SpotiglassL10n.string("browser.disconnect.confirm.message") }
        return SpotiglassL10n.format("browser.disconnect.confirm.message.switch", next.displayName)
    }

    static func disconnectHint(switchingTo next: MusicService?) -> String {
        guard let next else { return SpotiglassL10n.string("browser.disconnect.hint") }
        return SpotiglassL10n.format("browser.disconnect.hint.switch", next.displayName)
    }

    /// Where you are, falling back to the app name at the root. With the lyrics open that is
    /// the lyrics, not the page underneath them (#438).
    private var windowTitle: String {
        if lyricsOverlay.isPresented {
            return SpotiglassL10n.string("playback.controls.lyrics")
        }
        return BrowserToolbarPresentation.windowTitle(
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
                    pinDroppedTransfers: pinDroppedTransfers,
                    header: sidebarHeader
                )
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
                        hasPlaybackDevice: hasPlaybackDevice,
                        onRequestCreatePlaylist: requestCreatePlaylist,
                        onRequestLibraryContinuation: requestLibraryContinuation
                    )
                    // The page is covered while the lyrics are open: VoiceOver, Tab and the
                    // page's own shortcuts must not reach rows you can't see.
                    .disabled(lyricsOverlay.isPresented)
                    .accessibilityHidden(lyricsOverlay.isPresented)
                    // Lyrics take the place of the page in this column only, so the sidebar,
                    // the queue and the player bar below stay as on every other screen (#438).
                    .overlay {
                        LyricsOverlayLayer(
                            lyricsOverlay: lyricsOverlay,
                            keymapStore: commandPaletteManager.keymapStore
                        )
                    }
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
            switch playbackMode {
            case .live:
                BrowserTransportBar(
                    playbackViewModel: playbackViewModel,
                    isLyricsPresented: isLyricsPresentedBinding,
                    openArtist: { target in
                        openArtistFromTapTarget(target)
                    }
                )
            case let .unavailable(message):
                PlaybackUnavailableBar(message: message)
            }
        }
    }

    private var browserChrome: some View {
        browserSplitLayout
        .animation(.easeOut(duration: 0.22), value: lyricsOverlay.isPresented)
        .animation(.easeOut(duration: 0.2), value: viewModel.canNavigateBack)
        // Measure the width the window offers, not the split view's own width. Below the
        // sidebar + detail minimums the split view keeps its minimum and overflows the window,
        // so its own width never dropped under the collapse breakpoint: the sidebar was cut off
        // instead of collapsing (#400). A flexible frame takes exactly the offered width.
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { _, newWidth in
            commitBrowserContentWidthIfNeeded(newWidth)
        }
        .background {
            BrowserPlaybackReactions(
                playbackViewModel: playbackViewModel,
                queueViewModel: queueViewModel,
                lyricsViewModel: lyricsViewModel,
                commandPaletteManager: commandPaletteManager
            )
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
            // The trail belongs to the page under the lyrics, so it leaves with that page (#438).
            if !lyricsOverlay.isPresented, viewModel.canNavigateBack || !viewModel.breadcrumbPath.isEmpty {
                ToolbarItem(placement: .navigation) {
                    NavigationToolbarChrome(viewModel: viewModel)
                }
            }
            // With the lyrics open the bar keeps what still applies (the queue panel stays next
            // to them) and trades Refresh and Disconnect for closing the lyrics: Refresh would
            // reload a page that isn't showing (#438).
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

                if lyricsOverlay.isPresented {
                    Button {
                        lyricsOverlay.dismiss()
                    } label: {
                        Label(SpotiglassL10n.string("browser.closeLyrics"), systemImage: "xmark")
                    }
                    .help(SpotiglassL10n.string("browser.closeLyrics"))
                    .accessibilityHint(SpotiglassL10n.string("browser.closeLyrics.hint"))
                } else if canDisconnect {
                    Button {
                        isConfirmingDisconnect = true
                    } label: {
                        Label(SpotiglassL10n.string("browser.disconnect"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .help(SpotiglassL10n.string("browser.disconnect"))
                    .accessibilityHint(Self.disconnectHint(switchingTo: disconnectSwitchesTo))
                }
            }
            if !lyricsOverlay.isPresented {
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
            Text(Self.disconnectConfirmationMessage(switchingTo: disconnectSwitchesTo))
        }
    }

    private var browserLifecycle: some View {
        browserChrome
        .task {
            await viewModel.loadIfNeeded()
        }
        .task {
            guard playbackMode == .live else { return }
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
        // `$deviceID` announces the new id before storing it: keep the value it delivers.
        .onReceive(playbackViewModel.$deviceID) { deviceID in
            if playbackDeviceID != deviceID { playbackDeviceID = deviceID }
        }
        .onChange(of: playbackDeviceID) { _, _ in
            syncTrackSelectionMenuState()
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
        #if DEBUG
        let _ = ViewBodyTally.record("PlaylistBrowserView")
        #endif
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
                // The sidebar is back (by hand or by widening), so nothing is held for the
                // queue any more; a later hide by hand must not be undone by a widening (#413).
                isSidebarHeldForQueue = false
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
        // The sidebar, the queue and the player bar stay usable next to the lyrics, so you can
        // go somewhere else while they are open (a sidebar row, an artist link, Back). The new
        // page would load out of sight under the lyrics, so going there closes them (#438).
        .onChange(of: LyricsCoveredPage(viewModel)) { oldPage, newPage in
            if lyricsOverlay.isPresented, newPage.isAnotherPage(than: oldPage) { lyricsOverlay.dismiss() }
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
                 ? SpotiglassL10n.format("playlist.detail.newPlaylist.empty", MusicServiceSelection.current.displayName)
                 : SpotiglassL10n.format(
                    "playlist.detail.newPlaylist.withTracks",
                    Int64(newPlaylistInitialRows.count)
                   ))
        }
        .modifier(PlaylistDeletionConfirmation(viewModel: viewModel))
        .modifier(LibraryRemovalConfirmation(viewModel: viewModel))
    }
}

/// Which page sits under the lyrics: the sidebar row and the trail pushed on top of it, by id.
/// Titles and covers are left out, so a rename or a sharper cover doesn't count as going
/// somewhere else.
struct LyricsCoveredPage: Equatable {
    let selection: SidebarSelection?
    let trail: [String]

    @MainActor
    init(_ viewModel: PlaylistBrowserViewModel) {
        selection = viewModel.sidebarSelection
        trail = viewModel.breadcrumbPath.map { crumb in
            switch crumb.kind {
            case .search: "search"
            case .likedSongs: "likedSongs"
            case let .playlist(id): "playlist:\(id)"
            case let .artist(id): "artist:\(id)"
            case let .album(id, _, _, _): "album:\(id)"
            }
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selection == rhs.selection && lhs.trail == rhs.trail
    }

    /// A pinned row is selected only for a moment: a pinned song plays and the previous row is
    /// selected again, so that round trip stays on the page. A pinned playlist, album or
    /// artist opens its page, which changes the trail.
    func isAnotherPage(than old: Self) -> Bool {
        if trail != old.trail { return true }
        guard selection != old.selection else { return false }
        return !Self.isPinnedRow(selection) && !Self.isPinnedRow(old.selection)
    }

    private static func isPinnedRow(_ selection: SidebarSelection?) -> Bool {
        if case .pinnedItem = selection { return true }
        return false
    }
}

/// The player bar. It observes the player, so a play/pause re-renders the bar, not the browser
/// around it (#422).
private struct BrowserTransportBar: View {
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    let isLyricsPresented: Binding<Bool>
    let openArtist: (ArtistTapTarget) -> Void

    var body: some View {
        // The bar shows and controls the music you hear (#396): the other service's player
        // while it plays and nothing plays here.
        let transport = playbackViewModel.audiblePlayer
        PlaybackControlsView(
            viewModel: transport,
            isLyricsPresented: isLyricsPresented,
            openArtist: openArtist,
            otherService: transport === playbackViewModel ? nil : transport.service
        )
    }
}

/// What the browser does when the player changes: refresh the queue, preload lyrics, update the
/// menus. A view of its own that draws nothing and observes the player and the queue, so a
/// play/pause or a new track runs this small body instead of the whole browser's (#422).
private struct BrowserPlaybackReactions: View {
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    @ObservedObject var queueViewModel: QueueViewModel
    let lyricsViewModel: ImmersiveLyricsViewModel
    let commandPaletteManager: CommandPaletteManager

    /// Now playing track used to prefetch LRCLIB lyrics before the lyrics overlay opens (only while transport is playing).
    private var lyricsPrefetchTrack: PlaybackNowPlaying? {
        PlaylistBrowserPlaybackHelpers.lyricsPrefetchTrack(connectionState: playbackViewModel.connectionState)
    }

    /// Stable per playing track; used to schedule halfway next-track lyrics prefetch.
    private var lyricsHalfwayNextPreloadTaskID: String? {
        PlaylistBrowserPlaybackHelpers.lyricsHalfwayNextPreloadTaskID(
            prefetchTrack: lyricsPrefetchTrack,
            nextQueueURI: queueViewModel.upcomingItems.first?.uri
        )
    }

    /// Playback identity without scrubber position ticks (avoids re-running queue hooks every progress frame).
    private var queueRelevantPlaybackKey: String {
        PlaylistBrowserPlaybackHelpers.queueRelevantPlaybackKey(connectionState: playbackViewModel.connectionState)
    }

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .task(id: lyricsPrefetchTrack?.uri) {
                guard let track = lyricsPrefetchTrack, track.lyricsTrackKey != nil else { return }
                await Task(priority: .userInitiated) {
                    await lyricsViewModel.preload(track: track)
                }.value
            }
            .task(id: lyricsHalfwayNextPreloadTaskID) {
                guard let current = lyricsPrefetchTrack,
                      current.durationMilliseconds > 0,
                      current.lyricsTrackKey != nil
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
                          let nextID = nextPlayback.lyricsTrackKey
                    else { return }
                    guard nextID != current.lyricsTrackKey else { return }
                    await lyricsViewModel.preload(track: nextPlayback)
                }.value
            }
            .onChange(of: playbackViewModel.connectionState) { _, _ in
                commandPaletteManager.setPlaybackTransportMutability(playbackViewModel.isTransportMutationReady)
            }
            .onChange(of: playbackViewModel.isTransportStateKnown) { _, _ in
                commandPaletteManager.setPlaybackTransportMutability(playbackViewModel.isTransportMutationReady)
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
    }
}

/// Keeps an object for the life of a view, as `@StateObject` does, without re-rendering the view
/// when the object changes. For objects a view only calls into or hands to other views (#422).
final class UnobservedStateObject<Object: AnyObject>: ObservableObject {
    let object: Object

    init(_ object: Object) {
        self.object = object
    }
}
