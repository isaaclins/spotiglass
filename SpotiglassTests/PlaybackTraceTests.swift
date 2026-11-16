import CoreAudio
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

    func testAddingSeveralSongsIsNumberedNotARepeatAndANewRequestStartsANewRun() {
        let trace = makeTrace()
        trace.request("add 3 to the queue", file: "Spotiglass/AlbumView.swift", line: 88, planned: 3)
        for _ in 0..<3 {
            time += .milliseconds(50)
            trace.command("addToQueue")
        }
        XCTAssertTrue(lines[2].hasSuffix("ago) (2 of 3 asked for)"), lines[2])
        XCTAssertTrue(lines[3].hasSuffix("ago) (3 of 3 asked for)"), lines[3])
        // A fourth with no new request is a repeat.
        time += .milliseconds(50)
        trace.command("addToQueue")
        XCTAssertTrue(lines[4].hasSuffix("REPEATED x4 within 1 s"), lines[4])
        // Two quick presses are two runs of one, not a repeat.
        trace.request("pause", file: "Spotiglass/PlaybackControlsView.swift", line: 625)
        trace.command("pause")
        time += .milliseconds(200)
        trace.request("pause", file: "Spotiglass/PlaybackControlsView.swift", line: 625)
        trace.command("pause")
        XCTAssertFalse(lines[8].contains("REPEATED"), lines[8])
        // Songs carried into a shuffled queue say how many are on purpose.
        trace.command("carried", planned: 2)
        time += .milliseconds(10)
        trace.command("carried", planned: 2)
        XCTAssertTrue(lines[10].hasSuffix("(2 of 2 asked for)"), lines[10])
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

    func testAPositionThatStopsMovingWhilePlayingIsReportedOnceAndAgainWhenItMoves() {
        var watch = PlaybackPositionWatch()
        let start = ContinuousClock.now
        var lines: [Int: String] = [:]
        // Plays 0:10 to 0:13, then stays at 0:13 for a minute while the player says "playing".
        for second in 0...70 {
            let position = second <= 3 ? 10_000 + second * 1000 : (second < 63 ? 13_000 : 13_000 + (second - 62) * 1000)
            if let line = watch.observe(positionMilliseconds: position, isPlaying: true, item: "a", at: start + .seconds(second)) {
                lines[second] = line
            }
        }
        XCTAssertEqual(lines.keys.sorted(), [4, 63], lines.values.joined(separator: "\n"))
        XCTAssertEqual(lines[4], "position stuck at 0:13.0 while playing")
        XCTAssertEqual(lines[63], "position moving again at 0:14.0 after 60.00 s stuck at 0:13.0")
    }

    func testRepeatOneStartingTheSongOverIsNoJump() {
        var watch = PlaybackPositionWatch()
        let start = ContinuousClock.now
        XCTAssertNil(watch.observe(positionMilliseconds: 178_000, isPlaying: true, item: "a", durationMilliseconds: 180_000, at: start))
        XCTAssertNil(watch.observe(positionMilliseconds: 179_000, isPlaying: true, item: "a", durationMilliseconds: 180_000, at: start + .seconds(1)))
        XCTAssertNil(watch.observe(positionMilliseconds: 800, isPlaying: true, item: "a", durationMilliseconds: 180_000, at: start + .seconds(2)))
        XCTAssertNil(watch.observe(positionMilliseconds: 1_800, isPlaying: true, item: "a", durationMilliseconds: 180_000, at: start + .seconds(3)))
        // A jump back in the middle of the song still counts.
        XCTAssertNotNil(watch.observe(positionMilliseconds: 100, isPlaying: true, item: "a", durationMilliseconds: 180_000, at: start + .seconds(30)))
    }

    func testACommandFromAShortcutMenuOrPaletteNamesItAndAnInternalCallKeepsTheCause() {
        let trace = makeTrace()
        trace.via("playback.togglePlayPause", file: "Spotiglass/CommandPaletteManager.swift", line: 704)
        trace.request("play/pause (appleMusic)", file: "Spotiglass/PlaylistBrowserCommandPaletteConfiguration.swift", line: 72)
        trace.request("play x (appleMusic)", file: "Spotiglass/PlaybackSessionViewModel+PlayCommands.swift", line: 141)
        trace.command("pause")
        let cause = "play/pause (appleMusic) from PlaylistBrowserCommandPaletteConfiguration.swift:72 via playback.togglePlayPause from CommandPaletteManager.swift:704"
        XCTAssertEqual(lines[0], "request \(cause)")
        XCTAssertTrue(lines[1].hasSuffix("(inside the app, after: \(cause))"), lines[1])
        XCTAssertTrue(lines[2].contains("last request: \(cause),"), lines[2])
        // A command that doesn't reach the player doesn't label the click after it.
        trace.via("view.sidebar.toggle", file: "Spotiglass/SpotiglassMenuCommands.swift", line: 178)
        trace.request("add x to the queue", file: "Spotiglass/TrackListRow.swift", line: 90)
        XCTAssertEqual(lines[3], "request add x to the queue from TrackListRow.swift:90")
        // A shortcut a while ago doesn't label a later click.
        time += .seconds(2)
        trace.via("playback.next", file: "Spotiglass/CommandPaletteManager.swift", line: 704)
        time += .seconds(2)
        trace.request("next (appleMusic)", file: "Spotiglass/PlaybackControlsView.swift", line: 611)
        XCTAssertEqual(lines[4], "request next (appleMusic) from PlaybackControlsView.swift:611")
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

/// The sound path in the log (#590): the default output and every output's sample rate.
@MainActor
final class AudioOutputTraceTests: XCTestCase {
    func testStartLogsTheDefaultOutputAndEveryOutputsRateOnceUntilSomethingChanges() {
        var lines: [String] = []
        let trace = AudioOutputTrace(write: { lines.append($0) })
        defer { trace.stop() }
        trace.start()
        trace.start()
        XCTAssertEqual(lines.count, 1, lines.joined(separator: "\n"))
        XCTAssertTrue(lines[0].hasPrefix("default output "), lines[0])
        XCTAssertTrue(lines[0].contains("; outputs: "), lines[0])
        for device in MacAudioOutputHardware.enumerateOutputDevices() {
            XCTAssertTrue(lines[0].contains(", \(device.id)) "), lines[0])
            XCTAssertTrue(lines[0].contains(", \(device.id)) "), lines[0])
        }
        if let id = MacAudioOutputHardware.defaultOutputDeviceID(),
           let rate = MacAudioOutputHardware.nominalSampleRate(deviceID: id) {
            XCTAssertTrue(lines[0].contains(", \(id)) \(Int(rate)) Hz"), lines[0])
        }

        // An equalizer route change logs the path again, with why.
        trace.log(reason: "equalizer route off -> starting(target none)")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasSuffix(" [equalizer route off -> starting(target none)]"), lines[1])
    }

    func testWirelessDevicesAreNamedOnlyByTheirKind() {
        XCTAssertEqual(AudioOutputTrace.publicName("AirPods Max von Isaac", transport: "bluetooth"), "bluetooth device")
        XCTAssertEqual(AudioOutputTrace.publicName("Isaac\u{2019}s HomePod", transport: "airplay"), "airplay device")
        XCTAssertEqual(AudioOutputTrace.publicName("MacBook Pro Speakers", transport: "built-in"), "MacBook Pro Speakers")
        XCTAssertEqual(AudioOutputTrace.describe(uid: "00-11-22-33-44-55:output"), "a device that is gone")
    }

    func testARealDevicesUIDIsDescribedByItsIDNotItsUID() throws {
        guard let id = MacAudioOutputHardware.defaultOutputDeviceID() else { throw XCTSkip("no output device") }
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid) == noErr,
              let uidString = uid?.takeRetainedValue() as String? else { throw XCTSkip("no UID") }
        let line = AudioOutputTrace.describe(uid: uidString)
        XCTAssertTrue(line.contains(", \(id)) "), line)
        XCTAssertFalse(line.contains(uidString), line)
    }

    func testTheEqualizerRouteIsDescribedWithoutItsMessage() {
        let target = { (uid: String) in uid == "AA-BB-CC-DD-EE-FF:output" ? "bluetooth device (bluetooth, 91) 48000 Hz" : "?" }
        XCTAssertEqual(EqualizerRouteState.disabled.logDescription(target: target), "off")
        XCTAssertEqual(EqualizerRouteState.starting(targetUID: nil).logDescription(target: target), "starting(target none)")
        let live = EqualizerRouteState.live(targetUID: "AA-BB-CC-DD-EE-FF:output", errorMessage: nil).logDescription(target: target)
        XCTAssertEqual(live, "live(target bluetooth device (bluetooth, 91) 48000 Hz)")
        XCTAssertFalse(live.contains("AA-BB"))
        XCTAssertEqual(EqualizerRouteState.failed(message: nil, isEngaged: true).logDescription(target: target), "failed(still engaged)")
        XCTAssertEqual(EqualizerRouteState.failed(message: nil, isEngaged: false).logDescription(target: target), "failed(released)")
    }
}
