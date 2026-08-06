import SwiftUI

struct ImmersiveLyricsLeftColumnView: View {
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    @ObservedObject var queueViewModel: QueueViewModel
    let navigateToArtist: (ArtistTapTarget) -> Void
    let navigateToAlbum: (AlbumTapTarget, String, URL?) -> Void
    let currentTrack: PlaybackNowPlaying?

    var body: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            if let track = currentTrack {
                ArtworkView(url: track.albumArtURL, size: 220)
                    .shadow(color: .black.opacity(0.45), radius: 28, y: 14)

                HStack(alignment: .firstTextBaseline, spacing: SpotiglassDesign.spacingS) {
                    Text(track.name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        Task { await playbackViewModel.cycleRepeat() }
                    } label: {
                        Image(systemName: lyricsRepeatButtonIcon)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(lyricsRepeatUsesAccent ? SpotiglassDesign.controlAccent : .white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasPlaybackDeviceForTransportControls)
                    .help(PlaybackTransportTooltips.repeatTooltip(currentMode: playbackViewModel.repeatMode))
                    .accessibilityLabel(lyricsRepeatAccessibilityLabel)
                    .accessibilityHint(SpotiglassL10n.string("playback.controls.repeat.hint"))
                }

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
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(format: SpotiglassL10n.string("lyrics.openAlbum"), album))
                }

                ImmersiveLyricsNextInQueueSectionView(
                    queueViewModel: queueViewModel,
                    playbackViewModel: playbackViewModel,
                    navigateToArtist: navigateToArtist,
                    navigateToAlbum: navigateToAlbum
                )
            }
        }
    }

    private var lyricsRepeatButtonIcon: String {
        switch playbackViewModel.repeatMode {
        case .off, .context:
            "infinity.circle"
        case .track:
            "infinity.circle.fill"
        }
    }

    private var lyricsRepeatUsesAccent: Bool {
        playbackViewModel.repeatMode != .off
    }

    private var lyricsRepeatAccessibilityLabel: String {
        switch playbackViewModel.repeatMode {
        case .off:
            SpotiglassL10n.string("playback.repeat.off")
        case .context:
            SpotiglassL10n.string("playback.repeat.playlist")
        case .track:
            SpotiglassL10n.string("playback.repeat.one")
        }
    }

    /// Matches ``PlaybackControlsView`` transport availability for prev/next/repeat.
    private var hasPlaybackDeviceForTransportControls: Bool {
        switch playbackViewModel.connectionState {
        case .ready, .transferring, .playing, .paused:
            true
        case .disconnected, .connecting, .unavailable, .error:
            false
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
