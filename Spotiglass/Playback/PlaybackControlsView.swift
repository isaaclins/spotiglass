import SwiftUI

/// Tooltip copy for the transport toggles, shared by the now-playing bar, the
/// queue panel and the immersive lyrics column so the same button never
/// explains itself two different ways.
///
/// The convention: a tooltip names the action the next click performs, not the
/// state the control is in. The accessibility label keeps naming the state, so
/// VoiceOver still reports where playback currently stands.
enum PlaybackTransportTooltips {
    static func repeatTooltip(currentMode: SpotifyRepeatMode) -> String {
        switch currentMode.next {
        case .off:
            SpotiglassL10n.string("tooltip.playback.repeat.toOff")
        case .context:
            SpotiglassL10n.string("tooltip.playback.repeat.toPlaylist")
        case .track:
            SpotiglassL10n.string("tooltip.playback.repeat.toTrack")
        }
    }

    static func shuffleTooltip(isEnabled: Bool) -> String {
        isEnabled
            ? SpotiglassL10n.string("tooltip.playback.shuffle.turnOff")
            : SpotiglassL10n.string("tooltip.playback.shuffle.turnOn")
    }
}

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
                        .help(SpotiglassL10n.string("tooltip.playback.lyrics"))
                        .accessibilityLabel(SpotiglassL10n.string("playback.controls.lyrics"))
                        .accessibilityHint(SpotiglassL10n.string("playback.controls.lyrics.hint"))
                    }
                    if shouldShowPausedIndicator {
                        Text(SpotiglassL10n.string("playback.paused.label"))
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
                    .help(SpotiglassL10n.string("tooltip.playback.lyrics"))
                    .accessibilityLabel(SpotiglassL10n.string("playback.controls.openLyrics"))
                    .accessibilityHint(SpotiglassL10n.string("playback.controls.lyrics.hint"))
                } else {
                    ArtworkView(url: item.albumArtURL, size: 44)
                        .id("artwork:\(item.uri ?? item.name)")
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                        .accessibilityHidden(true)
                }
            } else {
                Image(systemName: stateIcon)
                    .font(.title3)
                    .foregroundStyle(stateIconStyle)
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
                .accessibilityLabel(String(format: SpotiglassL10n.string("playback.controls.openArtist"), target.name))
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
            .help(SpotiglassL10n.string("tooltip.playback.previous"))
            .accessibilityLabel(SpotiglassL10n.string("playback.controls.previous"))
            .accessibilityHint(SpotiglassL10n.string("playback.controls.previous.hint"))

            Button {
                Task { await viewModel.togglePlayPause() }
            } label: {
                Image(systemName: playPauseIcon)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.smooth(duration: 0.18), value: playPauseIcon)
            }
            .disabled(!hasReadyDevice)
            // Label and tooltip agree here: the state and the next action are
            // the same word, so "Pause" shows while something is playing.
            .help(playPauseAccessibilityLabel)
            .accessibilityLabel(playPauseAccessibilityLabel)
            .accessibilityHint(SpotiglassL10n.string("playback.controls.playPause.hint"))

            Button {
                Task { await viewModel.next() }
            } label: {
                Image(systemName: "forward.fill")
            }
            .disabled(!hasReadyDevice || viewModel.isSkipCommandPending || viewModel.isNextCommandLockedOut)
            .help(SpotiglassL10n.string("tooltip.playback.next"))
            .accessibilityLabel(SpotiglassL10n.string("playback.controls.next"))
            .accessibilityHint(SpotiglassL10n.string("playback.controls.next.hint"))

            Button {
                Task { await viewModel.cycleRepeat() }
            } label: {
                Image(systemName: repeatButtonIcon)
                    .foregroundStyle(
                        repeatButtonUsesAccent
                            ? AnyShapeStyle(SpotiglassAccentStyle())
                            : AnyShapeStyle(.secondary)
                    )
            }
            .disabled(!hasReadyDevice)
            .help(PlaybackTransportTooltips.repeatTooltip(currentMode: viewModel.repeatMode))
            .accessibilityLabel(repeatAccessibilityLabel)
            .accessibilityHint(SpotiglassL10n.string("playback.controls.repeat.hint"))
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
            SpotiglassL10n.string("playback.repeat.off")
        case .context:
            SpotiglassL10n.string("playback.repeat.playlist")
        case .track:
            SpotiglassL10n.string("playback.repeat.one")
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
            .help(SpotiglassL10n.string("tooltip.playback.device"))
            .accessibilityLabel(SpotiglassL10n.string("playback.controls.device"))
            .accessibilityHint(SpotiglassL10n.string("playback.controls.device.hint"))
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
        .help(SpotiglassL10n.string("playback.controls.volume"))
        .accessibilityLabel(SpotiglassL10n.string("playback.controls.volume"))
        .accessibilityHint(SpotiglassL10n.string("playback.controls.volume.hint"))
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
                Label(SpotiglassL10n.string("playback.controls.reconnect"), systemImage: "dot.radiowaves.left.and.right")
            }
            .accessibilityLabel(SpotiglassL10n.string("playback.controls.reconnect.label"))
            .accessibilityHint(SpotiglassL10n.string("playback.controls.reconnect.hint"))
        case .connecting:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(SpotiglassL10n.string("playback.controls.connecting"))
        case let .error(error):
            switch error.recoveryAction {
            case .reconnect:
                Button {
                    viewModel.start()
                } label: {
                    Label(SpotiglassL10n.string("playback.controls.reconnect"), systemImage: "dot.radiowaves.left.and.right")
                }
                .accessibilityLabel(SpotiglassL10n.string("playback.controls.reconnect.label"))
                .accessibilityHint(SpotiglassL10n.string("playback.controls.reconnect.sdk.hint"))
            case .retryTransfer:
                Button {
                    Task { await viewModel.retryPlaybackTransfer() }
                } label: {
                    Label(SpotiglassL10n.string("playback.controls.retry"), systemImage: "arrow.clockwise")
                }
                .accessibilityLabel(SpotiglassL10n.string("playback.controls.retry.label"))
                .accessibilityHint(SpotiglassL10n.string("playback.controls.retry.hint"))
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
            SpotiglassL10n.string("playback.controls.state.disconnected.title")
        case .connecting:
            SpotiglassL10n.string("playback.controls.state.connecting.title")
        case .ready:
            SpotiglassL10n.string("playback.controls.state.ready.title")
        case .transferring:
            SpotiglassL10n.string("playback.controls.state.transferring.title")
        case let .playing(nowPlaying):
            nowPlaying.name
        case let .paused(nowPlaying):
            nowPlaying?.name ?? SpotiglassL10n.string("playback.controls.state.paused.title")
        case .unavailable:
            SpotiglassL10n.string("playback.controls.state.unavailable.title")
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
            SpotiglassL10n.string("playback.controls.state.disconnected.subtitle")
        case .connecting:
            SpotiglassL10n.string("playback.controls.state.connecting.subtitle")
        case .ready:
            SpotiglassL10n.string("playback.controls.state.ready.subtitle")
        case .transferring:
            SpotiglassL10n.string("playback.controls.state.transferring.subtitle")
        case let .playing(nowPlaying):
            nowPlaying.artistText
        case let .paused(nowPlaying):
            nowPlaying?.artistText ?? SpotiglassL10n.string("playback.controls.state.paused.subtitle")
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
            SpotiglassL10n.string("playback.pause")
        default:
            SpotiglassL10n.string("playback.play")
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

    /// The playing and ready states are an accent, so they grey out with the window.
    /// Error and unavailable stay orange: that is a status, not an emphasis, and a warning
    /// that only reads while the window is frontmost is a warning you can miss.
    private var stateIconStyle: AnyShapeStyle {
        switch viewModel.connectionState {
        case .error, .unavailable:
            AnyShapeStyle(.orange)
        case .playing, .ready:
            AnyShapeStyle(SpotiglassAccentStyle())
        default:
            AnyShapeStyle(.secondary)
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
