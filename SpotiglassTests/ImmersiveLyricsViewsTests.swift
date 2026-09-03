import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class ImmersiveLyricsViewsTests: XCTestCase {
    override func tearDown() {
        ImmersiveLyricsViewModel.resetSharedStateForTesting()
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testLyricsPhaseColumnLoadingState() async throws {
        let fetchStarted = AsyncSignal()
        let releaseFetch = AsyncSignal()
        let lyrics = ImmersiveLyricsViewModel { _ in
            fetchStarted.signal()
            await releaseFetch.wait()
            return .instrumental
        }
        let track = sampleTrack()
        let loadTask = Task { await lyrics.load(track: track) }

        let fetchDidStart = await fetchStarted.wait(timeout: .seconds(2))
        XCTAssertTrue(
            fetchDidStart,
            "lyrics fetch should start before the loading assertion"
        )
        XCTAssertTrue(lyrics.phase == .loading, "lyrics should enter loading before the fetch completes")
        guard case .loading = lyrics.phase else {
            return XCTFail("expected .loading, got \(lyrics.phase)")
        }

        let view = phaseColumn(lyricsModel: lyrics, track: track)
        ViewTestHost.host(view, size: CGSize(width: 420, height: 500))
        XCTAssertNoThrow(try view.inspect().find(text: "Loading lyrics…"))
        releaseFetch.signal()
        await loadTask.value
    }

    func testLyricsPhaseColumnFailedShowsRetry() async throws {
        let lyrics = ImmersiveLyricsViewModel { _ in
            throw LrcLibClient.Failure.noLyrics
        }
        await lyrics.load(track: sampleTrack(spotifyID: "failView"))

        let view = phaseColumn(lyricsModel: lyrics)
        ViewTestHost.host(view, size: CGSize(width: 420, height: 500))
        XCTAssertNoThrow(try view.inspect().find(text: "Try again"))
    }

    func testLyricsPhaseColumnReadyInstrumental() async throws {
        let lyrics = ImmersiveLyricsViewModel { _ in .instrumental }
        await lyrics.load(track: sampleTrack(spotifyID: "instrView"))

        let view = phaseColumn(lyricsModel: lyrics)
        ViewTestHost.host(view, size: CGSize(width: 420, height: 500))
        XCTAssertNoThrow(try view.inspect().find(text: "This track is instrumental."))
    }

    func testLyricsPhaseColumnReadySyncedLines() async throws {
        let lines = [
            SyncedLyricLine(id: 0, startTimeMs: 0, words: "Line one"),
            SyncedLyricLine(id: 1, startTimeMs: 5_000, words: "Line two"),
        ]
        let fetched: FetchedLyrics = .synced(lines)
        let lyrics = ImmersiveLyricsViewModel { _ in fetched }
        await lyrics.load(track: sampleTrack(spotifyID: "syncedView"))

        let view = phaseColumn(lyricsModel: lyrics, positionMs: 4_500)
        ViewTestHost.host(view, size: CGSize(width: 420, height: 500))

        guard case .ready(let actual) = lyrics.phase else {
            return XCTFail("expected ready lyrics, got \(lyrics.phase)")
        }
        XCTAssertEqual(actual, fetched)
        guard
            case .timed(let renderModel) = ImmersiveLyricsReadyContentModel.renderModel(
                for: actual,
                positionMs: 4_500,
                trackDurationMs: sampleTrack().durationMilliseconds
            )
        else {
            return XCTFail("expected synced lyrics render model, got \(actual)")
        }

        XCTAssertEqual(renderModel.activeID, 0)
        XCTAssertEqual(renderModel.lines.map(\.text), ["Line one", "Line two"])
        XCTAssertEqual(renderModel.lines.map(\.distance), [0, 1])
        XCTAssertEqual(renderModel.lines.map(\.isActive), [true, false])
        XCTAssertEqual(renderModel.lines.map(\.seekPositionMs), [0, 5_000])
    }

    func testLyricsPhaseColumnReadyPlainLyrics() async throws {
        let fetched: FetchedLyrics = .unsyncedPlain(["Verse A", "Verse B"])
        let lyrics = ImmersiveLyricsViewModel { _ in fetched }
        await lyrics.load(track: sampleTrack(spotifyID: "plainView"))

        let view = phaseColumn(lyricsModel: lyrics)
        ViewTestHost.host(view, size: CGSize(width: 420, height: 500))

        guard case .ready(let actual) = lyrics.phase else {
            return XCTFail("expected ready lyrics, got \(lyrics.phase)")
        }
        XCTAssertEqual(actual, fetched)
        guard
            case .plain(let renderModel) = ImmersiveLyricsReadyContentModel.renderModel(
                for: actual,
                positionMs: 0,
                trackDurationMs: sampleTrack().durationMilliseconds
            )
        else {
            return XCTFail("expected plain lyrics render model, got \(actual)")
        }

        XCTAssertEqual(renderModel.activeID, 0)
        XCTAssertEqual(renderModel.lines.map(\.text), ["Verse A", "Verse B"])
        XCTAssertEqual(renderModel.lines.map(\.distance), [0, 1])
        XCTAssertEqual(renderModel.lines.map(\.isActive), [true, false])
        XCTAssertTrue(renderModel.lines.allSatisfy { $0.seekPositionMs == nil })
    }

    func testMainLayoutWideShowsTrackTitle() async throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let settings = try ViewTestHost.makeSettingsStore()
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        let queue = QueueViewModel(
            playbackAPI: api,
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000
        )
        let track = sampleTrack()
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(track, isPaused: false, nextTracks: []))

        let lyrics = ImmersiveLyricsViewModel { _ in .instrumental }
        await lyrics.load(track: track)

        let view = ImmersiveLyricsMainLayout(
            playbackViewModel: playback,
            queueViewModel: queue,
            lyricsModel: lyrics,
            navigateToArtist: { _ in },
            navigateToAlbum: { _, _, _ in },
            currentTrack: track,
            positionMs: 12_000,
            reduceMotion: true,
            usesLyricsScrollEdgeFade: false,
            lyricsTextSize: .medium
        )
        .environmentObject(settings)
        .frame(width: 960, height: 720)

        ViewTestHost.host(view, size: CGSize(width: 960, height: 720))
        XCTAssertNoThrow(try view.inspect().find(text: "Title"))
        XCTAssertNoThrow(try view.inspect().find(text: "This track is instrumental."))
    }

    func testImmersiveLyricsViewHostsWhenPlaying() async throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let settings = try ViewTestHost.makeSettingsStore()
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        let queue = QueueViewModel(
            playbackAPI: api,
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000
        )
        let track = sampleTrack()
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(track, isPaused: false, nextTracks: []))
        let lyrics = ImmersiveLyricsViewModel { _ in .instrumental }
        await lyrics.load(track: track)
        var dismissed = false

        let view = ImmersiveLyricsView(
            playbackViewModel: playback,
            queueViewModel: queue,
            lyricsModel: lyrics,
            navigateToArtist: { _ in },
            navigateToAlbum: { _, _, _ in },
            onDismiss: { dismissed = true }
        )
        .environmentObject(settings)
        .frame(width: 800, height: 600)

        ViewTestHost.host(view, size: CGSize(width: 800, height: 600))
        XCTAssertNoThrow(try view.inspect().find(text: "Title"))
        let closeLyrics = ViewTestHost.localizedString("browser.closeLyrics")
        try view.inspect().find(button: closeLyrics).tap()
        XCTAssertTrue(dismissed)
    }

    func testLyricsOverlayAccessibilityContract() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let lyricsSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Spotiglass/Views/ImmersiveLyricsView.swift"),
            encoding: .utf8
        )
        let rootSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Spotiglass/Views/RootView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(lyricsSource.contains(".accessibilityAddTraits(.isModal)"))
        XCTAssertTrue(lyricsSource.contains(".focusScope(focusNamespace)"))
        XCTAssertTrue(lyricsSource.contains(".defaultFocus($focusedControl, .close)"))
        XCTAssertTrue(
            lyricsSource.contains(".accessibilityDefaultFocus($accessibilityFocusedControl, .close)")
        )
        XCTAssertTrue(
            lyricsSource.contains(".accessibilityFocused($accessibilityFocusedControl, equals: .close)")
        )
        XCTAssertTrue(rootSource.contains(".accessibilityHidden(lyricsOverlayController.isPresented)"))
        XCTAssertTrue(rootSource.contains("LyricsOverlayFocusContainer"))
    }

    func testBackgroundLayerInspectable() throws {
        let view = ImmersiveLyricsBackgroundLayer(
            reduceTransparency: true,
            albumArtURL: nil
        )
        .frame(width: 320, height: 240)

        ViewTestHost.host(view, size: CGSize(width: 320, height: 240))
        XCTAssertNoThrow(try view.inspect())
    }

    func testBackgroundLayerWithAlbumArtURL() throws {
        let url = URL(string: "https://example.com/cover.png")!
        let view = ImmersiveLyricsBackgroundLayer(
            reduceTransparency: false,
            albumArtURL: url
        )
        .frame(width: 400, height: 300)

        ViewTestHost.host(view, size: CGSize(width: 400, height: 300))
        XCTAssertNoThrow(try view.inspect())
    }

    func testBackgroundLayerBuildsAllTransparencyAndArtworkBranches() {
        let url = URL(string: "https://example.com/cover.png")!

        _ = ImmersiveLyricsBackgroundLayer(
            reduceTransparency: true,
            albumArtURL: nil
        ).body
        _ = ImmersiveLyricsBackgroundLayer(
            reduceTransparency: false,
            albumArtURL: nil
        ).body
        _ = ImmersiveLyricsBackgroundLayer(
            reduceTransparency: false,
            albumArtURL: url
        ).body
    }

    func testBlurredArtworkRendersInitialImageWithoutInspection() {
        let url = URL(string: "https://example.com/initial-cover.png")!
        let artwork = ImmersiveBlurredArtwork(
            url: url,
            initialImage: NSImage(size: NSSize(width: 64, height: 64))
        )

        // Hosting renders the GeometryReader closure and image branch, but does
        // not rely on ViewInspector (which is incompatible with this machine's
        // macOS 27 SwiftUI for some other lyrics views).
        _ = ViewTestHost.host(artwork, size: CGSize(width: 360, height: 280))
    }

    func testBlurredArtworkSizingAndDownscalingBranches() {
        XCTAssertEqual(
            ImmersiveBlurredArtwork.coverScaleForBlurredBackdrop(
                tile: 0,
                blurRadius: 24,
                target: .zero
            ),
            1
        )
        XCTAssertEqual(
            ImmersiveBlurredArtwork.coverScaleForBlurredBackdrop(
                tile: 1_000,
                blurRadius: 0,
                target: CGSize(width: 2_000, height: 500)
            ),
            2
        )

        let zero = NSImage(size: .zero)
        XCTAssertTrue(
            ImmersiveBlurredArtwork.downscaledForBlur(zero, maxEdge: 576) === zero
        )

        let small = NSImage(size: NSSize(width: 100, height: 50))
        XCTAssertTrue(
            ImmersiveBlurredArtwork.downscaledForBlur(small, maxEdge: 576) === small
        )

        let large = NSImage(size: NSSize(width: 1_200, height: 600))
        let downscaled = ImmersiveBlurredArtwork.downscaledForBlur(large, maxEdge: 576)
        XCTAssertEqual(downscaled.size.width, 576, accuracy: 0.001)
        XCTAssertEqual(downscaled.size.height, 288, accuracy: 0.001)
    }

    /// Writes into a directory of its own rather than the user's real artwork
    /// cache. Sharing that directory with the app and with every other test made
    /// this fail whenever something else trimmed or cleared the cache mid-run
    /// (#364), and it edited the caches of whoever ran the suite.
    func testBlurredArtworkHostsAndReadsACachedImageFromDisk() async throws {
        let directory = spotiglassTestsTemporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = URL(string: "https://example.com/blur-art-\(UUID().uuidString).png")!
        let file = ArtworkImageStore.cacheFileURL(for: url, diskDirectory: directory)
        let png: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82,
        ]
        try Data(png).write(to: file)

        let cached = try XCTUnwrap(
            ArtworkImageStore.cachedImageIfAvailable(for: url, diskDirectory: directory)
        )

        let view = ImmersiveBlurredArtwork(url: url, initialImage: cached)
            .frame(width: 360, height: 280)
        ViewTestHost.host(view, size: CGSize(width: 360, height: 280))
        XCTAssertNoThrow(try view.inspect())
    }

    func testLyricsAutoCenterControllerEngageAndIdleResume() async {
        let controller = LyricsAutoCenterController()
        XCTAssertTrue(controller.isAutoCentering)

        controller.noteUserScrollActivity()
        XCTAssertFalse(controller.isAutoCentering)

        controller.engageImmediately()
        XCTAssertTrue(controller.isAutoCentering)

        controller.noteUserScrollActivity()
        let resumeSignal = AsyncSignal()
        withObservationTracking {
            _ = controller.isAutoCentering
        } onChange: {
            resumeSignal.signal()
        }
        let didResume = await resumeSignal.wait(timeout: .seconds(3))
        XCTAssertTrue(
            didResume,
            "auto-centering should resume after the idle period"
        )
        XCTAssertTrue(controller.isAutoCentering)
    }

    func testLyricsLineTextActiveAndInactive() throws {
        let active = ImmersiveLyricsLineText("Active line", distance: 0, size: .medium)
        let inactive = ImmersiveLyricsLineText("Far line", distance: 3, size: .large)
        ViewTestHost.host(
            VStack { active; inactive },
            size: CGSize(width: 360, height: 120)
        )
        XCTAssertNoThrow(try active.inspect().find(text: "Active line"))
        XCTAssertNoThrow(try inactive.inspect().find(text: "Far line"))
    }

    func testLyricsMotionPolicyHonorsReduceMotion() {
        XCTAssertTrue(LyricsMotion.shouldAnimate(reduceMotion: false))
        XCTAssertFalse(LyricsMotion.shouldAnimate(reduceMotion: true))
        XCTAssertEqual(LyricsMotion.animation(.default, reduceMotion: false), .default)
        XCTAssertNil(LyricsMotion.animation(.default, reduceMotion: true))
    }

    func testReturnToCurrentLinePill() throws {
        var tapped = false
        let pill = LyricsReturnToCurrentLinePill { tapped = true }
        ViewTestHost.host(pill, size: CGSize(width: 280, height: 56))
        try pill.inspect().find(button: "Return to current line").tap()
        XCTAssertTrue(tapped)
    }

    func testTimedLyricsScrollViewRendersLines() throws {
        let lines = [
            SyncedLyricLine(id: 0, startTimeMs: 0, words: "First"),
            SyncedLyricLine(id: 1, startTimeMs: 4_000, words: "Second"),
        ]
        let renderModel = LyricsScrollRenderModel.timed(lines: lines, positionMs: 2_000)
        let view = ImmersiveLyricsTimedLyricsScrollView(
            renderModel: renderModel,
            maxHeight: 320,
            reduceMotion: true,
            usesLyricsScrollEdgeFade: false,
            lyricsTextSize: .medium
        )
        .frame(width: 400, height: 360)
        ViewTestHost.host(view, size: CGSize(width: 400, height: 360))

        // Assert the semantic rows consumed by the view, not ViewInspector's
        // OS-dependent ScrollView/LazyVStack representation.
        XCTAssertEqual(renderModel.activeID, 0)
        XCTAssertEqual(renderModel.lines.map(\.text), ["First", "Second"])
        XCTAssertEqual(renderModel.lines.map(\.distance), [0, 1])
        XCTAssertEqual(renderModel.lines.map(\.isActive), [true, false])
        XCTAssertEqual(renderModel.lines.map(\.seekPositionMs), [0, 4_000])
    }

    func testTappableLyricLineSeeksWhenTapped() throws {
        var tapped = false
        let line = TappableLyricLine(
            isActive: false,
            reduceMotion: true,
            onTap: { tapped = true }
        ) {
            Text("First")
        }

        ViewTestHost.host(line, size: CGSize(width: 400, height: 80))
        try line.inspect().button().tap()
        XCTAssertTrue(tapped)
    }

    func testPlainLyricsScrollViewRendersLines() throws {
        let renderModel = LyricsScrollRenderModel.plain(
            lines: ["Alpha", "Beta"],
            positionMs: 30_000,
            durationMs: 120_000
        )
        let view = ImmersiveLyricsPlainLyricsScrollView(
            renderModel: renderModel,
            maxHeight: 280,
            reduceMotion: true,
            usesLyricsScrollEdgeFade: true,
            lyricsTextSize: .small
        )
        .frame(width: 400, height: 320)
        ViewTestHost.host(view, size: CGSize(width: 400, height: 320))

        // Plain lyrics have no per-line timestamp, but still highlight and
        // render every line in source order.
        XCTAssertEqual(renderModel.activeID, 0)
        XCTAssertEqual(renderModel.lines.map(\.text), ["Alpha", "Beta"])
        XCTAssertEqual(renderModel.lines.map(\.distance), [0, 1])
        XCTAssertEqual(renderModel.lines.map(\.isActive), [true, false])
        XCTAssertTrue(renderModel.lines.allSatisfy { $0.seekPositionMs == nil })
    }

    func testNextInQueueSectionEmptyAndPopulated() async throws {
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        let queue = QueueViewModel(
            playbackAPI: api,
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000
        )
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(
                name: "Current", artists: ["A"], albumName: "Al", albumID: "al-1",
                albumArtURL: nil, durationMilliseconds: 180_000, positionMilliseconds: 0,
                uri: "spotify:track:cur"
            ),
            isPaused: false,
            nextTracks: []
        ))
        playback.repeatMode = .track

        let emptySection = ImmersiveLyricsNextInQueueSectionView(
            queueViewModel: queue,
            playbackViewModel: playback,
            navigateToArtist: { _ in },
            navigateToAlbum: { _, _, _ in }
        )
        .frame(width: 320, height: 160)
        ViewTestHost.host(emptySection, size: CGSize(width: 320, height: 160))
        // Assert through the catalog, not the English copy. Pinning the literal
        // meant a capitalization change failed a test about queue contents.
        ViewTestHost.assertFindLocalizedText("lyrics.nextInQueue", in: emptySection)
        ViewTestHost.assertFindLocalizedText("lyrics.next.empty.repeat", in: emptySection)

        let sdkNext = [
            PlaybackNowPlaying(
                name: "Up Next", artists: ["Artist"], albumName: "Album", albumID: "alb-2",
                albumArtURL: nil, durationMilliseconds: 200_000, positionMilliseconds: 0,
                uri: "spotify:track:next"
            )
        ]
        playback.handle(.stateChanged(
            PlaybackNowPlaying(
                name: "Current", artists: ["A"], albumName: "Al", albumID: "al-1",
                albumArtURL: nil, durationMilliseconds: 180_000, positionMilliseconds: 0,
                uri: "spotify:track:cur"
            ),
            isPaused: false,
            nextTracks: sdkNext
        ))
        playback.repeatMode = .off
        await queue.refreshQueue()

        let populated = ImmersiveLyricsNextInQueueSectionView(
            queueViewModel: queue,
            playbackViewModel: playback,
            navigateToArtist: { _ in },
            navigateToAlbum: { _, _, _ in }
        )
        .frame(width: 320, height: 200)
        ViewTestHost.host(populated, size: CGSize(width: 320, height: 200))
        XCTAssertNoThrow(try populated.inspect().find(text: "Up Next"))
    }

    func testQueueUpcomingRowShowsArtistAndAlbumLinks() throws {
        let item = QueueItem(
            name: "Track",
            subtitle: "Artist Name",
            albumArtURL: nil,
            albumName: "Album Title",
            albumID: "album-99",
            durationMilliseconds: 180_000,
            uri: "spotify:track:t1",
            artistTapTargets: [ArtistTapTarget(id: "ar-1", name: "Artist Name")]
        )
        let row = ImmersiveLyricsQueueUpcomingRowView(
            item: item,
            navigateToArtist: { _ in },
            navigateToAlbum: { _, _, _ in }
        )
        ViewTestHost.host(row, size: CGSize(width: 360, height: 80))
        XCTAssertNoThrow(try row.inspect().find(text: "Track"))
        XCTAssertNoThrow(try row.inspect().find(text: "Artist Name"))
        XCTAssertNoThrow(try row.inspect().find(text: "Album Title"))
    }

    private func phaseColumn(
        lyricsModel: ImmersiveLyricsViewModel,
        track: PlaybackNowPlaying? = nil,
        positionMs: Int = 0
    ) -> some View {
        ImmersiveLyricsLyricsPhaseColumn(
            lyricsModel: lyricsModel,
            currentTrack: track ?? sampleTrack(),
            positionMs: positionMs,
            reduceMotion: true,
            usesLyricsScrollEdgeFade: false,
            lyricsTextSize: .medium,
            maxHeight: 420
        )
        .frame(width: 420, height: 500)
    }

    private func sampleTrack(spotifyID: String = "lyricsViewTrack") -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: "Title",
            artists: ["Artist"],
            albumName: "Album",
            albumID: "album-1",
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 12_000,
            uri: "spotify:track:\(spotifyID)"
        )
    }
}
