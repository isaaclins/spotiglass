import Foundation

/// Testable playback-derived values for playlist browser UI (scroll restore, lyrics prefetch, queue hooks).
enum PlaylistBrowserPlaybackHelpers {
    static func anchorTrackIDForPlaylistListScrollRestore(
        detailContent: BrowsingDetailContent?,
        currentPlaybackURI: String?,
        detailLastVisibleTrackID: String?
    ) -> String? {
        guard let content = detailContent else { return detailLastVisibleTrackID }
        switch content {
        case let .playlist(detail):
            if let uri = currentPlaybackURI,
               let row = detail.tracks.first(where: { $0.playableURI == uri }) {
                return row.id
            }
        case let .artist(detail):
            if let uri = currentPlaybackURI,
               let row = detail.tracks.first(where: { $0.playableURI == uri }) {
                return row.id
            }
        }
        return detailLastVisibleTrackID
    }

    static func lyricsPrefetchTrack(connectionState: PlaybackConnectionState) -> PlaybackNowPlaying? {
        switch connectionState {
        case let .playing(np):
            return np
        case .paused, .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            return nil
        }
    }

    static func lyricsHalfwayNextPreloadTaskID(
        prefetchTrack: PlaybackNowPlaying?,
        nextQueueURI: String?
    ) -> String? {
        guard let np = prefetchTrack,
              np.durationMilliseconds > 0,
              np.spotifyTrackIDForLyrics != nil
        else { return nil }
        let nextURI = nextQueueURI ?? ""
        return "\(np.uri ?? "")|\(np.durationMilliseconds)|\(nextURI)"
    }

    static func queueRelevantPlaybackKey(connectionState: PlaybackConnectionState) -> String {
        switch connectionState {
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case let .ready(deviceID):
            "ready:\(deviceID)"
        case let .transferring(deviceID):
            "transferring:\(deviceID)"
        case let .playing(item):
            "playing:\(item.uri ?? "")"
        case let .paused(.some(item)):
            "paused:\(item.uri ?? "")"
        case .paused(.none):
            "paused-empty"
        case let .unavailable(message):
            "unavailable:\(message)"
        case let .error(error):
            "error:\(error.title)"
        }
    }

    static func currentPlaybackURI(connectionState: PlaybackConnectionState) -> String? {
        switch connectionState {
        case let .playing(nowPlaying):
            nowPlaying.uri
        case let .paused(nowPlaying):
            nowPlaying?.uri
        case .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            nil
        }
    }

    static func isCurrentlyPlaying(connectionState: PlaybackConnectionState) -> Bool {
        if case .playing = connectionState { return true }
        return false
    }
}
