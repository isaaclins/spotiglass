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
        PlaylistBrowserPlaybackHelpers.anchorTrackIDForPlaylistListScrollRestore(
            detailContent: viewModel.detailState.currentValue,
            currentPlaybackURI: currentPlaybackURI,
            detailLastVisibleTrackID: detailLastVisibleTrackID
        )
    }

    /// Now playing track used to prefetch LRCLIB lyrics before the lyrics overlay opens (only while transport is playing).
    var lyricsPrefetchTrack: PlaybackNowPlaying? {
        PlaylistBrowserPlaybackHelpers.lyricsPrefetchTrack(connectionState: playbackViewModel.connectionState)
    }

    /// Stable per playing track; used to schedule halfway next-track lyrics prefetch.
    var lyricsHalfwayNextPreloadTaskID: String? {
        PlaylistBrowserPlaybackHelpers.lyricsHalfwayNextPreloadTaskID(
            prefetchTrack: lyricsPrefetchTrack,
            nextQueueURI: queueViewModel.upcomingItems.first?.uri
        )
    }

    /// Playback identity without scrubber position ticks (avoids re-running queue hooks every progress frame).
    var queueRelevantPlaybackKey: String {
        PlaylistBrowserPlaybackHelpers.queueRelevantPlaybackKey(connectionState: playbackViewModel.connectionState)
    }

    var currentPlaybackURI: String? {
        PlaylistBrowserPlaybackHelpers.currentPlaybackURI(connectionState: playbackViewModel.connectionState)
    }

    var isCurrentlyPlaying: Bool {
        PlaylistBrowserPlaybackHelpers.isCurrentlyPlaying(connectionState: playbackViewModel.connectionState)
    }

    var hasPlaybackDevice: Bool {
        playbackViewModel.deviceID != nil
    }
}
