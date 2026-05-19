import Foundation

/// Test-observable counters and recovery metrics for playback session behavior.
/// Not `@Published` — UI does not bind to these values.
struct PlaybackSessionDiagnostics: Equatable {
    var playCommandAttemptedCount = 0
    var playCommandDedupedCount = 0
    var playCommandSentCount = 0
    var playCommandSupersededCount = 0
    var nextCommandAttemptedCount = 0
    var nextCommandSentCount = 0
    var nextCommandDroppedDedupeCount = 0
    var nextCommandDroppedLockoutCount = 0
    var nextCommandTimeoutUnlockCount = 0
    var playbackHostReloadAttemptCount = 0
    var playbackHostReloadSuppressedCooldownCount = 0
    var playbackHostReloadSuppressedBudgetCount = 0
    var playbackHostReuseConnectAttemptCount = 0
    var playbackHostReuseSoftResetAttemptCount = 0
    var playbackHostReuseSuccessCount = 0
    var playbackHostRecoveryFailureCount = 0
    var playbackHostReloadAttemptsByCause: [String: Int] = [:]
    var playbackHostReloadSuppressedCooldownByCause: [String: Int] = [:]
    var playbackHostReloadSuppressedBudgetByCause: [String: Int] = [:]
    var playbackHostReuseAttemptsByCause: [String: Int] = [:]
    var playbackHostRecoveryFailuresByCause: [String: Int] = [:]
}
