import Foundation

/// A command the player refused with an error whose fix is Retry (a network error, a server
/// error, a rate limit): Retry sends it again instead of only moving playback here (#451).
struct FailedPlaybackCommand {
    /// What the bar showed before the error: Retry goes back to it while the command is sent.
    let restoreState: PlaybackConnectionState?
    let resend: @MainActor (PlaybackSessionViewModel) async -> Void
}

@MainActor
extension PlaybackSessionViewModel {
    /// Shows a failed command's error and, when it offers Retry, keeps the command for it.
    func showFailedCommand(
        _ error: Error,
        resend: @escaping @MainActor (PlaybackSessionViewModel) async -> Void
    ) {
        let restoreState = stateToRestoreOnRetry()
        setConnectionState(.error(Self.displayError(for: error)))
        guard case let .error(shown) = connectionState, shown.recoveryAction == .retryTransfer else { return }
        failedCommand = FailedPlaybackCommand(restoreState: restoreState, resend: resend)
    }

    /// Whether Retry sends a failed command again rather than moving playback here.
    var retriesFailedCommand: Bool {
        failedCommand != nil
    }

    private func stateToRestoreOnRetry() -> PlaybackConnectionState? {
        switch connectionState {
        case .error:
            // A command sent from an error that failed too: go back to what was before that one.
            // With nothing kept, go where the old Retry left the bar, so the error and its Retry
            // don't stay up while the command goes out (a second click moved playback here with
            // `play: false` next to the command sent again).
            failedCommand?.restoreState ?? deviceID.map { .ready(deviceID: $0) }
        case let .transferring(deviceID):
            // A play moves playback here first; the play sent again does that again.
            .ready(deviceID: deviceID)
        case .disconnected, .connecting, .ready, .unavailable, .playing, .paused:
            connectionState
        }
    }
}
