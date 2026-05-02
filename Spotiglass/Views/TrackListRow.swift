import SwiftUI

struct TrackListRow: View {
    let trackNumber: Int
    let track: TrackRowViewModel
    let playURI: (String) -> Void
    let togglePlayPause: () -> Void
    let isCurrent: Bool
    let isPlaying: Bool
    let hasPlaybackDevice: Bool
    let addToQueue: (String) async -> Void
    let openArtist: (String) -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            leadingColumn
                .frame(width: 40, alignment: .trailing)

            ArtworkView(url: track.artworkURL, size: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(track.title)
                        .font(.headline)
                        .foregroundStyle(track.isUnavailable ? .secondary : .primary)
                        .lineLimit(1)

                    if let badgeText = track.badgeText {
                        Text(badgeText)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15), in: Capsule())
                    }
                }

                artistSubtitle
            }

            Spacer()

            Text(track.durationText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, SpotiglassDesign.spacingXS)
        .padding(.horizontal, SpotiglassDesign.spacingXS)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            if isCurrent {
                togglePlayPause()
            } else if let playableURI = track.playableURI {
                playURI(playableURI)
            }
        }
        .contextMenu {
            if !track.artistRefs.isEmpty {
                Menu("Open Artist") {
                    ForEach(track.artistRefs) { ref in
                        Button(ref.name) {
                            openArtist(ref.id)
                        }
                    }
                }
            }
            Button("Add to Queue") {
                guard let uri = track.playableURI else { return }
                Task { await addToQueue(uri) }
            }
            .disabled(!hasPlaybackDevice || track.playableURI == nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(trackNumber). \(track.title), \(track.subtitle), \(track.durationText)\(isCurrent ? ", currently playing" : "")")
    }

    @ViewBuilder
    private var artistSubtitle: some View {
        if track.artistRefs.isEmpty {
            Text(track.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(track.artistRefs.enumerated()), id: \.element.id) { index, ref in
                    if index > 0 {
                        Text(", ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        openArtist(ref.id)
                    } label: {
                        Text(ref.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var leadingColumn: some View {
        if isCurrent && isHovering {
            Image(systemName: "pause.fill")
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .center)
        } else if isCurrent {
            PlayingWaveformIcon(isPlaying: isPlaying)
                .frame(maxWidth: .infinity, alignment: .center)
        } else if isHovering {
            Image(systemName: "play.fill")
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            Text("\(trackNumber)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        ZStack {
            if isCurrent {
                RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                    .fill(Color.primary.opacity(0.10))
            }
            if isHovering {
                RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            }
        }
    }
}
