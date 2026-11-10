import SwiftUI

struct ImmersiveLyricsMainLayout: View {
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    @ObservedObject var queueViewModel: QueueViewModel
    @ObservedObject var lyricsModel: ImmersiveLyricsViewModel
    let navigateToArtist: (ArtistTapTarget) -> Void
    let navigateToAlbum: (AlbumTapTarget, String, URL?) -> Void
    let currentTrack: PlaybackNowPlaying?
    var followsOtherService = false
    let positionMs: Int
    let reduceMotion: Bool
    let usesLyricsScrollEdgeFade: Bool
    let lyricsTextSize: LyricsTextMetrics
    /// Height of the narrow header, measured: a long title or artist line wraps and makes it
    /// taller than its 64 pt cover.
    @State private var compactHeaderHeight = SpotiglassDesign.Layout.lyricsCompactArtworkSize

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
            // The reader's size already leaves out the bottom safe area (the player bar,
            // #474), so this is only the gap above it; adding the inset again left a band of
            // nothing above the bar.
            let bottomPadding = SpotiglassDesign.spacingM
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
                            currentTrack: currentTrack,
                            linksToLibrary: !followsOtherService
                        )
                        .frame(width: min(SpotiglassDesign.Layout.lyricsSideColumnMaxWidth, geo.size.width * 0.36), alignment: .leading)
                        // In a short window Next in Queue runs longer than the room above the
                        // player bar. The column runs behind the bar now (#474), so the list
                        // fades out above it like the lyrics instead of showing under the bar.
                        // It keeps its full height, so the section runs past the frame and
                        // fades rather than being squeezed out of the column.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxHeight: usableHeight, alignment: .top)
                        .mask { ImmersiveLyricsLayout.bottomEdgeFade }
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
                    // Narrow: the lyrics now share the window with the sidebar and the player
                    // bar, so a small header keeps the lyrics in view (#438).
                    VStack(alignment: .leading, spacing: SpotiglassDesign.spacingM) {
                        ImmersiveLyricsLeftColumnView(
                            playbackViewModel: playbackViewModel,
                            queueViewModel: queueViewModel,
                            navigateToArtist: navigateToArtist,
                            navigateToAlbum: navigateToAlbum,
                            currentTrack: currentTrack,
                            linksToLibrary: !followsOtherService,
                            isCompact: true
                        )
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { compactHeaderHeight = $0 }
                        ImmersiveLyricsLyricsPhaseColumn(
                            lyricsModel: lyricsModel,
                            currentTrack: currentTrack,
                            positionMs: positionMs,
                            reduceMotion: reduceMotion,
                            usesLyricsScrollEdgeFade: usesLyricsScrollEdgeFade,
                            lyricsTextSize: lyricsTextSize,
                            maxHeight: max(SpotiglassDesign.Layout.lyricsColumnMinHeight, usableHeight - compactHeaderHeight - SpotiglassDesign.spacingM),
                            onSeek: seekHandler
                        )
                        .frame(maxHeight: .infinity, alignment: .top)
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
