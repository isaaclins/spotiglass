import SwiftUI

struct ImmersiveLyricsNextInQueueSectionView: View {
    @ObservedObject var queueViewModel: QueueViewModel
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    let navigateToArtist: (ArtistTapTarget) -> Void
    let navigateToAlbum: (AlbumTapTarget, String, URL?) -> Void

    var body: some View {
        let upcoming = Array(queueViewModel.upcomingItems.prefix(3))
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            Text(SpotiglassL10n.string("lyrics.nextInQueue"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, SpotiglassDesign.spacingS)

            if upcoming.isEmpty {
                Text(nextInQueueEmptyMessage)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
                    ForEach(upcoming) { item in
                        ImmersiveLyricsQueueUpcomingRowView(
                            item: item,
                            navigateToArtist: navigateToArtist,
                            navigateToAlbum: navigateToAlbum
                        )
                    }
                }
            }
        }
    }

    private var nextInQueueEmptyMessage: String {
        if playbackViewModel.repeatMode == .track {
            return SpotiglassL10n.string("lyrics.next.empty.repeat")
        }
        return SpotiglassL10n.string("lyrics.next.empty.default")
    }
}

struct ImmersiveLyricsQueueUpcomingRowView: View {
    let item: QueueItem
    let navigateToArtist: (ArtistTapTarget) -> Void
    let navigateToAlbum: (AlbumTapTarget, String, URL?) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: SpotiglassDesign.spacingS) {
            ArtworkView(url: item.albumArtURL, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                ImmersiveLyricsQueueUpcomingSubtitleView(
                    item: item,
                    navigateToArtist: navigateToArtist,
                    navigateToAlbum: navigateToAlbum
                )
            }
            Spacer(minLength: 0)
        }
    }
}

struct ImmersiveLyricsQueueUpcomingSubtitleView: View {
    let item: QueueItem
    let navigateToArtist: (ArtistTapTarget) -> Void
    let navigateToAlbum: (AlbumTapTarget, String, URL?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if item.artistTapTargets.isEmpty {
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(item.artistTapTargets.enumerated()), id: \.element.stableID) { index, target in
                        if index > 0 {
                            Text(SpotiglassL10n.string("common.comma"))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        Button {
                            navigateToArtist(target)
                        } label: {
                            Text(target.name)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(format: SpotiglassL10n.string("lyrics.openArtist"), target.name))
                    }
                    Spacer(minLength: 0)
                }
            }

            if let albumName = item.albumName, !albumName.isEmpty {
                Button {
                    navigateToAlbum(
                        AlbumTapTarget(id: item.albumID, name: albumName),
                        item.subtitle,
                        item.albumArtURL
                    )
                } label: {
                    Text(albumName)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(format: SpotiglassL10n.string("lyrics.openAlbum"), albumName))
            }
        }
    }
}
