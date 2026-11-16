import Foundation
import XCTest
@testable import Spotiglass

/// The playback log (#590): a report's log alone has to show a command loop, where each command
/// came from, and a position that jumps or runs fast.
@MainActor
final class PlaybackTraceTests: XCTestCase {
    private var time = ContinuousClock.now
    private var lines: [String] = []

    private func makeTrace() -> PlaybackTrace {
        PlaybackTrace(now: { [unowned self] in time }, write: { [unowned self] in lines.append($0) })
    }

    func testACommandSentAgainWithinASecondIsMarkedAsARepeat() {
        let trace = makeTrace()
        trace.request("play/pause (appleMusic)", file: "Spotiglass/PlaybackControlsView.swift", line: 625)
        time += .milliseconds(20)
        trace.command("pause")
        // A loop: the same command again and again with no press behind it.
        time += .milliseconds(300)
        trace.command("pause")
        time += .milliseconds(300)
        trace.command("pause")

        XCTAssertEqual(lines[0], "request play/pause (appleMusic) from PlaybackControlsView.swift:625")
        XCTAssertEqual(lines[1], "send pause (last request: play/pause (appleMusic) from PlaybackControlsView.swift:625, 0.02 s ago)")
        XCTAssertFalse(lines[1].contains("REPEATED"))
        XCTAssertTrue(lines[2].hasSuffix("0.32 s ago) REPEATED x2 within 1 s"), lines[2])
        XCTAssertTrue(lines[3].hasSuffix("0.62 s ago) REPEATED x3 within 1 s"), lines[3])
    }

    func testACommandASecondApartOrADifferentCommandIsNotARepeat() {
        let trace = makeTrace()
        trace.command("seek", "to 0:10.0")
        time += .milliseconds(100)
        trace.command("pause")
        time += .seconds(1)
        trace.command("seek", "to 0:20.0")

        XCTAssertEqual(lines[0], "send seek to 0:10.0 (no request since launch)")
        XCTAssertFalse(lines.contains { $0.contains("REPEATED") }, lines.joined(separator: "\n"))
    }

    func testAStateChangeSaysHowLongAfterTheLastCommandItCame() {
        let trace = makeTrace()
        trace.playerReported("status playing -> paused at 0:42.0")
        trace.command("pause")
        time += .milliseconds(250)
        trace.playerReported("status playing -> paused at 0:42.3")

        XCTAssertEqual(lines[0], "player status playing -> paused at 0:42.0 (no command sent since launch)")
        XCTAssertEqual(lines[2], "player status playing -> paused at 0:42.3 (0.25 s after the last command)")
    }

    func testAPositionThatJumpsBackWhilePlayingIsReported() {
        var watch = PlaybackPositionWatch()
        let start = ContinuousClock.now
        XCTAssertNil(watch.observe(positionMilliseconds: 40_000, isPlaying: true, item: "a", at: start))
        // A late poll is no jump.
        XCTAssertNil(watch.observe(positionMilliseconds: 41_000, isPlaying: true, item: "a", at: start + .milliseconds(1400)))
        let line = watch.observe(positionMilliseconds: 38_000, isPlaying: true, item: "a", at: start + .seconds(2))
        XCTAssertEqual(line, "position back by 0:04.0: expected 0:42.0, player says 0:38.0, 2.00 s after 0:40.0 (-1.00x speed)")
    }

    func testASongRunningFastAddsUpUntilItIsReported() {
        var watch = PlaybackPositionWatch()
        let start = ContinuousClock.now
        var reported: [Int: String] = [:]
        // 8 % fast, read once a second: each reading is only 80 ms off the one before.
        for second in 0...30 {
            let position = 10_000 + second * 1080
            if let line = watch.observe(positionMilliseconds: position, isPlaying: true, item: "a", at: start + .seconds(second)) {
                reported[second] = line
            }
        }
        XCTAssertEqual(reported.keys.sorted(), [19], reported.values.joined(separator: "\n"))
        XCTAssertTrue(reported[19]?.hasSuffix("(1.08x speed)") == true, reported[19] ?? "")
    }

    func testPausesSeeksAndNewSongsStartOver() {
        var watch = PlaybackPositionWatch()
        let start = ContinuousClock.now
        _ = watch.observe(positionMilliseconds: 10_000, isPlaying: true, item: "a", at: start)
        XCTAssertNil(watch.observe(positionMilliseconds: 10_000, isPlaying: false, item: "a", at: start + .seconds(5)))
        XCTAssertNil(watch.observe(positionMilliseconds: 10_000, isPlaying: true, item: "a", at: start + .seconds(6)))
        XCTAssertNil(watch.observe(positionMilliseconds: 0, isPlaying: true, item: "b", at: start + .seconds(7)))
        watch.reset()
        XCTAssertNil(watch.observe(positionMilliseconds: 90_000, isPlaying: true, item: "b", at: start + .seconds(8)))
        XCTAssertNil(watch.observe(positionMilliseconds: 91_000, isPlaying: true, item: "b", at: start + .seconds(9)))
    }
}
