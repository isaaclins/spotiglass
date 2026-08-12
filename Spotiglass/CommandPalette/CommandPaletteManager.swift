import AppKit
import Combine
import Foundation

@MainActor
final class CommandPaletteManager: ObservableObject {
    let viewModel = CommandPaletteViewModel()
    let keymapStore: CommandPaletteKeymapStore

    /// While a Settings hotkey field is recording, global shortcut matching is suspended so the same chord is not executed as a command.
    @Published var isRecordingHotkey = false

    var isSignedIn = false
    var signOut: (() -> Void)?
    var openSettings: (() -> Void)?
    /// Reloads the focused surface (library, playlist or artist detail, or queue when the queue column has focus).
    var unifiedRefresh: (() async -> Void)?
    var selectNextPlaylist: (() async -> Void)?
    var selectPreviousPlaylist: (() async -> Void)?
    var connectPlayback: (() -> Void)?
    var togglePlayback: (() async -> Void)?
    var nextTrack: (() async -> Void)?
    var previousTrack: (() async -> Void)?
    var disconnectPlayback: (() async -> Void)?
    /// Routed through ``QueueViewModel`` rather than the playback session so the
    /// menu bar reorders **Up next** exactly like the queue panel's shuffle button.
    var toggleShuffle: (() async -> Void)?
    var cycleRepeat: (() async -> Void)?
    var playURI: ((String) async -> Void)?
    var openPlaylist: ((String) async -> Void)?
    var openArtist: ((String) async -> Void)?
    /// Opens the dedicated catalog Search view. Wired by the browser host.
    var openSearch: (() -> Void)?
    var spotifySearch: ((String, CommandPaletteSearchCategory) async throws -> CommandPaletteSearchResults)?
    /// Synchronous in-memory matches (open-playlist tracks + library playlists) for the
    /// palette's local-first instant render. Returns empty when no browser context is wired.
    var localSpotifySearch: ((String) -> CommandPaletteSearchResults)?
    var filterByArtist: ((String) -> Void)?
    var toggleQueue: (() -> Void)?
    var toggleLyrics: (() -> Void)?
    /// Bulk-warms the on-disk track cache for every library playlist + Liked
    /// Songs. Invoking the command while a run is in flight cancels it.
    var prefetchAllPlaylists: (() -> Void)?
    /// When immersive lyrics are visible, return true after calling dismiss so Escape is consumed before keymaps/WebKit.
    var dismissLyricsOverlayIfPresented: (() -> Bool)?
    /// When set, Toggle Play/Pause only runs if this returns true (e.g. Web Playback transport ready).
    var playbackTogglePrerequisite: (() -> Bool)?

    private var cancellables: Set<AnyCancellable> = []

    init(keymapStore: CommandPaletteKeymapStore? = nil) {
        self.keymapStore = keymapStore ?? CommandPaletteKeymapStore()
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

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        if viewModel.isPresented {
            // Bare Tab / Shift+Tab cycle the Spotify search category (footer segments)
            // while the query field stays focused. Modifier-bearing Tab events
            // (e.g. custom bindings) fall through to the keymap
            // dispatch path below so user-rebound shortcuts still fire.
            if event.keyCode == 48,
               CommandPaletteScope.parse(viewModel.query).scope != .commands,
               event.modifierFlags.intersection([.control, .option, .command]).isEmpty {
                viewModel.cycleSearchCategory(forward: !event.modifierFlags.contains(.shift))
                return true
            }
            if event.keyCode == 53 { // esc
                viewModel.hide()
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

        if event.keyCode == 53, dismissLyricsOverlayIfPresented?() == true {
            return true
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
        guard !matched.isEmpty else { return false }
        let filtered = matched.filter { binding in
            if binding.command == CommandPaletteCommandID.togglePlayback {
                return playbackTogglePrerequisite?() ?? true
            }
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
            signOut?()
        case CommandPaletteCommandID.connectPlayback:
            connectPlayback?()
        case CommandPaletteCommandID.togglePlayback:
            guard playbackTogglePrerequisite?() ?? true else { return }
            Task { await togglePlayback?() }
        case CommandPaletteCommandID.nextTrack:
            Task { await nextTrack?() }
        case CommandPaletteCommandID.previousTrack:
            Task { await previousTrack?() }
        case CommandPaletteCommandID.disconnectPlayback:
            Task { await disconnectPlayback?() }
        case CommandPaletteCommandID.toggleShuffle:
            Task { await toggleShuffle?() }
        case CommandPaletteCommandID.cycleRepeat:
            Task { await cycleRepeat?() }
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
                Task { await openArtist?(artistID) }
            }
        case CommandPaletteCommandID.openSearch:
            openSearch?()
        case CommandPaletteCommandID.filterByArtist:
            if case let .string(name)? = args?["name"] {
                filterByArtist?(name)
            }
        case CommandPaletteCommandID.toggleQueue:
            toggleQueue?()
        case CommandPaletteCommandID.toggleLyrics:
            toggleLyrics?()
        case CommandPaletteCommandID.pinSelected:
            Task { await viewModel.executeSelectionPinning() }
        case CommandPaletteCommandID.unpinSelected:
            Task { await viewModel.executeSelectionUnpinning() }
        case CommandPaletteCommandID.enqueueSelected:
            Task { await viewModel.executeSelectionEnqueue() }
        case CommandPaletteCommandID.prefetchAllPlaylists:
            prefetchAllPlaylists?()
        default:
            break
        }
    }

    private func baseItems() -> [CommandPaletteItem] {
        CommandPaletteCommandCatalog.editable.compactMap { spec in
            guard !spec.requiresSignInForPalette || isSignedIn else { return nil }
            return CommandPaletteItem(
                id: spec.commandID,
                title: spec.title,
                subtitle: spec.subtitle,
                iconSystemName: spec.iconSystemName,
                section: .commands,
                keywords: defaultKeywords(for: spec.commandID)
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
            ["queue", "up next", "sidebar"]
        case CommandPaletteCommandID.toggleLyrics:
            ["lyrics", "immersive", "karaoke", "overlay"]
        case CommandPaletteCommandID.signOut:
            ["disconnect", "logout", "sign out"]
        case CommandPaletteCommandID.prefetchAllPlaylists:
            ["prefetch", "preload", "cache", "warm", "prefire", "all songs", "library", "load", "everything"]
        default:
            []
        }
    }
}
