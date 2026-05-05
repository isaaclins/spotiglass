import SwiftUI

struct PlaybackControlsView: View {
    @ObservedObject var viewModel: PlaybackSessionViewModel
    @Binding var isLyricsPresented: Bool
    let openArtist: (ArtistTapTarget) -> Void
    @State private var dragFraction: Double?

    var body: some View {
        GlassPanel {
            HStack(spacing: SpotiglassDesign.spacingM) {
                nowPlayingSummary
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 320, alignment: .leading)

                centerScrubberGroup
                    .frame(maxWidth: .infinity)

                HStack(spacing: SpotiglassDesign.spacingM) {
                    controlsCluster
                    volumeGroup
                }
            }
            .padding(.horizontal, SpotiglassDesign.spacingM)
            .padding(.vertical, SpotiglassDesign.spacingS)
        }
        .padding(.horizontal, SpotiglassDesign.spacingM)
        .padding(.bottom, SpotiglassDesign.spacingM)
    }

    private var nowPlayingSummary: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            leadingNowPlayingVisual

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(.smooth(duration: 0.28), value: title)
                    if showsLyricsButton {
                        Button {
                            isLyricsPresented = true
                        } label: {
                            Image(systemName: "music.note.list")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Lyrics")
                        .accessibilityHint("Opens synchronized lyrics for the current track.")
                    }
                    if shouldShowPausedIndicator {
                        Text("Paused")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .animation(.smooth(duration: 0.22), value: shouldShowPausedIndicator)

                if artistTapTargets.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(.smooth(duration: 0.28), value: subtitle)
                } else {
                    artistLine
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var leadingNowPlayingVisual: some View {
        ZStack {
            if let item = nowPlaying {
                if showsLyricsButton {
                    Button {
                        isLyricsPresented = true
                    } label: {
                        ArtworkView(url: item.albumArtURL, size: 44)
                    }
                    .buttonStyle(.plain)
                    .id("artwork:\(item.uri ?? item.name)")
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .accessibilityLabel("Open lyrics")
                    .accessibilityHint("Opens synchronized lyrics for the current track.")
                } else {
                    ArtworkView(url: item.albumArtURL, size: 44)
                        .id("artwork:\(item.uri ?? item.name)")
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                        .accessibilityHidden(true)
                }
            } else {
                Image(systemName: stateIcon)
                    .font(.title3)
                    .foregroundStyle(stateIconColor)
                    .frame(width: 28)
                    .id("state-icon:\(stateIcon)")
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .animation(.smooth(duration: 0.32), value: nowPlaying?.uri ?? "no-uri:\(stateIcon)")
    }

    private var artistLine: some View {
        HStack(spacing: 0) {
            ForEach(Array(artistTapTargets.enumerated()), id: \.element.stableID) { index, target in
                if index > 0 {
                    Text(", ")
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
                .accessibilityLabel("Open artist \(target.name)")
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .contentTransition(.opacity)
        .animation(.smooth(duration: 0.28), value: subtitle)
    }

    private var centerScrubberGroup: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Text(elapsedText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 36, alignment: .trailing)
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.18), value: elapsedText)

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
            .animation(.smooth(duration: 0.24), value: nowPlaying != nil)

            Text(remainingText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .leading)
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.18), value: remainingText)
        }
    }

    private var controlsCluster: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            recoveryLeadingControl
                .animation(.smooth(duration: 0.22), value: recoveryControlKey)

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
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.smooth(duration: 0.18), value: playPauseIcon)
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

            Button {
                Task { await viewModel.cycleRepeat() }
            } label: {
                Image(systemName: repeatButtonIcon)
                    .foregroundStyle(repeatButtonUsesAccent ? SpotiglassDesign.controlAccent : Color.secondary)
            }
            .disabled(!hasReadyDevice)
            .accessibilityLabel(repeatAccessibilityLabel)
            .accessibilityHint("Cycles repeat: off, repeat playlist, repeat one track.")
        }
        .controlSize(.regular)
    }

    private var repeatButtonIcon: String {
        switch viewModel.repeatMode {
        case .off, .context:
            "repeat"
        case .track:
            "repeat.1"
        }
    }

    private var repeatButtonUsesAccent: Bool {
        viewModel.repeatMode != .off
    }

    private var repeatAccessibilityLabel: String {
        switch viewModel.repeatMode {
        case .off:
            "Repeat off"
        case .context:
            "Repeat playlist"
        case .track:
            "Repeat one"
        }
    }

    private var volumeGroup: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Image(systemName: "speaker.wave.2")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Slider(value: playbackVolumeBinding, in: 0 ... 1)
                .controlSize(.small)
                .frame(minWidth: 100, idealWidth: 120, maxWidth: 140)
                .disabled(!hasReadyDevice)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playback volume")
        .accessibilityHint("Adjusts Spotify Web Playback output in Spotiglass. This is not the Mac system volume.")
    }

    private var playbackVolumeBinding: Binding<Double> {
        Binding(
            get: { viewModel.playbackVolume },
            set: { viewModel.setPlaybackVolume($0) }
        )
    }

    @ViewBuilder
    private var recoveryLeadingControl: some View {
        switch viewModel.connectionState {
        case .disconnected, .unavailable:
            Button {
                viewModel.start()
            } label: {
                Label("Reconnect", systemImage: "dot.radiowaves.left.and.right")
            }
            .accessibilityLabel("Reconnect playback")
            .accessibilityHint("Registers the Spotiglass Web Playback device with Spotify. Spotify Premium is required.")
        case .connecting:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Connecting playback")
        case let .error(error):
            switch error.recoveryAction {
            case .reconnect:
                Button {
                    viewModel.start()
                } label: {
                    Label("Reconnect", systemImage: "dot.radiowaves.left.and.right")
                }
                .accessibilityLabel("Reconnect playback")
                .accessibilityHint("Restarts the hidden Spotify Web Playback SDK device.")
            case .retryTransfer:
                Button {
                    Task { await viewModel.retryPlaybackTransfer() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .accessibilityLabel("Retry playback transfer")
                .accessibilityHint("Attempts to move Spotify playback to Spotiglass again.")
            case .reauthenticate, .none:
                EmptyView()
            }
        case .ready, .transferring, .playing, .paused:
            EmptyView()
        }
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

    private var shouldShowPausedIndicator: Bool {
        if case let .paused(item) = viewModel.connectionState {
            return item != nil
        }
        return false
    }

    private var showsLyricsButton: Bool {
        guard let uri = nowPlaying?.uri else { return false }
        return uri.hasPrefix("spotify:track:")
    }

    private var subtitle: String {
        switch viewModel.connectionState {
        case .disconnected:
            "Spotiglass connects playback automatically when signed in. Use Reconnect if playback stops."
        case .connecting:
            "Spotify Premium is required for in-app playback."
        case .ready:
            "Choose a track or press play."
        case .transferring:
            "Moving Spotify playback to Spotiglass."
        case let .playing(nowPlaying):
            nowPlaying.artistText
        case let .paused(nowPlaying):
            nowPlaying?.artistText ?? "Paused"
        case let .unavailable(message):
            message
        case let .error(error):
            error.message
        }
    }

    private var artistTapTargets: [ArtistTapTarget] {
        guard let nowPlaying else { return [] }
        return nowPlaying.artistTapTargets
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

    /// String key that changes whenever the recovery (leading) control should
    /// switch between Reconnect / Retry / progress / hidden. Drives a smooth
    /// crossfade rather than a hard cut when the playback state transitions.
    private var recoveryControlKey: String {
        switch viewModel.connectionState {
        case .disconnected: "disconnected"
        case .unavailable: "unavailable"
        case .connecting: "connecting"
        case let .error(error):
            switch error.recoveryAction {
            case .reconnect: "error.reconnect"
            case .retryTransfer: "error.retry"
            case .reauthenticate, .none: "error.passive"
            }
        case .ready, .transferring, .playing, .paused: "transport"
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
