import SwiftUI

struct ImmersiveLyricsMainLayout: View {
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    @ObservedObject var queueViewModel: QueueViewModel
    @ObservedObject var lyricsModel: ImmersiveLyricsViewModel
    let navigateToArtist: (ArtistTapTarget) -> Void
    let navigateToAlbum: (AlbumTapTarget, String, URL?) -> Void
    let currentTrack: PlaybackNowPlaying?
    let positionMs: Int
    let reduceMotion: Bool
    let usesLyricsScrollEdgeFade: Bool
    let lyricsTextSize: LyricsTextSize

    /// Hand to the lyrics column so tapping a synced line seeks playback to
    /// that line's timestamp. The async hop is wrapped in a `Task` so the
    /// SwiftUI tap callback stays synchronous.
    private var seekHandler: (Int) -> Void {
        { ms in
            Task { await playbackViewModel.seek(to: ms) }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let topClearance = max(geo.safeAreaInsets.top, ImmersiveLyricsLayout.minimumTopClearance)
            let bottomPadding = max(SpotiglassDesign.spacingM, geo.safeAreaInsets.bottom)
            let usableHeight = max(0, geo.size.height - topClearance - bottomPadding)
            let leadingGutter = max(SpotiglassDesign.spacingL, geo.safeAreaInsets.leading)
            let trailingGutter = max(SpotiglassDesign.spacingL, geo.safeAreaInsets.trailing)
            let wide = geo.size.width > 720
            Group {
                if wide {
                    HStack(alignment: .top, spacing: SpotiglassDesign.spacingL) {
                        ImmersiveLyricsLeftColumnView(
                            playbackViewModel: playbackViewModel,
                            queueViewModel: queueViewModel,
                            navigateToArtist: navigateToArtist,
                            navigateToAlbum: navigateToAlbum,
                            currentTrack: currentTrack
                        )
                        .frame(width: min(320, geo.size.width * 0.36), alignment: .leading)
                        ImmersiveLyricsLyricsPhaseColumn(
                            lyricsModel: lyricsModel,
                            currentTrack: currentTrack,
                            positionMs: positionMs,
                            reduceMotion: reduceMotion,
                            usesLyricsScrollEdgeFade: usesLyricsScrollEdgeFade,
                            lyricsTextSize: lyricsTextSize,
                            maxHeight: usableHeight,
                            onSeek: seekHandler
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: SpotiglassDesign.spacingM) {
                        ImmersiveLyricsLeftColumnView(
                            playbackViewModel: playbackViewModel,
                            queueViewModel: queueViewModel,
                            navigateToArtist: navigateToArtist,
                            navigateToAlbum: navigateToAlbum,
                            currentTrack: currentTrack
                        )
                        ImmersiveLyricsLyricsPhaseColumn(
                            lyricsModel: lyricsModel,
                            currentTrack: currentTrack,
                            positionMs: positionMs,
                            reduceMotion: reduceMotion,
                            usesLyricsScrollEdgeFade: usesLyricsScrollEdgeFade,
                            lyricsTextSize: lyricsTextSize,
                            maxHeight: max(200, usableHeight * 0.5)
                        )
                    }
                }
            }
            .padding(.top, topClearance)
            .padding(.leading, leadingGutter)
            .padding(.trailing, trailingGutter)
            .padding(.bottom, bottomPadding)
        }
    }
}
