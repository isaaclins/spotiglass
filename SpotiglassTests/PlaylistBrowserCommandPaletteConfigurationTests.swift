import SwiftUI
import XCTest

@testable import Spotiglass

@MainActor
final class PlaylistBrowserCommandPaletteConfigurationTests: XCTestCase {
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
                spotifySearchClient: SpotifyAPIClient(
                    tokenProvider: StaticSpotifyAccessTokenProvider(token: "tok"),
                    httpClient: QueueHTTPClient([
                        .json(
                            #"{"tracks":{"items":[]},"artists":{"items":[]},"albums":{"items":[]},"playlists":{"items":[]}}"#
                        )
                    ])
                ),
                signOut: {},
                syncUnifiedRefreshRouting: {}
            ),
            queueVisible: Binding(get: { queueVisible }, set: { queueVisible = $0 }),
            lyricsPresented: Binding(get: { lyricsVisible }, set: { lyricsVisible = $0 })
        )

        XCTAssertTrue(manager.isSignedIn)
        manager.toggleQueue?()
        XCTAssertTrue(queueVisible)
        manager.toggleLyrics?()
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
            .json(#"{"tracks":{"items":[]},"artists":{"items":[]},"albums":{"items":[]},"playlists":{"items":[]}}"#)
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "tok"),
            httpClient: http
        )
        let results = try await PlaylistBrowserCommandPaletteConfiguration.paletteSearch(
            query: "test",
            category: .tracks,
            spotifySearchClient: client,
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
