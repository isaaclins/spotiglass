import AppKit
import Combine
import Foundation

@MainActor
final class CommandPaletteManager: ObservableObject {
    let viewModel = CommandPaletteViewModel()
    let keymapStore: CommandPaletteKeymapStore

    /// While a Settings hotkey field is recording, global shortcut matching is suspended so the same chord is not executed as a command.
    @Published var isRecordingHotkey = false
    /// Mirrors the browser's back stack so the View menu's Back item can dim
    /// when there is nowhere to go. The app scene does not own the browser view
    /// model, and this manager is already the seam between the two.
    /// Whether the track table's selection can be queued: at least one selected
    /// row has a playable URI and there is a device to queue onto. The row
    /// context menu has always checked both, so the menu bar item does too (#132).
    @Published var canEnqueueTrackSelection = false
    /// Whether the selection can be pinned, unpinned, or neither. Drives both
    /// the enabled state and the Pin/Unpin title, the same way the queue item
    /// flips between Show and Hide.
    @Published var trackSelectionPinState: TrackSelectionPinState = .unavailable

    @Published var canNavigateBack = false
    /// Drives the View menu's "Show Sidebar" / "Hide Sidebar" title for this scene (#436).
    @Published private(set) var isSidebarVisible = true

    var isSignedIn = false
    /// Event monitors exist in every main-window scene. Only the key scene may
    /// consume a shortcut, while standalone manager tests keep the default.
    var isCurrentScene: () -> Bool = { true }
    /// The main window this scene runs in. `nil` in tests and previews.
    var sceneWindow: () -> NSWindow? = { nil }
    /// The window the palette opens in, also in tests and previews; set by its key monitor.
    var paletteWindow: () -> NSWindow? = { nil }
    /// The window in front; a seam so tests can put another window there.
    var frontWindow: () -> NSWindow? = { NSApp.keyWindow }
    /// The system's Show/Hide Sidebar action for the window in front; a seam for tests.
    var sendSystemSidebarToggle: () -> Void = {
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    }

