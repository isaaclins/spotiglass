import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserShellViewsTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testMutualExclusionWidthStaticHelper() {
        let comfortable = SpotiglassDesign.dualSidebarComfortableMinWidth
        XCTAssertTrue(PlaylistBrowserView.mutualExclusionWidth(for: comfortable - 100))
        XCTAssertFalse(PlaylistBrowserView.mutualExclusionWidth(for: comfortable + 100))
    }

    func testPlaylistBrowserSidebarHosts() async throws {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Daily")])],
            trackResults: [:]
        )
        let browserVM = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await browserVM.load()
        let playbackVM = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "user")
        let liked = PlaylistRowViewModel(likedSongsOwnerDisplay: "You", totalTrackCount: nil, artworkURL: nil)
        let summary: (PlaylistRowViewModel) -> SpotifyPlaylistSummary = { row in
            SpotifyPlaylistSummary(
                id: row.id, name: row.title, ownerName: row.owner,
                imageURL: row.artworkURL, trackCount: 0, snapshotID: row.snapshotID
            )
        }
        let sidebar = PlaylistBrowserSidebar(
            viewModel: browserVM,
            playbackViewModel: playbackVM,
            libraryRows: [.home],
            libraryDropInsertionIndex: .constant(nil),
            libraryRowFramesByToken: .constant([:]),
            dragPreviewState: PinnedDragPreviewState.shared,
            likedSongsStubRow: liked,
            playlistSummaryFromRow: summary,
            onLibraryAppear: {},
            onSidebarListSelectionChange: { _, _ in },
            handlePinnedTransferDrop: { _, _ in false },
            handleLibraryTransferDrop: { _, _ in false }
        )
        .environmentObject(store)
        ViewTestHost.host(sidebar, size: CGSize(width: 280, height: 480))
        XCTAssertNoThrow(try sidebar.inspect().find(text: "Library"))
        XCTAssertNoThrow(try sidebar.inspect().find(text: "Daily"))
    }

    func testDetailWithQueueSplitHostsMainColumn() throws {
        let browserVM = PlaylistBrowserViewModel(
            api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
            cache: MockBrowsingCache()
        )
        let playbackVM = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        let queueVM = QueueViewModel(
            playbackAPI: MockPlaybackAPI(),
            playbackSession: playbackVM
        )
        let split = PlaylistBrowserDetailWithQueueSplit(
            unifiedRefreshFocus: .constant(.mainContent),
            isQueueVisible: false
        ) {
            PlaylistBrowserMainDetailColumn(
                viewModel: browserVM,
                playbackViewModel: playbackVM,
                queueViewModel: queueVM,
                pendingPlaylistListScrollRestoreID: .constant(nil),
                detailLastVisibleTrackID: .constant(nil),
                currentPlaybackURI: nil,
                isCurrentlyPlaying: false,
                hasPlaybackDevice: false
            )
        } queueColumn: {
            Text("Queue")
        }
        .environmentObject(LyricsOverlayController())
        ViewTestHost.host(split, size: CGSize(width: 640, height: 400))
        XCTAssertNoThrow(try split.inspect())
    }

    func testPinnedSidebarLibraryRowHosts() throws {
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "pin", name: "Pinned")
        let item = PinnedItem.playlist(playlist)
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "u1")
        store.pin(item)
        let row = PinnedSidebarLibraryRow(item: item, isSelected: false)
            .environmentObject(store)
        ViewTestHost.host(row, size: CGSize(width: 240, height: 44))
        XCTAssertNoThrow(try row.inspect().find(text: "Pinned"))
    }

    func testMainDetailColumnHostsLoadingState() throws {
        let browserVM = PlaylistBrowserViewModel(
            api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
            cache: MockBrowsingCache()
        )
        browserVM.detailState = .loading
        let playbackVM = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        let queueVM = QueueViewModel(playbackAPI: MockPlaybackAPI(), playbackSession: playbackVM)
        let column = PlaylistBrowserMainDetailColumn(
            viewModel: browserVM,
            playbackViewModel: playbackVM,
            queueViewModel: queueVM,
            pendingPlaylistListScrollRestoreID: .constant(nil),
            detailLastVisibleTrackID: .constant(nil),
            currentPlaybackURI: nil,
            isCurrentlyPlaying: false,
            hasPlaybackDevice: false
        )
        .environmentObject(LyricsOverlayController())
        ViewTestHost.host(column, size: CGSize(width: 720, height: 520))
        ViewTestHost.assertFindText("Loading…", in: column)
    }

    func testPlaylistBrowserViewHostsShell() async throws {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Focus")])],
            trackResults: [:]
        )
        let browserVM = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await browserVM.load()
        let tokens = ShellTestTokenProvider()
        let view = PlaylistBrowserView(
            viewModel: browserVM,
            playbackTokenProvider: tokens,
            searchTokenProvider: tokens,
            commandPaletteManager: CommandPaletteManager(),
            signOut: {}
        )
        .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
        .environmentObject(LyricsOverlayController())
        let controller = ViewTestHost.host(view, size: CGSize(width: 960, height: 640))
        XCTAssertNoThrow(try view.inspect().find(text: "Focus"))

        controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 640)
        controller.view.layoutSubtreeIfNeeded()
        AppKitTestSupport.pumpRunLoop(for: 0.15)
        XCTAssertTrue(PlaylistBrowserView.mutualExclusionWidth(for: 400))
    }

}

@MainActor
private final class ShellTestTokenProvider: PlaybackAccessTokenProviding, SpotifyAccessTokenProviding {
    func playbackAccessToken() async throws -> String { "shell-token" }
    func refreshedPlaybackAccessToken() async throws -> String { "shell-token" }
    func accessToken() async throws -> String { "shell-token" }
    func refreshAccessTokenAfterUnauthorized() async throws -> String { "shell-token" }
}
