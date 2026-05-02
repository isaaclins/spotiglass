import SwiftUI

struct ArtistDetailContent: View {
    let detail: ArtistDetailViewModel
    let refresh: () -> Void
    /// Starts playback of one track; caller supplies playlist-style queue of URIs.
    let playTrack: (String) -> Void
    let playAlbumContext: (String) -> Void
    let currentPlaybackURI: String?
    let isPlaying: Bool
    let togglePlayPause: () -> Void
    let hasPlaybackDevice: Bool
    let addToQueue: (String) async -> Void
    let openArtist: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingL) {
                header
                if !detail.tracks.isEmpty {
                    Text("Tracks")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, SpotiglassDesign.spacingL)
                    tracksSection
                }
                albumStrip(title: "Albums", albums: detail.albums)
                albumStrip(title: "Singles", albums: detail.singles)
                albumStrip(title: "Compilations", albums: detail.compilations)
                albumStrip(title: "Appears on", albums: detail.appearsOn)
            }
            .padding(.vertical, SpotiglassDesign.spacingM)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: SpotiglassDesign.spacingL) {
            ArtworkView(url: detail.artist.imageURL, size: 120)
                .clipShape(RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))

            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
                Text(detail.artist.name)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(2)

                if let followers = detail.artist.followersTotal {
                    Text(NumberFormatter.localizedString(from: NSNumber(value: followers), number: .decimal) + " followers")
                        .foregroundStyle(.secondary)
                }

                if !detail.artist.genres.isEmpty {
                    Text(detail.artist.genres.prefix(6).joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Button(action: refresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .accessibilityHint("Reloads artist details from Spotify.")
        }
        .padding(.horizontal, SpotiglassDesign.spacingL)
    }

    private var tracksSection: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(detail.tracks.enumerated()), id: \.element.id) { index, track in
                TrackListRow(
                    trackNumber: index + 1,
                    track: track,
                    playURI: playTrack,
                    togglePlayPause: togglePlayPause,
                    isCurrent: track.playableURI != nil && track.playableURI == currentPlaybackURI,
                    isPlaying: isPlaying,
                    hasPlaybackDevice: hasPlaybackDevice,
                    addToQueue: addToQueue,
                    openArtist: openArtist
                )
            }
        }
        .padding(.horizontal, SpotiglassDesign.spacingS)
    }

    @ViewBuilder
    private func albumStrip(title: String, albums: [ArtistAlbumRowViewModel]) -> some View {
        if albums.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, SpotiglassDesign.spacingL)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: SpotiglassDesign.spacingM) {
                        ForEach(albums) { album in
                            Button {
                                playAlbumContext(album.uri)
                            } label: {
                                albumCard(album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, SpotiglassDesign.spacingL)
                    .padding(.bottom, SpotiglassDesign.spacingS)
                }
            }
        }
    }

    private func albumCard(_ album: ArtistAlbumRowViewModel) -> some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            ArtworkView(url: album.artworkURL, size: 132)
                .clipShape(RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))

            Text(album.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .frame(width: 132, alignment: .leading)

            if let year = album.yearText {
                Text(year)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(album.trackCountText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 132)
    }
}
