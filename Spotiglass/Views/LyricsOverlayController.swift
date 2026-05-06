import Combine
import SwiftUI

/// Owns immersive lyrics presentation and holds references to the main-window playback session
/// so ``ImmersiveLyricsView`` can be hosted above ``NavigationSplitView`` (full-window compositing).
@MainActor
final class LyricsOverlayController: ObservableObject {
    @Published var isPresented = false

    private(set) var playbackViewModel: PlaybackSessionViewModel?
    private(set) var queueViewModel: QueueViewModel?
    private(set) var lyricsModel: ImmersiveLyricsViewModel?
    private(set) var navigateToArtist: ((ArtistTapTarget) -> Void)?
    private(set) var navigateToAlbum: ((AlbumTapTarget, String, URL?) -> Void)?

    func attach(
        playback: PlaybackSessionViewModel,
        queue: QueueViewModel,
        lyrics: ImmersiveLyricsViewModel,
        navigateToArtist: @escaping (ArtistTapTarget) -> Void,
        navigateToAlbum: @escaping (AlbumTapTarget, String, URL?) -> Void
    ) {
        playbackViewModel = playback
        queueViewModel = queue
        lyricsModel = lyrics
        self.navigateToArtist = navigateToArtist
        self.navigateToAlbum = navigateToAlbum
    }

    func detach() {
        isPresented = false
        playbackViewModel = nil
        queueViewModel = nil
        lyricsModel = nil
        navigateToArtist = nil
        navigateToAlbum = nil
    }

    func dismiss() {
        isPresented = false
    }
}
