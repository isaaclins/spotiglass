import AppKit
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
    /// Optional shift-click selection contract. When provided, modifier-aware
    /// click handling routes through these callbacks; `nil` keeps the legacy
    /// "click = play" behaviour for surfaces that don't surface multi-select.
    var isSelected: Bool = false
    var onShiftSelect: ((String) -> Void)? = nil
    var onPrimarySelect: ((String) -> Void)? = nil
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
                        Label(SpotiglassL10n.string("browser.pinned"), systemImage: "pin.fill")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(SpotiglassDesign.mediaBadgeForegroundColor(colorScheme: colorScheme))
                            .padding(3)
                            .background(
                                Circle().fill(SpotiglassDesign.mediaBadgeBackgroundColor(colorScheme: colorScheme))
                            )
                            .padding(2)
                            .accessibilityElement()
                            .accessibilityLabel(SpotiglassL10n.string("browser.pinned"))
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
        .modifier(
            TrackListPinningModifier(
                track: track,
                tracksSurfaceID: tracksSurfaceID
            )
        )
        .onTapGesture {
            // Shift-click ⇒ extend selection (no playback).
            // Plain click   ⇒ replace selection, then play / toggle.
            if NSEvent.modifierFlags.contains(.shift), let onShiftSelect {
                onShiftSelect(track.id)
                return
            }
            if let onPrimarySelect {
                onPrimarySelect(track.id)
            }
            if isCurrent {
                togglePlayPause()
            } else if let playableURI = track.playableURI {
                playURI(playableURI)
            }
        }
        .contextMenu {
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

    @ViewBuilder
    private var leadingColumn: some View {
        if isCurrent && isHovering {
            Image(systemName: "pause.fill")
                .foregroundStyle(SpotiglassDesign.controlAccent)
                .frame(maxWidth: .infinity, alignment: .center)
        } else if isCurrent {
            PlayingWaveformIcon(isPlaying: isPlaying)
                .frame(maxWidth: .infinity, alignment: .center)
        } else if isHovering {
            Image(systemName: "play.fill")
                .foregroundStyle(SpotiglassDesign.controlAccent)
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
            if isSelected {
                RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                    .fill(SpotiglassDesign.controlAccent.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                            .strokeBorder(SpotiglassDesign.controlAccent.opacity(0.45), lineWidth: 1)
                    )
            } else if isCurrent {
                RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                    .fill(Color.primary.opacity(0.10))
            }
            if isHovering && !isSelected {
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