    /// True while a window other than this scene's main window is in front, such as Settings.
    /// Show/Hide Sidebar then belongs to that window's own sidebar (#436).
    var isAnotherWindowInFront: Bool {
        guard let front = frontWindow(), let own = sceneWindow() else { return false }
        return front !== own
    }
    var signOut: (() -> Void)?
    var openSettings: (() -> Void)?
    /// Switches the app to another added service. App-wide and browser-free, so ``detach()``
    /// keeps it: ⌃1 / ⌃2 also work from a service's sign-in screen.
    var switchService: ((MusicService) -> Void)?
    /// The added services other than the one on screen. Only these get a palette row and a
    /// working ⌃1 / ⌃2.
    var switchableServices: [MusicService] = []
    /// Reloads the focused surface (library, playlist or artist detail, or queue when the queue column has focus).
    var unifiedRefresh: (() async -> Void)?
    var selectNextPlaylist: (() async -> Void)?
    var selectPreviousPlaylist: (() async -> Void)?
    /// Only a player that is its own connection (Spotify's web player) has one to connect;
    /// Apple Music plays on this Mac and leaves this unwired (#453).
    var connectPlayback: (() -> Void)? {
        didSet {
            let wired = connectPlayback != nil
            if canConnectPlayback != wired { canConnectPlayback = wired }
        }
    }
    /// Synchronous, so the controls show the new state before any task runs (#437).
    var togglePlayback: (() -> Void)?
    var nextTrack: (() async -> Void)?
    var previousTrack: (() async -> Void)?
    var disconnectPlayback: (() async -> Void)?
    /// Routed through ``QueueViewModel`` rather than the playback session so the
    /// menu bar reorders **Up next** exactly like the queue panel's shuffle button.
    var toggleShuffle: (() async -> Void)?
    var cycleRepeat: (() async -> Void)?
    /// Sets a specific repeat mode from the Playback menu's native Picker.
    var setRepeatModeAction: ((MusicRepeatMode) async -> Void)?
    /// Menu bar equivalents of the row context menu, acting on the track
    /// table's selection (#132).
    var enqueueTrackSelection: (() async -> Void)?
    var pinTrackSelection: (() -> Void)?
    var navigateBack: (() async -> Void)?
    var seekBy: ((Int) async -> Void)?
    var playURI: ((String) async -> Void)?
    var openPlaylist: ((String) async -> Void)?
    /// Artist ID and, when the caller knows it, the artist's name.
    var openArtist: ((String, String?) async -> Void)?
    var openAlbum: ((String, String, String, URL?) async -> Void)?
    /// Opens the dedicated catalog Search view. Wired by the browser host.
    var openSearch: (() -> Void)?
    var spotifySearch: ((String, CommandPaletteSearchCategory) async throws -> CommandPaletteSearchResults)?
    /// Synchronous in-memory matches (open-playlist tracks + library playlists) for the
    /// palette's local-first instant render. Returns empty when no browser context is wired.
    var localSpotifySearch: ((String) -> CommandPaletteSearchResults)?
    var filterByArtist: ((String) -> Void)?
    var toggleQueue: (() -> Void)?
    var toggleLyrics: (() -> Void)?
    /// Opens the pop-out lyrics window (#439). App-wide like ``switchService``: the window
    /// follows whatever plays, so ``detach()`` keeps it.
    var popOutLyrics: (() -> Void)?
    /// Shows or hides the browser's playlist sidebar (#436).
    var toggleSidebar: (() -> Void)?
    /// Bulk-warms the on-disk track cache for every library playlist + Liked
    /// Songs. Invoking the command while a run is in flight cancels it.
    var prefetchAllPlaylists: (() -> Void)?
    /// When immersive lyrics are visible, return true after calling dismiss so Escape is consumed before keymaps/WebKit.
    var dismissLyricsOverlayIfPresented: (() -> Bool)?
    /// Whether this scene's lyrics are open. Refresh leaves the palette while they are: it
    /// would reload the page under them (#438).
    var isLyricsPresented: (() -> Bool)?
    /// When set, Toggle Play/Pause only runs if this returns true (e.g. Web Playback transport ready).
    var playbackTogglePrerequisite: (() -> Bool)?
    /// Mirrors the session's effective local Play/Pause readiness for the menu bar
    /// and command palette. The playback session owns the predicate; this published
    /// projection keeps both surfaces observable from the app scene.
    @Published private(set) var canTogglePlayback = false
    /// Mirrors whether a current Spotify music track can open immersive lyrics.
    @Published private(set) var canToggleLyrics = false
    /// Whether Next and Previous Track have a song to skip from: with nothing loaded (the bar
    /// says "Ready to play") they did nothing (#500), so the palette and menu leave them out.
    @Published private(set) var canSkipTrack = false
    /// Mirrors whether ``connectPlayback`` is wired, so Playback › Connect Playback shows only
    /// for a player that has a connection (#453).
    @Published private(set) var canConnectPlayback = false
    /// Mirrors the session's live shuffle state for the Playback menu.
    @Published private(set) var shuffleEnabled = false
    /// Mirrors the session's live repeat mode for the Playback menu.
    @Published private(set) var repeatMode: MusicRepeatMode = .off
    /// Mirrors the session's confirmed shuffle/repeat readiness for the menu bar.
    @Published var canMutatePlaybackTransport = false
    /// Repeat follows the music you hear (#396): the menu's Repeat items are enabled by that
    /// player, Shuffle by the on-screen one.
    @Published var canMutateRepeat = false
    /// Bulk prefetch state is owned by the browser, but the app menu and palette
    /// both need the same scene-local projection to render its toggle state.
    @Published private(set) var prefetchProgress: PrefetchAllPlaylistsProgress?
    /// Guards shuffle/repeat commands from the command palette and menu key equivalents.
    var playbackTransportMutationPrerequisite: (() -> Bool)?
    /// Repeat follows the music you hear (#396), so it has its own readiness: Shuffle goes
    /// through the on-screen queue.
    var repeatMutationPrerequisite: (() -> Bool)?

    private var cancellables: Set<AnyCancellable> = []
    private var playbackReadinessCancellables: Set<AnyCancellable> = []

