import SwiftUI
import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserCommandPaletteConfigurationTests: XCTestCase {
    /// Apple Music browsing has no player yet. "Connect playback" (and its ⇧⌘K shortcut) must
    /// not start the Spotify player behind it; Spotify keeps the command.
    func testConnectPlaybackIsOnlyWiredWhenTheServiceHasPlayback() throws {
        func wire(playbackAvailable: Bool) -> CommandPaletteManager {
            let viewModel = PlaylistBrowserViewModel(
                api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
                cache: MockBrowsingCache()
            )
            let playback = PlaybackSessionViewModel(
                playbackAPI: MockPlaybackAPI(),
                webCommander: MockWebPlaybackCommander()
            )
            let manager = CommandPaletteManager()
            PlaylistBrowserCommandPaletteConfiguration.apply(
                to: manager,
                dependencies: .init(
                    viewModel: viewModel,
                    playbackViewModel: playback,
                    queueViewModel: QueueViewModel(playbackAPI: MockPlaybackAPI(), playbackSession: playback),
                    commandPaletteManager: manager,
                    pinnedStore: PinnedItemsStore(cache: InMemoryPinnedItemsCache()),
                    catalogProvider: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
                    signOut: {},
                    syncUnifiedRefreshRouting: {},
                    isPlaybackAvailable: playbackAvailable
                ),
                queueVisible: .constant(false),
                lyricsPresented: .constant(false)
            )
            return manager
        }
        XCTAssertNotNil(wire(playbackAvailable: true).connectPlayback)
        XCTAssertNil(wire(playbackAvailable: false).connectPlayback)
    }

    func testApplyWiresCallbacksWithoutHostingView() async throws {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "One")])],
            trackResults: [:]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()
        let playback = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        let queue = QueueViewModel(playbackAPI: MockPlaybackAPI(), playbackSession: playback)
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
            playbackAPI: MockPlaybackAPI(),
            playbackSession: PlaybackSessionViewModel(
                playbackAPI: MockPlaybackAPI(),
                webCommander: MockWebPlaybackCommander()
            )
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
            unpin: { pinnedIDs.remove($0) }
        )
        XCTAssertTrue(results.tracks.isEmpty)
    }
}

