import Foundation

/// One seek step, shared by the Playback menu items and the scrubber's
/// VoiceOver adjustable action so both move by the same amount.
enum PlaybackSeekStep {
    static let milliseconds = 5_000
}
