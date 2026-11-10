import SwiftUI

extension PlaylistBrowserView {
    /// The bar's Lyrics button and View › Show Lyrics (#486).
    var isLyricsPresentedBinding: Binding<Bool> {
        lyricsOverlay.presentedBinding {
            pendingPlaylistListScrollRestoreID = anchorTrackIDForPlaylistListScrollRestore()
        }
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
