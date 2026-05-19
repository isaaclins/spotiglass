import SwiftUI

struct ImmersiveLyricsView: View {
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    @ObservedObject var queueViewModel: QueueViewModel
    @ObservedObject var lyricsModel: ImmersiveLyricsViewModel
    let navigateToArtist: (ArtistTapTarget) -> Void
    let navigateToAlbum: (AlbumTapTarget, String, URL?) -> Void
    let onDismiss: () -> Void

    @EnvironmentObject private var settingsStore: SpotiglassSettingsStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Soft fade at scroll top/bottom; off when legibility or calm motion is preferred.
    private var usesLyricsScrollEdgeFade: Bool {
        !reduceTransparency && !reduceMotion
    }

    private var lyricsTextSize: LyricsTextSize {
        settingsStore.settings.appearance.lyricsTextSize
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
                lyricsMainLayout
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

    @ViewBuilder
    private var lyricsMainLayout: some View {
        if let anchor = playbackViewModel.progressAnchor, anchor.isAdvancing {
            TimelineView(.animation) { context in
                immersiveMainLayout(positionMs: anchor.interpolatedPositionMs(at: context.date))
            }
        } else {
            immersiveMainLayout(positionMs: staticPositionMs)
        }
    }

    private func immersiveMainLayout(positionMs: Int) -> some View {
        ImmersiveLyricsMainLayout(
            playbackViewModel: playbackViewModel,
            queueViewModel: queueViewModel,
            lyricsModel: lyricsModel,
            navigateToArtist: navigateToArtist,
            navigateToAlbum: navigateToAlbum,
            currentTrack: currentTrack,
            positionMs: positionMs,
            reduceMotion: reduceMotion,
            usesLyricsScrollEdgeFade: usesLyricsScrollEdgeFade,
            lyricsTextSize: lyricsTextSize
        )
    }

    /// Frozen position when paused or between anchors; playback uses `progressAnchor` + `TimelineView` instead.
    private var staticPositionMs: Int {
        if let anchor = playbackViewModel.progressAnchor {
            return anchor.positionMilliseconds
        }
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
