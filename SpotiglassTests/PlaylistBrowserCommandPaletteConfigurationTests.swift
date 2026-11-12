import SwiftUI
import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserCommandPaletteConfigurationTests: XCTestCase {
    /// Apple Music browsing has no player yet. "Connect playback" (and its ⇧⌘K shortcut) must
    /// not start the Spotify player behind it; Spotify keeps the command.
    func testPlaybackAndDisconnectAreOnlyWiredWhenTheServiceHasThem() throws {
        func wire(playbackAvailable: Bool, canDisconnect: Bool = true) -> CommandPaletteManager {
            let viewModel = PlaylistBrowserViewModel(
                api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
                cache: MockBrowsingCache()
            )
            let playback = PlaybackSessionViewModel(
                provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander())
            )
            let manager = CommandPaletteManager()
            PlaylistBrowserCommandPaletteConfiguration.apply(
                to: manager,
                dependencies: .init(
                    viewModel: viewModel,
                    playbackViewModel: playback,
                    queueViewModel: QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI()), playbackSession: playback),
                    commandPaletteManager: manager,
                    pinnedStore: PinnedItemsStore(cache: InMemoryPinnedItemsCache()),
                    catalogProvider: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
                    signOut: {},
                    syncUnifiedRefreshRouting: {},
                    isPlaybackAvailable: playbackAvailable,
                    canDisconnect: canDisconnect
                ),
                queueVisible: .constant(false),
                lyricsPresented: .constant(false)
            )
            return manager
        }
        XCTAssertNotNil(wire(playbackAvailable: true).connectPlayback)
        XCTAssertNil(wire(playbackAvailable: false).connectPlayback)
        // Every transport command stays unwired without a player, so neither the palette nor a
        // shortcut can reach the Spotify player.
        let spotify = wire(playbackAvailable: true)
        XCTAssertNotNil(spotify.nextTrack)
        XCTAssertNotNil(spotify.playURI)
        let noPlayer = wire(playbackAvailable: false)
        XCTAssertNil(noPlayer.togglePlayback)
        XCTAssertNil(noPlayer.nextTrack)
        XCTAssertNil(noPlayer.previousTrack)
        XCTAssertNil(noPlayer.seekBy)
        XCTAssertNil(noPlayer.playURI)
        XCTAssertNil(noPlayer.enqueueTrackSelection)
        XCTAssertNil(noPlayer.toggleShuffle)
        // No Disconnect for a service whose access is a system permission.
        XCTAssertNotNil(wire(playbackAvailable: true).signOut)
        XCTAssertNil(wire(playbackAvailable: false, canDisconnect: false).signOut)
    }

    /// #453: with Apple Music, Playback › Connect Playback (⇧⌘K) and the palette's "Connect
    /// Spotiglass playback device" were still offered. Apple Music plays on this Mac, so there is
    /// nothing to connect, and running it restarted the player session. Spotify keeps it.
    func testConnectPlaybackIsOfferedOnlyForAPlayerWithAConnection() throws {
        func menu(_ registry: SpotiglassSceneRegistry, keymap: CommandPaletteKeymapStore, service: MusicService) -> SpotiglassMenuCommands {
            let settingsURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("SpotiglassConnectPlayback-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("settings.json", isDirectory: false)
            return SpotiglassMenuCommands(
                sceneRegistry: registry,
                keymapStore: keymap,
                settingsStore: SpotiglassSettingsStore(fileURL: settingsURL),
                serviceStore: MusicServiceStore(
                    storage: InMemoryMusicServiceSelectionStorage(services: [.spotify, .appleMusic], active: service)
                ),
                isSignedIn: true,
                isQueueVisible: false
            )
        }
        // `onto` rewires a window's manager the way switching services does: each service's
        // browser binds the window's palette when it appears.
        func wire(
            _ playback: PlaybackSessionViewModel, service: MusicService, onto existing: CommandPaletteManager? = nil
        ) throws -> (CommandPaletteManager, SpotiglassMenuCommands) {
            let manager: CommandPaletteManager
            if let existing {
                manager = existing
            } else {
                let keymap = CommandPaletteKeymapStore(settingsStore: SpotiglassSettingsStore(fileURL: makeCommandPaletteTestsTempSettingsURL()))
                try keymap.setBinding(
                    commandID: CommandPaletteCommandID.connectPlayback,
                    shortcut: try CommandShortcut(keystroke: "shift-cmd-k"),
                    replaceConflicting: true
                )
                manager = CommandPaletteManager(keymapStore: keymap)
                manager.isSignedIn = true
            }
            PlaylistBrowserCommandPaletteConfiguration.apply(
                to: manager,
                dependencies: .init(
                    viewModel: PlaylistBrowserViewModel(
                        api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
                        cache: MockBrowsingCache()
                    ),
                    playbackViewModel: playback,
                    queueViewModel: QueueViewModel(provider: playback.provider, playbackSession: playback),
                    commandPaletteManager: manager,
                    pinnedStore: PinnedItemsStore(cache: InMemoryPinnedItemsCache()),
                    catalogProvider: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
                    signOut: {},
                    syncUnifiedRefreshRouting: {},
                    canDisconnect: service == .spotify
                ),
                queueVisible: .constant(false),
                lyricsPresented: .constant(false)
            )
            let scene = SpotiglassSceneHost(commandPaletteManager: manager)
            let registry = SpotiglassSceneRegistry()
            registry.activate(scene)
            return (manager, menu(registry, keymap: manager.keymapStore, service: service))
        }
        func paletteIDs(_ manager: CommandPaletteManager) -> Set<String> {
            Set(manager.viewModel.staticItemsProvider().map(\.id))
        }
        // ⇧⌘K from the key monitor; `true` means the app took the keypress for Connect.
        func pressConnectShortcut(_ manager: CommandPaletteManager) -> Bool {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                windowNumber: 0, context: nil, characters: "K", charactersIgnoringModifiers: "k",
                isARepeat: false, keyCode: 40
            )!
            return manager.handleKeyEvent(event)
        }

        // Apple Music, playing: neither the menu, the palette nor the shortcut offers Connect,
        // and running the command anyway leaves the music alone.
        let appleMusic = PlaybackSessionViewModel(provider: AppleMusicPlaybackProvider(player: ScriptedAppleMusicPlayer()))
        appleMusic.deviceID = AppleMusicPlaybackProvider.deviceID
        appleMusic.setActivePlaybackDeviceID(AppleMusicPlaybackProvider.deviceID)
        appleMusic.setConnectionState(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))
        let (appleManager, appleMenu) = try wire(appleMusic, service: .appleMusic)
        XCTAssertNil(appleManager.connectPlayback)
        XCTAssertFalse(paletteIDs(appleManager).contains(CommandPaletteCommandID.connectPlayback))
        XCTAssertFalse(appleMenu.isConnectPlaybackOffered, "Playback › Connect Playback shows for Apple Music")
        // In an error the old command restarted the player session (while music plays, `start`
        // returns early anyway, so only this state shows whether Connect reaches the player).
        let failure = PlaybackSessionViewModel.playbackHostConnectionTimedOutError()
        appleMusic.setConnectionState(.error(failure))
        let appleMusicError = appleMusic.connectionState
        guard case .error = appleMusicError else { return XCTFail("Apple Music isn't in an error: \(appleMusicError)") }
        XCTAssertFalse(pressConnectShortcut(appleManager), "⇧⌘K is swallowed for a command that does nothing")
        appleManager.execute(commandID: CommandPaletteCommandID.connectPlayback)
        XCTAssertEqual(appleMusic.connectionState, appleMusicError)
        XCTAssertEqual(appleMusic.playbackHostReloadAttemptCount, 0, "Connect restarted the Apple Music session")

        // Spotify keeps Connect Playback in the menu, the palette and the shortcut.
        let spotify = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander())
        )
        let (spotifyManager, spotifyMenu) = try wire(spotify, service: .spotify)
        XCTAssertNotNil(spotifyManager.connectPlayback)
        XCTAssertTrue(paletteIDs(spotifyManager).contains(CommandPaletteCommandID.connectPlayback))
        XCTAssertTrue(spotifyMenu.isConnectPlaybackOffered)
        // ⇧⌘K after an error reloads the web player, as before.
        spotify.setConnectionState(.error(failure))
        XCTAssertTrue(pressConnectShortcut(spotifyManager))
        XCTAssertEqual(spotify.connectionState, .connecting)
        XCTAssertEqual(spotify.playbackHostReloadAttemptCount, 1)

        // Switching the window to Apple Music and back rewires the same manager each way.
        let (_, switchedToAppleMusic) = try wire(appleMusic, service: .appleMusic, onto: spotifyManager)
        XCTAssertFalse(spotifyManager.canConnectPlayback, "Spotify's Connect outlives the switch to Apple Music")
        XCTAssertFalse(switchedToAppleMusic.isConnectPlaybackOffered)
        XCTAssertFalse(pressConnectShortcut(spotifyManager))
        XCTAssertFalse(paletteIDs(spotifyManager).contains(CommandPaletteCommandID.connectPlayback))
        let (_, switchedBack) = try wire(spotify, service: .spotify, onto: spotifyManager)
        XCTAssertTrue(switchedBack.isConnectPlaybackOffered)
        XCTAssertTrue(paletteIDs(spotifyManager).contains(CommandPaletteCommandID.connectPlayback))

        // With every window closed the menu follows the selected service.
        let noWindow = SpotiglassSceneRegistry()
        XCTAssertFalse(menu(noWindow, keymap: spotifyManager.keymapStore, service: .appleMusic).isConnectPlaybackOffered)
        XCTAssertTrue(menu(noWindow, keymap: spotifyManager.keymapStore, service: .spotify).isConnectPlaybackOffered)
    }

    func testApplyWiresCallbacksWithoutHostingView() async throws {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "One")])],
            trackResults: [:]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI()), playbackSession: playback)
        let manager = CommandPaletteManager()
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "u1")
        var queueVisible = false
        var lyricsVisible = false
        PlaylistBrowserCommandPaletteConfiguration.apply(
            to: manager,
            dependencies: .init(
                viewModel: viewModel,
                playbackViewModel: playback,
                queueViewModel: queue,
                commandPaletteManager: manager,
                pinnedStore: store,
                catalogProvider: SpotifyAPIClient(
                    tokenProvider: StaticSpotifyAccessTokenProvider(token: "tok"),
                    httpClient: QueueHTTPClient([
                        .json(#"{"tracks":{"items":[]},"artists":{"items":[]},"albums":{"items":[]},"playlists":{"items":[]}}"#),
                    ])
                ),
                signOut: {},
                syncUnifiedRefreshRouting: {}
            ),
            queueVisible: Binding(get: { queueVisible }, set: { queueVisible = $0 }),
            lyricsPresented: Binding(get: { lyricsVisible }, set: { lyricsVisible = $0 })
        )

        XCTAssertTrue(manager.isSignedIn)
        XCTAssertFalse(manager.canTogglePlayback)
        playback.deviceID = "device-1"
        playback.setConnectionState(.ready(deviceID: "device-1"))
        XCTAssertTrue(manager.canTogglePlayback)
        manager.execute(commandID: CommandPaletteCommandID.toggleLyrics)
        XCTAssertFalse(lyricsVisible)
        playback.setConnectionState(.playing(
            PlaybackNowPlaying(
                name: "Song",
                artists: ["Artist"],
                albumName: "Album",
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 180_000,
                positionMilliseconds: 0,
                uri: "spotify:track:lyrics-config"
            )
        ))
        manager.toggleQueue?()
        XCTAssertTrue(queueVisible)
        manager.execute(commandID: CommandPaletteCommandID.toggleLyrics)
        XCTAssertTrue(lyricsVisible)
        manager.filterByArtist?("Artist")
        XCTAssertEqual(manager.viewModel.query, "Artist", "filterByArtist should update palette query")

        await manager.openPlaylist?("p1")
        XCTAssertEqual(viewModel.sidebarSelection, .playlist("p1"))

        let results = try await manager.spotifySearch?("ab", .tracks)
        XCTAssertNotNil(results)
    }

    func testPaletteSearchUsesInjectedEnvironment() async throws {
        let viewModel = PlaylistBrowserViewModel(
            api: MockBrowsingAPI(playlistResults: [.success([])], trackResults: [:]),
            cache: MockBrowsingCache()
        )
        let queue = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI()),
            playbackSession: PlaybackSessionViewModel(
                provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        )
        let manager = CommandPaletteManager()
        var pinnedIDs: Set<String> = []
        let http = QueueHTTPClient([
            .json(#"{"tracks":{"items":[]},"artists":{"items":[]},"albums":{"items":[]},"playlists":{"items":[]}}"#),
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "tok"),
            httpClient: http
        )
        let results = try await PlaylistBrowserCommandPaletteConfiguration.paletteSearch(
            query: "test",
            category: .tracks,
            catalogProvider: client,
            commandPaletteManager: manager,
            viewModel: viewModel,
            queueViewModel: queue,
            isPinnedByID: { pinnedIDs.contains($0) },
            pin: { pinnedIDs.insert($0.id) },
            unpin: { pinnedIDs.remove($0) },
            otherPinIDs: { _ in [] }
        )
        XCTAssertTrue(results.tracks.isEmpty)
    }
}