    init(
        keymapStore: CommandPaletteKeymapStore? = nil,
        recentSearches: CommandPaletteRecentSearches = .inMemory()
    ) {
        self.keymapStore = keymapStore ?? CommandPaletteKeymapStore()
        viewModel.recentSearches = recentSearches
        // The palette's own window: the window that is key can be another one (Settings).
        viewModel.rememberFocus = { [weak self] in
            CommandPaletteFocusReturn(window: self?.paletteWindow())?.restore
        }
        viewModel.staticItemsProvider = { [weak self] in
            self?.baseItems() ?? []
        }
        viewModel.searchProvider = { [weak self] query, category in
            guard let self, let spotifySearch = self.spotifySearch else {
                return CommandPaletteSearchResults()
            }
            return try await spotifySearch(query, category)
        }
        viewModel.localResultsProvider = { [weak self] query in
            self?.localSpotifySearch?(query) ?? CommandPaletteSearchResults()
        }
        viewModel.cancelPrefetchAllPlaylists = { [weak self] in
            self?.prefetchAllPlaylists?()
        }

        // SwiftUI only observes the outermost ObservableObject. Forward
        // nested object changes so that views observing this manager
        // re-render when viewModel/keymapStore mutate.
        viewModel.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        self.keymapStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    /// Sets ``canMutatePlaybackTransport`` only when it changes: every published change re-renders
    /// the menus and the browser, and the session reports its state many times a minute (#409).
    func setPlaybackTransportMutability(_ ready: Bool) {
        guard canMutatePlaybackTransport != ready else { return }
        canMutatePlaybackTransport = ready
    }

    /// Publishes only real changes: each one rebuilds the menus (#409).
    func setSidebarVisible(_ visible: Bool) {
        guard isSidebarVisible != visible else { return }
        isSidebarVisible = visible
    }

    func setPlaybackToggleAvailability(_ available: Bool) {
        guard canTogglePlayback != available else { return }
        canTogglePlayback = available
        // Commands show in `>` scope and, before a search starts, as quick actions (#472):
        // both lists have to follow what the service can do right now.
        viewModel.refreshListedCommands()
    }

    func setSkipAvailability(_ available: Bool) {
        guard canSkipTrack != available else { return }
        canSkipTrack = available
        // Like Play/Pause: the quick actions and `>` scope follow it while the panel is open.
        viewModel.refreshListedCommands()
    }

    /// Show Lyrics needs a song in the bar; Hide Lyrics works whenever the lyrics show, also
    /// while they wait for a song that is on its way (#486).
    var isLyricsToggleAllowed: Bool {
        canToggleLyrics || isLyricsPresented?() == true
    }

    func setLyricsToggleAvailability(_ available: Bool) {
        guard canToggleLyrics != available else { return }
        canToggleLyrics = available
        // Commands show in `>` scope and, before a search starts, as quick actions (#472):
        // both lists have to follow what the service can do right now.
        viewModel.refreshListedCommands()
    }

    /// Keeps menu state and command enablement on the same live playback
    /// projection. The browser is the source of truth; this manager only
    /// forwards it to the app-level menu for the active scene.
    func setPrefetchProgress(_ progress: PrefetchAllPlaylistsProgress?) {
        guard prefetchProgress != progress || viewModel.prefetchProgress != progress else { return }
        prefetchProgress = progress
        viewModel.prefetchProgress = progress
    }

    /// Requests a concrete repeat mode from the native Picker. The command
    /// remains guarded by the same readiness predicate as the cycling shortcut.
    func requestRepeatMode(_ mode: MusicRepeatMode) {
        guard repeatMutationPrerequisite?() ?? false else { return }
        Task { await setRepeatModeAction?(mode) }
    }

    func bindPlaybackReadiness(to playback: PlaybackSessionViewModel) {
        playbackReadinessCancellables.removeAll()
        setPlaybackToggleAvailability(playback.isPlaybackToggleReady)
        setLyricsToggleAvailability(playback.audiblePlayer.currentLyricTrack != nil)
        setSkipAvailability(
            playback.isOtherServiceHeard || playback.connectionState.hasTrackToSkipFrom
        )
        shuffleEnabled = playback.shuffleEnabled
        repeatMode = playback.repeatMode
        canMutatePlaybackTransport = playback.isTransportMutationReady
        canMutateRepeat = playback.audiblePlayer.isTransportMutationReady

        let playerPushesState = playback.playerPushesState
        Publishers.CombineLatest4(
            Publishers.CombineLatest4(
                playback.connectionStatePublisher,
                playback.$deviceID,
                playback.$activePlaybackDeviceID,
                playback.$isTransportStateKnown
            ),
            playback.$isOtherServiceHeard,
            playback.$isOtherServiceTransportMutationReady,
            playback.$otherServiceHasLyrics
        )
        .sink { [weak self] state, isOtherServiceHeard, isOtherServiceTransportMutationReady, otherServiceHasLyrics in
            let (connectionState, deviceID, activePlaybackDeviceID, isTransportStateKnown) = state
            // While the other service's music is what you hear, Play/Pause pauses or resumes it
            // (#396, #468).
            let followsOtherService = isOtherServiceHeard
                && !PlaylistBrowserPlaybackHelpers.isCurrentlyPlaying(connectionState: connectionState)
            self?.setPlaybackToggleAvailability(
                followsOtherService || PlaybackSessionViewModel.isPlaybackToggleReady(
                    connectionState: connectionState,
                    deviceID: deviceID,
                    activePlaybackDeviceID: activePlaybackDeviceID,
                    playerPushesState: playerPushesState
                )
            )
            // View › Show Lyrics opens the lyrics of the song in the bar (#486).
            self?.setLyricsToggleAvailability(
                followsOtherService ? otherServiceHasLyrics : connectionState.currentLyricTrack != nil
            )
            // Skipping goes to the music you hear (#396): the other service's song counts too.
            self?.setSkipAvailability(isOtherServiceHeard || connectionState.hasTrackToSkipFrom)
            let isTransportMutationReady = PlaybackSessionViewModel.isTransportMutationReady(
                isTransportStateKnown: isTransportStateKnown,
                connectionState: connectionState,
                commandDeviceID: activePlaybackDeviceID ?? deviceID
            )
            self?.setPlaybackTransportMutability(isTransportMutationReady)
            let canMutateRepeat = followsOtherService ? isOtherServiceTransportMutationReady : isTransportMutationReady
            if self?.canMutateRepeat != canMutateRepeat { self?.canMutateRepeat = canMutateRepeat }
        }
        .store(in: &playbackReadinessCancellables)

        playback.$shuffleEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.shuffleEnabled = enabled
            }
            .store(in: &playbackReadinessCancellables)
        // The menu's repeat checkmark is the repeat of the music you hear (#396), like the bar.
        Publishers.CombineLatest4(
            playback.$repeatMode,
            playback.$otherServiceRepeatMode,
            playback.$isOtherServiceHeard,
            playback.connectionStatePublisher
        )
        .map { mode, otherMode, isOtherServiceHeard, connectionState in
            let followsOtherService = isOtherServiceHeard
                && !PlaylistBrowserPlaybackHelpers.isCurrentlyPlaying(connectionState: connectionState)
            return followsOtherService ? otherMode : mode
        }
        .removeDuplicates()
        .sink { [weak self] mode in
            self?.repeatMode = mode
        }
        .store(in: &playbackReadinessCancellables)
    }

