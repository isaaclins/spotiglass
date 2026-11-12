import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Spotiglass

/// A window manager (Hammerspoon's `setFrame`, Rectangle, Magnet) resizes the window from code and
/// waits for every size it sets. Each size change made AppKit save the window frame to the app's
/// defaults, and the queue flag in `@AppStorage` re-ran the whole browser for every such write: its
/// sidebar, its page, its player bar and its toolbar, about 70 ms a step in a Release build where
/// Finder takes 15 (#473). A resize must only lay the window out again.
@MainActor
final class WindowResizeCostTests: XCTestCase {
    override func tearDown() {
        ViewBodyTally.counts = nil
        ViewTestHost.appStorageDefaults.removeObject(forKey: Self.frameKey)
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    /// Where AppKit saves a window's frame, here in the store the hosted views' `@AppStorage` reads.
    private static let frameKey = "NSWindow Frame SpotiglassTests.resize"

    private enum Page { case home, bigPlaylist }

    /// Hosts the real browser the way the app shows it: the library loaded once, both playlists
    /// in the sidebar and, for `.bigPlaylist`, a 500-song page with its rows drawn.
    private func hostBrowser(on page: Page) async throws -> NSWindow {
        let tracks = (0..<500).map { PlaylistBrowsingTestFixtures.track(id: "t\($0)") }
        let api = MockBrowsingAPI(
            playlistResults: [.success([
                PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Big"),
                PlaylistBrowsingTestFixtures.playlist(id: "p2", name: "Daily"),
            ])],
            trackResults: ["p1": [.success(tracks)]]
        )
        // Home as a Spotify account fills it: 20 top tracks and a shelf of recently played
        // albums, most of both off screen. Empty sections hid what a full Home costs (#473).
        api.topTracksHandler = { _, _ in Self.homeTracks(prefix: "top", count: Self.topTrackCount) }
        api.recentlyPlayedHandler = { _ in Self.homeTracks(prefix: "recent", count: Self.recentAlbumCount) }
        let browserVM = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        // As the browser's own `.task` loads it, so the hosted view doesn't load it again.
        await browserVM.loadIfNeeded()
        switch page {
        case .home:
            await browserVM.selectSidebar(.home)
            guard case let .loaded(top) = browserVM.homeTopTracks, case let .loaded(recent) = browserVM.homeRecentlyPlayed else {
                XCTFail("Home's sections didn't load: \(browserVM.homeTopTracks), \(browserVM.homeRecentlyPlayed)")
                throw CancellationError()
            }
            XCTAssertEqual(top.count, Self.topTrackCount)
            XCTAssertEqual(recent.count, Self.recentAlbumCount)
        case .bigPlaylist:
            await browserVM.selectPlaylist(id: "p1")
            XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(browserVM.detailState).count, tracks.count)
        }

        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "u1")
        // The live player bar, driven by a stand-in Spotify player: no web page and no network,
        // whose answers would arrive whenever they like in a test that fails on any re-render.
        let playbackHost = SpotiglassPlaybackHost(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander())
        )
        let playback = playbackHost.playbackViewModel
        playback.deviceID = "device-1"
        playback.hasTransferredPlaybackToCurrentDevice = true
        playback.setTransportStateKnown(true)
        playback.setConnectionState(.paused(PlaybackNowPlaying(
            name: "Midnight City", artists: ["M83"], albumName: "Hurry Up, We're Dreaming", albumID: nil,
            albumArtURL: nil, durationMilliseconds: 243_000, positionMilliseconds: 60_000, uri: "spotify:track:t1"
        )))
        let view = PlaylistBrowserView(
            viewModel: browserVM,
            playbackHost: playbackHost,
            catalogProvider: api,
            commandPaletteManager: CommandPaletteManager(),
            signOut: {}
        )
        .environmentObject(store)
        .environmentObject(LyricsOverlayController())
        ViewBodyTally.counts = [:]
        let controller = ViewTestHost.host(view, size: CGSize(width: 1_400, height: 900))
        let window = try XCTUnwrap(controller.view.window)
        // Each step waits for what it needs to see, not for a time: on a busy Mac the sidebar
        // rows came after a fixed 0.5 s (#533).
        let rendered = { (view: String) in ViewBodyTally.counts?[view] != nil }
        XCTAssertTrue(AppKitTestSupport.pumpRunLoop(until: { rendered("PlaybackControlsView") }), "the browser never rendered")
        // The browser starts at a width of zero and collapses the sidebar; a widening brings it
        // back, as it does when a real window opens.
        window.setContentSize(NSSize(width: 1_450, height: 900))

        // What is on screen before the resize, so the test can't pass on an empty window.
        // Built one statement at a time: as one expression the compiler gives up on it (CI, Xcode 26).
        typealias Expectation = (message: String, matches: (String) -> Bool)
        var onScreen: [Expectation] = [
            ("the live player bar isn't on screen", { $0 == "PlaybackControlsView" }),
            ("the sidebar doesn't list the playlist p1", { $0 == "PlaylistListRow:p1" }),
            ("the sidebar doesn't list the playlist p2", { $0 == "PlaylistListRow:p2" }),
        ]
        if page == .home {
            onScreen.append(("Home isn't on screen", { $0 == "HomeView" }))
            onScreen.append(("no recently played album on screen", { $0 == "HomeMediaCardView:recent-album-0" }))
        } else {
            onScreen.append(("no song rows on screen", { $0.hasPrefix("TrackListRow:") }))
        }
        let missing = { onScreen.filter { _, matches in !(ViewBodyTally.counts ?? [:]).keys.contains(where: matches) } }
        _ = AppKitTestSupport.pumpRunLoop(until: { missing().isEmpty })
        for (message, _) in missing() {
            XCTFail(message)
        }
        return window
    }

    private static let topTrackCount = 20
    private static let recentAlbumCount = 30

    /// Songs from `count` different albums, so each one is its own recently played card.
    nonisolated private static func homeTracks(prefix: String, count: Int) -> [MusicTrack] {
        (0..<count).map { index in
            MusicTrack(
                id: "\(prefix)-\(index)",
                name: "Song \(index)",
                artists: ["Artist \(index)"],
                albumArtworkURL: nil,
                albumName: "Album \(index)",
                albumID: "\(prefix)-album-\(index)",
                durationMilliseconds: 200_000,
                isExplicit: false,
                isPlayable: true,
                linkedFromID: nil,
                uri: "spotify:track:\(prefix)-\(index)"
            )
        }
    }

    /// One step of a window manager's animated resize: the new size, then the frame AppKit saves.
    private func resize(_ window: NSWindow, toWidth width: CGFloat, height: CGFloat) {
        window.setContentSize(NSSize(width: width, height: height))
        window.layoutIfNeeded()
        ViewTestHost.appStorageDefaults.set(window.frameDescriptor, forKey: Self.frameKey)
        // About the pace of Hammerspoon's 0.2 s animation in 12 steps.
        AppKitTestSupport.pumpRunLoop(for: 0.02)
    }

    func testAnAnimatedResizeFromCodeDoesNotReRenderABigPlaylist() async throws {
        let window = try await hostBrowser(on: .bigPlaylist)
        assertAnAnimatedResizeReRendersNothing(in: window, extraViews: ["PlaylistDetailContent"])
    }

    func testAnAnimatedResizeFromCodeDoesNotReRenderHome() async throws {
        let window = try await hostBrowser(on: .home)
        // Growing back brings rows and cards into Home's lazy stacks again, which builds them;
        // while the window only shrinks nothing new comes into view, so nothing may run.
        assertAnAnimatedResizeReRendersNothing(in: window, extraViews: ["HomeView"], rowsMayReturnWhileGrowing: true)
    }

    /// Home's top tracks and its recently played shelf were plain stacks, which build and lay out
    /// every row and card on every size the window takes, on screen or not, so a full Home cost
    /// each resize step about twice what its content costs now (#473). Only what can be seen may
    /// be built, before and during a resize.
    func testHomeBuildsOnlyTheRowsAndCardsOnScreen() async throws {
        let window = try await hostBrowser(on: .home)
        // Home's sections load after it appears; wait for the first top track as well.
        XCTAssertTrue(
            AppKitTestSupport.pumpRunLoop(until: { ViewBodyTally.counts?["TrackListRow:top-0"] != nil }),
            "the top tracks never came on screen"
        )
        let offScreen = { () -> [String] in
            (ViewBodyTally.counts ?? [:]).keys.filter {
                $0 == "TrackListRow:top-\(Self.topTrackCount - 1)"
                    || $0 == "HomeMediaCardView:recent-album-\(Self.recentAlbumCount - 1)"
            }.sorted()
        }
        XCTAssertEqual(offScreen(), [], "Home built a row or card far outside the window")

        ViewBodyTally.counts = [:]
        for step in 0..<12 {
            resize(window, toWidth: 1_450 - CGFloat(step) * 30, height: 900 - CGFloat(step) * 10)
        }
        AppKitTestSupport.pumpRunLoop(for: 0.3)
        XCTAssertEqual(offScreen(), [], "a resize built a row or card far outside the window")

        // Back to full size. A window growing taller makes the lazy stack place the rows within
        // about a window's height below the visible ones, which on Home reaches all 20 top
        // tracks, so only the shelf's far card can be held to "never built" here.
        for step in (0..<12).reversed() {
            resize(window, toWidth: 1_450 - CGFloat(step) * 30, height: 900 - CGFloat(step) * 10)
        }
        AppKitTestSupport.pumpRunLoop(for: 0.3)
        let farCard = "HomeMediaCardView:recent-album-\(Self.recentAlbumCount - 1)"
        XCTAssertNil(ViewBodyTally.counts?[farCard], "growing the window built \(farCard) far outside it")
    }

    /// Search's track list and its card rows were plain stacks too, so a page of results built
    /// every row and card on every size the window took (#473).
    func testSearchBuildsOnlyTheTrackRowsOnScreen() async throws {
        try await assertSearchBuildsOnlyWhatIsOnScreen(
            tracks: Self.homeTracks(prefix: "found", count: 10), albums: [],
            farOff: "TrackListRow:found-9"
        )
    }

    /// Back on All after a category pill, a row of cards holds every page that pill fetched.
    func testSearchBuildsOnlyTheAlbumCardsOnScreen() async throws {
        let albums = (0..<30).map { index in
            MusicAlbum(id: "found-album-\(index)", name: "Album \(index)", artists: ["Artist \(index)"], imageURL: nil, uri: "spotify:album:found-album-\(index)")
        }
        try await assertSearchBuildsOnlyWhatIsOnScreen(tracks: [], albums: albums, farOff: "HomeMediaCardView:found-album-29")
    }

    /// Hosts Search on results, lays it out once, and checks `farOff` (a row below the window or
    /// a card past its right edge) is built neither then nor during a resize.
    private func assertSearchBuildsOnlyWhatIsOnScreen(
        tracks: [MusicTrack],
        albums: [MusicAlbum],
        farOff: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let browserVM = PlaylistBrowserViewModel(
            api: MockBrowsingAPI(playlistResults: [.success([])], trackResults: [:]),
            cache: MockBrowsingCache()
        )
        await browserVM.selectSidebar(.search)
        let search = browserVM.catalogSearch
        search.searchProvider = { _, offset, _ in
            offset == 0
                ? MusicSearchResults(tracks: tracks, artists: [], albums: albums, playlists: [])
                : MusicSearchResults(tracks: [], artists: [], albums: [], playlists: [])
        }
        search.query = "found"
        search.queryDidChange()
        await search.waitForSearchCompletion()
        XCTAssertEqual(search.visibleResults.tracks.count, tracks.count, file: file, line: line)
        XCTAssertEqual(search.visibleResults.albums.count, albums.count, file: file, line: line)

        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()),
            defaults: makeEphemeralDefaults()
        )
        let view = CatalogSearchView(
            viewModel: browserVM,
            searchViewModel: search,
            playbackViewModel: playback,
            queueViewModel: QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI()), playbackSession: playback),
            hasPlaybackDevice: false
        )
        .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
        ViewBodyTally.counts = [:]
        let controller = ViewTestHost.host(view, size: CGSize(width: 900, height: 600))
        let window = try XCTUnwrap(controller.view.window, file: file, line: line)
        // The hosted page lays itself out fully once its window takes a size, as a real one does.
        resize(window, toWidth: 900, height: 600)
        let second = tracks.isEmpty ? "HomeMediaCardView:found-album-1" : "TrackListRow:found-1"
        XCTAssertTrue(
            AppKitTestSupport.pumpRunLoop(until: { ViewBodyTally.counts?[second] != nil }),
            "the results never came on screen", file: file, line: line
        )
        AppKitTestSupport.pumpRunLoop(for: 0.3)
        XCTAssertNil(ViewBodyTally.counts?[farOff], "Search built \(farOff) far outside the window", file: file, line: line)

        for step in 0..<12 {
            resize(window, toWidth: 900 - CGFloat(step) * 20, height: 600 - CGFloat(step) * 10)
        }
        AppKitTestSupport.pumpRunLoop(for: 0.3)
        XCTAssertNil(ViewBodyTally.counts?[farOff], "a resize built \(farOff) far outside the window", file: file, line: line)
    }

    private func assertAnAnimatedResizeReRendersNothing(
        in window: NSWindow,
        extraViews: [String],
        rowsMayReturnWhileGrowing: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Wide to narrow and back, all of it wider than the narrowest breakpoint, so no panel
        // opens or closes and nothing on screen changes but the layout.
        let comfortable: CGFloat = SpotiglassDesign.dualSidebarComfortableMinWidth(sidebarWidth: SpotiglassDesign.sidebarWidth)
        let steps = 12
        let span: CGFloat = 1_400 - (comfortable + 40)
        let widths: [CGFloat] = (1...steps).map { step in 1_400 - span * CGFloat(step) / CGFloat(steps) }
        waitUntilNothingRenders()
        let content = window.contentView!
        let wideLimit = Self.sidebarMaximumThickness(in: content)
        ViewBodyTally.counts = [:]
        var countsWhileShrinking: [String: Int] = [:]
        for (step, width) in (widths + widths.reversed()).enumerated() {
            resize(window, toWidth: width, height: 900 - CGFloat(step % steps) * 10)
            if step == steps - 1 {
                // At the narrowest step the browser must have taken the new width: its sidebar
                // limit follows the committed width, so a resize that never reached it can't pass.
                // However late a busy Mac commits it (#535).
                if let wideLimit {
                    let narrowed = AppKitTestSupport.pumpRunLoop(until: {
                        (Self.sidebarMaximumThickness(in: content) ?? .infinity) < wideLimit - 100
                    })
                    XCTAssertTrue(narrowed, "the resize never reached the browser", file: file, line: line)
                } else {
                    XCTFail("no sidebar split item", file: file, line: line)
                }
                // After the wait, so what the last shrinking step does once it settles counts too.
                countsWhileShrinking = ViewBodyTally.counts ?? [:]
            }
        }
        AppKitTestSupport.pumpRunLoop(for: 0.3)
        let counts = ViewBodyTally.counts ?? [:]

        for container in [
            "PlaylistBrowserView",
            "BrowserTransportBar",
            "PlaybackControlsView",
            "PlaylistBrowserSidebar",
            "PlaylistsSidebarSectionContent",
            "PlaylistBrowserMainDetailColumn",
        ] + extraViews {
            XCTAssertNil(
                counts[container],
                "\(container) re-rendered \(counts[container] ?? 0) times in \(steps * 2) resize steps",
                file: file, line: line
            )
        }
        let rows = (rowsMayReturnWhileGrowing ? countsWhileShrinking : counts).keys.filter { name in
            ["TrackListRow:", "PlaylistListRow:", "HomeMediaCardView:"].contains(where: name.hasPrefix)
        }
        XCTAssertTrue(rows.isEmpty, "rows re-rendered while resizing: \(rows.sorted().prefix(5))", file: file, line: line)
        if rowsMayReturnWhileGrowing {
            // A row coming back into view is built once; one built again on later steps means the
            // growing half re-renders rows, which the shrinking-half check alone wouldn't see.
            let rebuilt = counts.filter { name, count in
                ["TrackListRow:", "HomeMediaCardView:"].contains(where: name.hasPrefix)
                    && count - (countsWhileShrinking[name] ?? 0) > 1
            }
            XCTAssertTrue(rebuilt.isEmpty, "rows re-rendered while growing: \(rebuilt.keys.sorted().prefix(5))", file: file, line: line)
            // The sidebar's rows never leave the window, so none may run in either half.
            let sidebarRows = counts.keys.filter { $0.hasPrefix("PlaylistListRow:") }
            XCTAssertTrue(sidebarRows.isEmpty, "sidebar rows re-rendered while resizing: \(sidebarRows.sorted().prefix(5))", file: file, line: line)
        }
    }

    /// Waits until a whole 0.1 s passes with no counted body running, so a load or player update
    /// that lands late on a busy Mac can't be taken for a re-render the resize caused. A browser
    /// that never stops re-rendering fails at ``mustHappenTimeout``: a synchronous loop on the main
    /// thread would keep the per-test limit from stopping it (#535).
    private func waitUntilNothingRenders() {
        let deadline = Date().addingTimeInterval(mustHappenTimeout)
        while Date() < deadline {
            ViewBodyTally.counts = [:]
            AppKitTestSupport.pumpRunLoop(for: 0.1)
            if ViewBodyTally.counts?.isEmpty ?? true { return }
        }
        XCTFail("the browser kept re-rendering before the resize: \(ViewBodyTally.counts ?? [:])")
    }

    /// Opening the queue narrows how far the sidebar can be dragged, so a drag can't push the
    /// columns past the window with the queue open (#459). The limit no longer comes from the
    /// browser's body, so check the one AppKit applies.
    func testOpeningTheQueueNarrowsTheSidebarsDragLimit() async throws {
        let window = try await hostBrowser(on: .bigPlaylist)
        let content = try XCTUnwrap(window.contentView)
        let queueShare = SpotiglassDesign.playlistSidebarMaxWidth(browserWidth: 2_000, isQueueVisible: false)
            - SpotiglassDesign.playlistSidebarMaxWidth(browserWidth: 2_000, isQueueVisible: true)
        // Waits for the limit AppKit applies to change, however late a busy Mac gets there (#533).
        let limitBecomes = { (expected: CGFloat) in
            AppKitTestSupport.pumpRunLoop(until: {
                abs((Self.sidebarMaximumThickness(in: content) ?? .infinity) - expected) < 0.5
            })
        }

        // The closed limit is the one for the widened window, not one left from before the
        // widening committed: wait for that value instead of for a quiet moment.
        let widenedLimit = SpotiglassDesign.playlistSidebarMaxWidth(
            browserWidth: content.bounds.width, isQueueVisible: false
        )
        XCTAssertTrue(limitBecomes(widenedLimit), "the drag limit never matched the widened window")
        let closedLimit = try XCTUnwrap(Self.sidebarMaximumThickness(in: content), "no sidebar split item")

        StoredFlag.queuePanelVisible.isOn = true
        _ = limitBecomes(closedLimit - queueShare)
        let openLimit = try XCTUnwrap(Self.sidebarMaximumThickness(in: content))
        XCTAssertEqual(closedLimit - openLimit, queueShare, accuracy: 0.5, "closed \(closedLimit), open \(openLimit)")

        StoredFlag.queuePanelVisible.isOn = false
        _ = limitBecomes(closedLimit)
        XCTAssertEqual(try XCTUnwrap(Self.sidebarMaximumThickness(in: content)), closedLimit, accuracy: 0.5)
    }

    /// The playlist sidebar's widest drag as the split view controller has it.
    private static func sidebarMaximumThickness(in view: NSView) -> CGFloat? {
        if let split = view as? NSSplitView, split.arrangedSubviews.count >= 2,
           let controller = split.delegate as? NSSplitViewController,
           let sidebar = controller.splitViewItems.first {
            return sidebar.maximumThickness
        }
        for subview in view.subviews {
            if let found = sidebarMaximumThickness(in: subview) { return found }
        }
        return nil
    }

    /// The flag behind the queue panel tells its views about its own changes only.
    func testTheQueueFlagPublishesOnlyARealChange() {
        let defaults = makeEphemeralDefaults()
        let flag = StoredFlag(key: "queue.panel.visible", defaultValue: false, defaults: defaults)
        var changes = 0
        let subscription = flag.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        flag.isOn = false
        XCTAssertEqual(changes, 0, "writing the value it already has is no change")

        flag.isOn = true
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(defaults.object(forKey: "queue.panel.visible") as? Bool, true)
        XCTAssertTrue(
            StoredFlag(key: "queue.panel.visible", defaultValue: false, defaults: defaults).isOn,
            "a new window reads what the last one saved"
        )
    }

    /// Under the test host the app's flags live in memory, shared by every hosted view, so a test
    /// that opens the queue or unpins the lyrics must not leave it that way for the next one.
    func testTheTestHostPutsTheAppsFlagsBack() {
        StoredFlag.queuePanelVisible.isOn = true
        StoredFlag.lyricsPopOutPinned.isOn = !LyricsPopOutWindow.isPinnedByDefault

        ViewTestHost.tearDownAll()

        XCTAssertFalse(StoredFlag.queuePanelVisible.isOn, "the next test would start with the queue open")
        XCTAssertEqual(StoredFlag.lyricsPopOutPinned.isOn, LyricsPopOutWindow.isPinnedByDefault)
    }
}
