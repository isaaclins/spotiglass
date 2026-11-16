import Foundation

/// The playback log (#590): what the app asked for and from where, every command it sends to the
/// player, what the player reports back, and jumps in the position. Everything goes to
/// ``SpotiglassLog`` under `playback`, so a report's log alone shows a loop (the same command again
/// and again with no press behind it), a seek back, or a song running fast.
@MainActor
final class PlaybackTrace {
    static let shared = PlaybackTrace()

    /// A command sent again within this long counts as a repeat, and the line says so.
    static let repeatWindow: Duration = .seconds(1)

    private let now: () -> ContinuousClock.Instant
    private let write: (String) -> Void

    /// The last thing the app was asked to do, and when.
    private var lastRequest: (what: String, at: ContinuousClock.Instant)?
    /// The command (shortcut, menu, palette) that is about to make a request.
    private var via: (what: String, at: ContinuousClock.Instant)?
    /// Per command name: when it was last sent and how often in a row within ``repeatWindow``.
    private var lastSent: [String: (at: ContinuousClock.Instant, run: Int)] = [:]
    /// When the app last sent the player anything, so a state change without one is marked as
    /// coming from outside (media keys, Control Center, the system).
    private var lastCommandAt: ContinuousClock.Instant?

    init(
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
        write: @escaping (String) -> Void = { SpotiglassLog.info(.playback, $0) }
    ) {
        self.now = now
        self.write = write
    }

    /// Someone asked the app for `what` (a button, a shortcut, a row, the palette). `file` and
    /// `line` are the caller's, which names the control.
    func request(_ what: String, file: String, line: Int) {
        let fileName = (file as NSString).lastPathComponent
        var label = "\(what) from \(fileName):\(line)"
        // The session calling itself (a fallback, a Retry sending a command again, a handover)
        // isn't a new cause: the request that led to it stays the one commands are blamed on.
        if fileName.hasPrefix("PlaybackSessionViewModel") {
            write("request \(label) (inside the app, after: \(lastRequest?.what ?? "nothing"))")
            return
        }
        let at = now()
        if let via, via.at.duration(to: at) < Self.repeatWindow {
            label += " via \(via.what)"
        }
        via = nil
        lastRequest = (label, at)
        write("request \(label)")
    }

    /// A shortcut, menu item or palette row ran `commandID`; the request it makes next is labelled
    /// with it, since they all reach the player through the same closures.
    func via(_ commandID: String, file: String, line: Int) {
        via = ("\(commandID) from \((file as NSString).lastPathComponent):\(line)", now())
    }

    /// The app sends `command` to the player. The line names the last request and how long ago it
    /// was, and marks a command sent again within ``repeatWindow``.
    func command(_ command: String, _ detail: String = "") {
        let at = now()
        lastCommandAt = at
        var run = 1
        if let last = lastSent[command], last.at.duration(to: at) < Self.repeatWindow {
            run = last.run + 1
        }
        lastSent[command] = (at, run)
        var line = "send \(command)"
        if !detail.isEmpty { line += " \(detail)" }
        if let lastRequest {
            line += " (last request: \(lastRequest.what), \(Self.seconds(lastRequest.at.duration(to: at))) ago)"
        } else {
            line += " (no request since launch)"
        }
        if run > 1 { line += " REPEATED x\(run) within 1 s" }
        write(line)
    }

    /// The player reports something the app didn't just ask for or did: a new status, rate, song.
    func playerReported(_ what: String) {
        let at = now()
        var line = "player \(what)"
        if let lastCommandAt {
            line += " (\(Self.seconds(lastCommandAt.duration(to: at))) after the last command)"
        } else {
            line += " (no command sent since launch)"
        }
        write(line)
    }

    /// A line about the sound path (output device, sample rate, equalizer route).
    func audio(_ what: String) {
        write("audio \(what)")
    }

    nonisolated static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2f s", value)
    }
}

