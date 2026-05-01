import SwiftUI

struct PlaybackControlsView: View {
    @ObservedObject var viewModel: PlaybackSessionViewModel
    @State private var dragFraction: Double?

    var body: some View {
        GlassPanel {
            HStack(spacing: SpotiglassDesign.spacingM) {
                nowPlayingSummary
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 320, alignment: .leading)

                centerScrubberGroup
                    .frame(maxWidth: .infinity)

                controlsCluster
            }
            .padding(.horizontal, SpotiglassDesign.spacingM)
            .padding(.vertical, SpotiglassDesign.spacingS)
        }
        .padding(.horizontal, SpotiglassDesign.spacingM)
        .padding(.bottom, SpotiglassDesign.spacingM)
    }

    private var nowPlayingSummary: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Image(systemName: stateIcon)
                .font(.title3)
                .foregroundStyle(stateIconColor)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var centerScrubberGroup: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Text(elapsedText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 36, alignment: .trailing)

            ScrubberView(
                positionFraction: positionFraction ?? 0,
                durationMilliseconds: nowPlaying?.durationMilliseconds ?? 0,
                onSeek: { milliseconds in
                    Task { await viewModel.seek(to: milliseconds) }
                },
                onDragUpdate: { fraction in
                    dragFraction = fraction
                }
            )
            .frame(maxWidth: .infinity)
            .opacity(nowPlaying != nil ? 1 : 0.4)
            .disabled(nowPlaying == nil)

            Text(remainingText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .leading)
        }
    }

    private var controlsCluster: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Button {
                viewModel.start()
            } label: {
                Label("Connect", systemImage: "dot.radiowaves.left.and.right")
            }
            .accessibilityLabel("Connect playback")
            .accessibilityHint("Connects the hidden Spotify Web Playback SDK device. Spotify Premium is required.")

            Button {
                Task { await viewModel.previous() }
            } label: {
                Image(systemName: "backward.fill")
            }
            .disabled(!hasReadyDevice)
            .accessibilityLabel("Previous track")
            .accessibilityHint("Skips to the previous Spotify track when playback is connected.")

            Button {
                Task { await viewModel.togglePlayPause() }
            } label: {
                Image(systemName: playPauseIcon)
            }
            .disabled(!hasReadyDevice)
            .accessibilityLabel(playPauseAccessibilityLabel)
            .accessibilityHint("Toggles Spotify playback in Spotiglass.")

            Button {
                Task { await viewModel.next() }
            } label: {
                Image(systemName: "forward.fill")
            }
            .disabled(!hasReadyDevice)
            .accessibilityLabel("Next track")
            .accessibilityHint("Skips to the next Spotify track when playback is connected.")
        }
        .controlSize(.regular)
    }

    private var title: String {
        switch viewModel.connectionState {
        case .disconnected:
            "Playback disconnected"
        case .connecting:
            "Connecting Spotify playback..."
        case .ready:
            "Ready to play"
        case .transferring:
            "Transferring playback..."
        case let .playing(nowPlaying):
            nowPlaying.name
        case let .paused(nowPlaying):
            nowPlaying?.name ?? "Playback paused"
        case .unavailable:
            "Playback unavailable"
        case let .error(error):
            error.title
        }
    }

    private var subtitle: String {
        switch viewModel.connectionState {
        case .disconnected:
            "Connect the hidden Spotify Web Playback SDK device."
        case .connecting:
            "Spotify Premium is required for in-app playback."
        case let .ready(deviceID):
            "Device ready: \(deviceID)"
        case .transferring:
            "Moving Spotify playback to Spotiglass."
        case let .playing(nowPlaying):
            nowPlaying.artistText
        case let .paused(nowPlaying):
            nowPlaying.map { "\($0.artistText) • Paused" } ?? "Paused"
        case let .unavailable(message):
            message
        case let .error(error):
            error.message
        }
    }

    private var playPauseIcon: String {
        switch viewModel.connectionState {
        case .playing:
            "pause.fill"
        default:
            "play.fill"
        }
    }

    private var playPauseAccessibilityLabel: String {
        switch viewModel.connectionState {
        case .playing:
            "Pause"
        default:
            "Play"
        }
    }

    private var hasReadyDevice: Bool {
        switch viewModel.connectionState {
        case .ready, .transferring, .playing, .paused:
            true
        case .disconnected, .connecting, .unavailable, .error:
            false
        }
    }

    private var stateIcon: String {
        switch viewModel.connectionState {
        case .disconnected:
            "speaker.slash"
        case .connecting, .transferring:
            "arrow.triangle.2.circlepath"
        case .ready:
            "speaker.wave.2"
        case .playing:
            "play.circle.fill"
        case .paused:
            "pause.circle"
        case .unavailable:
            "exclamationmark.circle"
        case .error:
            "exclamationmark.triangle"
        }
    }

    private var stateIconColor: Color {
        switch viewModel.connectionState {
        case .error, .unavailable:
            .orange
        case .playing, .ready:
            .accentColor
        default:
            .secondary
        }
    }

    private var positionFraction: Double? {
        if let dragFraction { return dragFraction }
        guard let item = nowPlaying, item.durationMilliseconds > 0 else { return nil }
        return min(max(Double(item.positionMilliseconds) / Double(item.durationMilliseconds), 0), 1)
    }

    private var elapsedText: String {
        guard let item = nowPlaying else { return "0:00" }
        let positionMs: Int
        if let dragFraction {
            positionMs = Int((dragFraction * Double(item.durationMilliseconds)).rounded())
        } else {
            positionMs = item.positionMilliseconds
        }
        return PlaybackNowPlaying.mmss(milliseconds: positionMs)
    }

    private var remainingText: String {
        guard let item = nowPlaying else { return "−0:00" }
        let positionMs: Int
        if let dragFraction {
            positionMs = Int((dragFraction * Double(item.durationMilliseconds)).rounded())
        } else {
            positionMs = item.positionMilliseconds
        }
        let remainingMs = max(0, item.durationMilliseconds - positionMs)
        return "−" + PlaybackNowPlaying.mmss(milliseconds: remainingMs)
    }

    private var nowPlaying: PlaybackNowPlaying? {
        switch viewModel.connectionState {
        case let .playing(item):
            item
        case let .paused(item):
            item
        default:
            nil
        }
    }
}
