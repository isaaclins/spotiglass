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

    func testBackgroundLayerInspectable() throws {
        let view = ImmersiveLyricsBackgroundLayer(
            reduceTransparency: true,
            albumArtURL: nil
        )
        .frame(width: 320, height: 240)

        ViewTestHost.host(view, size: CGSize(width: 320, height: 240))
        XCTAssertNoThrow(try view.inspect())
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
