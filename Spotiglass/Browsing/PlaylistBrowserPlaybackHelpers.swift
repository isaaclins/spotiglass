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
        case .home, .search:
            break
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
              np.lyricsTrackKey != nil
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

    /// The URI the rows of `detailContent` mark as playing (#396). Apple Music names one song by
    /// different ids depending on where it was read (a library `i.` id from search, the library's
    /// persistent id inside an album or playlist), and its player reports the id of the row the
    /// song was started from. So when no row of this list has that URI, a song started elsewhere
    /// is found by what the row shows: title, artists and length. Spotify's ids are the same
    /// everywhere, so its rows match by URI only.
    static func currentPlaybackURI(
        connectionState: PlaybackConnectionState,
        detailContent: BrowsingDetailContent?
    ) -> String? {
        let uri = currentPlaybackURI(connectionState: connectionState)
        guard let uri, uri.hasPrefix(AppleMusicItemMapping.uriScheme + ":"),
              let nowPlaying = nowPlaying(connectionState: connectionState)
        else { return uri }
        let rows: [TrackRowViewModel]
        switch detailContent {
        case let .playlist(detail)?: rows = detail.tracks
        case let .artist(detail)?: rows = detail.tracks
        case .home?, .search?, nil: return uri
        }
        guard !rows.contains(where: { $0.playableURI == uri }),
              let row = rows.first(where: { isSameSong($0, as: nowPlaying) })
        else { return uri }
        return row.playableURI
    }

    /// Same title, artists and length (within two seconds: one song's duration differs by a few
    /// milliseconds between the library and the catalog).
    static func isSameSong(_ row: TrackRowViewModel, as nowPlaying: PlaybackNowPlaying) -> Bool {
        guard row.playableURI != nil,
              row.title.localizedCaseInsensitiveCompare(nowPlaying.name) == .orderedSame,
              row.subtitle.localizedCaseInsensitiveCompare(nowPlaying.artists.joined(separator: ", ")) == .orderedSame
        else { return false }
        return abs(row.durationMilliseconds - nowPlaying.durationMilliseconds) <= 2_000
    }

    private static func nowPlaying(connectionState: PlaybackConnectionState) -> PlaybackNowPlaying? {
        switch connectionState {
        case let .playing(nowPlaying): nowPlaying
        case let .paused(nowPlaying): nowPlaying
        case .disconnected, .connecting, .ready, .transferring, .unavailable, .error: nil
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
