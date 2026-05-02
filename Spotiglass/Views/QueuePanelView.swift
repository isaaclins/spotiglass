import AppKit
import SwiftUI

struct QueuePanelView: View {
    @ObservedObject var viewModel: QueueViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let error = viewModel.lastError {
                errorBanner(error)
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
                Task { await viewModel.refreshQueue() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(viewModel.isLoading)
            .accessibilityLabel("Refresh queue")
            .help("Reload queue from Spotify")
        }
        .padding(SpotiglassDesign.spacingM)
    }

    private var subtitleText: String {
        let count = viewModel.upcomingItems.count
        if viewModel.isLoading {
            return "Updating…"
        }
        return count == 1 ? "1 track up next" : "\(count) tracks up next"
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
                    Task { await viewModel.refreshQueue() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            Button("Dismiss") {
                viewModel.clearError()
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

            if let item = viewModel.nowPlayingItem {
                QueueRowView(
                    item: item,
                    isCurrent: true,
                    isPlaying: viewModel.isPlaybackPlaying,
                    onSelect: {
                        Task { await viewModel.playItem(item) }
                    },
                    onCopyURI: { copyURI(item.uri) }
                )
            } else {
                Text("Nothing playing")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SpotiglassDesign.spacingM)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            Text("Up next")
                .font(.headline)

            if viewModel.upcomingItems.isEmpty {
                Text("No upcoming tracks. Start a playlist or add tracks to the queue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SpotiglassDesign.spacingM)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
            } else {
                ForEach(viewModel.upcomingItems) { item in
                    QueueRowView(
                        item: item,
                        isCurrent: false,
                        isPlaying: false,
                        onSelect: {
                            Task { await viewModel.playItem(item) }
                        },
                        onCopyURI: { copyURI(item.uri) }
                    )
                }
            }
        }
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