    /// Whether Escape is meant for what has the keyboard: a text field being edited, or a
    /// sheet or prompt in front of the window.
    static func escapeBelongsToFocusedControl(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        if window.sheetParent != nil || window.attachedSheet != nil { return true }
        if window is NSPanel { return true }
        return window.firstResponder is NSText
    }

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        // The pop-out lyrics window answers its own transport keys (#439), even with no main
        // window open. Everything here (Escape, the palette, the browser's commands) belongs to a
        // main window and must not act on it from a window that shows none of it.
        guard !LyricsPopOutWindow.isPopOut(event.window) else { return false }
        guard isCurrentScene() else { return false }

        // Escape keeps the existing dismissal priority: close the command
        // palette first, then the lyrics modal. It is intentionally handled
        // before the focused-owner seam so the modal's Escape escape hatch
        // remains available.
        if event.keyCode == 53 {
            if viewModel.isPresented {
                viewModel.hide()
                return true
            }
            // The sidebar and the queue stay usable next to the lyrics (#438): Escape in a
            // text field there (a playlist rename) or in a prompt over the window cancels
            // that, not the lyrics.
            if !Self.escapeBelongsToFocusedControl(event), dismissLyricsOverlayIfPresented?() == true {
                return true
            }
        }

        // The local monitor runs before AppKit sends the event to the focused
        // responder. Let a focused control claim the events it handles before
        // any app-wide or palette command handling (for example, Space arms
        // the shortcut recorder instead of toggling playback).
        if FocusedKeyEventDispatcher.shouldDeferGlobalDispatch(for: event) {
            return false
        }

