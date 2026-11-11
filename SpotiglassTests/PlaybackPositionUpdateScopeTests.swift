import AppKit
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

        // Any write to the defaults re-renders every view using `@AppStorage`, the window included.
        var defaultsWrites = 0
        let defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { _ in defaultsWrites += 1 }
        defer { NotificationCenter.default.removeObserver(defaultsObserver) }

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
        XCTAssertEqual(defaultsWrites, 0, "an unchanged volume must not be written again")

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

/// The scrubber's track moves 4 to 7 times a second while a track plays. As a `Canvas` in a
/// `TimelineView` inside the window's hosting view, each of those ticks laid out the whole window,
/// constraints and minimum size included: about 8 % of a core (#409). The track is now drawn by an
/// AppKit view that only redraws.
@MainActor
final class ScrubberTickCostTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { AppKitTestSupport.closeWindowSafely($0) }
        windows = []
        super.tearDown()
    }

    private func playingAnchor(isAdvancing: Bool = true, at date: Date = Date()) -> PlaybackProgressAnchor {
        PlaybackProgressAnchor(
            positionMilliseconds: 60_000,
            anchorDate: date,
            durationMilliseconds: 240_000,
            isAdvancing: isAdvancing
        )
    }

    /// A window that is on screen as far as AppKit knows (timelines tick only there), placed
    /// where nobody sees it, whose hosting view counts its layout passes.
    private func host<V: View>(_ view: V, size: CGSize) -> LayoutCountingHostingView {
        AppKitTestSupport.activateAppIfNeeded()
        let hosting = LayoutCountingHostingView(rootView: AnyView(view))
        let window = VisibilityControlledWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        windows.append(window)
        hosting.layoutSubtreeIfNeeded()
        AppKitTestSupport.pumpRunLoop(for: 0.3)
        return hosting
    }

    func testAPlayingBarDoesNotLayOutTheWindowOnEveryTick() {
        let hosting = host(
            PlaybackProgressScrubberGroup(
                progressAnchor: playingAnchor(),
                durationMilliseconds: 240_000,
                isEnabled: true,
                onSeek: { _ in }
            )
            .frame(width: 600, height: 30),
            size: CGSize(width: 600, height: 30)
        )
        hosting.layoutCount = 0
        AppKitTestSupport.pumpRunLoop(for: 3)

        // The two time labels change once a second each, which still lays out the window: about 6
        // passes in 3 s. The track alone ticked 5 times a second here (600 pt, 4:00), 15 more.
        XCTAssertLessThanOrEqual(hosting.layoutCount, 9, "the moving track must not lay out the window")
        XCTAssertGreaterThanOrEqual(hosting.layoutCount, 3, "the labels still tick, so the window is live")
    }

    func testTheTrackWakesOnlyWhilePlaying() throws {
        let view = ScrubberTrackCanvasView(frame: CGRect(x: 0, y: 0, width: 416, height: 18))
        // A clock of its own, so a busy machine pausing the test can't make the first tick due.
        let clock = Date().addingTimeInterval(3600)
        view.now = { clock }
        let colors = ScrubberTrackDrawing.Colors(track: .gray, played: .blue, thumbFill: .white, thumbBorder: .black)
        func drawing(_ anchor: PlaybackProgressAnchor, dragFraction: Double? = nil) -> ScrubberTrackCanvasView.Drawing {
            .init(
                trackHeight: 4,
                progress: ScrubberProgress(anchor: anchor, durationMilliseconds: 240_000, dragFraction: dragFraction),
                dragFraction: dragFraction,
                thumbDiameter: 12,
                overhang: 8,
                colors: colors
            )
        }
        view.drawing = drawing(playingAnchor(at: clock))
        XCTAssertNil(view.tickTimer, "nothing to wake outside a window")

        let window = VisibilityControlledWindow(
            contentRect: NSRect(x: 0, y: 0, width: 416, height: 18),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView?.addSubview(view)

        // 400 pt for 4:00 moves 1.67 pt a second: 4 ticks a second keep each step under half a point.
        let timer = try XCTUnwrap(view.tickTimer)
        let wait = timer.fireDate.timeIntervalSince(clock)
        XCTAssertGreaterThan(wait, 0)
        XCTAssertLessThanOrEqual(wait, 0.25 + 0.01)

        view.drawing = drawing(playingAnchor(isAdvancing: false, at: clock))
        XCTAssertNil(view.tickTimer, "paused: no wakeups")

        view.drawing = drawing(playingAnchor(at: clock))
        XCTAssertNotNil(view.tickTimer)
        view.drawing = drawing(playingAnchor(at: clock), dragFraction: 0.5)
        XCTAssertNil(view.tickTimer, "dragging: the pointer moves the thumb, not the clock")

        view.drawing = drawing(playingAnchor(at: clock))
        // Minimized, hidden or covered: nobody sees the track move.
        window.reportsVisible = false
        XCTAssertNil(view.tickTimer, "a window nobody sees: no wakeups")
        window.reportsVisible = true
        XCTAssertNotNil(view.tickTimer, "visible again: the track moves on")

        view.removeFromSuperview()
        XCTAssertNil(view.tickTimer, "out of the window: no wakeups")
    }

    /// After the main thread stalls (or the Mac sleeps) while a track plays, the next tick is
    /// scheduled from now. Scheduling from the tick that fired late would fire every missed tick
    /// at once, one right after the other. The view's clock stands in for the stall, and the test
    /// fires each tick itself, so how late the run loop gets on a busy machine changes nothing.
    func testAStallDoesNotFireTheMissedTicksAtOnce() throws {
        let window = VisibilityControlledWindow(
            contentRect: NSRect(x: 0, y: 0, width: 416, height: 18),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        windows.append(window)
        // Hours ahead of the real clock: the run loop never reaches these ticks by itself.
        var clock = Date().addingTimeInterval(3600)
        let anchor = playingAnchor(at: clock)
        let view = TickCountingTrackView(frame: CGRect(x: 0, y: 0, width: 416, height: 18))
        view.now = { clock }
        view.drawing = .init(
            trackHeight: 4,
            progress: ScrubberProgress(anchor: anchor, durationMilliseconds: 240_000, dragFraction: nil),
            dragFraction: nil,
            thumbDiameter: 12,
            overhang: 8,
            colors: ScrubberTrackDrawing.Colors(track: .gray, played: .blue, thumbFill: .white, thumbBorder: .black)
        )
        window.contentView?.addSubview(view)
        defer { view.removeFromSuperview() }

        // 400 pt for 4:00: 4 ticks a second, each on a fixed grid from the anchor.
        let tick = 0.25
        let first = try XCTUnwrap(view.tickTimer)
        XCTAssertGreaterThan(first.fireDate, clock)
        XCTAssertLessThanOrEqual(first.fireDate.timeIntervalSince(clock), tick + 0.01)

        // On time: the next tick follows one tick later.
        let firstDate = first.fireDate
        clock = firstDate
        view.ticks = 0
        first.fire()
        XCTAssertEqual(view.ticks, 1, "the tick redraws the track")
        let second = try XCTUnwrap(view.tickTimer)
        XCTAssertEqual(second.fireDate.timeIntervalSince(firstDate), tick, accuracy: 0.001)

        // A 2.1 s stall misses 8 ticks; the one that was due fires late.
        clock = second.fireDate.addingTimeInterval(2.1)
        view.ticks = 0
        second.fire()
        XCTAssertEqual(view.ticks, 1, "the late tick fired once")
        let next = try XCTUnwrap(view.tickTimer)
        XCTAssertGreaterThan(next.fireDate, clock, "the missed ticks must not fire one after the other")
        XCTAssertLessThanOrEqual(next.fireDate.timeIntervalSince(clock), tick, "the track moves on at its rate")
    }

    /// The stall test above fires its ticks by hand, so this one checks that the run loop fires
    /// them by itself. It waits for the first tick to have scheduled a later one, however late a
    /// busy machine runs it.
    func testTheTrackTicksOnTheRunLoopByItself() throws {
        let window = VisibilityControlledWindow(
            contentRect: NSRect(x: 0, y: 0, width: 416, height: 18),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        windows.append(window)
        let view = ScrubberTrackCanvasView(frame: CGRect(x: 0, y: 0, width: 416, height: 18))
        view.drawing = .init(
            trackHeight: 4,
            progress: ScrubberProgress(anchor: playingAnchor(), durationMilliseconds: 240_000, dragFraction: nil),
            dragFraction: nil,
            thumbDiameter: 12,
            overhang: 8,
            colors: ScrubberTrackDrawing.Colors(track: .gray, played: .blue, thumbFill: .white, thumbBorder: .black)
        )
        window.contentView?.addSubview(view)
        defer { view.removeFromSuperview() }

        let firstFireDate = try XCTUnwrap(view.tickTimer).fireDate
        let ticked = expectation(
            for: NSPredicate { _, _ in
                MainActor.assumeIsolated { (view.tickTimer?.fireDate ?? .distantPast) > firstFireDate }
            },
            evaluatedWith: nil
        )
        wait(for: [ticked], timeout: 30)
    }

    func testTheTrackIsNeverHitOrReadByVoiceOver() {
        let view = ScrubberTrackCanvasView(frame: CGRect(x: 0, y: 0, width: 100, height: 18))
        XCTAssertNil(view.hitTest(NSPoint(x: 50, y: 9)), "clicks and hover belong to the surface above it")
        XCTAssertFalse(view.isAccessibilityElement())
    }
}

/// An off-screen test window that tells the track whether it can be seen, the way a minimized,
/// hidden or covered window does through its occlusion state.
private final class VisibilityControlledWindow: OffscreenTestWindow {
    var reportsVisible = true {
        didSet { NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: self) }
    }

    override var occlusionState: NSWindow.OcclusionState {
        reportsVisible ? .visible : []
    }
}

/// Counts the redraws its ticks ask for.
private final class TickCountingTrackView: ScrubberTrackCanvasView {
    var ticks = 0

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue { ticks += 1 }
            super.needsDisplay = newValue
        }
    }
}

private final class LayoutCountingHostingView: NSHostingView<AnyView> {
    var layoutCount = 0

    override func layout() {
        layoutCount += 1
        super.layout()
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
