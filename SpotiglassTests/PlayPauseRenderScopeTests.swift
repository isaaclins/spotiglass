import AppKit
import SwiftUI
import XCTest
@testable import Spotiglass

/// Play/pause and a new track re-render only what shows them (#422): the bar, the playing row
/// (old and new) and the sidebar's now-playing playlist. Before, every view observing the player
/// session ran its body again: the browser, the sidebar, the detail column and every visible
/// track and playlist row, though only the playing ones looked any different.
@MainActor
final class PlayPauseRenderScopeTests: XCTestCase {
    override func tearDown() {
        ViewBodyTally.counts = nil
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    private static let trackIDs = (1...20).map { "t\($0)" }

    private static func nowPlaying(_ trackID: String) -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: "Track \(trackID)",
            artists: ["Artist"],
            albumName: "Album",
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 10_000,
            uri: "spotify:track:\(trackID)"
        )
    }

    /// The real browser window with a 20-track playlist open and its third track playing.
    private func hostBrowserPlaying() async throws -> PlaybackSessionViewModel {
        let api = MockBrowsingAPI(
            playlistResults: [.success([
                PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Focus"),
                PlaylistBrowsingTestFixtures.playlist(id: "p2", name: "Daily"),
                PlaylistBrowsingTestFixtures.playlist(id: "p3", name: "Gym"),
            ])],
            trackResults: ["p1": [.success(Self.trackIDs.map(PlaylistBrowsingTestFixtures.track(id:)))]]
        )
        let browserVM = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await browserVM.load()
        await browserVM.selectPlaylist(id: "p1")
        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(browserVM.detailState).count, 20)

        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "u1")
        let tokens = RenderScopeTokenProvider()
        let playbackHost = SpotiglassPlaybackHost(tokenProvider: tokens)
        let playback = playbackHost.playbackViewModel
        let view = PlaylistBrowserView(
            viewModel: browserVM,
            playbackHost: playbackHost,
            catalogProvider: SpotifyAPIClient(tokenProvider: tokens, getResponseCache: .shared),
            commandPaletteManager: CommandPaletteManager(),
            signOut: {}
        )
        .environmentObject(store)
        .environmentObject(LyricsOverlayController())
        let controller = ViewTestHost.host(view, size: CGSize(width: 1_600, height: 1_400))
        AppKitTestSupport.pumpRunLoop(for: 0.5)
        // The browser starts at a width of zero and collapses the sidebar; a widening brings it
        // back, as it does when a real window opens.
        controller.view.window?.setContentSize(NSSize(width: 1_700, height: 1_400))
        AppKitTestSupport.pumpRunLoop(for: 0.5)

        playback.activePlaylistID = "p1"
        playback.setConnectionState(.playing(Self.nowPlaying("t3")))
        AppKitTestSupport.pumpRunLoop(for: 0.5)
        return playback
    }

    /// Runs `change` and returns which counted bodies ran because of it.
    private func bodies(after change: () -> Void) -> [String: Int] {
        ViewBodyTally.counts = [:]
        change()
        AppKitTestSupport.pumpRunLoop(for: 0.5)
        defer { ViewBodyTally.counts = nil }
        return ViewBodyTally.counts ?? [:]
    }

    private func trackRows(in counts: [String: Int]) -> Set<String> {
        Set(counts.keys.filter { $0.hasPrefix("TrackListRow:") }.map { String($0.dropFirst("TrackListRow:".count)) })
    }

    private func playlistRows(in counts: [String: Int]) -> Set<String> {
        Set(counts.keys.filter { $0.hasPrefix("PlaylistListRow:") }.map { String($0.dropFirst("PlaylistListRow:".count)) })
    }

    private func assertOnlyTheRowsChanged(
        _ counts: [String: Int],
        tracks: Set<String>,
        playlists: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for container in [
            "PlaylistBrowserView",
            "PlaylistBrowserSidebar",
            "PlaylistsSidebarSectionContent",
            "PlaylistBrowserMainDetailColumn",
            "PlaylistDetailContent",
        ] {
            XCTAssertNil(counts[container], "\(container) re-rendered", file: file, line: line)
        }
        XCTAssertEqual(trackRows(in: counts), tracks, "track rows that re-rendered", file: file, line: line)
        XCTAssertEqual(playlistRows(in: counts), playlists, "sidebar rows that re-rendered", file: file, line: line)
    }

    func testPlayPauseRerendersOnlyThePlayingRowAndThePlayingPlaylist() async throws {
        let playback = try await hostBrowserPlaying()
        let paused = bodies { playback.setConnectionState(.paused(Self.nowPlaying("t3"))) }
        assertOnlyTheRowsChanged(paused, tracks: ["t3"], playlists: ["p1"])

        let resumed = bodies { playback.setConnectionState(.playing(Self.nowPlaying("t3"))) }
        assertOnlyTheRowsChanged(resumed, tracks: ["t3"], playlists: ["p1"])
    }

    func testANewTrackRerendersOnlyTheOldAndTheNewPlayingRow() async throws {
        let playback = try await hostBrowserPlaying()

        let next = bodies { playback.setConnectionState(.playing(Self.nowPlaying("t4"))) }
        assertOnlyTheRowsChanged(next, tracks: ["t3", "t4"], playlists: [])

        // Starting another playlist moves the sidebar's playing mark from one row to the other.
        let otherPlaylist = bodies {
            playback.activePlaylistID = "p2"
            playback.setConnectionState(.playing(Self.nowPlaying("t5")))
        }
        assertOnlyTheRowsChanged(otherPlaylist, tracks: ["t4", "t5"], playlists: ["p1", "p2"])
    }
}

@MainActor
private final class RenderScopeTokenProvider: PlaybackAccessTokenProviding, SpotifyAccessTokenProviding {
    func playbackAccessToken() async throws -> String { "render-scope-token" }
    func refreshedPlaybackAccessToken() async throws -> String { "render-scope-token" }
    func accessToken() async throws -> String { "render-scope-token" }
    func refreshAccessTokenAfterUnauthorized(rejectedToken: String) async throws -> String { "render-scope-token" }
}

extension TrackRowPlaybackSource {
    /// A player that never connects: every row shows as not playing.
    static var nothingPlaying: TrackRowPlaybackSource {
        TrackRowPlaybackSource(session: PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander())))
    }
}
