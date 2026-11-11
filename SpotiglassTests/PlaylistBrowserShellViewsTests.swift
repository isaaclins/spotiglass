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
        let sidebar = SpotiglassDesign.sidebarWidth
        let comfortable = SpotiglassDesign.dualSidebarComfortableMinWidth(sidebarWidth: sidebar)
        XCTAssertTrue(PlaylistBrowserView.mutualExclusionWidth(for: comfortable - 100, sidebarWidth: sidebar))
        XCTAssertFalse(PlaylistBrowserView.mutualExclusionWidth(for: comfortable + 100, sidebarWidth: sidebar))
    }

    func testBrowserScenesShareTheAppScopedPlaybackHost() {
        let tokens = ShellTestTokenProvider()
        let playbackHost = SpotiglassPlaybackHost(tokenProvider: tokens)
        let first = PlaylistBrowserView(
            viewModel: PlaylistBrowserViewModel(
                api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
                cache: MockBrowsingCache()
            ),
            playbackHost: playbackHost,
            catalogProvider: SpotifyAPIClient(tokenProvider: tokens, getResponseCache: .shared),
            commandPaletteManager: CommandPaletteManager(),
            signOut: {}
        )
        let second = PlaylistBrowserView(
            viewModel: PlaylistBrowserViewModel(
                api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
                cache: MockBrowsingCache()
            ),
            playbackHost: playbackHost,
            catalogProvider: SpotifyAPIClient(tokenProvider: tokens, getResponseCache: .shared),
            commandPaletteManager: CommandPaletteManager(),
            signOut: {}
        )

        XCTAssertTrue(first.playbackViewModel === playbackHost.playbackViewModel)
        XCTAssertTrue(second.playbackViewModel === playbackHost.playbackViewModel)
    }

    func testPlaylistBrowserSidebarHosts() async throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Daily")])],
            trackResults: [:]
        )
        let browserVM = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await browserVM.load()
        let playbackVM = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "user")
        let liked = PlaylistRowViewModel(likedSongsOwnerDisplay: "You", totalTrackCount: nil, artworkURL: nil)
        let summary: (PlaylistRowViewModel) -> MusicPlaylistSummary = { row in
            MusicPlaylistSummary(
                id: row.id, name: row.title,
                ownerID: "test-owner", ownerName: row.owner,
                imageURL: row.artworkURL, trackCount: 0, snapshotID: row.snapshotID
            )
        }
        let sidebar = PlaylistBrowserSidebar(
            viewModel: browserVM,
            playbackViewModel: playbackVM,
            libraryRows: [.home],
            likedSongsStubRow: liked,
            playlistSummaryFromRow: summary,
            onLibraryAppear: {},
            onSidebarListSelectionChange: { _, _ in },
            moveLibraryRows: { _, _ in },
            pinDroppedTransfers: { _ in false }
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
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        let queueVM = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI()),
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
                hasPlaybackDevice: false
            )
        } queueColumn: {
            Text("Queue")
        }
        .environmentObject(LyricsOverlayController())
        ViewTestHost.host(split, size: CGSize(width: 640, height: 400))
        XCTAssertNoThrow(try split.inspect())
    }

    func testPinnedSidebarLibraryRowHostsAndDragLifecycle() throws {
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
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        let queueVM = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI()), playbackSession: playbackVM)
        let column = PlaylistBrowserMainDetailColumn(
            viewModel: browserVM,
            playbackViewModel: playbackVM,
            queueViewModel: queueVM,
            pendingPlaylistListScrollRestoreID: .constant(nil),
            detailLastVisibleTrackID: .constant(nil),
            hasPlaybackDevice: false
        )
        .environmentObject(LyricsOverlayController())
        ViewTestHost.host(column, size: CGSize(width: 720, height: 520))
        ViewTestHost.assertFindText("Loading…", in: column)
    }

    func testPlaylistBrowserViewHostsShell() async throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Focus")])],
            trackResults: ["p1": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]]
        )
        let browserVM = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await browserVM.load()
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "u1")
        store.pin(PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "pin", name: "Pinned")))
        let palette = CommandPaletteManager()
        let tokens = ShellTestTokenProvider()
        let playbackHost = SpotiglassPlaybackHost(tokenProvider: tokens)
        let view = PlaylistBrowserView(
            viewModel: browserVM,
            playbackHost: playbackHost,
            catalogProvider: SpotifyAPIClient(tokenProvider: tokens, getResponseCache: .shared),
            commandPaletteManager: palette,
            signOut: {}
        )
        .environmentObject(store)
        .environmentObject(LyricsOverlayController())
        let controller = ViewTestHost.host(view, size: CGSize(width: 960, height: 640))
        AppKitTestSupport.pumpRunLoop(for: 0.4)
        XCTAssertNoThrow(try view.inspect().find(text: "Focus"))
        XCTAssertTrue(palette.isSignedIn)

        controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 640)
        controller.view.layoutSubtreeIfNeeded()
        AppKitTestSupport.pumpRunLoop(for: 0.2)
        XCTAssertTrue(PlaylistBrowserView.mutualExclusionWidth(for: 400, sidebarWidth: SpotiglassDesign.sidebarWidth))
    }

    /// #501: the toolbar is outside the window's content, so hiding the page behind the open
    /// palette left Queue, Refresh and Back reachable for VoiceOver. This reads the real window
    /// through the Accessibility API: the toolbar's buttons are there with the palette closed,
    /// gone while it is open, and back after it closes.
    func testToolbarIsOutOfVoiceOverReachWhileThePaletteIsOpen() async throws {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Focus")])],
            trackResults: ["p1": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]]
        )
        let browserVM = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await browserVM.load()
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "u1")
        let tokens = ShellTestTokenProvider()
        let palette = PalettePresentation()
        let view = PalettePresentationHost(presentation: palette) {
            PlaylistBrowserView(
                viewModel: browserVM,
                playbackHost: SpotiglassPlaybackHost(tokenProvider: tokens),
                catalogProvider: SpotifyAPIClient(tokenProvider: tokens, getResponseCache: .shared),
                commandPaletteManager: CommandPaletteManager(),
                signOut: {}
            )
        }
        .environmentObject(store)
        .environmentObject(try ViewTestHost.makeSettingsStore())
        .environmentObject(LyricsOverlayController())
        let controller = ViewTestHost.host(view, size: CGSize(width: 1_040, height: 680))
        // The app's window shows the browser's toolbar; a bare hosting controller doesn't.
        controller.sizingOptions = []
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = try XCTUnwrap(controller.view.window)
        window.setContentSize(CGSize(width: 1_040, height: 680))
        // Only a window on screen is in the app's accessibility tree.
        window.makeKeyAndOrderFront(nil)
        // Queue and Disconnect sit in two different toolbar items.
        let toolbarButtons = ["browser.queue", "browser.disconnect"].map { "AXButton: \(SpotiglassL10n.string($0))" }
        let reachesToolbar = { (elements: [String]) in toolbarButtons.allSatisfy(elements.contains) }
        let reachesAnyToolbarButton = { (elements: [String]) in toolbarButtons.contains(where: elements.contains) }

        let closed = try AppKitTestSupport.settledAccessibilityElements(in: window, until: reachesToolbar)
        XCTAssertTrue(reachesToolbar(closed), "Queue and Disconnect should be reachable: \(closed)")

        palette.isPresented = true
        let open = try AppKitTestSupport.settledAccessibilityElements(in: window) { !reachesAnyToolbarButton($0) }
        XCTAssertFalse(reachesAnyToolbarButton(open), "VoiceOver still reaches the toolbar behind the palette: \(open)")

        palette.isPresented = false
        let reopened = try AppKitTestSupport.settledAccessibilityElements(in: window, until: reachesToolbar)
        XCTAssertTrue(reachesToolbar(reopened), "The toolbar should be back after the palette closes: \(reopened)")
    }

    func testLibraryHomeRowHosts() throws {
        let row = LibraryHomeSidebarRow()
        ViewTestHost.host(row, size: CGSize(width: 220, height: 36))
        ViewTestHost.assertFindLocalizedText("browser.home", in: row)
    }

    func testPlaylistBrowserSidebarWithLibraryRowsHosts() throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let browserVM = PlaylistBrowserViewModel(
            api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
            cache: MockBrowsingCache()
        )
        let playbackVM = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "u1")
        let liked = PlaylistRowViewModel(likedSongsOwnerDisplay: "You", totalTrackCount: nil, artworkURL: nil)
        let sidebar = PlaylistBrowserSidebar(
            viewModel: browserVM,
            playbackViewModel: playbackVM,
            libraryRows: [.home],
            likedSongsStubRow: liked,
            playlistSummaryFromRow: { row in
                MusicPlaylistSummary(
                    id: row.id, name: row.title,
                ownerID: "test-owner", ownerName: row.owner,
                    imageURL: row.artworkURL, trackCount: 0, snapshotID: row.snapshotID
                )
            },
            onLibraryAppear: {},
            onSidebarListSelectionChange: { _, _ in },
            moveLibraryRows: { _, _ in },
            pinDroppedTransfers: { _ in false }
        )
        .environmentObject(store)
        ViewTestHost.host(sidebar, size: CGSize(width: 280, height: 520))
        XCTAssertNoThrow(try sidebar.inspect().find(text: "Library"))
    }

    func testDetailColumnWithLoadedPlaylistHostsTracks() async throws {
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Loaded")
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlist])],
            trackResults: ["p1": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]]
        )
        let browserVM = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await browserVM.load()
        browserVM.sidebarSelection = .playlist("p1")
        browserVM.detailState = .loading

        let playbackVM = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        let queueVM = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI()), playbackSession: playbackVM)
        let column = PlaylistBrowserMainDetailColumn(
            viewModel: browserVM,
            playbackViewModel: playbackVM,
            queueViewModel: queueVM,
            pendingPlaylistListScrollRestoreID: .constant(nil),
            detailLastVisibleTrackID: .constant(nil),
            hasPlaybackDevice: true
        )
        .environmentObject(LyricsOverlayController())
        ViewTestHost.host(column, size: CGSize(width: 720, height: 520))
        AppKitTestSupport.pumpRunLoop(for: 0.15)
        XCTAssertNoThrow(try column.inspect())
    }


    /// The real browser, hosted, on a playlist page with the lyrics open over it.
    private func hostBrowserWithLyricsOpen() async throws -> (
        root: NSView, browser: PlaylistBrowserViewModel, lyricsOverlay: LyricsOverlayController
    ) {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Focus")])],
            trackResults: ["p1": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]]
        )
        let browserVM = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await browserVM.load()
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "u1")
        let settings = try ViewTestHost.makeSettingsStore()
        let lyricsOverlay = LyricsOverlayController()
        let palette = CommandPaletteManager()
        let tokens = ShellTestTokenProvider()
        let playbackHost = SpotiglassPlaybackHost(tokenProvider: tokens)
        let view = PlaylistBrowserView(
            viewModel: browserVM,
            playbackHost: playbackHost,
            catalogProvider: SpotifyAPIClient(tokenProvider: tokens, getResponseCache: .shared),
            commandPaletteManager: palette,
            signOut: {}
        )
        .environmentObject(store)
        .environmentObject(settings)
        .environmentObject(lyricsOverlay)
        let controller = ViewTestHost.host(view, size: CGSize(width: 1_100, height: 720))
        AppKitTestSupport.pumpRunLoop(for: 0.4)

        // A paused track: the lyrics need one, and paused keeps the browser from prefetching
        // real lyrics over the network. The overlay gets a lyrics model that never fetches.
        let playback = playbackHost.playbackViewModel
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(Self.lyricsTrack, isPaused: true, nextTracks: []))
        let queue = QueueViewModel(
            provider: playbackHost.playbackProvider,
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000
        )
        lyricsOverlay.attach(
            playback: playback,
            queue: queue,
            lyrics: ImmersiveLyricsViewModel { _ in .instrumental },
            navigateToArtist: { _ in },
            navigateToAlbum: { _, _, _ in }
        )
        lyricsOverlay.isPresented = true
        let root = controller.view
        root.frame = CGRect(x: 0, y: 0, width: 1_100, height: 720)
        root.layoutSubtreeIfNeeded()
        AppKitTestSupport.pumpRunLoop(for: 0.6)
        root.layoutSubtreeIfNeeded()
        return (root, browserVM, lyricsOverlay)
    }

    /// #438: the lyrics used to cover the whole window, player bar included, so while they were
    /// open there was no play/pause, skip or scrubber. The lyrics now take the main column only.
    /// This hosts the real browser with the lyrics open and checks that the lyrics are there,
    /// that the player bar's buttons sit outside them and that a click on the bar reaches the
    /// bar, not the lyrics.
    func testLyricsLeaveThePlayerBarVisibleAndUsable() async throws {
        let hosted = try await hostBrowserWithLyricsOpen()
        let root = hosted.root
        let lyricsOverlay = hosted.lyricsOverlay
        XCTAssertTrue(lyricsOverlay.isPresented, "the lyrics closed by themselves")
        let lyricsSurface = try XCTUnwrap(
            Self.firstView(in: root) { String(describing: type(of: $0)).hasPrefix("LyricsOverlayFocusContainerView") },
            "the browser shows no lyrics while they are open"
        )
        let lyricsFrame = lyricsSurface.convert(lyricsSurface.bounds, to: nil)
        XCTAssertGreaterThan(
            lyricsFrame.height, 200,
            "the lyrics are open but have no room: \(lyricsFrame) in \(root.frame)"
        )

        let barLyricsButton = try XCTUnwrap(
            Self.allNSButtons(in: root).first {
                $0.accessibilityLabel() == SpotiglassL10n.string("playback.controls.lyrics")
                    && !$0.isDescendant(of: lyricsSurface)
            },
            "the player bar is gone while the lyrics are open"
        )
        let barFrame = barLyricsButton.convert(barLyricsButton.bounds, to: nil)
        XCTAssertGreaterThan(barFrame.width, 0)
        XCTAssertFalse(
            barFrame.intersects(lyricsFrame),
            "the lyrics cover the player bar: bar \(barFrame), lyrics \(lyricsFrame)"
        )

        // `hitTest` takes a point in the receiver's superview's coordinates.
        let container = try XCTUnwrap(root.superview)
        let clickPoint = container.convert(NSPoint(x: barFrame.midX, y: barFrame.midY), from: nil)
        let hit = try XCTUnwrap(root.hitTest(clickPoint), "nothing answers a click on the player bar")
        XCTAssertFalse(hit.isDescendant(of: lyricsSurface), "a click on the player bar lands in the lyrics")
    }

    /// #438: with the sidebar, the queue and the player bar usable next to the lyrics, picking
    /// another page there loaded it out of sight under the lyrics, which stayed open. Going
    /// somewhere else closes them; a change that stays on the same page does not.
    func testGoingToAnotherPageClosesTheLyrics() async throws {
        let hosted = try await hostBrowserWithLyricsOpen()
        XCTAssertTrue(hosted.lyricsOverlay.isPresented)

        // Same page, same trail: the lyrics stay.
        hosted.browser.sidebarSelection = hosted.browser.sidebarSelection
        AppKitTestSupport.pumpRunLoop(for: 0.2)
        XCTAssertTrue(hosted.lyricsOverlay.isPresented, "the lyrics closed without going anywhere")

        let elsewhere: SidebarSelection = hosted.browser.sidebarSelection == .likedSongs ? .home : .likedSongs
        await hosted.browser.selectSidebar(elsewhere)
        AppKitTestSupport.pumpRunLoop(for: 0.3)
        XCTAssertFalse(hosted.lyricsOverlay.isPresented, "\(elsewhere) loaded under the lyrics, which stayed open")
    }

    func testCoveredPageIgnoresTitlesAndCovers() {
        let browser = PlaylistBrowserViewModel(
            api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
            cache: MockBrowsingCache()
        )
        browser.breadcrumbPath = [Self.albumCrumb(artwork: nil)]
        let before = LyricsCoveredPage(browser)
        browser.breadcrumbPath = [Self.albumCrumb(artwork: URL(string: "https://example.com/large.jpg"))]
        XCTAssertEqual(LyricsCoveredPage(browser), before, "a sharper cover counted as another page")
        browser.breadcrumbPath = [Self.albumCrumb(artwork: nil), Self.albumCrumb(id: "a2", artwork: nil)]
        XCTAssertNotEqual(LyricsCoveredPage(browser), before)
    }

    /// A pinned song selects its pinned row for a moment, plays, and selects the previous row
    /// again; that round trip stays on the page, so the lyrics stay open.
    func testPinnedSongRoundTripStaysOnThePage() {
        let browser = PlaylistBrowserViewModel(
            api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
            cache: MockBrowsingCache()
        )
        browser.sidebarSelection = .playlist("p1")
        let onPlaylist = LyricsCoveredPage(browser)
        browser.sidebarSelection = .pinnedItem("pin-song")
        let onPinnedRow = LyricsCoveredPage(browser)
        XCTAssertFalse(onPinnedRow.isAnotherPage(than: onPlaylist), "selecting a pinned song counted as leaving")
        browser.sidebarSelection = .playlist("p1")
        XCTAssertFalse(LyricsCoveredPage(browser).isAnotherPage(than: onPinnedRow))

        browser.sidebarSelection = .playlist("p2")
        XCTAssertTrue(LyricsCoveredPage(browser).isAnotherPage(than: onPlaylist))
        browser.sidebarSelection = .pinnedItem("pin-album")
        browser.breadcrumbPath = [Self.albumCrumb(artwork: nil)]
        XCTAssertTrue(LyricsCoveredPage(browser).isAnotherPage(than: onPlaylist), "a pinned album opened under the lyrics")
    }

    private static func albumCrumb(id: String = "a1", artwork: URL?) -> BrowserBreadcrumb {
        BrowserBreadcrumb(
            id: UUID(),
            label: "Album",
            systemImage: "square.stack",
            kind: .album(id: id, title: "Album", subtitle: "Artist", artworkURL: artwork)
        )
    }

    private static let lyricsTrack = PlaybackNowPlaying(
        name: "Title",
        artists: ["Artist"],
        albumName: "Album",
        albumID: "album-1",
        albumArtURL: nil,
        durationMilliseconds: 180_000,
        positionMilliseconds: 12_000,
        uri: "spotify:track:lyricsShellTrack"
    )

    private static func firstView(in view: NSView, where matches: (NSView) -> Bool) -> NSView? {
        if matches(view) { return view }
        for subview in view.subviews {
            if let found = firstView(in: subview, where: matches) { return found }
        }
        return nil
    }

    private static func allNSButtons(in view: NSView) -> [NSButton] {
        let own = view as? NSButton
        return (own.map { [$0] } ?? []) + view.subviews.flatMap { allNSButtons(in: $0) }
    }
}

@MainActor
private final class ShellTestTokenProvider: PlaybackAccessTokenProviding, SpotifyAccessTokenProviding {
    func playbackAccessToken() async throws -> String { "shell-token" }
    func refreshedPlaybackAccessToken() async throws -> String { "shell-token" }
    func accessToken() async throws -> String { "shell-token" }
    func refreshAccessTokenAfterUnauthorized(rejectedToken: String) async throws -> String { "shell-token" }
}

/// Stands in for the root view's palette state: the browser reads it from the environment.
@MainActor
private final class PalettePresentation: ObservableObject {
    @Published var isPresented = false
}

private struct PalettePresentationHost<Content: View>: View {
    @ObservedObject var presentation: PalettePresentation
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().environment(\.isCommandPalettePresented, presentation.isPresented)
    }
}