        if viewModel.isPresented {
            // Bare Tab / Shift+Tab cycle the Spotify search category (footer segments)
            // while the query field stays focused. Modifier-bearing Tab events
            // (e.g. custom bindings) fall through to the keymap
            // dispatch path below so user-rebound shortcuts still fire.
            // In `>` scope there are no filters, but Tab is still the palette's: passed on, the
            // field handed focus to the page behind and typing stopped reaching it.
            if event.keyCode == 48,
               event.modifierFlags.intersection([.control, .option, .command]).isEmpty {
                if CommandPaletteScope.parse(viewModel.query).scope != .commands {
                    viewModel.cycleSearchCategory(forward: !event.modifierFlags.contains(.shift))
                }
                return true
            }
            if event.keyCode == 125 { // down
                viewModel.moveSelection(delta: 1)
                return true
            }
            if event.keyCode == 126 { // up
                viewModel.moveSelection(delta: -1)
                return true
            }
            if event.keyCode == 36 { // return
                // Plain ↩ runs the highlighted item. Modifier-bearing returns
                // (most importantly ⌘↩ for `palette.pin`) fall through to the
                // keymap-matching path below so user-rebound shortcuts work.
                let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                if modifiers.isEmpty {
                    Task { await self.viewModel.executeSelection() }
                    return true
                }
            }
        }

        if isRecordingHotkey {
            return false
        }

        // macOS keyDown auto-repeat would otherwise fire the matched command at ~10-20 Hz while
        // a chord is held. None of the catalog commands (playback transport, refresh, settings,
        // pin, …) are rate-safe under auto-repeat, and the palette navigation that does need
        // repeat (Up/Down/Tab) is consumed in the palette block above before reaching this seam.
        if event.isARepeat {
            return false
        }

        // A bare key (no ⌘/⌃/⌥) must reach a focused text field rather than fire a
        // single-key command like Space → Play/Pause while the user is typing. The
        // palette has its own field handling above, so this only guards the global
        // dispatch path. Only ⌘/⌃/⌥ count as modifiers here — a Shift-only combo is
        // treated as bare so shifted typing still reaches the field — but shortcuts
        // carrying ⌘/⌃/⌥ continue to fire inside text fields.
        if !viewModel.isPresented, Self.eventTargetsTextInput(event) {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            if modifiers.isEmpty {
                return false
            }
        }

