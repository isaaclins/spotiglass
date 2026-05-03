import AppKit
import SwiftUI

struct QueuePanelView: View {
    @ObservedObject var queueViewModel: QueueViewModel
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel

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
                Text("Queue")
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
            .disabled(queueViewModel.isLoading || playbackViewModel.deviceID == nil)
            .accessibilityLabel(playbackViewModel.shuffleEnabled ? "Shuffle on" : "Shuffle off")
            .accessibilityHint("Toggles shuffle for Spotify playback on this device.")
            .help("Shuffle playback order")

            Button {
                Task { await queueViewModel.refreshQueue() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(queueViewModel.isLoading)
            .accessibilityLabel("Refresh queue")
            .help("Reload queue from Spotify")
        }
        .padding(SpotiglassDesign.spacingM)
    }

    private var subtitleText: String {
        let countLine: String
        if queueViewModel.isLoading {
            countLine = "Updating…"
        } else {
            let count = queueViewModel.upcomingItems.count
            countLine = count == 1 ? "1 track up next" : "\(count) tracks up next"
        }
        let repeatSuffix: String = {
            switch playbackViewModel.repeatMode {
            case .off: return ""
            case .context: return "Repeat playlist"
            case .track: return "Repeat one"
            }
        }()
        if repeatSuffix.isEmpty { return countLine }
        return "\(countLine) · \(repeatSuffix)"
    }

    private func errorBanner(_ error: BrowsingDisplayError) -> some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            Text(error.title)
                .font(.subheadline.weight(.semibold))
            Text(error.message)
                .font(.caption)
                .foregroundStyle(.secondary)
            if error.canRetry {
                Button("Retry") {
                    Task { await queueViewModel.refreshQueue() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            Button("Dismiss") {
                queueViewModel.clearError()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(SpotiglassDesign.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
        .padding(.horizontal, SpotiglassDesign.spacingM)
    }

    @ViewBuilder
    private var nowPlayingSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            Text("Now playing")
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
                        onCopyURI: { copyURI(item.uri) }
                    )
                    .id("now-playing-row:\(item.id)")
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    Text("Nothing playing")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(SpotiglassDesign.spacingM)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.3), value: queueViewModel.nowPlayingItem?.id)
        }
    }

    @ViewBuilder
    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            Text("Up next")
                .font(.headline)

            if queueViewModel.upcomingItems.isEmpty {
                Text("No upcoming tracks. Start a playlist or add tracks to the queue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SpotiglassDesign.spacingM)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
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
    let onCopyURI: () -> Void

    var body: some View {
        Button(action: onSelect) {
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
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(item.durationLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(SpotiglassDesign.spacingS)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play Now", action: onSelect)
            if item.uri != nil {
                Button("Copy Spotify URI", action: onCopyURI)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(item.subtitle)")
    }

    private var rowBackground: Color {
        isCurrent ? Color.primary.opacity(0.10) : Color.primary.opacity(0.04)
    }
}
