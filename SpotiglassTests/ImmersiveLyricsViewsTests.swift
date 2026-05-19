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
        let lyrics = ImmersiveLyricsViewModel { _ in
            try await Task.sleep(nanoseconds: 200_000_000)
            return .instrumental
        }
        let track = sampleTrack()
        let loadTask = Task { await lyrics.load(track: track) }

        for _ in 0 ..< 30 {
            if case .loading = lyrics.phase { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        guard case .loading = lyrics.phase else {
            return XCTFail("expected .loading, got \(lyrics.phase)")
        }

        let view = phaseColumn(lyricsModel: lyrics, track: track)
        ViewTestHost.host(view, size: CGSize(width: 420, height: 500))
        XCTAssertNoThrow(try view.inspect().find(text: "Loading lyrics…"))
        loadTask.cancel()
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
            SyncedLyricLine(id: 1, startTimeMs: 5_000, words: "Line two")
        ]
        let lyrics = ImmersiveLyricsViewModel { _ in .synced(lines) }
        await lyrics.load(track: sampleTrack(spotifyID: "syncedView"))

        let view = phaseColumn(lyricsModel: lyrics, positionMs: 4_500)
        ViewTestHost.host(view, size: CGSize(width: 420, height: 500))
        XCTAssertNoThrow(try view.inspect().find(text: "Line one"))
        XCTAssertNoThrow(try view.inspect().find(text: "Line two"))
    }

    func testLyricsPhaseColumnReadyPlainLyrics() async throws {
        let lyrics = ImmersiveLyricsViewModel { _ in .unsyncedPlain(["Verse A", "Verse B"]) }
        await lyrics.load(track: sampleTrack(spotifyID: "plainView"))

        let view = phaseColumn(lyricsModel: lyrics)
        ViewTestHost.host(view, size: CGSize(width: 420, height: 500))
        XCTAssertNoThrow(try view.inspect().find(text: "Verse A"))
    }

    func testMainLayoutWideShowsTrackTitle() async throws {
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

        let view = ImmersiveLyricsView(
            playbackViewModel: playback,
            queueViewModel: queue,
            lyricsModel: lyrics,
            navigateToArtist: { _ in },
            navigateToAlbum: { _, _, _ in },
            onDismiss: {}
        )
        .environmentObject(settings)
        .frame(width: 800, height: 600)

        ViewTestHost.host(view, size: CGSize(width: 800, height: 600))
        XCTAssertNoThrow(try view.inspect().find(text: "Title"))
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

    func testBlurredArtworkHostsAndLoadsFromDiskCache() async throws {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppMetadata.displayName, isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = URL(string: "https://example.com/blur-art-\(UUID().uuidString).png")!
        let file = ArtworkImageStore.cacheFileURL(for: url, diskDirectory: base)
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

        let view = ImmersiveBlurredArtwork(url: url)
            .frame(width: 360, height: 280)
        ViewTestHost.host(view, size: CGSize(width: 360, height: 280))
        try await Task.sleep(nanoseconds: 100_000_000)
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
        let resumeDeadline = Date().addingTimeInterval(3.0)
        while Date() < resumeDeadline, !controller.isAutoCentering {
            try? await Task.sleep(for: .milliseconds(50))
        }
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
            SyncedLyricLine(id: 1, startTimeMs: 4_000, words: "Second")
        ]
        let view = ImmersiveLyricsTimedLyricsScrollView(
            lines: lines,
            maxHeight: 320,
            positionMs: 2_000,
            reduceMotion: true,
            usesLyricsScrollEdgeFade: false,
            lyricsTextSize: .medium
        )
        .frame(width: 400, height: 360)

        ViewTestHost.host(view, size: CGSize(width: 400, height: 360))
        XCTAssertNoThrow(try view.inspect().find(text: "First"))
        XCTAssertNoThrow(try view.inspect().find(text: "Second"))
    }

    func testPlainLyricsScrollViewRendersLines() throws {
        let view = ImmersiveLyricsPlainLyricsScrollView(
            lines: ["Alpha", "Beta"],
            maxHeight: 280,
            positionMs: 30_000,
            trackDurationMs: 120_000,
            reduceMotion: true,
            usesLyricsScrollEdgeFade: true,
            lyricsTextSize: .small
        )
        .frame(width: 400, height: 320)

        ViewTestHost.host(view, size: CGSize(width: 400, height: 320))
        XCTAssertNoThrow(try view.inspect().find(text: "Alpha"))
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
        XCTAssertNoThrow(try emptySection.inspect().find(text: "NEXT IN QUEUE:"))
        XCTAssertNoThrow(try emptySection.inspect().find(text: "This song repeats. Turn repeat off to see what plays next."))

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
