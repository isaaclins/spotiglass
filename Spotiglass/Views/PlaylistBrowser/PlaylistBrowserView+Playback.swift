import SwiftUI

extension PlaylistBrowserView {
    var isLyricsPresentedBinding: Binding<Bool> {
        Binding(
            get: { lyricsOverlay.isPresented },
            set: { newValue in
                if newValue, !lyricsOverlay.isPresented {
                    pendingPlaylistListScrollRestoreID = anchorTrackIDForPlaylistListScrollRestore()
                }
                lyricsOverlay.isPresented = newValue
            }
        )
    }

    /// Prefer the visible playlist row that matches the current Spotify URI; otherwise last `TrackListRow.onAppear` id.
    func anchorTrackIDForPlaylistListScrollRestore() -> String? {
        guard let content = viewModel.detailState.currentValue else { return detailLastVisibleTrackID }
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

    /// Now playing track used to prefetch LRCLIB lyrics before the lyrics overlay opens (only while transport is playing).
    var lyricsPrefetchTrack: PlaybackNowPlaying? {
        switch playbackViewModel.connectionState {
        case let .playing(np):
            return np
        case .paused, .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            return nil
        }
    }

    /// Stable while the current item is under halfway; becomes non-nil once past 50% so a `.task(id:)` can preload the next track’s lyrics once.
    var lyricsHalfwayNextPreloadTaskKey: String? {
        guard let np = lyricsPrefetchTrack,
              np.durationMilliseconds > 0,
              np.spotifyTrackIDForLyrics != nil
        else { return nil }
        guard np.positionMilliseconds * 2 >= np.durationMilliseconds else { return nil }
        let nextURI = queueViewModel.upcomingItems.first?.uri ?? ""
        return "\(np.uri ?? "")|\(nextURI)"
    }

    /// Playback identity without scrubber position ticks (avoids re-running queue hooks every progress frame).
    /// Includes playing vs paused so the queue refetches after transport changes (Spotify’s REST queue reflects play state).
    /// Track URI still identifies the current item when it advances.
    var queueRelevantPlaybackKey: String {
        switch playbackViewModel.connectionState {
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

    var currentPlaybackURI: String? {
        switch playbackViewModel.connectionState {
        case let .playing(nowPlaying):
            nowPlaying.uri
        case let .paused(nowPlaying):
            nowPlaying?.uri
        case .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            nil
        }
    }

    var isCurrentlyPlaying: Bool {
        if case .playing = playbackViewModel.connectionState { return true }
        return false
    }

    var hasPlaybackDevice: Bool {
        playbackViewModel.deviceID != nil
    }
}
