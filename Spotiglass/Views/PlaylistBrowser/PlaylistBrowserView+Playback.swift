import SwiftUI

extension PlaylistBrowserView {
    var isLyricsPresentedBinding: Binding<Bool> {
        Binding(
            get: { lyricsOverlay.isPresented },
            set: { newValue in
                guard !newValue || lyricsOverlay.hasLyricsToShow else { return }
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

    var currentPlaybackURI: String? {
        PlaylistBrowserPlaybackHelpers.currentPlaybackURI(
            connectionState: playbackViewModel.connectionState,
            detailContent: viewModel.detailState.currentValue
        )
    }

    /// Only a space that plays its own music offers Play and Shuffle: the Apple Music space must
    /// not reach Spotify's player just because Spotify's space started it earlier (#373).
    var hasPlaybackDevice: Bool {
        playbackMode == .live && playbackDeviceID != nil
    }
}
