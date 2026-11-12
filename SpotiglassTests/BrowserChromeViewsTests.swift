import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class BrowserChromeViewsTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    /// The title names where you are: Home at the root, the place after. Never the app (#495).
    func testWindowTitleNamesTheCurrentPlace() async throws {
        let liked = PlaylistBrowsingTestFixtures.track(id: "liked-one")
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            savedTracksResult: .success(MusicSavedTracksResult(tracks: [liked], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()
        await viewModel.selectSidebar(.home)
        XCTAssertEqual(
            BrowserToolbarPresentation.windowTitle(for: viewModel.breadcrumbPath, selection: viewModel.sidebarSelection),
            ViewTestHost.localizedString("browser.home")
        )
        XCTAssertFalse(BrowserToolbarPresentation.showsTitleInToolbar(for: viewModel.breadcrumbPath))
        await viewModel.selectSidebar(.likedSongs)
        await viewModel.selectArtist(id: "artist-xyz", origin: .extend, displayName: "Malcolm Todd")
        XCTAssertEqual(
            BrowserToolbarPresentation.windowTitle(for: viewModel.breadcrumbPath, selection: viewModel.sidebarSelection),
            "Artist artist-xyz"
        )
        XCTAssertTrue(BrowserToolbarPresentation.showsTitleInToolbar(for: viewModel.breadcrumbPath))
    }

    func testPlayingWaveformIconPausedAndPlaying() throws {
        let playing = PlayingWaveformIcon(isPlaying: true)
            .frame(width: 24, height: 16)
        ViewTestHost.host(playing, size: CGSize(width: 48, height: 32))
        XCTAssertNoThrow(try playing.inspect())

        let paused = PlayingWaveformIcon(isPlaying: false, color: .red)
            .frame(width: 24, height: 16)
        ViewTestHost.host(paused, size: CGSize(width: 48, height: 32))
        XCTAssertNoThrow(try paused.inspect())
    }

    /// The icon sits in every playing row, so it must hold still for someone who
    /// asked the system for less motion (#118). Drives the playback and the
    /// Reduce Motion change on a live host, since both decide the frozen state.
    /// The motion policy is asserted directly, because whether a hosted view
    /// actually animates depends on the machine's Reduce Motion setting, which a
    /// test cannot write and CI does not guarantee (#118).
    func testPlayingWaveformIconMotionPolicy() {
        XCTAssertTrue(PlayingWaveformIcon.shouldAnimate(isPlaying: true, reduceMotion: false))
        XCTAssertFalse(PlayingWaveformIcon.shouldAnimate(isPlaying: true, reduceMotion: true))
        XCTAssertFalse(PlayingWaveformIcon.shouldAnimate(isPlaying: false, reduceMotion: false))
        XCTAssertFalse(PlayingWaveformIcon.shouldAnimate(isPlaying: false, reduceMotion: true))

        // Animating: each bar targets a different extreme, so the wave is staggered.
        let animatedScales = (0..<3).map {
            PlayingWaveformIcon.barScale(index: $0, baseFraction: 0.5, isAnimating: true)
        }
        XCTAssertEqual(Set(animatedScales).count, 3)

        // Frozen: bars hold fixed mid-heights, so a paused row still reads as a waveform.
        let frozen = PlayingWaveformIcon.barScale(index: 0, baseFraction: 0.5, isAnimating: false)
        XCTAssertEqual(frozen, 0.55 / 0.5, accuracy: 0.0001)
        XCTAssertNotEqual(frozen, animatedScales[0])

        let timing = PlayingWaveformIcon.barTiming(isAnimating: true, durationScale: 1, durationOffset: 0.15)
        XCTAssertEqual(timing?.duration ?? 0, 0.45, accuracy: 0.0001)
        XCTAssertEqual(timing?.delay ?? 0, 0.15, accuracy: 0.0001)
        XCTAssertNil(PlayingWaveformIcon.barTiming(isAnimating: false, durationScale: 1, durationOffset: 0))
    }

    /// The bars move through Core Animation, not a SwiftUI animation (#394). A
    /// repeating SwiftUI animation redrew the whole window at the display's
    /// refresh rate while any row played, even one scrolled out of sight. Here
    /// the layers carry the animation, and pausing removes it.
    func testPlayingWaveformIconAnimatesItsLayersOnlyWhilePlaying() throws {
        let bars = WaveformBarsView()
        bars.frame = CGRect(x: 0, y: 0, width: 13, height: 14)
        bars.layout()

        bars.update(color: CGColor(red: 0, green: 0.5, blue: 1, alpha: 1), isAnimating: true)
        let layers = try XCTUnwrap(bars.layer?.sublayers)
        XCTAssertEqual(layers.count, 3)
        for bar in layers {
            let animation = try XCTUnwrap(bar.animation(forKey: WaveformBarsView.animationKey) as? CABasicAnimation)
            XCTAssertEqual(animation.keyPath, "transform.scale.y")
            XCTAssertEqual(animation.repeatCount, .infinity)
            XCTAssertTrue(animation.autoreverses)
        }
        let durations = layers.compactMap { $0.animation(forKey: WaveformBarsView.animationKey)?.duration }
        XCTAssertEqual(Set(durations).count, 3, "each bar keeps its own pace, so the wave stays staggered")

        bars.update(color: CGColor(red: 0, green: 0.5, blue: 1, alpha: 1), isAnimating: false)
        for (index, bar) in layers.enumerated() {
            XCTAssertNil(bar.animation(forKey: WaveformBarsView.animationKey))
            let frozen = PlayingWaveformIcon.barScale(
                index: index,
                baseFraction: PlayingWaveformIcon.bars[index].baseFraction,
                isAnimating: false
            )
            XCTAssertEqual(bar.transform.m22, frozen, accuracy: 0.0001)
        }
    }

    /// Pausing mid-swing eases the bars to their paused heights instead of
    /// snapping there, as the SwiftUI animation did before the bars moved to
    /// Core Animation.
    func testPausingEasesTheBarsToTheirPausedHeights() throws {
        let bars = WaveformBarsView()
        bars.frame = CGRect(x: 0, y: 0, width: 13, height: 14)
        let window = OffscreenTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(bars)
        window.orderFrontRegardless()
        defer { AppKitTestSupport.closeWindowSafely(window) }
        bars.layout()

        let color = CGColor(red: 0, green: 0.5, blue: 1, alpha: 1)
        bars.update(color: color, isAnimating: true)
        AppKitTestSupport.pumpRunLoop(for: 0.3)
        bars.update(color: color, isAnimating: false)

        let layers = try XCTUnwrap(bars.layer?.sublayers)
        var eased = 0
        for (index, bar) in layers.enumerated() {
            XCTAssertNil(bar.animation(forKey: WaveformBarsView.animationKey))
            let frozen = PlayingWaveformIcon.barScale(
                index: index,
                baseFraction: PlayingWaveformIcon.bars[index].baseFraction,
                isAnimating: false
            )
            XCTAssertEqual(bar.transform.m22, frozen, accuracy: 0.0001, "the bar rests at its paused height")
            guard let settle = bar.animation(forKey: WaveformBarsView.settleKey) as? CABasicAnimation else { continue }
            eased += 1
            XCTAssertEqual(settle.toValue as? CGFloat, frozen)
            XCTAssertNotEqual(settle.fromValue as? CGFloat, frozen)
            XCTAssertEqual(settle.repeatCount, 0)
            XCTAssertLessThanOrEqual(settle.duration, 0.3)
        }
        // 0.3 s into the swing at least one bar is away from its paused height.
        XCTAssertGreaterThan(eased, 0, "pausing mid-swing snapped every bar")

        // Playing again drops the ease and swings from the paused heights.
        bars.update(color: color, isAnimating: true)
        for bar in layers {
            XCTAssertNil(bar.animation(forKey: WaveformBarsView.settleKey))
            XCTAssertNotNil(bar.animation(forKey: WaveformBarsView.animationKey))
        }
    }

    func testPlayingWaveformIconFollowsPlaybackChanges() throws {
        let driver = WaveformMotionDriver(isPlaying: false)
        let view = WaveformMotionDriverView(driver: driver)
        ViewTestHost.host(view, size: CGSize(width: 48, height: 32))

        driver.isPlaying = true
        AppKitTestSupport.pumpRunLoop()
        driver.isPlaying = false
        AppKitTestSupport.pumpRunLoop()

        XCTAssertNoThrow(try view.inspect())
    }

    func testNavigationToolbarChromeIsDisabledWhenCannotNavigate() async throws {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()

        let chrome = NavigationToolbarChrome(viewModel: viewModel)
        ViewTestHost.host(chrome, size: CGSize(width: 48, height: 32))
        XCTAssertFalse(viewModel.canNavigateBack)
        XCTAssertTrue(try chrome.inspect().find(ViewType.Button.self).isDisabled())
        XCTAssertNil(viewModel.backDestination)
        XCTAssertEqual(chrome.destinationDescription, "Back")
    }

    /// #443: opening a playlist from Home showed "< Spotiglass" in small text,
    /// as if back went to the app. Back must name Home, and nothing in the
    /// toolbar may print the app name.
    func testBackFromAPlaylistOpenedOnHomeNamesHomeNotTheApp() async throws {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "fav", name: "Favourite Songs")])],
            trackResults: ["fav": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()
        await viewModel.selectSidebar(.home)
        await viewModel.selectSidebar(.playlist("fav"))
        XCTAssertTrue(viewModel.canNavigateBack)

        let chrome = NavigationToolbarChrome(viewModel: viewModel)
        ViewTestHost.host(chrome, size: CGSize(width: 48, height: 32))
        XCTAssertEqual(chrome.destinationDescription, "Go back to Home")
        // VoiceOver reads a toolbar button's title, so the title names the place.
        XCTAssertNoThrow(try chrome.inspect().find(text: "Go back to Home"))
        XCTAssertFalse(try chrome.inspect().find(ViewType.Button.self).isDisabled())
        XCTAssertThrowsError(try chrome.inspect().find(text: AppMetadata.displayName))
    }

    /// The label has to match what a click does: walk Liked Songs, an artist
    /// and an album, then go back step by step and check every step lands on
    /// the place the button named before the click.
    func testBackButtonNamesEveryPlaceItThenOpens() async throws {
        let liked = PlaylistBrowsingTestFixtures.track(id: "liked-one")
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            savedTracksResult: .success(MusicSavedTracksResult(tracks: [liked], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()
        await viewModel.selectSidebar(.home)
        // The title of every place visited, in order: what back has to name
        // and open again on the way out.
        var visited: [String] = ["Home"]
        await viewModel.selectSidebar(.likedSongs)
        visited.append(BrowserToolbarPresentation.windowTitle(for: viewModel.breadcrumbPath, selection: viewModel.sidebarSelection))
        await viewModel.selectArtist(id: "artist-xyz", origin: .extend, displayName: "Malcolm Todd")
        visited.append(BrowserToolbarPresentation.windowTitle(for: viewModel.breadcrumbPath, selection: viewModel.sidebarSelection))
        await viewModel.selectAlbum(
            id: "album-1",
            displayTitle: "Sweet Boy",
            displaySubtitle: "Malcolm Todd",
            artworkURL: nil,
            origin: .extend
        )

        var named: [String] = []
        var landed: [String] = []
        while viewModel.canNavigateBack {
            let destination = try XCTUnwrap(viewModel.backDestination)
            named.append(viewModel.displayName(for: destination))
            await viewModel.navigateBack()
            landed.append(
                viewModel.sidebarSelection == .home
                    ? "Home"
                    : BrowserToolbarPresentation.windowTitle(for: viewModel.breadcrumbPath, selection: viewModel.sidebarSelection)
            )
        }

        XCTAssertEqual(named, Array(visited.reversed()))
        XCTAssertEqual(named, landed)
        XCTAssertFalse(named.contains(AppMetadata.displayName))
    }

    /// Leaving an artist before its page loads drops the breadcrumb that knew
    /// the name and caches nothing, yet back still opens that artist. It has
    /// to keep naming them instead of saying "Artist".
    func testBackNamesAnArtistLeftBeforeTheirPageLoaded() async throws {
        let entered = LibraryEditsGate()
        let release = LibraryEditsGate()
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            artistAlbumsHandler: { _, _, _ in
                entered.open()
                await release.wait()
                return []
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()
        await viewModel.selectSidebar(.search)

        let opening = Task { @MainActor in
            await viewModel.selectArtist(id: "artist-xyz", origin: .extend, displayName: "Malcolm Todd")
        }
        await entered.wait()
        await viewModel.selectSidebar(.home)
        release.open()
        await opening.value

        XCTAssertNil(viewModel.cachedArtistSnapshots["artist-xyz"])
        XCTAssertEqual(viewModel.backDestination, .artist("artist-xyz"))
        let chrome = NavigationToolbarChrome(viewModel: viewModel)
        XCTAssertEqual(chrome.destinationDescription, "Go back to Malcolm Todd")
    }

    /// An artist link in a track row hands over the name that row shows, not
    /// one looked up elsewhere: with the same artist in two rows, one of them
    /// with Spotify's "Unknown artist" placeholder, clicking Bonobo in the other
    /// row must make back say Bonobo, even when the page never loaded.
    func testBackNamesTheArtistAsTheClickedRowShowsThem() async throws {
        func item(_ id: String, artistName: String) -> MusicPlaylistTrackItem {
            MusicPlaylistTrackItem(
                id: id,
                content: .track(MusicTrack(
                    id: id,
                    name: "Track \(id)",
                    artists: [artistName],
                    artistRefs: [MusicArtistRef(id: "artist-bonobo", name: artistName)],
                    albumArtworkURL: nil,
                    durationMilliseconds: 237_000,
                    isExplicit: false,
                    isPlayable: true,
                    linkedFromID: nil,
                    uri: "spotify:track:\(id)"
                ))
            )
        }
        let items = [item("first", artistName: "Unknown artist"), item("kerala", artistName: "Bonobo")]
        let rows = TrackRowViewModel.numberedPlaylistRows(items)

        var clicked: MusicArtistRef?
        let row = TrackListRow(
            trackNumber: 2,
            track: rows[1],
            playURI: { _ in },
            togglePlayPause: {},
            isCurrent: false,
            isPlaying: false,
            openArtist: { clicked = $0 }
        )
        .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
        ViewTestHost.host(row, size: CGSize(width: 520, height: 48))
        try row.inspect().find(button: "Bonobo").tap()
        let artist = try XCTUnwrap(clicked)
        XCTAssertEqual(artist, MusicArtistRef(id: "artist-bonobo", name: "Bonobo"))

        let entered = LibraryEditsGate()
        let release = LibraryEditsGate()
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success(items)]],
            artistAlbumsHandler: { _, _, _ in
                entered.open()
                await release.wait()
                return []
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()
        await viewModel.selectSidebar(.playlist("one"))

        let opening = Task { @MainActor in
            await viewModel.selectArtist(id: artist.id, origin: .extend, displayName: artist.name)
        }
        await entered.wait()
        XCTAssertEqual(BrowserToolbarPresentation.windowTitle(for: viewModel.breadcrumbPath, selection: viewModel.sidebarSelection), "Bonobo")
        await viewModel.selectSidebar(.home)
        release.open()
        await opening.value

        XCTAssertNil(viewModel.cachedArtistSnapshots["artist-bonobo"])
        XCTAssertEqual(NavigationToolbarChrome(viewModel: viewModel).destinationDescription, "Go back to Bonobo")
    }

    /// Going back to an artist whose page failed to load replays them without
    /// a name. The title and the next back must still say the name the link
    /// showed, not "Artist".
    func testGoingBackToAnArtistThatFailedToLoadKeepsTheirName() async throws {
        struct Offline: Error {}
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            artistAlbumsHandler: { _, _, _ in throw Offline() }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()
        await viewModel.selectSidebar(.search)
        await viewModel.selectArtist(id: "artist-bonobo", origin: .extend, displayName: "Bonobo")
        XCTAssertNil(viewModel.cachedArtistSnapshots["artist-bonobo"])
        await viewModel.selectSidebar(.home)

        XCTAssertEqual(NavigationToolbarChrome(viewModel: viewModel).destinationDescription, "Go back to Bonobo")
        await viewModel.navigateBack()
        XCTAssertEqual(BrowserToolbarPresentation.windowTitle(for: viewModel.breadcrumbPath, selection: viewModel.sidebarSelection), "Bonobo")

        await viewModel.selectArtist(id: "artist-tycho", origin: .extend, displayName: "Tycho")
        XCTAssertEqual(NavigationToolbarChrome(viewModel: viewModel).destinationDescription, "Go back to Bonobo")
    }

    /// Every app language names the destination, not just English.
    func testBackDestinationIsLocalized() async throws {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "fav", name: "Favourite Songs")])],
            trackResults: ["fav": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()
        await viewModel.selectSidebar(.home)
        await viewModel.selectSidebar(.playlist("fav"))

        let expected = ["en": "Go back to Home", "de": "Zurück zu Start", "es": "Volver a Inicio"]
        for (identifier, text) in expected {
            XCTAssertEqual(
                NavigationToolbarChrome.destinationDescription(for: viewModel, locale: Locale(identifier: identifier)),
                text
            )
        }
    }
}