        let context: CommandPaletteContext = viewModel.isPresented ? .paletteOpen : (isSignedIn ? .signedIn : .signedOut)
        let matched = keymapStore.commandBindings(for: event, context: context)
        let filtered = matched.filter { binding in
            if binding.command == CommandPaletteCommandID.togglePlayback {
                return playbackTogglePrerequisite?() ?? true
            }
            if binding.command == CommandPaletteCommandID.toggleLyrics {
                return isLyricsToggleAllowed
            }
            // With nothing to skip from, or no player wired (an Apple Music account without a
            // subscription), the shortcut would run and do nothing (#500).
            if binding.command == CommandPaletteCommandID.nextTrack {
                return canSkipTrack && nextTrack != nil
            }
            if binding.command == CommandPaletteCommandID.previousTrack {
                return canSkipTrack && previousTrack != nil
            }
            if binding.command == CommandPaletteCommandID.popOutLyrics {
                return popOutLyrics != nil
            }
            if let service = MusicService(switchCommandID: binding.command) {
                return switchService != nil && switchableServices.contains(service)
            }
            if binding.command == CommandPaletteCommandID.toggleSidebar {
                return toggleSidebar != nil && !CommandPaletteSidebarShortcut.isTypingKeyPress(event)
            }
            return true
        }
        // ⌃⌘S is the system's Show/Hide Sidebar chord, kept next to the rebindable one (#436).
        // With Settings in front it is Settings' chord, answered by Settings itself.
        if filtered.isEmpty, toggleSidebar != nil, !isAnotherWindowInFront,
           CommandPaletteSidebarShortcut.isSystemChord(event),
           !CommandPaletteSidebarShortcut.isTypingKeyPress(event) {
            execute(commandID: CommandPaletteCommandID.toggleSidebar)
            return true
        }
        guard !filtered.isEmpty else { return false }
        var executed = Set<String>()
        for binding in filtered {
            guard executed.insert(binding.command).inserted else { continue }
            execute(commandID: binding.command, args: binding.args)
        }
        return true
    }

    /// True when the key event is destined for an active text editor (a focused
    /// `NSTextField`/`NSTextView` uses the window's field editor — an `NSTextView` —
    /// as first responder), so bare keys should be typed, not treated as commands.
    private static func eventTargetsTextInput(_ event: NSEvent) -> Bool {
        guard let responder = event.window?.firstResponder else { return false }
        return responder is NSTextView
    }

    func execute(commandID: String, args: [String: JSONValue]? = nil) {
        switch commandID {
        case CommandPaletteCommandID.openPalette:
            viewModel.show()
        case CommandPaletteCommandID.refreshPlaylists, CommandPaletteCommandID.refreshTracks:
            Task { await unifiedRefresh?() }
        case CommandPaletteCommandID.selectNextPlaylist:
            Task { await selectNextPlaylist?() }
        case CommandPaletteCommandID.selectPreviousPlaylist:
            Task { await selectPreviousPlaylist?() }
        case CommandPaletteCommandID.openSettings:
            openSettings?()
        case CommandPaletteCommandID.signOut:
            let signOut = signOut
            detach()
            signOut?()
        case CommandPaletteCommandID.connectPlayback:
            connectPlayback?()
        case CommandPaletteCommandID.togglePlayback:
            guard playbackTogglePrerequisite?() ?? true else { return }
            togglePlayback?()
        case CommandPaletteCommandID.nextTrack:
            Task { await nextTrack?() }
        case CommandPaletteCommandID.previousTrack:
            Task { await previousTrack?() }
        case CommandPaletteCommandID.disconnectPlayback:
            Task { await disconnectPlayback?() }
        case CommandPaletteCommandID.toggleShuffle:
            guard playbackTransportMutationPrerequisite?() ?? false else { return }
            Task { await toggleShuffle?() }
        case CommandPaletteCommandID.cycleRepeat:
            guard repeatMutationPrerequisite?() ?? false else { return }
            Task { await cycleRepeat?() }
        case CommandPaletteCommandID.navigateBack:
            Task { await navigateBack?() }
        case CommandPaletteCommandID.seekForward:
            Task { await seekBy?(PlaybackSeekStep.milliseconds) }
        case CommandPaletteCommandID.seekBackward:
            Task { await seekBy?(-PlaybackSeekStep.milliseconds) }
        case "playback.playURI":
            if case let .string(uri)? = args?["uri"] {
                Task { await playURI?(uri) }
            }
        case "navigation.playlist.open":
            if case let .string(playlistID)? = args?["playlistID"] {
                Task { await openPlaylist?(playlistID) }
            }
        case CommandPaletteCommandID.openArtist:
            if case let .string(artistID)? = args?["artistID"] {
                var artistName: String?
                if case let .string(name)? = args?["artistName"] { artistName = name }
                Task { await openArtist?(artistID, artistName) }
            }
        case CommandPaletteCommandID.openAlbum:
            guard case let .string(albumID)? = args?["albumID"],
                  case let .string(title)? = args?["title"],
                  case let .string(subtitle)? = args?["subtitle"]
            else { break }
            let artworkURL: URL?
            if case let .string(rawURL)? = args?["artworkURL"] {
                artworkURL = URL(string: rawURL)
            } else {
                artworkURL = nil
            }
            Task { await openAlbum?(albumID, title, subtitle, artworkURL) }
        case CommandPaletteCommandID.openSearch:
            openSearch?()
        case CommandPaletteCommandID.filterByArtist:
            if case let .string(name)? = args?["name"] {
                filterByArtist?(name)
            }
        case CommandPaletteCommandID.toggleQueue:
            toggleQueue?()
        case CommandPaletteCommandID.toggleLyrics:
            guard isLyricsToggleAllowed else { return }
            toggleLyrics?()
        case CommandPaletteCommandID.popOutLyrics:
            viewModel.hide()
            popOutLyrics?()
        case CommandPaletteCommandID.toggleSidebar:
            // Like the system item it replaces, Show/Hide Sidebar acts on the window in front:
            // with Settings in front it collapses Settings' own sidebar, not the browser's
            // sidebar behind it (#436).
            if isAnotherWindowInFront {
                sendSystemSidebarToggle()
            } else {
                toggleSidebar?()
            }
        case CommandPaletteCommandID.enqueueTrackSelection:
            Task { await enqueueTrackSelection?() }
        case CommandPaletteCommandID.pinTrackSelection:
            pinTrackSelection?()
        case CommandPaletteCommandID.pinSelected:
            Task { await viewModel.executeSelectionPinning() }
        case CommandPaletteCommandID.unpinSelected:
            Task { await viewModel.executeSelectionUnpinning() }
        case CommandPaletteCommandID.enqueueSelected:
            Task { await viewModel.executeSelectionEnqueue() }
        case CommandPaletteCommandID.prefetchAllPlaylists:
            prefetchAllPlaylists?()
        case CommandPaletteCommandID.switchToSpotify, CommandPaletteCommandID.switchToAppleMusic:
            guard let service = MusicService(switchCommandID: commandID),
                switchableServices.contains(service)
            else { return }
            viewModel.hide()
            // Switch once the palette has closed and handed focus back. Tearing the browser down
            // in the same pass as the palette's dismissal left the window's title bar area
            // collapsed (sidebar and toolbar items shifted under the window buttons).
            let switchService = switchService
            DispatchQueue.main.async { switchService?(service) }
        default:
            break
        }
    }

    /// Detaches all scene-specific palette state and callbacks. This is called
    /// before auth content replaces the browser and when the scene disappears,
    /// so a later scene cannot inherit a search task or a closure retaining the
    /// old browser.
    func detach() {
        viewModel.hide()
        viewModel.showAllResults = nil
        viewModel.setAvailableSearchCategories(
            CommandPaletteSearchCategory.footerOrder(includeThisPlaylist: false),
            refreshIfFilterInvalidated: false
        )
        viewModel.prefetchProgress = nil

        isSignedIn = false
        isRecordingHotkey = false
        canNavigateBack = false
        isSidebarVisible = true
        canEnqueueTrackSelection = false
        trackSelectionPinState = .unavailable
        canTogglePlayback = false
        canToggleLyrics = false
        canSkipTrack = false
        shuffleEnabled = false
        repeatMode = .off
        canMutatePlaybackTransport = false
        canMutateRepeat = false
        prefetchProgress = nil
        playbackReadinessCancellables.removeAll()

        signOut = nil
        openSettings = nil
        unifiedRefresh = nil
        selectNextPlaylist = nil
        selectPreviousPlaylist = nil
        connectPlayback = nil
        togglePlayback = nil
        nextTrack = nil
        previousTrack = nil
        disconnectPlayback = nil
        toggleShuffle = nil
        cycleRepeat = nil
        setRepeatModeAction = nil
        enqueueTrackSelection = nil
        pinTrackSelection = nil
        navigateBack = nil
        seekBy = nil
        playURI = nil
        openPlaylist = nil
        openArtist = nil
        openSearch = nil
        spotifySearch = nil
        localSpotifySearch = nil
        filterByArtist = nil
        toggleQueue = nil
        toggleLyrics = nil
        toggleSidebar = nil
        prefetchAllPlaylists = nil
        dismissLyricsOverlayIfPresented = nil
        isLyricsPresented = nil
        playbackTogglePrerequisite = nil
        playbackTransportMutationPrerequisite = nil
        repeatMutationPrerequisite = nil
    }

    private func baseItems() -> [CommandPaletteItem] {
        CommandPaletteCommandCatalog.editable.compactMap { spec in
            guard !spec.requiresSignInForPalette || isSignedIn else { return nil }
            guard spec.commandID != CommandPaletteCommandID.togglePlayback || canTogglePlayback else { return nil }
            guard spec.commandID != CommandPaletteCommandID.toggleLyrics || isLyricsToggleAllowed else { return nil }
            guard spec.commandID != CommandPaletteCommandID.popOutLyrics || popOutLyrics != nil else { return nil }
            guard spec.commandID != CommandPaletteCommandID.refreshPlaylists || isLyricsPresented?() != true else {
                return nil
            }
            // A service without Disconnect or that can't play (Apple Music without a
            // subscription) leaves these unwired; listing them would offer commands that do nothing.
            guard spec.commandID != CommandPaletteCommandID.signOut || signOut != nil else { return nil }
            guard spec.commandID != CommandPaletteCommandID.connectPlayback || connectPlayback != nil else { return nil }
            guard spec.commandID != CommandPaletteCommandID.nextTrack || (nextTrack != nil && canSkipTrack) else {
                return nil
            }
            guard spec.commandID != CommandPaletteCommandID.previousTrack || (previousTrack != nil && canSkipTrack) else {
                return nil
            }
            guard spec.commandID != CommandPaletteCommandID.toggleSidebar || toggleSidebar != nil else { return nil }
            if let service = MusicService(switchCommandID: spec.commandID) {
                guard switchService != nil, switchableServices.contains(service) else { return nil }
            }
            let canExecute: (@MainActor () -> Bool)?
            if spec.commandID == CommandPaletteCommandID.togglePlayback {
                canExecute = { [weak self] in
                    guard let self else { return false }
                    return self.playbackTogglePrerequisite?() ?? self.canTogglePlayback
                }
            } else {
                canExecute = nil
            }
            return CommandPaletteItem(
                id: spec.commandID,
                title: spec.title,
                subtitle: spec.subtitle,
                iconSystemName: spec.iconSystemName,
                section: .commands,
                keywords: defaultKeywords(for: spec.commandID),
                canExecute: canExecute
            ) { [weak self] in
                self?.execute(commandID: spec.commandID)
            }
        }
    }

    private func defaultKeywords(for commandID: String) -> [String] {
        switch commandID {
        case CommandPaletteCommandID.openSettings:
            ["settings", "preferences", "keymap"]
        case CommandPaletteCommandID.openPalette:
            ["palette", "command", "search"]
        case CommandPaletteCommandID.openSearch:
            ["search", "find", "catalog", "browse", "tracks", "albums", "artists", "playlists"]
        case CommandPaletteCommandID.refreshPlaylists:
            ["reload", "sync", "playlist", "tracks", "artist", "queue", "refresh"]
        case CommandPaletteCommandID.connectPlayback:
            ["playback", "device", "connect"]
        case CommandPaletteCommandID.togglePlayback:
            ["play", "pause"]
        case CommandPaletteCommandID.nextTrack:
            ["next", "skip"]
        case CommandPaletteCommandID.previousTrack:
            ["previous", "back"]
        case CommandPaletteCommandID.toggleQueue:
            ["queue", "up next", "panel"]
        case CommandPaletteCommandID.toggleLyrics:
            ["lyrics", "immersive", "karaoke", "overlay"]
        case CommandPaletteCommandID.popOutLyrics:
            ["lyrics", "pop out", "window", "mini player", "miniplayer", "float", "on top", "pin"]
        case CommandPaletteCommandID.toggleSidebar:
            ["sidebar", "library", "playlists", "show", "hide"]
        case CommandPaletteCommandID.signOut:
            ["disconnect", "logout", "sign out"]
        case CommandPaletteCommandID.switchToSpotify, CommandPaletteCommandID.switchToAppleMusic:
            ["switch", "service", "account", "profile", "spotify", "apple music", "library"]
        case CommandPaletteCommandID.prefetchAllPlaylists:
            ["prefetch", "preload", "cache", "warm", "prefire", "all songs", "library", "load", "everything"]
        default:
            []
        }
    }
}
