import SwiftUI
import ViewInspector
import XCTest

@testable import Spotiglass

@MainActor
final class PlaybackChromeViewsTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testScrubberViewExposesAccessibilityProgress() throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let view = ScrubberView(
            displayFraction: 0.42,
            durationMilliseconds: 180_000,
            onSeek: { _ in },
            onDragUpdate: { _ in }
        )
        .frame(width: 280, height: 24)

        ViewTestHost.host(view, size: CGSize(width: 320, height: 48))
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(viewWithAccessibilityLabel: "Playback progress"))
    }

    func testPlaybackProgressScrubberGroupStaticLabels() throws {
        let view = PlaybackProgressScrubberGroup(
            progressAnchor: PlaybackProgressAnchor(
                positionMilliseconds: 90_000,
                anchorDate: Date(),
                durationMilliseconds: 180_000,
                isAdvancing: false
            ),
            durationMilliseconds: 180_000,
            isEnabled: true,
            onSeek: { _ in },
            dragFraction: .constant(nil)
        )
        .frame(width: 360)

        ViewTestHost.host(view, size: CGSize(width: 400, height: 48))
        XCTAssertNoThrow(try view.inspect().find(text: "1:30"))
        XCTAssertNoThrow(try view.inspect().find(text: "−1:30"))
    }

    func testPlaybackControlsDisconnectedState() throws {
        let playback = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 900, height: 120))
        XCTAssertNoThrow(try view.inspect().find(text: "Playback disconnected"))
    }

    func testPlaybackControlsPlayingShowsTrackTitleAndLyricsControl() throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let playback = makePlayingPlayback()
        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 900, height: 120))
        XCTAssertNoThrow(try view.inspect().find(text: "Midnight City"))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityLabel: "Lyrics"))
    }

    func testPlaybackControlsConnectingState() throws {
        let playback = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        playback.start()
        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 900, height: 120))
        XCTAssertNoThrow(try view.inspect().find(text: "Connecting Spotify playback..."))
    }

    func testPlaybackControlsInitializationErrorShowsReconnect() throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let playback = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        playback.handle(.initializationError("Web Playback failed to load"))
        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 900, height: 120))
        XCTAssertNoThrow(try view.inspect().find(text: "Playback could not start"))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityLabel: "Reconnect playback"))
    }

    func testPlaybackControlsPlaybackErrorShowsRetry() throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let playback = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        playback.handle(.playbackError("No active device"))
        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 900, height: 120))
        XCTAssertNoThrow(try view.inspect().find(text: "Playback error"))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityLabel: "Retry playback transfer"))
    }

    func testPlaybackControlsReadyShowsTransportAccessibility() throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let playback = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        playback.handle(.ready(deviceID: "device-1"))
        playback.repeatMode = .context
        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 900, height: 120))
        XCTAssertNoThrow(try view.inspect().find(text: "Ready to play"))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityLabel: "Previous track"))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityLabel: "Repeat playlist"))
    }

    func testPlaybackControlsArtistLineRendersOpenArtistButtons() throws {
        try ViewTestHost.skipIfViewInspectorGeometryUnsupported()
        let playback = makePlayingPlayback()
        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 900, height: 120))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityLabel: "Open artist M83"))
    }

    func testPlaybackControlsPausedShowsPausedBadge() throws {
        let playback = makePlayingPlayback(paused: true)
        let view = PlaybackControlsView(
            viewModel: playback,
            isLyricsPresented: .constant(false),
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 900, height: 120))
        XCTAssertNoThrow(try view.inspect().find(text: "Paused"))
    }

    func testQueuePanelEmptyStates() throws {
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(
            playbackAPI: api,
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000
        )
        let view = QueuePanelView(
            queueViewModel: queue,
            playbackViewModel: playback,
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 420, height: 640))
        ViewTestHost.assertFindLocalizedText("queue.title", in: view)
        ViewTestHost.assertFindText("Nothing playing", in: view)
        ViewTestHost.assertFindText(
            "No upcoming tracks. Start a playlist or add tracks to the queue.",
            in: view
        )
    }

    func testQueuePanelPopulatedNowPlayingAndUpNext() async throws {
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        let queue = QueueViewModel(
            playbackAPI: api,
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000
        )

        playback.handle(.ready(deviceID: "device-1"))
        let current = PlaybackNowPlaying(
            name: "Current",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 200_000,
            positionMilliseconds: 0,
            uri: "spotify:track:current"
        )
        let next = PlaybackNowPlaying(
            name: "Next",
            artists: ["Next Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:next"
        )
        playback.handle(.stateChanged(current, isPaused: false, nextTracks: [next]))

        let trackCurrent = SpotifyTrack(
            id: "current",
            name: "Current",
            artists: ["Artist"],
            albumArtworkURL: nil,
            durationMilliseconds: 200_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:current"
        )
        let trackNext = SpotifyTrack(
            id: "next",
            name: "Next",
            artists: ["Next Artist"],
            albumArtworkURL: nil,
            durationMilliseconds: 180_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:next"
        )
        api.queueResponse = SpotifyQueueResponse(queue: [.track(trackCurrent), .track(trackNext)])

        queue.setPanelVisible(true)
        await queue.refreshQueue()

        let view = QueuePanelView(
            queueViewModel: queue,
            playbackViewModel: playback,
            openArtist: { _ in }
        )
        ViewTestHost.host(view, size: CGSize(width: 420, height: 640))
        XCTAssertNoThrow(try view.inspect().find(text: "Now playing"))
        XCTAssertNoThrow(try view.inspect().find(text: "Up next"))
        XCTAssertNoThrow(try view.inspect().find(text: "Next"))
    }

    func testQueuePanelShowsPlaybackUnavailableError() async throws {
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        let queue = QueueViewModel(
            playbackAPI: api,
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000
        )

        await queue.addToQueue(uri: "spotify:track:missing-device")

        let view = QueuePanelView(
            queueViewModel: queue,
            playbackViewModel: playback,
            openArtist: { _ in }
        )
        ViewTestHost.host(view, size: CGSize(width: 420, height: 640))
        XCTAssertNoThrow(try view.inspect().find(text: "Playback unavailable"))
    }

    func testQueuePanelRepeatOneSubtitle() throws {
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-1"))
        playback.repeatMode = .track
        let queue = QueueViewModel(
            playbackAPI: api,
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000
        )
        let view = QueuePanelView(
            queueViewModel: queue,
            playbackViewModel: playback,
            openArtist: { _ in }
        )

        ViewTestHost.host(view, size: CGSize(width: 420, height: 640))
        XCTAssertNoThrow(
            try view.inspect().find(text: "Repeat one — upcoming tracks resume when repeat is off")
        )
    }

    private func makePlayingPlayback(paused: Bool = false) -> PlaybackSessionViewModel {
        let playback = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        playback.handle(.ready(deviceID: "device-1"))
        let nowPlaying = PlaybackNowPlaying(
            name: "Midnight City",
            artists: ["M83"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 240_000,
            positionMilliseconds: 30_000,
            uri: "spotify:track:midnight"
        )
        playback.handle(.stateChanged(nowPlaying, isPaused: paused, nextTracks: []))
        return playback
    }
}
