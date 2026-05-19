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
                    connectDeviceMenuGroup
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
                        .accessibilityLabel(String(localized: "playback.controls.lyrics"))
                        .accessibilityHint(String(localized: "playback.controls.lyrics.hint"))
                    }
                    if shouldShowPausedIndicator {
                        Text("playback.paused.label", bundle: .main)
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
                    .accessibilityLabel(String(localized: "playback.controls.openLyrics"))
                    .accessibilityHint(String(localized: "playback.controls.lyrics.hint"))
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
                    Text("common.comma", bundle: .main)
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
                .accessibilityLabel(String(format: String(localized: "playback.controls.openArtist"), target.name))
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .contentTransition(.opacity)
        .animation(.smooth(duration: 0.28), value: subtitle)
    }

    private var centerScrubberGroup: some View {
        PlaybackProgressScrubberGroup(
            progressAnchor: viewModel.progressAnchor,
            durationMilliseconds: nowPlaying?.durationMilliseconds ?? 0,
            isEnabled: nowPlaying != nil,
            onSeek: { milliseconds in
                Task { await viewModel.seek(to: milliseconds) }
            },
            dragFraction: $dragFraction
        )
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
            .disabled(!hasReadyDevice || viewModel.isSkipCommandPending)
            .accessibilityLabel(String(localized: "playback.controls.previous"))
            .accessibilityHint(String(localized: "playback.controls.previous.hint"))

            Button {
                Task { await viewModel.togglePlayPause() }
            } label: {
                Image(systemName: playPauseIcon)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.smooth(duration: 0.18), value: playPauseIcon)
            }
            .disabled(!hasReadyDevice)
            .accessibilityLabel(playPauseAccessibilityLabel)
            .accessibilityHint(String(localized: "playback.controls.playPause.hint"))

            Button {
                Task { await viewModel.next() }
            } label: {
                Image(systemName: "forward.fill")
            }
            .disabled(!hasReadyDevice || viewModel.isSkipCommandPending || viewModel.isNextCommandLockedOut)
            .accessibilityLabel(String(localized: "playback.controls.next"))
            .accessibilityHint(String(localized: "playback.controls.next.hint"))

            Button {
                Task { await viewModel.cycleRepeat() }
            } label: {
                Image(systemName: repeatButtonIcon)
                    .foregroundStyle(repeatButtonUsesAccent ? SpotiglassDesign.controlAccent : Color.secondary)
            }
            .disabled(!hasReadyDevice)
            .accessibilityLabel(repeatAccessibilityLabel)
            .accessibilityHint(String(localized: "playback.controls.repeat.hint"))
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
            String(localized: "playback.repeat.off")
        case .context:
            String(localized: "playback.repeat.playlist")
        case .track:
            String(localized: "playback.repeat.one")
        }
    }

    @ViewBuilder
    private var connectDeviceMenuGroup: some View {
        if viewModel.deviceID != nil {
            Menu {
                Group {
                    ForEach(viewModel.connectDevices) { device in
                        Button {
                            Task { await viewModel.transferPlayback(toConnectDevice: device.deviceID) }
                        } label: {
                            HStack(spacing: 8) {
                                if device.isActive {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 12)
                                } else {
                                    Color.clear.frame(width: 12)
                                }
                                Image(systemName: connectDeviceRowSymbol(for: device))
                                Text(device.name)
                                    .lineLimit(1)
                            }
                        }
                        .disabled(device.isRestricted)
                    }

                    Divider()

                    ForEach(viewModel.macAudioOutputDevices) { device in
                        Button {
                            viewModel.setSystemDefaultOutputDevice(device.id)
                        } label: {
                            HStack(spacing: 8) {
                                if viewModel.systemDefaultOutputDeviceID == device.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 12)
                                } else {
                                    Color.clear.frame(width: 12)
                                }
                                Image(systemName: macAudioOutputRowSymbol(for: device))
                                Text(device.name)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .onAppear {
                    Task { @MainActor in
                        await viewModel.refreshConnectDevices()
                        viewModel.refreshMacAudioOutputDevices()
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.08))
                    Image(systemName: viewModel.trayOutputSymbolName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                }
                .frame(width: 28, height: 28)
            }
            .menuIndicator(.hidden)
            .disabled(!hasReadyDevice)
            .opacity(hasReadyDevice ? 1 : 0.45)
            .accessibilityLabel(String(localized: "playback.controls.device"))
            .accessibilityHint(String(localized: "playback.controls.device.hint"))
        }
    }

    private func connectDeviceRowSymbol(for device: SpotifyConnectDevice) -> String {
        PlaybackOutputSFResolver.symbolName(deviceName: device.name, spotifyDeviceType: device.type)
    }

    private func macAudioOutputRowSymbol(for device: MacAudioOutputDevice) -> String {
        PlaybackOutputSFResolver.symbolName(deviceName: device.name, spotifyDeviceType: nil)
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
        .accessibilityLabel(String(localized: "playback.controls.volume"))
        .accessibilityHint(String(localized: "playback.controls.volume.hint"))
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
                Label(String(localized: "playback.controls.reconnect"), systemImage: "dot.radiowaves.left.and.right")
            }
            .accessibilityLabel(String(localized: "playback.controls.reconnect.label"))
            .accessibilityHint(String(localized: "playback.controls.reconnect.hint"))
        case .connecting:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(String(localized: "playback.controls.connecting"))
        case let .error(error):
            switch error.recoveryAction {
            case .reconnect:
                Button {
                    viewModel.start()
                } label: {
                    Label(String(localized: "playback.controls.reconnect"), systemImage: "dot.radiowaves.left.and.right")
                }
                .accessibilityLabel(String(localized: "playback.controls.reconnect.label"))
                .accessibilityHint(String(localized: "playback.controls.reconnect.sdk.hint"))
            case .retryTransfer:
                Button {
                    Task { await viewModel.retryPlaybackTransfer() }
                } label: {
                    Label(String(localized: "playback.controls.retry"), systemImage: "arrow.clockwise")
                }
                .accessibilityLabel(String(localized: "playback.controls.retry.label"))
                .accessibilityHint(String(localized: "playback.controls.retry.hint"))
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
            String(localized: "playback.pause")
        default:
            String(localized: "playback.play")
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
