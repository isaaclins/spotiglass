import SwiftUI

struct PlaybackControlsView: View {
    @ObservedObject var viewModel: PlaybackSessionViewModel

    var body: some View {
        GlassPanel {
            HStack(spacing: SpotiglassDesign.spacingM) {
                nowPlayingSummary

                Spacer()

                HStack(spacing: SpotiglassDesign.spacingS) {
                    Button {
                        viewModel.start()
                    } label: {
                        Label("Connect", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
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
                    .keyboardShortcut(.space, modifiers: [])
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

                if let progressFraction {
                    ProgressView(value: progressFraction)
                        .controlSize(.small)
                        .frame(maxWidth: 260)
                        .accessibilityLabel("Playback progress")
                        .accessibilityValue(progressAccessibilityValue)
                }
            }
        }
        .frame(minWidth: 280, alignment: .leading)
        .accessibilityElement(children: .combine)
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
            "\(nowPlaying.artistText) • \(nowPlaying.progressText)"
        case let .paused(nowPlaying):
            nowPlaying.map { "\($0.artistText) • Paused • \($0.progressText)" } ?? "Paused"
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

    private var progressFraction: Double? {
        nowPlaying.flatMap { item in
            guard item.durationMilliseconds > 0 else { return nil }
            return min(max(Double(item.positionMilliseconds) / Double(item.durationMilliseconds), 0), 1)
        }
    }

    private var progressAccessibilityValue: String {
        nowPlaying?.progressText ?? ""
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
