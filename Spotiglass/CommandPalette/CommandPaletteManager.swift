import AppKit
import Combine
import Foundation

@MainActor
final class CommandPaletteManager: ObservableObject {
    let viewModel = CommandPaletteViewModel()
    let keymapStore = CommandPaletteKeymapStore()

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
    var spotifySearch: ((String) async throws -> CommandPaletteSearchResults)?
    var filterByArtist: ((String) -> Void)?

    private var cancellables: Set<AnyCancellable> = []

    init() {
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
        keymapStore.objectWillChange
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
        case CommandPaletteCommandID.filterByArtist:
            if case let .string(name)? = args?["name"] {
                filterByArtist?(name)
            }
        default:
            break
        }
    }

    private func baseItems() -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = [
            CommandPaletteItem(
                id: CommandPaletteCommandID.openSettings,
                title: "Open Settings",
                subtitle: "Edit keymap and command palette preferences",
                iconSystemName: "gearshape",
                section: .commands,
                keywords: ["settings", "preferences", "keymap"]
            ) { [weak self] in
                self?.execute(commandID: CommandPaletteCommandID.openSettings)
            }
        ]

        if isSignedIn {
            items.append(contentsOf: [
                CommandPaletteItem(
                    id: CommandPaletteCommandID.refreshPlaylists,
                    title: "Refresh Playlists",
                    subtitle: "Reload your Spotify playlists",
                    iconSystemName: "arrow.clockwise",
                    section: .commands,
                    keywords: ["reload", "sync", "playlist"]
                ) { [weak self] in
                    self?.execute(commandID: CommandPaletteCommandID.refreshPlaylists)
                },
                CommandPaletteItem(
                    id: CommandPaletteCommandID.refreshTracks,
                    title: "Refresh Tracks",
                    subtitle: "Reload tracks for selected playlist",
                    iconSystemName: "text.badge.plus",
                    section: .commands,
                    keywords: ["track", "playlist", "reload"]
                ) { [weak self] in
                    self?.execute(commandID: CommandPaletteCommandID.refreshTracks)
                },
                CommandPaletteItem(
                    id: CommandPaletteCommandID.connectPlayback,
                    title: "Connect Playback",
                    subtitle: "Connect Spotiglass playback device",
                    iconSystemName: "dot.radiowaves.left.and.right",
                    section: .commands,
                    keywords: ["playback", "device", "connect"]
                ) { [weak self] in
                    self?.execute(commandID: CommandPaletteCommandID.connectPlayback)
                },
                CommandPaletteItem(
                    id: CommandPaletteCommandID.togglePlayback,
                    title: "Toggle Play/Pause",
                    subtitle: "Pause or resume Spotify playback",
                    iconSystemName: "playpause",
                    section: .commands,
                    keywords: ["play", "pause"]
                ) { [weak self] in
                    self?.execute(commandID: CommandPaletteCommandID.togglePlayback)
                },
                CommandPaletteItem(
                    id: CommandPaletteCommandID.nextTrack,
                    title: "Next Track",
                    subtitle: "Skip to the next track",
                    iconSystemName: "forward.fill",
                    section: .commands,
                    keywords: ["next", "skip"]
                ) { [weak self] in
                    self?.execute(commandID: CommandPaletteCommandID.nextTrack)
                },
                CommandPaletteItem(
                    id: CommandPaletteCommandID.previousTrack,
                    title: "Previous Track",
                    subtitle: "Return to previous track",
                    iconSystemName: "backward.fill",
                    section: .commands,
                    keywords: ["previous", "back"]
                ) { [weak self] in
                    self?.execute(commandID: CommandPaletteCommandID.previousTrack)
                },
                CommandPaletteItem(
                    id: CommandPaletteCommandID.signOut,
                    title: "Disconnect Spotify",
                    subtitle: "Sign out and clear local session",
                    iconSystemName: "xmark.circle",
                    section: .commands,
                    keywords: ["disconnect", "logout", "sign out"]
                ) { [weak self] in
                    self?.execute(commandID: CommandPaletteCommandID.signOut)
                }
            ])
        }
        return items
    }
}
