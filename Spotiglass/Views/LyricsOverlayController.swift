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

    func attach(
        playback: PlaybackSessionViewModel,
        queue: QueueViewModel,
        lyrics: ImmersiveLyricsViewModel
    ) {
        playbackViewModel = playback
        queueViewModel = queue
        lyricsModel = lyrics
    }

    func detach() {
        isPresented = false
        playbackViewModel = nil
        queueViewModel = nil
        lyricsModel = nil
    }

    func dismiss() {
        isPresented = false
    }
}
