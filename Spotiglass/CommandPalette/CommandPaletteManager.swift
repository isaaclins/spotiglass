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
    var refreshPlaylists: (() async -> Void)?
    var refreshTracks: (() async -> Void)?
    var selectNextPlaylist: (() async -> Void)?
    var selectPreviousPlaylist: (() async -> Void)?
    var connectPlayback: (() -> Void)?
    var togglePlayback: (() async -> Void)?
    var nextTrack: (() async -> Void)?
    var previousTrack: (() async -> Void)?
    var disconnectPlayback: (() async -> Void)?
    var playURI: ((String) async -> Void)?
    var openPlaylist: ((String) async -> Void)?
    var openArtist: ((String) async -> Void)?
    var spotifySearch: ((String) async throws -> CommandPaletteSearchResults)?
    var filterByArtist: ((String) -> Void)?
    var toggleQueue: (() -> Void)?

    private var cancellables: Set<AnyCancellable> = []

    init(keymapStore: CommandPaletteKeymapStore? = nil) {
        self.keymapStore = keymapStore ?? CommandPaletteKeymapStore()
        viewModel.staticItemsProvider = { [weak self] in
            self?.baseItems() ?? []
        }
        viewModel.searchProvider = { [weak self] query in
            guard let self, let spotifySearch = self.spotifySearch else {
                return CommandPaletteSearchResults()
            }
            return try await spotifySearch(query)
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
                Task { await self.viewModel.executeSelection() }
                return true
            }
        }

        if isRecordingHotkey {
            return false
        }

        let context: CommandPaletteContext = viewModel.isPresented ? .paletteOpen : (isSignedIn ? .signedIn : .signedOut)
        let matched = keymapStore.commandBindings(for: event, context: context)
        guard !matched.isEmpty else { return false }
        for binding in matched {
            execute(commandID: binding.command, args: binding.args)
        }
        return true
    }

    func execute(commandID: String, args: [String: JSONValue]? = nil) {
        switch commandID {
        case CommandPaletteCommandID.openPalette:
            viewModel.show()
        case CommandPaletteCommandID.refreshPlaylists:
            Task { await refreshPlaylists?() }
        case CommandPaletteCommandID.refreshTracks:
            Task { await refreshTracks?() }
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
            Task { await togglePlayback?() }
        case CommandPaletteCommandID.nextTrack:
            Task { await nextTrack?() }
        case CommandPaletteCommandID.previousTrack:
            Task { await previousTrack?() }
        case CommandPaletteCommandID.disconnectPlayback:
            Task { await disconnectPlayback?() }
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
        case CommandPaletteCommandID.filterByArtist:
            if case let .string(name)? = args?["name"] {
                filterByArtist?(name)
            }
        case CommandPaletteCommandID.toggleQueue:
            toggleQueue?()
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
        case CommandPaletteCommandID.refreshPlaylists:
            ["reload", "sync", "playlist"]
        case CommandPaletteCommandID.refreshTracks:
            ["track", "playlist", "reload"]
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
        case CommandPaletteCommandID.signOut:
            ["disconnect", "logout", "sign out"]
        default:
            []
        }
    }
}
