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

    /// At the root the window title already names the app, so the breadcrumb
    /// renders nothing rather than repeating it as an inert second copy (#161).
    func testBreadcrumbToolbarEmptyPathShowsNothing() throws {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        let view = BreadcrumbToolbarView(viewModel: viewModel)

        ViewTestHost.host(view, size: CGSize(width: 400, height: 44))
        XCTAssertThrowsError(try view.inspect().find(text: AppMetadata.displayName))
    }

    func testBreadcrumbToolbarShowsCrumbLabels() async throws {
        let liked = PlaylistBrowsingTestFixtures.track(id: "liked-one")
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [liked], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)

        let view = BreadcrumbToolbarView(viewModel: viewModel)
        ViewTestHost.host(view, size: CGSize(width: 520, height: 44))
        XCTAssertNoThrow(try view.inspect().find(text: "Liked Songs"))
    }

    func testBreadcrumbToolbarHomeTapClearsTrail() async throws {
        let liked = PlaylistBrowsingTestFixtures.track(id: "liked-one")
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            savedTracksResult: .success(SpotifySavedTracksResult(tracks: [liked], totalAvailable: 1))
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()
        await viewModel.selectSidebar(.likedSongs)
        XCTAssertFalse(viewModel.breadcrumbPath.isEmpty)

        let view = BreadcrumbToolbarView(viewModel: viewModel)
        ViewTestHost.host(view, size: CGSize(width: 520, height: 44))
        // The home crumb is a real Button now, not a tap gesture, so that the
        // trait it advertises matches a working action (#113).
        try view.inspect().find(button: AppMetadata.displayName).tap()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(viewModel.breadcrumbPath.isEmpty)
        XCTAssertEqual(viewModel.sidebarSelection, .home)
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

        XCTAssertNotNil(
            PlayingWaveformIcon.barAnimation(isAnimating: true, durationScale: 1, durationOffset: 0)
        )
        XCTAssertEqual(
            PlayingWaveformIcon.barAnimation(isAnimating: false, durationScale: 1, durationOffset: 0),
            .default
        )
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

    func testNavigationToolbarChromeHidesBackWhenCannotNavigate() async throws {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await viewModel.load()

        let chrome = NavigationToolbarChrome(viewModel: viewModel)
            .frame(width: 480, height: 44)
        ViewTestHost.host(chrome, size: CGSize(width: 480, height: 44))
        XCTAssertNoThrow(try chrome.inspect())
        XCTAssertFalse(viewModel.canNavigateBack)
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
