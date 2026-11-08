import AppKit
import SwiftUI
import XCTest
@testable import Spotiglass

/// The progress bar lost the first click while a track played, and its
/// timeline redrew at display rate the whole time (#394).
@MainActor
final class ScrubberViewTests: XCTestCase {
    private let groupSize = CGSize(width: 400, height: 48)

    private var hostedWindows: [NSWindow] = []

    override func tearDown() {
        hostedWindows.forEach(AppKitTestSupport.closeWindowSafely)
        hostedWindows.removeAll()
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    // MARK: - Click while playing

    /// Replays the report: a track is playing, the listener clicks the bar once.
    /// Before the fix the press switched the row from its ticking branch to its
    /// static branch, SwiftUI dropped the gesture with the old view, and the
    /// release never arrived, so no seek was sent.
    func testSingleClickWhilePlayingSeeks() throws {
        var seeks: [Int] = []
        let window = hostGroup(isAdvancing: true) { seeks.append($0) }

        click(in: window, atFraction: 0.75)

        XCTAssertEqual(seeks.count, 1, "the first click while playing must seek")
        let seek = try XCTUnwrap(seeks.first)
        XCTAssertGreaterThan(seek, 90_000, "a click at three quarters seeks past the playing position")
        XCTAssertLessThan(seek, 180_000)
    }

    /// The same click on a paused track already worked; it must keep working.
    func testSingleClickWhilePausedSeeks() {
        var seeks: [Int] = []
        let window = hostGroup(isAdvancing: false) { seeks.append($0) }

        click(in: window, atFraction: 0.75)

        XCTAssertEqual(seeks.count, 1)
    }

    /// Two clicks in a row each seek once: the first one must not leave a drag
    /// position behind that swallows or distorts the second.
    func testEveryClickWhilePlayingSeeksOnce() {
        var seeks: [Int] = []
        let window = hostGroup(isAdvancing: true) { seeks.append($0) }

        click(in: window, atFraction: 0.75)
        click(in: window, atFraction: 0.25)

        XCTAssertEqual(seeks.count, 2)
        if seeks.count == 2 {
            XCTAssertGreaterThan(seeks[0], seeks[1])
        }
    }

    // MARK: - Tick rate

    /// A typical bar (about 400 pt) and a 3-minute song move the fill ~2.2 pt a
    /// second, so 5 ticks a second keep each step under half a point. The old
    /// `.animation` schedule ran at the display rate (60 to 120 a second).
    func testTicksJustOftenEnoughForHalfAPointPerTick() {
        XCTAssertEqual(
            ScrubberTimelineSchedule.ticksPerSecond(durationMilliseconds: 180_000, trackWidth: 400),
            5
        )
        // A long track barely moves: once a second for the labels.
        XCTAssertEqual(
            ScrubberTimelineSchedule.ticksPerSecond(durationMilliseconds: 3_600_000, trackWidth: 400),
            1
        )
        // A very short clip on a wide bar is capped.
        XCTAssertEqual(
            ScrubberTimelineSchedule.ticksPerSecond(durationMilliseconds: 5_000, trackWidth: 1_200),
            ScrubberTimelineSchedule.maximumTicksPerSecond
        )
        XCTAssertEqual(ScrubberTimelineSchedule.ticksPerSecond(durationMilliseconds: 0, trackWidth: 400), 1)
    }

    func testPlayingScheduleTicksAtThatRateAndLandsOnEverySecond() {
        let anchorDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let anchor = PlaybackProgressAnchor(
            positionMilliseconds: 12_345,
            anchorDate: anchorDate,
            durationMilliseconds: 180_000,
            isAdvancing: true
        )
        let schedule = ScrubberTimelineSchedule(anchor: anchor, isPaused: false, trackWidth: 400)
        let start = anchorDate.addingTimeInterval(0.1)
        let dates = Array(schedule.entries(from: start, mode: .normal).prefix(51))

        XCTAssertEqual(dates.first, start)
        let ticks = Array(dates.dropFirst())
        for (earlier, later) in zip(ticks, ticks.dropFirst()) {
            XCTAssertEqual(later.timeIntervalSince(earlier), 0.2, accuracy: 0.000_1)
        }
        // Ten seconds of ticks show every whole second of position exactly once.
        let seconds = ticks.map { anchor.interpolatedPositionMs(at: $0) / 1_000 }
        XCTAssertEqual(Set(seconds), Set(12 ... 22))
        let secondStarts = ticks.filter { anchor.interpolatedPositionMs(at: $0) % 1_000 < 10 }
        XCTAssertEqual(secondStarts.count, 10, "a tick lands right after every whole second")
    }

    /// Real tracks rarely last a whole number of seconds. With the labels'
    /// ticks on the elapsed time's seconds, the remaining time of a 3:00.010
    /// track still read -3:00 half a second in, when 2:59.51 remained. Each
    /// label must show, at every moment, the text it would show if redrawn then.
    func testBothLabelsAreNeverStaleOnATrackWithLeftoverMilliseconds() {
        let anchorDate = Date(timeIntervalSinceReferenceDate: 1_000)
        for (duration, start) in [(180_010, 0), (243_412, 61_250), (200_999, 5)] {
            let progress = ScrubberProgress(
                anchor: PlaybackProgressAnchor(
                    positionMilliseconds: start,
                    anchorDate: anchorDate,
                    durationMilliseconds: duration,
                    isAdvancing: true
                ),
                durationMilliseconds: duration
            )
            let labels: [(name: String, boundary: Int, text: (Int) -> String)] = [
                ("elapsed", 0, { PlaybackProgressScrubberGroup.elapsedText(positionMs: $0) }),
                ("remaining", progress.remainingBoundaryMilliseconds, {
                    PlaybackProgressScrubberGroup.remainingText(positionMs: $0, durationMs: duration)
                }),
            ]
            for label in labels {
                let ticks = Array(
                    progress.schedule(trackWidth: 0, boundaryMilliseconds: label.boundary)
                        .entries(from: anchorDate, mode: .normal)
                        .prefix(12)
                )
                // Every 10 ms over ten seconds. A tick lands 2 ms after its
                // boundary, so the text may still be the one from 3 ms ago.
                for step in 0 ..< 1_000 {
                    let now = anchorDate.addingTimeInterval(Double(step) / 100 + 0.005)
                    guard let shown = ticks.last(where: { $0 <= now }) else { continue }
                    let shownText = label.text(progress.positionMilliseconds(at: shown))
                    XCTAssertTrue(
                        [now, now.addingTimeInterval(-0.003)]
                            .map { label.text(progress.positionMilliseconds(at: $0)) }
                            .contains(shownText),
                        "\(label.name) label shows \(shownText), stale \(now.timeIntervalSince(anchorDate)) s into a \(duration) ms track"
                    )
                }
            }
        }
    }

    func testPausedDraggingOrFinishedScheduleDoesNotWakeAgain() {
        let anchorDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let playing = PlaybackProgressAnchor(
            positionMilliseconds: 10_000,
            anchorDate: anchorDate,
            durationMilliseconds: 180_000,
            isAdvancing: true
        )
        var paused = playing
        paused.isAdvancing = false
        let start = anchorDate.addingTimeInterval(1)

        func entries(_ schedule: ScrubberTimelineSchedule, from date: Date = start) -> [Date] {
            Array(schedule.entries(from: date, mode: .normal).prefix(5))
        }

        XCTAssertEqual(entries(ScrubberTimelineSchedule(anchor: paused, isPaused: false, trackWidth: 400)), [start])
        XCTAssertEqual(entries(ScrubberTimelineSchedule(anchor: nil, isPaused: false, trackWidth: 400)), [start])
        XCTAssertEqual(entries(ScrubberTimelineSchedule(anchor: playing, isPaused: true, trackWidth: 400)), [start])

        let afterEnd = anchorDate.addingTimeInterval(200)
        XCTAssertEqual(
            entries(ScrubberTimelineSchedule(anchor: playing, isPaused: false, trackWidth: 400), from: afterEnd),
            [afterEnd]
        )

        // Near the end the last tick is the end itself, then the schedule stops.
        let endDate = anchorDate.addingTimeInterval(170)
        let nearEnd = endDate.addingTimeInterval(-0.3)
        let tail = Array(
            ScrubberTimelineSchedule(anchor: playing, isPaused: false, trackWidth: 400)
                .entries(from: nearEnd, mode: .normal)
                .prefix(10)
        )
        XCTAssertEqual(tail.last, endDate)
        XCTAssertLessThanOrEqual(tail.count, 4)
    }

    func testLowFrequencyModeTicksOncePerSecond() {
        let anchorDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let anchor = PlaybackProgressAnchor(
            positionMilliseconds: 0,
            anchorDate: anchorDate,
            durationMilliseconds: 5_000,
            isAdvancing: true
        )
        let schedule = ScrubberTimelineSchedule(anchor: anchor, isPaused: false, trackWidth: 1_200)
        let ticks = Array(schedule.entries(from: anchorDate, mode: .lowFrequency).dropFirst().prefix(3))
        XCTAssertEqual(ticks.count, 3)
        for (earlier, later) in zip(ticks, ticks.dropFirst()) {
            XCTAssertEqual(later.timeIntervalSince(earlier), 1, accuracy: 0.000_1)
        }
    }

    // MARK: - Drawing

    /// At the end of a track the thumb hangs half its width past the end of the
    /// bar, as it always did. Drawn in a canvas exactly as wide as the bar, its
    /// right half was clipped away.
    func testThumbAtTheEndOfTheTrackIsDrawnWhole() throws {
        let barWidth: CGFloat = 200, margin: CGFloat = 20
        let view = ScrubberView(
            progress: ScrubberProgress(
                anchor: PlaybackProgressAnchor(
                    positionMilliseconds: 180_000,
                    anchorDate: Date(),
                    durationMilliseconds: 180_000,
                    isAdvancing: false
                ),
                durationMilliseconds: 180_000
            ),
            onSeek: { _ in },
            onDragUpdate: { _ in }
        )
        .frame(width: barWidth)
        .padding(margin)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        AppKitTestSupport.pumpRunLoop(for: 0.1)

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        func brightness(atX x: CGFloat) -> CGFloat {
            let color = bitmap.colorAt(x: Int(x * scale), y: Int(host.bounds.midY * scale))?
                .usingColorSpace(.sRGB)
            return color?.brightnessComponent ?? 0
        }
        // 3 pt past the end of the bar, inside the thumb's right half.
        XCTAssertGreaterThan(brightness(atX: margin + barWidth + 3), 0.5, "the thumb's right half is missing")
        // Well past the thumb, only the background.
        XCTAssertLessThan(brightness(atX: margin + barWidth + 12), 0.2)
    }

    // MARK: - Helpers

    private func hostGroup(isAdvancing: Bool, onSeek: @escaping (Int) -> Void) -> NSWindow {
        let view = PlaybackProgressScrubberGroup(
            progressAnchor: PlaybackProgressAnchor(
                positionMilliseconds: 60_000,
                anchorDate: Date(),
                durationMilliseconds: 180_000,
                isAdvancing: isAdvancing
            ),
            durationMilliseconds: 180_000,
            isEnabled: true,
            onSeek: onSeek
        )
        .frame(width: groupSize.width, height: groupSize.height)

        let controller = NSHostingController(rootView: view)
        let window = ClickableTestWindow(
            contentRect: NSRect(origin: .zero, size: groupSize),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        hostedWindows.append(window)
        window.orderFrontRegardless()
        window.makeKey()
        AppKitTestSupport.pumpRunLoop(for: 0.3)
        return window
    }

    /// Sends a real press and release through the window, the way AppKit
    /// delivers a click. The x position is a fraction of the whole row, so 0.75
    /// lands well inside the track between the two time labels.
    private func click(in window: NSWindow, atFraction fraction: CGFloat) {
        let content = window.contentView!
        let pointInContent = CGPoint(x: content.bounds.width * fraction, y: content.bounds.midY)
        let location = content.convert(pointInContent, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            )!
            window.sendEvent(event)
            // A playing row redraws between press and release, as it does when
            // a person clicks; that redraw is what dropped the gesture.
            AppKitTestSupport.pumpRunLoop(for: 0.15)
        }
    }
}

/// SwiftUI hands mouse events to gestures only in the key window. A test run
/// cannot always make its process the active app, so this window reports
/// itself key without taking focus from whatever is in front.
private final class ClickableTestWindow: OffscreenTestPanel {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
}
