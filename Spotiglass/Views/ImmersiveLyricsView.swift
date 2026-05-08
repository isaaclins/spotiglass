import SwiftUI

struct ImmersiveLyricsView: View {
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    @ObservedObject var queueViewModel: QueueViewModel
    @ObservedObject var lyricsModel: ImmersiveLyricsViewModel
    let navigateToArtist: (ArtistTapTarget) -> Void
    let navigateToAlbum: (AlbumTapTarget, String, URL?) -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Soft fade at scroll top/bottom; off when legibility or calm motion is preferred.
    private var usesLyricsScrollEdgeFade: Bool {
        !reduceTransparency && !reduceMotion
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
                .ignoresSafeArea()

            ImmersiveLyricsBackgroundLayer(
                reduceTransparency: reduceTransparency,
                albumArtURL: currentTrack?.albumArtURL
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                ImmersiveLyricsMainLayout(
                    playbackViewModel: playbackViewModel,
                    queueViewModel: queueViewModel,
                    lyricsModel: lyricsModel,
                    navigateToArtist: navigateToArtist,
                    navigateToAlbum: navigateToAlbum,
                    currentTrack: currentTrack,
                    positionMs: positionMs,
                    reduceMotion: reduceMotion,
                    usesLyricsScrollEdgeFade: usesLyricsScrollEdgeFade
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: currentTrack?.uri) {
            guard let track = currentTrack else {
                onDismiss()
                return
            }
            async let lyricsLoad: Void = lyricsModel.load(track: track)
            async let queuePrefetch: Void = queueViewModel.prefetchQueueForLyricsOverlay()
            await lyricsLoad
            await queuePrefetch
        }
        .onExitCommand(perform: onDismiss)
    }

    private var currentTrack: PlaybackNowPlaying? {
        switch playbackViewModel.connectionState {
        case let .playing(np):
            return np
        case let .paused(opt):
            return opt
        default:
            return nil
        }
    }

    private var positionMs: Int {
        switch playbackViewModel.connectionState {
        case let .playing(np):
            return np.positionMilliseconds
        case let .paused(opt):
            return opt?.positionMilliseconds ?? 0
        default:
            return 0
        }
    }
}