/// Watches the position the player reports while it plays and says when it isn't where the
/// time since playback started (or last jumped) puts it: a jump back (a cut, a seek back), a jump
/// ahead, or a song that runs fast or slow, which adds up until it passes ``tolerance``. A position
/// that stops moving while the player says it plays is reported once when it sticks and once when
/// it moves again. A song that starts over from its end (repeat one) starts the comparison over
/// without a line. Readings come once a second from the session's poll.
struct PlaybackPositionWatch {
    /// How far off the expected position a reading may be before it counts. The poll itself can
    /// be a few hundred milliseconds late.
    static let tolerance: Duration = .milliseconds(1500)
    /// A position that moved less than this between two readings at least ``stuckAfter`` apart
    /// hasn't moved.
    static let stillWithin = 200
    static let stuckAfter: Duration = .milliseconds(500)
    /// How close to a song's end and start a jump back has to be to count as the song starting over.
    static let loopMargin = 5_000

    private var anchor: (positionMilliseconds: Int, at: ContinuousClock.Instant, item: String?)?
    private var last: (positionMilliseconds: Int, at: ContinuousClock.Instant)?
    private var stuck: (positionMilliseconds: Int, since: ContinuousClock.Instant)?

    /// Forgets the reference point: the app itself moved the position (a seek).
    mutating func reset() {
        anchor = nil
        last = nil
        stuck = nil
    }

    /// A reading. Returns a line to log when the position jumped, drifted, stuck or moved again.
    mutating func observe(
        positionMilliseconds: Int,
        isPlaying: Bool,
        item: String?,
        durationMilliseconds: Int? = nil,
        at instant: ContinuousClock.Instant
    ) -> String? {
        guard isPlaying else {
            reset()
            return nil
        }
        guard let anchor, anchor.item == item else {
            reset()
            restart(positionMilliseconds, at: instant, item: item)
            return nil
        }
        let previous = last
        last = (positionMilliseconds, instant)

        if let stuck {
            guard abs(positionMilliseconds - stuck.positionMilliseconds) > Self.stillWithin else { return nil }
            self.stuck = nil
            restart(positionMilliseconds, at: instant, item: item)
            return "position moving again at \(Self.time(positionMilliseconds)) after "
                + "\(PlaybackTrace.seconds(stuck.since.duration(to: instant))) stuck at \(Self.time(stuck.positionMilliseconds))"
        }
        if let previous, previous.at.duration(to: instant) >= Self.stuckAfter,
           abs(positionMilliseconds - previous.positionMilliseconds) <= Self.stillWithin {
            stuck = (positionMilliseconds, previous.at)
            return "position stuck at \(Self.time(positionMilliseconds)) while playing"
        }
        if let previous, let durationMilliseconds,
           previous.positionMilliseconds >= durationMilliseconds - Self.loopMargin,
           positionMilliseconds <= Self.loopMargin {
            restart(positionMilliseconds, at: instant, item: item)
            return nil
        }

        let elapsed = anchor.at.duration(to: instant)
        let elapsedMilliseconds = Int(elapsed / .milliseconds(1))
        let expected = anchor.positionMilliseconds + elapsedMilliseconds
        let off = positionMilliseconds - expected
        guard abs(off) > Int(Self.tolerance / .milliseconds(1)) else { return nil }
        restart(positionMilliseconds, at: instant, item: item)
        let direction = off > 0 ? "ahead" : "back"
        let speed = elapsedMilliseconds > 0
            ? String(format: "%.2fx", Double(positionMilliseconds - anchor.positionMilliseconds) / Double(elapsedMilliseconds))
            : "?"
        return "position \(direction) by \(Self.time(abs(off))): expected \(Self.time(expected)), "
            + "player says \(Self.time(positionMilliseconds)), "
            + "\(PlaybackTrace.seconds(elapsed)) after \(Self.time(anchor.positionMilliseconds)) (\(speed) speed)"
    }

    private mutating func restart(_ positionMilliseconds: Int, at instant: ContinuousClock.Instant, item: String?) {
        anchor = (positionMilliseconds, instant, item)
        last = (positionMilliseconds, instant)
    }

    static func time(_ milliseconds: Int) -> String {
        String(format: "%d:%04.1f", milliseconds / 60_000, Double(milliseconds % 60_000) / 1000)
    }
}
