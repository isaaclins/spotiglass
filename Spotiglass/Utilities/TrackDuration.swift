import Foundation

/// The one place a track length becomes text.
///
/// Two files built `"\(minutes):\(seconds)"` by hand, with a fixed colon and
/// Western digits regardless of language, and the result was then parsed back
/// into milliseconds elsewhere. That round trip breaks the moment a locale
/// presents the value differently, so the number is now carried as a number and
/// only formatted at the edge (#159).
enum TrackDuration {
    static func text(milliseconds: Int) -> String {
        text(seconds: max(0, milliseconds) / 1_000)
    }

    static func text(seconds: Int) -> String {
        // No leading zero on minutes, which is what a track listing uses.
        Duration.seconds(max(0, seconds)).formatted(
            .time(pattern: .minuteSecond(padMinuteToLength: 1))
        )
    }

    /// Shown when an item carries no length, for example an unavailable track.
    static var unknownText: String {
        SpotiglassL10n.string("browser.duration.unknown")
    }
}
