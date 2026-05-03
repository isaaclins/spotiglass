import SwiftUI

struct TrackListRow: View {
    /// Width for `m:ss` / `mm:ss` monospaced durations so resize does not reflow every row’s trailing edge.
    private static let durationColumnWidth: CGFloat = 48
    /// Source-of-truth row height for the virtualized playlist track list.
    /// 40pt artwork + 2 * spacingXS (6pt) padding + 4pt headroom = 56pt.
    static let listRowHeight: CGFloat = 56

    let trackNumber: Int
    let track: TrackRowViewModel
    let playURI: (String) -> Void
    let togglePlayPause: () -> Void
    let isCurrent: Bool
    let isPlaying: Bool
    let hasPlaybackDevice: Bool
    let addToQueue: (String) async -> Void
    let openArtist: (String) -> Void
    /// When set, the row participates in drag-to-pin for this surface (e.g. `pl:<playlistId>` or `ar:<artistID>`).
    var tracksSurfaceID: String? = nil
    /// Spotify playlist id when this list is a library playlist; `nil` for Liked Songs and artist top tracks.
    var originPlaylistID: String? = nil

    @EnvironmentObject private var pinnedStore: PinnedItemsStore
    @State private var isHovering: Bool = false

    private var isTrackPinned: Bool {
        pinnedStore.isPinned(spotifyID: track.id, kind: .track)
    }

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            leadingColumn
                .frame(width: 40, alignment: .trailing)

            ArtworkView(url: track.artworkURL, size: 40)
                .overlay(alignment: .topTrailing) {
                    if tracksSurfaceID != nil, isTrackPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .padding(2)
                            .accessibilityLabel("Pinned to sidebar")
                    }
                }

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
                .frame(width: Self.durationColumnWidth, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, SpotiglassDesign.spacingXS)
        .padding(.horizontal, SpotiglassDesign.spacingXS)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .modifier(TrackListPinningModifier(
            track: track,
            tracksSurfaceID: tracksSurfaceID,
            originPlaylistID: originPlaylistID
        ))
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
            if let pinned = track.pinnedTrackItem(originPlaylistID: originPlaylistID) {
                if isTrackPinned {
                    Button("Unpin from Sidebar") {
                        pinnedStore.unpin(id: pinned.id)
                    }
                } else {
                    Button("Pin to Sidebar") {
                        pinnedStore.pin(pinned)
                    }
                }
            }
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

/// Keeps `TrackListRow` itself a plain `View` for type-checker performance; pinning is optional via `tracksSurfaceID`.
private struct TrackListPinningModifier: ViewModifier {
    let track: TrackRowViewModel
    let tracksSurfaceID: String?
    let originPlaylistID: String?

    func body(content: Content) -> some View {
        if let sid = tracksSurfaceID, let pinned = track.pinnedTrackItem(originPlaylistID: originPlaylistID) {
            content
                .draggable(
                    PinnedItemTransfer(item: pinned, originScopeID: sid)
                ) {
                    PinnedItemDragPill(item: pinned)
                }
        } else {
            content
        }
    }
}
