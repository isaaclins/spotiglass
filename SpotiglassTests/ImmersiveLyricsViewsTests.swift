import MusicKit
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
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        let queue = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api),
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
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        let queue = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api),
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
        XCTAssertFalse(dismissed, "a playing track must keep the lyrics open")
    }

    /// #438: a small repeat button sat next to the song title in the lyrics, a second copy of
    /// the player bar's. The bar stays visible under the lyrics now, so repeat lives only there.
    /// Checked for every repeat mode, since each one drew its own icon.
    func testLyricsShowNoRepeatButtonNextToTheTitle() throws {
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        )
        let queue = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api),
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000
        )
        let track = sampleTrack(spotifyID: "noRepeatView")
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(track, isPaused: true, nextTracks: []))

        for mode in [MusicRepeatMode.off, .context, .track] {
            for isCompact in [false, true] {
            playback.repeatMode = mode
            let column = ImmersiveLyricsLeftColumnView(
                playbackViewModel: playback,
                queueViewModel: queue,
                navigateToArtist: { _ in },
                navigateToAlbum: { _, _, _ in },
                currentTrack: track,
                isCompact: isCompact
            )
            ViewTestHost.host(column, size: CGSize(width: 320, height: 640))
            XCTAssertNoThrow(try column.inspect().find(text: "Title"), "the title is missing")
            // ViewInspector can't read accessibility labels on macOS 26+, so look for the icon:
            // the stray button drew "infinity.circle" / "infinity.circle.fill".
            let symbols = try column.inspect().findAll(ViewType.Image.self)
                .compactMap { try? $0.actualImage().name() }
            XCTAssertFalse(symbols.isEmpty, "the column's images were not read")
            let repeatSymbols = symbols.filter { $0.contains("infinity") || $0.contains("repeat") }
            XCTAssertEqual(
                repeatSymbols, [],
                "a repeat button is back next to the title with repeat \(mode), compact \(isCompact)"
            )
            }
        }
    }

    /// #486: while the lyrics show the other service's song, its album, artists and queue are
    /// not in the library on screen, so the column shows them as plain text and leaves out
    /// Next in Queue. The on-screen service's song keeps its links and its queue.
    func testLyricsOfTheOtherServicesSongLinkNowhere() throws {
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        )
        let queue = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api),
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000
        )
        let track = sampleTrack(spotifyID: "otherServiceColumn")
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(track, isPaused: true, nextTracks: []))
        let nextInQueue = SpotiglassL10n.string("lyrics.nextInQueue")

        for linksToLibrary in [true, false] {
            let column = ImmersiveLyricsLeftColumnView(
                playbackViewModel: playback,
                queueViewModel: queue,
                navigateToArtist: { _ in },
                navigateToAlbum: { _, _, _ in },
                currentTrack: track,
                linksToLibrary: linksToLibrary
            )
            ViewTestHost.host(column, size: CGSize(width: 320, height: 640))
            XCTAssertNoThrow(try column.inspect().find(text: "Album"), "the album name is missing, links \(linksToLibrary)")
            let buttons = try column.inspect().findAll(ViewType.Button.self)
            let showsQueue = (try? column.inspect().find(text: nextInQueue)) != nil
            if linksToLibrary {
                XCTAssertFalse(buttons.isEmpty, "the album link is missing")
                XCTAssertTrue(showsQueue, "Next in Queue is missing")
            } else {
                XCTAssertEqual(buttons.count, 0, "the other service's album or artists link into this library")
                XCTAssertFalse(showsQueue, "Next in Queue shows this library's queue under the other service's song")
            }
        }
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

        // The lyrics share the window with the sidebar, the toolbar and the player bar (#438):
        // they must not claim to be modal or hide the rest of the window from VoiceOver.
        XCTAssertTrue(lyricsSource.contains(".accessibilityElement(children: .contain)"))
        XCTAssertFalse(lyricsSource.contains(".isModal"))
        XCTAssertFalse(rootSource.contains(".accessibilityHidden(lyricsOverlayController.isPresented)"))
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

    /// Apple Music library songs map their cover to a `musicKit://` URL, which no download can
    /// fetch. The backdrop downloaded it anyway and stayed black behind the lyrics (#448).
    func testLibraryCoverGivesTheBackdropAnImage() throws {
        let registry = AppleMusicArtworkRegistry()
        let library = try AppleMusicFixtures.decode(
            Artwork.self,
            #"{"url":"musicKit://artwork/transient/{w}x{h}?id=LYRICS","width":600,"height":600}"#
        )
        let url = try XCTUnwrap(AppleMusicItemMapping.artworkURL(library, size: 120, registry: registry))
        XCTAssertTrue(AppleMusicArtworkRegistry.needsMusicKit(url))

        XCTAssertEqual(
            ImmersiveBlurredArtwork.musicKitArtwork(for: url, registry: registry),
            library,
            "a library cover should be drawn by MusicKit behind the lyrics, not downloaded and left black"
        )

        // MusicKit draws nothing for a made-up artwork, so a red stand-in plays MusicKit's part.
        // On today's code the cover goes to the downloader, which can't fetch it: all black.
        let drawn = DrawnCovers()
        let view = ImmersiveBlurredArtwork(url: url, registry: registry) { artwork, edge in
            XCTAssertEqual(artwork, library)
            return AnyView(StandInCover(edge: edge, drawn: drawn))
        }
        // A Retina screen: MusicKit would ask for twice the edge unless the backdrop stops it.
        .environment(\.displayScale, 2)
        let center = try centerPixel(of: view, size: CGSize(width: 360, height: 280))
        XCTAssertGreaterThan(center.redComponent, 0.9, "the backdrop should show the blurred library cover, not black")
        XCTAssertGreaterThan(center.redComponent - center.greenComponent, 0.6, "the cover's own colour, not grey")
        // Same 576 px source a downloaded cover is downscaled to, so the blur costs the same.
        XCTAssertEqual(drawn.pixelEdges.last, 576)

        // A wide window: the small library cover is scaled up to fill it exactly like a
        // downloaded cover, not left as a 576 pt square in the middle with black around it.
        let downloaded = ImmersiveBlurredArtwork(
            url: try XCTUnwrap(URL(string: "https://example.com/600x600bb.jpg")),
            initialImage: StandInCover.red,
            registry: registry
        )
        let wide = CGSize(width: 2_400, height: 900)
        for point in [CGPoint(x: 8, y: 8), CGPoint(x: 240, y: 450), CGPoint(x: 2_160, y: 120)] {
            // Red as seen over black: the downloaded cover's faded edge is see-through, the
            // library one sits on black.
            let library = try pixel(of: view, size: wide, at: point).redOverBlack
            let reference = try pixel(of: downloaded, size: wide, at: point).redOverBlack
            XCTAssertEqual(library, reference, accuracy: 0.05, "the library cover should fill the window at \(point)")
        }
        XCTAssertGreaterThan(try pixel(of: view, size: wide, at: CGPoint(x: 240, y: 450)).redComponent, 0.5)
    }

    /// Going from a catalog song to a library song MusicKit doesn't know, in the same backdrop
    /// (as when the next song starts), must not keep the catalog song's cover behind the lyrics.
    /// `main` already behaved this way (the failing download cleared the cover); this guards it now
    /// that such a cover is never downloaded.
    func testNextSongWithAnUnknownLibraryCoverClearsTheBackdrop() throws {
        let registry = AppleMusicArtworkRegistry()
        let catalog = try XCTUnwrap(URL(string: "https://example.com/600x600bb.jpg"))
        let unknown = try XCTUnwrap(URL(string: "musicKit://artwork/transient/600x600?id=GONE"))
        let red = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }

        let host = NSHostingView(rootView: AnyView(
            ImmersiveBlurredArtwork(url: catalog, initialImage: red, registry: registry)
        ))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 280)
        host.layoutSubtreeIfNeeded()
        AppKitTestSupport.pumpRunLoop(for: 0.1)
        XCTAssertGreaterThan(try centerPixel(of: host).redComponent, 0.5, "the catalog cover should show first")

        host.rootView = AnyView(ImmersiveBlurredArtwork(url: unknown, registry: registry))
        host.layoutSubtreeIfNeeded()
        AppKitTestSupport.pumpRunLoop(for: 0.3)
        let center = try centerPixel(of: host)
        XCTAssertLessThan(
            center.redComponent + center.greenComponent + center.blueComponent,
            0.05,
            "the previous song's cover should not stay behind a library song"
        )
    }

    private func centerPixel(of host: NSView) throws -> NSColor {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        return try XCTUnwrap(color.usingColorSpace(.sRGB))
    }

    /// The colour at the middle of `view` rendered at `size`, 1x.
    private func centerPixel(of view: some View, size: CGSize) throws -> NSColor {
        try pixel(of: view, size: size, at: CGPoint(x: size.width / 2, y: size.height / 2))
    }

    /// The colour at `point` (in points from the top left) of `view` rendered at `size`, 1x.
    private func pixel(of view: some View, size: CGSize, at point: CGPoint) throws -> NSColor {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        let cgImage = try XCTUnwrap(renderer.cgImage, "the backdrop should render")
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let color = try XCTUnwrap(bitmap.colorAt(x: Int(point.x), y: Int(point.y)))
        return try XCTUnwrap(color.usingColorSpace(.sRGB))
    }

    /// Catalog covers stay plain https and keep going through the downloader.
    func testCatalogCoverIsStillDownloaded() throws {
        let registry = AppleMusicArtworkRegistry()
        let catalog = try AppleMusicFixtures.decode(
            Artwork.self,
            #"{"url":"https://example.com/{w}x{h}bb.jpg","width":600,"height":600}"#
        )
        let url = try XCTUnwrap(AppleMusicItemMapping.artworkURL(catalog, size: 120, registry: registry))

        let view = ImmersiveBlurredArtwork(
            url: url,
            initialImage: NSImage(size: NSSize(width: 64, height: 64)),
            registry: registry
        )
        XCTAssertNil(view.musicKitArtwork)
        // Same small source as before: the 576 px edge rounds up to Apple's 600 px size.
        XCTAssertEqual(view.url.absoluteString, "https://example.com/600x600bb.jpg")
        _ = ViewTestHost.host(view, size: CGSize(width: 360, height: 280))
    }

    /// A library cover MusicKit doesn't know (e.g. after its registry entry was evicted) is never
    /// handed to the downloader, which can't fetch it, nor drawn by MusicKit: the backdrop is black.
    func testUnknownLibraryCoverIsNeitherDownloadedNorDrawn() async throws {
        let registry = AppleMusicArtworkRegistry()
        let unknown = try XCTUnwrap(URL(string: "musicKit://artwork/transient/600x600?id=GONE"))
        XCTAssertNil(ImmersiveBlurredArtwork.musicKitArtwork(for: unknown, registry: registry))
        XCTAssertNil(ImmersiveBlurredArtwork.downloadURL(for: unknown))

        let catalog = try XCTUnwrap(URL(string: "https://example.com/600x600bb.jpg"))
        XCTAssertEqual(ImmersiveBlurredArtwork.downloadURL(for: catalog), catalog)

        let loader = ArtworkImageLoader(
            imageProvider: { _ in NSImage(size: NSSize(width: 64, height: 64)) }
        )
        await loader.load(for: ImmersiveBlurredArtwork.downloadURL(for: catalog))
        XCTAssertNotNil(loader.image)
        await loader.load(for: ImmersiveBlurredArtwork.downloadURL(for: unknown))
        XCTAssertNil(loader.image, "the previous song's cover should not stay behind a library song")

        // And nothing stands in for MusicKit: the backdrop is plain black.
        let view = ImmersiveBlurredArtwork(url: unknown, registry: registry) { _, _ in
            XCTFail("MusicKit doesn't know this cover, so nothing should ask it to draw")
            return AnyView(Color.red)
        }
        let center = try centerPixel(of: view, size: CGSize(width: 360, height: 280))
        XCTAssertLessThan(center.redComponent + center.greenComponent + center.blueComponent, 0.05)
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
        // The idle wait runs on a stepped clock, so a busy machine can't make it late (#510).
        let clock = ManualPlaybackClock()
        let controller = LyricsAutoCenterController(clock: clock)
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
        let delay = ImmersiveLyricsLayout.autoCenterResumeDelay
        clock.advance(by: delay - .milliseconds(1))
        let stillWaiting = await clock.waitForSleepers()
        XCTAssertTrue(stillWaiting, "the idle wait ended before its time")
        XCTAssertFalse(controller.isAutoCentering, "auto-centering came back before the idle period ended")
        clock.advance(by: .milliseconds(1))
        let didResume = await resumeSignal.wait(timeout: .seconds(30))
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
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        let queue = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api),
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

/// The pixel edges a stand-in cover was drawn at.
@MainActor
private final class DrawnCovers {
    var pixelEdges: [CGFloat] = []
}

/// Plays MusicKit's `ArtworkImage` in tests: solid red, and it notes the pixel edge it would ask
/// MusicKit for (points times the screen scale, as `ArtworkImage` does).
private struct StandInCover: View {
    let edge: CGFloat
    let drawn: DrawnCovers
    @Environment(\.displayScale) private var displayScale

    static let red = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        rect.fill()
        return true
    }

    var body: some View {
        drawn.pixelEdges.append(edge * displayScale)
        // An image, like the one `ArtworkImage` draws (a plain colour blurs differently at the edges).
        return Image(nsImage: Self.red).resizable().frame(width: edge, height: edge)
    }
}

private extension NSColor {
    var redOverBlack: CGFloat { redComponent * alphaComponent }
}