/// Drives `PlayingWaveformIcon` through playback and Reduce Motion changes on a
/// hosted view, so the icon keeps the same identity and its `onChange` handlers
/// actually run.
private final class WaveformMotionDriver: ObservableObject {
    @Published var isPlaying: Bool

    init(isPlaying: Bool) {
        self.isPlaying = isPlaying
    }
}

private struct WaveformMotionDriverView: View {
    @ObservedObject var driver: WaveformMotionDriver

    var body: some View {
        PlayingWaveformIcon(isPlaying: driver.isPlaying)
            .frame(width: 24, height: 16)
    }
}


/// The bar above Home said "Spotiglass" next to the sidebar button: the app's
/// name, not a place, above a page that already has its own greeting (#495).
/// These host the real browser the way the app's window scene does (title and
/// toolbar bridged into an `NSWindow`) and read what AppKit ends up with.
@MainActor
final class BrowserWindowTitleTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        if let window { AppKitTestSupport.closeWindowSafely(window) }
        window = nil
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    /// Where the queue button sits in the bar, in window coordinates.
    private func queueButtonFrame(in window: NSWindow) -> CGRect? {
        let queue = ViewTestHost.localizedString("browser.queue")
        guard let view = window.toolbar?.items.first(where: { $0.label == queue })?.view else { return nil }
        return view.convert(view.bounds, to: nil)
    }

    private func hostBrowser(_ viewModel: PlaylistBrowserViewModel) -> NSWindow {
        AppKitTestSupport.activateAppIfNeeded()
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "u1")
        let tokens = TitleTestTokenProvider()
        let view = PlaylistBrowserView(
            viewModel: viewModel,
            playbackHost: SpotiglassPlaybackHost(tokenProvider: tokens),
            catalogProvider: SpotifyAPIClient(tokenProvider: tokens, getResponseCache: .shared),
            commandPaletteManager: CommandPaletteManager(),
            signOut: {}
        )
        .environmentObject(store)
        .environmentObject(LyricsOverlayController())
        .defaultAppStorage(ViewTestHost.appStorageDefaults)
        let controller = NSHostingController(rootView: view)
        controller.sceneBridgingOptions = [.title, .toolbars]
        let window = OffscreenTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        // Hosting the controller shrinks the window to the browser's fitting size; give it the
        // size a real window has.
        window.setContentSize(CGSize(width: 1_100, height: 700))
        window.isReleasedWhenClosed = false
        self.window = window
        AppKitTestSupport.pumpRunLoop(for: 0.5)
        return window
    }

    /// Launch lands on Home, then a playlist, then back to Home: the bar shows no
    /// title on Home and the page's name elsewhere, while the window itself is
    /// always named after the place, never after the app, so the Window menu,
    /// Mission Control and VoiceOver still have a real name (#161).
    func testHomeBarHasNoTitleButTheWindowIsStillNamed() async throws {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Focus")])],
            trackResults: ["p1": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()
        await viewModel.selectSidebar(.home)
        let window = hostBrowser(viewModel)
        let home = ViewTestHost.localizedString("browser.home")
        let size = window.frame.size

        XCTAssertEqual(window.title, home)
        XCTAssertEqual(window.titleVisibility, .hidden, "Home has its own greeting; the bar stays empty")
        let homeQueue = try XCTUnwrap(queueButtonFrame(in: window))

        await viewModel.selectSidebar(.playlist("p1"))
        AppKitTestSupport.pumpRunLoop(for: 0.4)
        XCTAssertEqual(window.title, "Focus")
        XCTAssertEqual(window.titleVisibility, .visible)
        // Without the title the bar's buttons slid over next to the sidebar button on Home and
        // jumped back to the trailing edge on every other page.
        let playlistQueue = try XCTUnwrap(queueButtonFrame(in: window))
        XCTAssertEqual(homeQueue.minX, playlistQueue.minX, accuracy: 0.5, "the bar's buttons moved between Home and a page")
        XCTAssertGreaterThan(homeQueue.minX, window.frame.width / 2, "the bar's buttons left the trailing edge on Home")

        await viewModel.navigateBack()
        AppKitTestSupport.pumpRunLoop(for: 0.4)
        XCTAssertEqual(viewModel.sidebarSelection, .home)
        XCTAssertEqual(window.title, home)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.frame.size, size, "showing or hiding the title must not resize the window")

        XCTAssertNotEqual(window.title, AppMetadata.displayName)
    }

    /// A Command-click on the selected sidebar row clears the selection and leaves an empty
    /// placeholder. That page is not Home, so the window must not be named "Home" there, and
    /// the bar shows no title (it has no name of its own and must not say "Spotiglass"). A pinned
    /// row selected over Home is still Home.
    func testNothingSelectedIsNotNamedHome() async throws {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Focus")])],
            trackResults: ["p1": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()
        await viewModel.selectSidebar(.home)
        let window = hostBrowser(viewModel)
        XCTAssertEqual(window.title, ViewTestHost.localizedString("browser.home"))

        // A pinned track selects its row while it starts playing, with Home still on screen.
        await viewModel.selectSidebar(.pinnedItem("pinned-track"))
        AppKitTestSupport.pumpRunLoop(for: 0.4)
        XCTAssertEqual(window.title, ViewTestHost.localizedString("browser.home"))
        XCTAssertEqual(window.titleVisibility, .hidden)

        await viewModel.selectSidebar(nil)
        AppKitTestSupport.pumpRunLoop(for: 0.4)
        XCTAssertNil(viewModel.sidebarSelection)
        XCTAssertNotEqual(window.title, ViewTestHost.localizedString("browser.home"))
        XCTAssertFalse(window.title.isEmpty, "the window keeps a real name (#161)")
        XCTAssertEqual(window.titleVisibility, .hidden)
    }

    /// The welcome, sign-in and Apple Music access screens are a card whose heading is the
    /// app's name; the bar above it said "Spotiglass" a second time. The bar shows nothing
    /// there and the window keeps its name. The window starts with the name the main
    /// `WindowGroup` gives it (the app's), and the card must not replace or blank it.
    func testCardScreensShowNoTitleInTheBar() {
        let welcome = MusicServiceWelcomeView(services: MusicService.allCases, choose: { _ in })
        let controller = NSHostingController(rootView: welcome)
        controller.sceneBridgingOptions = [.title, .toolbars]
        let window = OffscreenTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppMetadata.displayName
        window.contentViewController = controller
        window.setContentSize(CGSize(width: 900, height: 600))
        window.isReleasedWhenClosed = false
        self.window = window
        AppKitTestSupport.pumpRunLoop(for: 0.4)

        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.title, AppMetadata.displayName)
    }
}

private final class TitleTestTokenProvider: PlaybackAccessTokenProviding, SpotifyAccessTokenProviding {
    func playbackAccessToken() async throws -> String { "title-token" }
    func refreshedPlaybackAccessToken() async throws -> String { "title-token" }
    func accessToken() async throws -> String { "title-token" }
    func refreshAccessTokenAfterUnauthorized(rejectedToken: String) async throws -> String { "title-token" }
}
