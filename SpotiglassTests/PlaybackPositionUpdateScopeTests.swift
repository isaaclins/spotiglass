import Combine
import SwiftUI
import XCTest
@testable import Spotiglass

/// A new position from the player re-renders only the views that show it (#409). Before, every
/// reading republished the whole session, and with it the command palette manager the menus
/// observe, so the track list, sidebar and menus re-ran their bodies about 3 times a second while
/// a song played.
@MainActor
final class PlaybackPositionUpdateScopeTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    private func makePlayback() -> PlaybackSessionViewModel {
        PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
    }

    private func track(uri: String = "spotify:track:one", at positionMilliseconds: Int) -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: "Song",
            artists: ["Artist"],
            albumName: "Album",
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 240_000,
            positionMilliseconds: positionMilliseconds,
            uri: uri
        )
    }

    /// The readings a playing track produces: the same track, a little further along each time.
    private func playThrough(_ playback: PlaybackSessionViewModel, from start: Int, readings: Int) {
        for reading in 1...readings {
            playback.setConnectionState(.playing(track(at: start + reading * 1_000)))
        }
    }

    func testPositionOnlyUpdatesDoNotPublishTheSessionButMoveTheProgress() {
        let playback = makePlayback()
        playback.setConnectionState(.playing(track(at: 0)))

        var sessionChanges = 0
        var progressChanges = 0
        var states: [PlaybackConnectionState] = []
        let cancellables: [AnyCancellable] = [
            playback.objectWillChange.sink { _ in sessionChanges += 1 },
            playback.progress.objectWillChange.sink { _ in progressChanges += 1 },
            playback.connectionStatePublisher.dropFirst().sink { states.append($0) },
        ]
        defer { cancellables.forEach { $0.cancel() } }

        playThrough(playback, from: 0, readings: 5)

        XCTAssertEqual(sessionChanges, 0, "a new position must not re-render everything that observes the session")
        XCTAssertTrue(states.isEmpty)
        XCTAssertGreaterThanOrEqual(progressChanges, 5, "the progress bar still gets every new position")
        XCTAssertEqual(playback.progressAnchor?.positionMilliseconds, 5_000)
        XCTAssertEqual(playback.currentNowPlaying?.positionMilliseconds, 5_000, "the state itself stays current")

        // Pausing and a new track are real changes and still publish.
        playback.setConnectionState(.paused(track(at: 5_200)))
        XCTAssertEqual(sessionChanges, 1)
        playback.setConnectionState(.playing(track(uri: "spotify:track:two", at: 0)))
        XCTAssertEqual(sessionChanges, 2)
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(playback.progressAnchor?.isAdvancing, true)
    }

    /// Every read of the player assigns shuffle, repeat, volume, device, output icon and up-next
    /// again. With the values unchanged, nothing may re-render; a real change still does.
    func testRereadingThePlayerWithUnchangedValuesPublishesNothing() {
        let playback = makePlayback()
        playback.setConnectionState(.playing(track(at: 0)))
        playback.setTransportStateKnown(true)
        playback.setActivePlaybackDeviceID("device")
        playback.applyTransportShuffleEnabled(true, minimumMutationVersion: nil)
        playback.applyTransportRepeatMode(.context)
        playback.applyRemotePlaybackVolume(0.4)
        playback.sdkNextTracks = [track(uri: "spotify:track:two", at: 0)]

        var sessionChanges = 0
        var shuffleValues: [Bool] = []
        let cancellables: [AnyCancellable] = [
            playback.objectWillChange.sink { _ in sessionChanges += 1 },
            playback.$shuffleEnabled.dropFirst().sink { shuffleValues.append($0) },
        ]
        defer { cancellables.forEach { $0.cancel() } }

        for _ in 0..<3 {
            playback.setTransportStateKnown(true)
            playback.setActivePlaybackDeviceID("device")
            playback.applyTransportShuffleEnabled(true, minimumMutationVersion: nil)
            playback.applyTransportRepeatMode(.context)
            playback.applyRemotePlaybackVolume(0.4)
            playback.sdkNextTracks = [track(uri: "spotify:track:two", at: 0)]
            playback.refreshTrayOutputSymbol()
        }
        XCTAssertEqual(sessionChanges, 0)
        XCTAssertTrue(shuffleValues.isEmpty)

        playback.applyTransportShuffleEnabled(false, minimumMutationVersion: nil)
        XCTAssertEqual(sessionChanges, 1)
        XCTAssertEqual(shuffleValues, [false])
        XCTAssertFalse(playback.shuffleEnabled)
    }

    /// The menus observe the scene registry, which forwards every change of the command palette
    /// manager. A playing track must not reach them.
    func testPositionOnlyUpdatesDoNotRepublishTheCommandPaletteManager() {
        let playback = makePlayback()
        playback.setTransportStateKnown(true)
        playback.deviceID = "device"
        let manager = CommandPaletteManager()
        manager.bindPlaybackReadiness(to: playback)
        playback.setConnectionState(.playing(track(at: 0)))
        XCTAssertTrue(manager.canMutatePlaybackTransport)

        var managerChanges = 0
        let cancellable = manager.objectWillChange.sink { _ in managerChanges += 1 }
        defer { cancellable.cancel() }

        playThrough(playback, from: 0, readings: 5)
        // The browser sets this on every change it sees; an unchanged value publishes nothing.
        manager.setPlaybackTransportMutability(playback.isTransportMutationReady)
        playback.shuffleEnabled = playback.shuffleEnabled
        playback.repeatMode = playback.repeatMode

        XCTAssertEqual(managerChanges, 0)

        playback.setConnectionState(.disconnected)
        XCTAssertGreaterThan(managerChanges, 0, "a real change still reaches the menus")
        XCTAssertFalse(manager.canMutatePlaybackTransport)
    }

    /// In a real hosting view: a view observing the session (like the track list, the sidebar and
    /// the bar itself) keeps its body while the track plays on; only the part inside
    /// `PlaybackProgressReader` (the scrubber, the lyrics) re-renders.
    func testHostedViewsReRenderOnlyTheProgressReaderWhileATrackPlays() {
        let playback = makePlayback()
        playback.setConnectionState(.playing(track(at: 0)))
        let counter = RenderCounter()
        ViewTestHost.host(RenderProbe(playback: playback, counter: counter), size: CGSize(width: 320, height: 120))
        AppKitTestSupport.pumpRunLoop(for: 0.1)
        let outerBefore = counter.outer
        let progressBefore = counter.progress
        XCTAssertEqual(counter.lastPosition, 0)

        for reading in 1...5 {
            playback.setConnectionState(.playing(track(at: reading * 1_000)))
            AppKitTestSupport.pumpRunLoop(for: 0.05)
        }

        XCTAssertEqual(counter.outer, outerBefore, "the view around the progress must not re-render for a new position")
        XCTAssertGreaterThanOrEqual(counter.progress - progressBefore, 5)
        XCTAssertEqual(counter.lastPosition, 5_000)

        playback.setConnectionState(.paused(track(at: 5_100)))
        AppKitTestSupport.pumpRunLoop(for: 0.05)
        XCTAssertEqual(counter.outer, outerBefore + 1, "pausing re-renders what shows the play state")
        XCTAssertEqual(counter.lastPosition, 5_100)
    }
}

@MainActor
private final class RenderCounter {
    var outer = 0
    var progress = 0
    var lastPosition: Int?
}

private struct RenderProbe: View {
    @ObservedObject var playback: PlaybackSessionViewModel
    let counter: RenderCounter

    var body: some View {
        counter.outer += 1
        return VStack {
            Text(playback.currentNowPlaying?.name ?? "")
            PlaybackProgressReader(progress: playback.progress) { anchor in
                progressBody(anchor)
            }
        }
    }

    private func progressBody(_ anchor: PlaybackProgressAnchor?) -> some View {
        counter.progress += 1
        counter.lastPosition = anchor?.positionMilliseconds
        return Text("\(anchor?.positionMilliseconds ?? -1)")
    }
}
