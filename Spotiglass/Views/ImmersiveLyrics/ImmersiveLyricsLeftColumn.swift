import SwiftUI

struct ImmersiveLyricsLeftColumnView: View {
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    @ObservedObject var queueViewModel: QueueViewModel
    let navigateToArtist: (ArtistTapTarget) -> Void
    let navigateToAlbum: (AlbumTapTarget, String, URL?) -> Void
    let currentTrack: PlaybackNowPlaying?

    /// Narrow layout: the lyrics share the column with this header, so it shrinks to a small
    /// cover beside the title and leaves Next in Queue to the queue panel (#438).
    var isCompact = false

    var body: some View {
        if let track = currentTrack {
            if isCompact {
                HStack(alignment: .center, spacing: SpotiglassDesign.spacingM) {
                    ArtworkView(url: track.albumArtURL, size: 64)
                        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
                    trackDetails(track, titleFont: .headline)
                }
            } else {
                VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
                    ArtworkView(url: track.albumArtURL, size: 220)
                        .shadow(color: .black.opacity(0.45), radius: 28, y: 14)

                    trackDetails(track, titleFont: .title2.weight(.bold))

                    ImmersiveLyricsNextInQueueSectionView(
                        queueViewModel: queueViewModel,
                        playbackViewModel: playbackViewModel,
                        navigateToArtist: navigateToArtist,
                        navigateToAlbum: navigateToAlbum
                    )
                }
            }
        }
    }

    /// Title, artists and album. Repeat lives in the player bar, which stays visible under the
    /// lyrics (#438).
    private func trackDetails(_ track: PlaybackNowPlaying, titleFont: Font) -> some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            Text(track.name)
                .font(titleFont.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(isCompact ? 2 : 3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            ImmersiveLyricsArtistLineView(track: track, navigateToArtist: navigateToArtist)

            if let album = track.albumName, !album.isEmpty {
                Button {
                    navigateToAlbum(
                        AlbumTapTarget(id: track.albumID, name: album),
                        track.artistText,
                        track.albumArtURL
                    )
                } label: {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(isCompact ? 1 : 2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(format: SpotiglassL10n.string("lyrics.openAlbum"), album))
            }
        }
    }
}

struct ImmersiveLyricsArtistLineView: View {
    let track: PlaybackNowPlaying
    let navigateToArtist: (ArtistTapTarget) -> Void

    var body: some View {
        if track.artistTapTargets.isEmpty {
            Text(track.artistText)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(track.artistTapTargets.enumerated()), id: \.element.stableID) { index, target in
                    if index > 0 {
                        Text(SpotiglassL10n.string("common.comma"))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    Button {
                        navigateToArtist(target)
                    } label: {
                        Text(target.name)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(format: SpotiglassL10n.string("lyrics.openArtist"), target.name))
                }
                Spacer(minLength: 0)
            }
        }
    }
}
