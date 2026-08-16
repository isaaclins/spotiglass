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
    /// Whether the row paints its own now-playing and hover tint. Inside a
    /// `List` the table owns the row background, and drawing a second fill on
    /// top of the system selection muddies it, so the playlist table passes
    /// `false` and lets the waveform glyph mark the playing row the way Music
    /// does. Surfaces that still stack rows in a plain stack keep it on.
    var drawsRowHighlights: Bool = true
    /// Whether the row takes keyboard focus itself. Inside the playlist table the
    /// `List` owns focus and arrow-key traversal, so it passes `false`. The
    /// surfaces that stack rows in a plain `VStack` (Home, Artist, Search) have
    /// no selection model at all, so the row has to be focusable or those rows
    /// cannot be reached without a mouse (#121).
    var isKeyboardFocusable: Bool = true
    /// Spotify-side track-ops menu items appended after the existing menu.
    /// Built lazily so closures don't fire until the menu opens.
    var trackOpsMenuItems: (() -> AnyView)? = nil

    @EnvironmentObject private var pinnedStore: PinnedItemsStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering: Bool = false

    private var isTrackPinned: Bool {
        pinnedStore.isPinned(spotifyID: track.id, kind: .track)
    }

    private var showsPinnedBadge: Bool {
        tracksSurfaceID != nil && isTrackPinned
    }

    private var accessibilityStatusSuffix: String {
        var suffix = isCurrent ? SpotiglassL10n.string("browser.trackRow.nowPlaying") : ""
        if showsPinnedBadge {
            suffix += ", \(SpotiglassL10n.string("browser.pinned"))"
        }
        return suffix
    }

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            leadingColumn
                .frame(width: 40, alignment: .trailing)

            ArtworkView(url: track.artworkURL, size: 40)
                .overlay(alignment: .topTrailing) {
                    if showsPinnedBadge {
                        PinnedBadge(scale: .compact)
                            .accessibilityElement()
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
            tracksSurfaceID: tracksSurfaceID
        ))
        // Double-click activates, which is what a Mac table does: a single
        // click belongs to the enclosing `List` so it can select. Attached
        // simultaneously so the tap recognizer cannot swallow that click.
        .simultaneousGesture(TapGesture(count: 2).onEnded(activate))
        .focusable(isKeyboardFocusable)
        // Return activates the focused row. Space is deliberately left alone: it
        // is the global play/pause binding, and swallowing it here would change
        // what that key does depending on which row happens to hold focus.
        .onKeyPress(.return) {
            activate()
            return .handled
        }
        .contextMenu {
            Button(SpotiglassL10n.string("browser.track.play"), action: activate)
                .disabled(track.playableURI == nil)
            Divider()
            if !track.artistRefs.isEmpty {
                Menu(SpotiglassL10n.string("browser.track.openArtist")) {
                    ForEach(track.artistRefs) { ref in
                        Button(ref.name) {
                            openArtist(ref.id)
                        }
                    }
                }
            }
            Button(SpotiglassL10n.string("browser.addToQueue")) {
                guard let uri = track.playableURI else { return }
                Task { await addToQueue(uri) }
            }
            .disabled(!hasPlaybackDevice || track.playableURI == nil)
            if let pinned = track.pinnedTrackItem() {
                if isTrackPinned {
                    Button(SpotiglassL10n.string("browser.unpin")) {
                        pinnedStore.unpin(id: pinned.id)
                    }
                } else {
                    Button(SpotiglassL10n.string("browser.pin")) {
                        pinnedStore.pin(pinned)
                    }
                }
            }
            if let trackOpsMenuItems {
                Divider()
                trackOpsMenuItems()
            }
        }
        .accessibilityElement(children: .combine)
        // The only activation used to be a raw double-tap gesture, which SwiftUI
        // never surfaces to assistive technology, and the play button existed
        // only while the pointer hovered. So VoiceOver could read a track but
        // never start one (#109).
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(SpotiglassL10n.string("browser.track.play")), activate)
        .accessibilityLabel(
            String(
                format: SpotiglassL10n.string("browser.trackRow.accessibility"),
                "\(trackNumber)",
                track.title,
                track.subtitle,
                track.durationText,
                accessibilityStatusSuffix
            )
        )
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
                        Text(SpotiglassL10n.string("common.comma"))
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

    /// Plays the row, or toggles transport when it is already the playing one.
    private func activate() {
        if isCurrent {
            togglePlayPause()
        } else if let playableURI = track.playableURI {
            playURI(playableURI)
        }
    }

    @ViewBuilder
    private var leadingColumn: some View {
        if isHovering {
            // A real button, so a single click still plays even though the row
            // itself now hands single clicks to the list for selection.
            Button(action: activate) {
                Image(systemName: isCurrent ? "pause.fill" : "play.fill")
                    .foregroundStyle(.spotiglassAccent)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(SpotiglassL10n.string(isCurrent ? "playback.pause" : "playback.play"))
            .accessibilityLabel(SpotiglassL10n.string(isCurrent ? "playback.pause" : "playback.play"))
        } else if isCurrent {
            PlayingWaveformIcon(isPlaying: isPlaying)
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
        if drawsRowHighlights {
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
}

/// Keeps `TrackListRow` itself a plain `View` for type-checker performance; pinning is optional via `tracksSurfaceID`.
private struct TrackListPinningModifier: ViewModifier {
    let track: TrackRowViewModel
    let tracksSurfaceID: String?

    func body(content: Content) -> some View {
        if tracksSurfaceID != nil, let pinned = track.pinnedTrackItem() {
            content
                .draggable(PinnedItemTransfer(item: pinned)) {
                    PinnedItemDragPill(item: pinned)
                }
        } else {
            content
        }
    }
}
