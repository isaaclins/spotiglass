import Foundation

@MainActor
extension PlaybackSessionViewModel {
    func reanchorProgress(from nowPlaying: PlaybackNowPlaying?, isAdvancing: Bool) {
        guard let nowPlaying, nowPlaying.durationMilliseconds > 0 else {
            progressAnchor = nil
            return
        }
        progressAnchor = PlaybackProgressAnchor(
            positionMilliseconds: nowPlaying.positionMilliseconds,
            anchorDate: Date(),
            durationMilliseconds: nowPlaying.durationMilliseconds,
            isAdvancing: isAdvancing
        )
    }

    func syncProgressAnchorWithConnectionState() {
        switch connectionState {
        case .playing(let nowPlaying):
            reanchorProgress(from: nowPlaying, isAdvancing: true)
        case .paused(let nowPlaying):
            reanchorProgress(from: nowPlaying, isAdvancing: false)
        case .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            progressAnchor = nil
        }
    }
}
