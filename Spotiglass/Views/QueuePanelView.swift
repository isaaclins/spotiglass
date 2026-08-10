import AppKit
import SwiftUI

struct QueuePanelView: View {
    @ObservedObject var queueViewModel: QueueViewModel
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    let openArtist: (ArtistTapTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let error = queueViewModel.lastError {
                errorBanner(error)
                    .transition(
                        .move(edge: .top).combined(with: .opacity)
                    )
            }

            ScrollView {
                VStack(alignment: .leading, spacing: SpotiglassDesign.spacingM) {
                    nowPlayingSection
                    upNextSection
                }
                .padding(SpotiglassDesign.spacingM)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: queueViewModel.lastError?.id)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
                Text(SpotiglassL10n.string("queue.title"))
                    .font(.title2.weight(.semibold))
                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await queueViewModel.toggleShuffle() }
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(playbackViewModel.shuffleEnabled ? SpotiglassDesign.controlAccent : Color.primary)
            }
            .disabled(playbackViewModel.deviceID == nil)
            .accessibilityLabel(
                playbackViewModel.shuffleEnabled
                    ? SpotiglassL10n.string("queue.shuffle.on")
                    : SpotiglassL10n.string("queue.shuffle.off")
            )
            .accessibilityHint(SpotiglassL10n.string("queue.shuffle.hint"))
            .help(SpotiglassL10n.string("queue.help.shuffle"))
        }
        .padding(SpotiglassDesign.spacingM)
    }

    private var subtitleText: String {
        switch playbackViewModel.repeatMode {
        case .track:
            return SpotiglassL10n.string("queue.subtitle.repeatOne")
        case .off:
            return upcomingCountLine
        case .context:
            return String(format: SpotiglassL10n.string("queue.subtitle.repeatPlaylist"), upcomingCountLine)
        }
    }

    private var upcomingCountLine: String {
        let count = queueViewModel.upcomingItems.count
        if count == 1 {
            return SpotiglassL10n.string("queue.subtitle.oneTrackUpNext")
        }
        return String(format: SpotiglassL10n.string("queue.subtitle.tracksUpNext"), count)
    }

    private func errorBanner(_ error: BrowsingDisplayError) -> some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            Text(error.title)
                .font(.subheadline.weight(.semibold))
            Text(error.message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(SpotiglassL10n.string("queue.dismiss")) {
                queueViewModel.clearError()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(SpotiglassDesign.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
        )
        .padding(.horizontal, SpotiglassDesign.spacingM)
    }

    @ViewBuilder
    private var nowPlayingSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            Text(SpotiglassL10n.string("queue.nowPlaying"))
                .font(.headline)

            ZStack {
                if let item = queueViewModel.nowPlayingItem {
                    QueueRowView(
                        item: item,
                        isCurrent: true,
                        isPlaying: queueViewModel.isPlaybackPlaying,
                        onSelect: {
                            Task { await queueViewModel.playItem(item) }
                        },
                        openArtist: openArtist,
                        onCopyURI: { copyURI(item.uri) }
                    )
                    .id("now-playing-row:\(item.id)")
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    Text(SpotiglassL10n.string("queue.nothingPlaying"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(SpotiglassDesign.spacingM)
                        .background(
                            .secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                        )
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.3), value: queueViewModel.nowPlayingItem?.id)
        }
    }

    @ViewBuilder
    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            Text(SpotiglassL10n.string("queue.upNext"))
                .font(.headline)

            if queueViewModel.upcomingItems.isEmpty {
                Text(upNextEmptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SpotiglassDesign.spacingM)
                    .background(
                        .secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                    )
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
                    ForEach(queueViewModel.upcomingItems) { item in
                        QueueRowView(
                            item: item,
                            isCurrent: false,
                            isPlaying: false,
                            onSelect: {
                                Task { await queueViewModel.playItem(item) }
                            },
                            openArtist: openArtist,
                            onCopyURI: { copyURI(item.uri) }
                        )
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.96))
                            )
                        )
                    }
                }
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: queueViewModel.upcomingItems.map(\.id))
    }

    private var upNextEmptyMessage: String {
        if playbackViewModel.repeatMode == .track {
            return SpotiglassL10n.string("queue.upNext.empty.repeat")
        }
        return SpotiglassL10n.string("queue.upNext.empty.default")
    }

    private func copyURI(_ uri: String?) {
        guard let uri else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(uri, forType: .string)
    }
}

private struct QueueRowView: View {
    let item: QueueItem
    let isCurrent: Bool
    let isPlaying: Bool
    let onSelect: () -> Void
    let openArtist: (ArtistTapTarget) -> Void
    let onCopyURI: () -> Void

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            if isCurrent {
                PlayingWaveformIcon(isPlaying: isPlaying)
                    .frame(width: 28, alignment: .center)
            }

            ArtworkView(url: item.albumArtURL, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                subtitleLine
            }

            Spacer(minLength: 8)

            Text(item.durationLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(SpotiglassDesign.spacingS)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button(SpotiglassL10n.string("queue.playNow"), action: onSelect)
            if item.uri != nil {
                Button(SpotiglassL10n.string("queue.copyURI"), action: onCopyURI)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(format: SpotiglassL10n.string("queue.item.accessibility"), item.name, item.subtitle)
        )
    }

    @ViewBuilder
    private var subtitleLine: some View {
        if item.artistTapTargets.isEmpty {
            Text(item.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(item.artistTapTargets.enumerated()), id: \.element.stableID) { index, target in
                    if index > 0 {
                        Text(SpotiglassL10n.string("common.comma"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        openArtist(target)
                    } label: {
                        Text(target.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(format: SpotiglassL10n.string("queue.openArtist"), target.name)
                    )
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
        }
    }

    private var rowBackground: Color {
        isCurrent ? Color.primary.opacity(0.10) : Color.primary.opacity(0.04)
    }
}
