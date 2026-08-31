import AppKit
import CoreAudio
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

/// Responsive geometry policy for the playback transport.
enum PlaybackTransportLayoutPolicy {
    static let scrubberMinimumWidth: CGFloat = 180
    static let compactVolumeBreakpoint: CGFloat = 760
    static let stackedScrubberBreakpoint: CGFloat = 680

    /// A playing summary always keeps the artwork, its gap, and enough title
    /// width to remain readable. The title is allowed to truncate beyond this
    /// floor rather than forcing the scrubber or timestamps off the bar.
    static let nowPlayingArtworkSize: CGFloat = 44
    static let nowPlayingSummaryTitleMinimumWidth: CGFloat = 120
    static let nowPlayingSummaryMinimumWidth: CGFloat =
        nowPlayingArtworkSize + SpotiglassDesign.spacingS + nowPlayingSummaryTitleMinimumWidth

    struct TransportChildMinimumWidths: Equatable {
        let summary: CGFloat
        let scrubber: CGFloat
        let actions: CGFloat
    }

    struct TransportLayoutCandidate: Equatable {
        let useCompactVolume: Bool
        /// Minimum proposal width at which this candidate can be selected.
        let minimumWidth: CGFloat
    }

    /// Candidate order mirrors `adaptiveTransportLayout`: full horizontal,
    /// compact horizontal, then stacked compact. The view uses these minimums
    /// as `ViewThatFits` frames; keeping the data here lets tests model the
    /// same selection without a geometry/state round trip.
    static func transportLayoutCandidates() -> [TransportLayoutCandidate] {
        [
            TransportLayoutCandidate(
                useCompactVolume: false,
                minimumWidth: compactVolumeBreakpoint
            ),
            TransportLayoutCandidate(
                useCompactVolume: true,
                minimumWidth: stackedScrubberBreakpoint
            ),
            TransportLayoutCandidate(
                useCompactVolume: true,
                minimumWidth: 0
            ),
        ]
    }

    static func usesCompactVolume(for width: CGFloat) -> Bool {
        width < compactVolumeBreakpoint
    }

    /// The fixed trailing controls' floor, including the two gaps between the
    /// controls cluster, device picker, and volume control.
    static func transportActionsMinimumWidth(useCompactVolume: Bool) -> CGFloat {
        let controlsClusterWidth =
            (4 * 28)
            + (3 * SpotiglassDesign.spacingS)
        let volumeWidth = useCompactVolume ? 28 : 16 + SpotiglassDesign.spacingS + 100
        return controlsClusterWidth
            + (2 * SpotiglassDesign.spacingM)
            + 28
            + volumeWidth
    }

    /// Floors for the three children in the compact transport row. Keeping
    /// this calculation beside the row's frames makes the reservation testable
    /// and prevents a flexible scrubber from starving its neighbours again.
    static func transportChildMinimumWidths(
        in transportWidth: CGFloat,
        useCompactVolume: Bool? = nil
    ) -> TransportChildMinimumWidths {
        let compactVolume = useCompactVolume ?? usesCompactVolume(for: transportWidth)
        return TransportChildMinimumWidths(
            summary: nowPlayingSummaryMinimumWidth,
            scrubber: scrubberWidth(in: transportWidth),
            actions: transportActionsMinimumWidth(useCompactVolume: compactVolume)
        )
    }

    /// The scrubber's minimum seeking surface is independent of the width
    /// proposal. Its flexible frame expands into the room left by the summary
    /// and actions, so no measurement needs to be written back into the view.
    static func scrubberWidth(in windowWidth: CGFloat) -> CGFloat {
        _ = windowWidth
        return scrubberMinimumWidth
    }
}

/// Geometry and motion policy for the horizontally scrollable artist credits.
/// The view uses these pure calculations both to decide when the scroll view
/// can move and to keep its animation speed independent of the summary width.
enum PlaybackArtistLineScrollPolicy {
    static func maxScrollOffset(contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        max(0, contentWidth - viewportWidth)
    }

    static func clampedScrollOffset(_ offset: CGFloat, maxScrollOffset: CGFloat) -> CGFloat {
        let upperBound = max(0, maxScrollOffset)
        return min(max(0, offset), upperBound)
    }

    static func duration(for scrollDistance: CGFloat) -> TimeInterval {
        guard scrollDistance > 0 else { return 0 }
        let distanceDuration = Double(
            scrollDistance / SpotiglassDesign.nowPlayingArtistLineScrollPointsPerSecond
        )
        return max(distanceDuration, SpotiglassDesign.nowPlayingArtistLineMinimumScrollDuration)
    }

    static func shouldAutoScroll(
        maxScrollOffset: CGFloat,
        reduceMotion: Bool,
        isUserInteracting: Bool = false
    ) -> Bool {
        maxScrollOffset > 0 && !reduceMotion && !isUserInteracting
    }

    static func animation(duration: TimeInterval, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .linear(duration: duration)
    }

    static func resetOffset(previousResetID: String, resetID: String) -> CGFloat? {
        previousResetID == resetID ? nil : 0
    }
}

struct PlaybackControlsView: View {
    @ObservedObject var viewModel: PlaybackSessionViewModel
    @Binding var isLyricsPresented: Bool
    let openArtist: (ArtistTapTarget) -> Void
    @Environment(\.openSettings) private var openSettingsAction
    @State private var dragFraction: Double?
    @State private var isVolumePopoverPresented = false

    var body: some View {
        GlassPanel {
            adaptiveTransportLayout
                .padding(.horizontal, SpotiglassDesign.spacingM)
                .padding(.vertical, SpotiglassDesign.spacingS)
        }
        .padding(.horizontal, SpotiglassDesign.spacingM)
        .padding(.bottom, SpotiglassDesign.spacingM)
    }

    /// `ViewThatFits` chooses among complete arrangements without measuring a
    /// child, storing that measurement, and feeding it back into this view.
    /// That structural boundary prevents the transport's child minimums from
    /// participating in a body/geometry feedback loop.
    @ViewBuilder
    private var adaptiveTransportLayout: some View {
        let candidates = PlaybackTransportLayoutPolicy.transportLayoutCandidates()
        ViewThatFits(in: .horizontal) {
            horizontalTransportRow(useCompactVolume: candidates[0].useCompactVolume)
                .frame(minWidth: candidates[0].minimumWidth)
            horizontalTransportRow(useCompactVolume: candidates[1].useCompactVolume)
                .frame(minWidth: candidates[1].minimumWidth)
            stackedTransportRow
        }
    }

    private func horizontalTransportRow(useCompactVolume: Bool) -> some View {
        let minimumWidths = PlaybackTransportLayoutPolicy.transportChildMinimumWidths(
            in: 0,
            useCompactVolume: useCompactVolume
        )
        return HStack(spacing: SpotiglassDesign.spacingM) {
            nowPlayingSummary
                .frame(minWidth: minimumWidths.summary, idealWidth: 280, maxWidth: 320, alignment: .leading)
                .clipped()

            centerScrubberGroup
                .frame(
                    minWidth: minimumWidths.scrubber,
                    maxWidth: .infinity
                )

            transportActions(useCompactVolume: useCompactVolume, includeSummary: false)
                .frame(minWidth: minimumWidths.actions, alignment: .trailing)
        }
    }

    private var stackedTransportRow: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            transportActions(useCompactVolume: true, includeSummary: true)
            centerScrubberGroup
                .frame(maxWidth: .infinity)
        }
    }

    private func transportActions(useCompactVolume: Bool, includeSummary: Bool) -> some View {
        HStack(spacing: SpotiglassDesign.spacingM) {
            if includeSummary {
                nowPlayingSummary
                    .frame(
                        minWidth: PlaybackTransportLayoutPolicy.nowPlayingSummaryMinimumWidth,
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .clipped()
            }

            controlsCluster
            connectDeviceMenuGroup
            if useCompactVolume {
                compactVolumeGroup
            } else {
                volumeGroup
            }
        }
    }

    private var nowPlayingSummary: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            leadingNowPlayingVisual

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .contentTransition(.opacity)
                        .animation(.smooth(duration: 0.28), value: title)
                    if showsLyricsButton {
                        PlaybackTransportButton(
                            accessibilityLabel: SpotiglassL10n.string("playback.controls.lyrics"),
                            accessibilityHint: SpotiglassL10n.string("playback.controls.lyrics.hint"),
                            size: CGSize(width: 22, height: 22),
                            action: { isLyricsPresented = true }
                        ) {
                            Image(systemName: "music.note.list")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 22, height: 22)
                        .help(SpotiglassL10n.string("tooltip.playback.lyrics"))
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
                        .help(subtitle)
                } else {
                    artistLine
                }
            }
        }
        // Keep the summary as an accessibility container, not a replacement
        // element. The artwork and title Lyrics controls and each artist are
        // real Buttons and must remain separate VoiceOver actions (#267).
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var leadingNowPlayingVisual: some View {
        ZStack {
            if let item = nowPlaying {
                if showsLyricsButton {
                    ZStack {
                        ArtworkView(
                            url: item.albumArtURL,
                            size: PlaybackTransportLayoutPolicy.nowPlayingArtworkSize
                        )
                        PlaybackTransportButton(
                            accessibilityLabel: SpotiglassL10n.string("playback.controls.openLyrics"),
                            accessibilityHint: SpotiglassL10n.string("playback.controls.lyrics.hint"),
                            size: CGSize(
                                width: PlaybackTransportLayoutPolicy.nowPlayingArtworkSize,
                                height: PlaybackTransportLayoutPolicy.nowPlayingArtworkSize
                            ),
                            action: { isLyricsPresented = true }
                        ) {
                            EmptyView()
                        }
                        .opacity(0.001)
                    }
                    .frame(
                        width: PlaybackTransportLayoutPolicy.nowPlayingArtworkSize,
                        height: PlaybackTransportLayoutPolicy.nowPlayingArtworkSize
                    )
                    .id("artwork:\(item.uri ?? item.name)")
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .help(SpotiglassL10n.string("tooltip.playback.lyrics"))
                } else {
                    ArtworkView(
                        url: item.albumArtURL,
                        size: PlaybackTransportLayoutPolicy.nowPlayingArtworkSize
                    )
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
        PlaybackArtistLine(
            targets: artistTapTargets,
            resetID: artistLineResetID,
            openArtist: openArtist
        )
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

            PlaybackTransportButton(
                accessibilityLabel: SpotiglassL10n.string("playback.controls.previous"),
                accessibilityHint: SpotiglassL10n.string("playback.controls.previous.hint"),
                size: CGSize(width: 28, height: 28),
                isEnabled: hasReadyDevice && !viewModel.isSkipCommandPending,
                action: { Task { await viewModel.previous() } }
            ) {
                Image(systemName: "backward.fill")
            }
            .frame(width: 28, height: 28)
            .help(SpotiglassL10n.string("tooltip.playback.previous"))

            PlaybackTransportButton(
                accessibilityLabel: playPauseAccessibilityLabel,
                accessibilityHint: SpotiglassL10n.string("playback.controls.playPause.hint"),
                size: CGSize(width: 28, height: 28),
                isEnabled: viewModel.isPlaybackToggleReady,
                action: { Task { await viewModel.togglePlayPause() } }
            ) {
                Image(systemName: playPauseIcon)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.smooth(duration: 0.18), value: playPauseIcon)
            }
            .frame(width: 28, height: 28)
            // Label and tooltip agree here: the state and the next action are
            // the same word, so "Pause" shows while something is playing.
            .help(playPauseAccessibilityLabel)

            PlaybackTransportButton(
                accessibilityLabel: SpotiglassL10n.string("playback.controls.next"),
                accessibilityHint: SpotiglassL10n.string("playback.controls.next.hint"),
                size: CGSize(width: 28, height: 28),
                isEnabled: hasReadyDevice
                    && !viewModel.isSkipCommandPending
                    && !viewModel.isNextCommandLockedOut,
                action: { Task { await viewModel.next() } }
            ) {
                Image(systemName: "forward.fill")
            }
            .frame(width: 28, height: 28)
            .help(SpotiglassL10n.string("tooltip.playback.next"))

            PlaybackTransportButton(
                accessibilityLabel: repeatAccessibilityLabel,
                accessibilityHint: SpotiglassL10n.string("playback.controls.repeat.hint"),
                size: CGSize(width: 28, height: 28),
                isEnabled: viewModel.isTransportMutationReady,
                action: { Task { await viewModel.cycleRepeat() } }
            ) {
                Image(systemName: repeatButtonIcon)
                    .foregroundStyle(
                        repeatButtonUsesAccent
                            ? AnyShapeStyle(SpotiglassAccentStyle())
                            : AnyShapeStyle(.secondary)
                    )
            }
            .frame(width: 28, height: 28)
            .help(PlaybackTransportTooltips.repeatTooltip(currentMode: viewModel.repeatMode))
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
                    Picker(selection: connectDeviceSelection) {
                        ForEach(viewModel.connectDevices) { device in
                            Label(
                                device.name,
                                systemImage: connectDeviceRowSymbol(for: device)
                            )
                            .lineLimit(1)
                            .tag(device.deviceID)
                            .disabled(device.isRestricted)
                        }
                    } label: {
                        Text(SpotiglassL10n.string("playback.controls.connectDevices"))
                    }
                    .pickerStyle(.inline)

                    Divider()

                    Picker(selection: macAudioOutputSelection) {
                        ForEach(viewModel.macAudioOutputDevices) { device in
                            Label(
                                device.name,
                                systemImage: macAudioOutputRowSymbol(for: device)
                            )
                            .lineLimit(1)
                            .tag(device.id)
                        }
                    } label: {
                        Text(SpotiglassL10n.string("playback.controls.macAudioOutputs"))
                    }
                    .pickerStyle(.inline)
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
                    Label(
                        SpotiglassL10n.string("playback.controls.device"),
                        systemImage: viewModel.trayOutputSymbolName
                    )
                    .labelStyle(.iconOnly)
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

    private var connectDeviceSelection: Binding<String> {
        Binding(
            get: {
                viewModel.connectDevices.first(where: \.isActive)?.deviceID ?? ""
            },
            set: { deviceID in
                guard
                    let device = viewModel.connectDevices.first(where: { $0.deviceID == deviceID }),
                    !device.isRestricted
                else { return }
                Task { await viewModel.transferPlayback(toConnectDevice: deviceID) }
            }
        )
    }

    private var macAudioOutputSelection: Binding<AudioDeviceID> {
        Binding(
            get: { viewModel.systemDefaultOutputDeviceID ?? 0 },
            set: { deviceID in
                guard deviceID != 0 else { return }
                viewModel.setSystemDefaultOutputDevice(deviceID)
            }
        )
    }

    private func connectDeviceRowSymbol(for device: SpotifyConnectDevice) -> String {
        PlaybackOutputSFResolver.symbolName(deviceName: device.name, spotifyDeviceType: device.type)
    }

    private func macAudioOutputRowSymbol(for device: MacAudioOutputDevice) -> String {
        PlaybackOutputSFResolver.symbolName(deviceName: device.name, spotifyDeviceType: nil)
    }

    private var compactVolumeGroup: some View {
        PlaybackTransportButton(
            accessibilityLabel: SpotiglassL10n.string("playback.controls.volume"),
            accessibilityHint: SpotiglassL10n.string("playback.controls.volume.hint"),
            size: CGSize(width: 28, height: 28),
            isEnabled: isPlaybackVolumeReady,
            action: { isVolumePopoverPresented.toggle() }
        ) {
            Image(systemName: "speaker.wave.2")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 28, height: 28)
        .popover(isPresented: $isVolumePopoverPresented) {
            Slider(value: playbackVolumeBinding, in: 0 ... 1)
                .controlSize(.small)
                .frame(width: 140)
                .padding()
        }
        .help(SpotiglassL10n.string("playback.controls.volume"))
        .accessibilityLabel(SpotiglassL10n.string("playback.controls.volume"))
        .accessibilityValue(
            (viewModel.playbackVolume).formatted(.percent.precision(.fractionLength(0)))
        )
        .accessibilityHint(SpotiglassL10n.string("playback.controls.volume.hint"))
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
                .disabled(!isPlaybackVolumeReady)
        }
        .disabled(!isPlaybackVolumeReady)
        .accessibilityElement(children: .combine)
        .help(SpotiglassL10n.string("playback.controls.volume"))
        .accessibilityLabel(SpotiglassL10n.string("playback.controls.volume"))
        // Combining the group swallowed the Slider's own value, so VoiceOver
        // named the control but never said how loud it was (#116).
        .accessibilityValue(
            (viewModel.playbackVolume).formatted(.percent.precision(.fractionLength(0)))
        )
        .accessibilityHint(SpotiglassL10n.string("playback.controls.volume.hint"))
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            switch direction {
            case .increment:
                viewModel.setPlaybackVolume(min(viewModel.playbackVolume + step, 1))
            case .decrement:
                viewModel.setPlaybackVolume(max(viewModel.playbackVolume - step, 0))
            @unknown default:
                break
            }
        }
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
            PlaybackTransportButton(
                accessibilityLabel: SpotiglassL10n.string("playback.controls.reconnect.label"),
                accessibilityHint: SpotiglassL10n.string("playback.controls.reconnect.hint"),
                size: CGSize(width: 170, height: 28),
                action: { viewModel.start() }
            ) {
                Label(SpotiglassL10n.string("playback.controls.reconnect"), systemImage: "dot.radiowaves.left.and.right")
            }
            .frame(width: 170, height: 28)
        case .connecting:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(SpotiglassL10n.string("playback.controls.connecting"))
        case let .error(error):
            switch error.recoveryAction {
            case .reconnect:
                PlaybackTransportButton(
                    accessibilityLabel: SpotiglassL10n.string("playback.controls.reconnect.label"),
                    accessibilityHint: SpotiglassL10n.string("playback.controls.reconnect.sdk.hint"),
                    size: CGSize(width: 170, height: 28),
                    action: { viewModel.start() }
                ) {
                    Label(SpotiglassL10n.string("playback.controls.reconnect"), systemImage: "dot.radiowaves.left.and.right")
                }
                .frame(width: 170, height: 28)
            case .retryTransfer:
                PlaybackTransportButton(
                    accessibilityLabel: SpotiglassL10n.string("playback.controls.retry.label"),
                    accessibilityHint: SpotiglassL10n.string("playback.controls.retry.hint"),
                    size: CGSize(width: 170, height: 28),
                    action: { Task { await viewModel.retryPlaybackTransfer() } }
                ) {
                    Label(SpotiglassL10n.string("playback.controls.retry"), systemImage: "arrow.clockwise")
                }
                .frame(width: 170, height: 28)
            case .reauthenticate:
                PlaybackTransportButton(
                    accessibilityLabel: SpotiglassL10n.string("auth.reconnect.button"),
                    accessibilityHint: error.message,
                    size: CGSize(width: 170, height: 28),
                    action: { openSettingsAction() }
                ) {
                    Label(SpotiglassL10n.string("auth.reconnect.button"), systemImage: "gear")
                }
                .frame(width: 170, height: 28)
            case .none:
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
        viewModel.currentLyricTrack != nil
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

    /// Position must restart at the leading edge for every track, even when
    /// the next track has the same artist credits. URI-less items still get a
    /// stable identity from the visible track and artist content.
    private var artistLineResetID: String {
        guard let nowPlaying else { return title }
        return [
            nowPlaying.uri ?? "",
            nowPlaying.name,
            nowPlaying.albumID ?? nowPlaying.albumName ?? nowPlaying.albumArtURL?.absoluteString ?? "",
            String(nowPlaying.durationMilliseconds),
            artistTapTargets.map(\.stableID).joined(separator: "|"),
        ].joined(separator: "\u{1F}")
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
            case .reauthenticate: "error.reauthenticate"
            case .none: "error.passive"
            }
        case .ready, .transferring, .playing, .paused: "transport"
        }
    }

    private var isPlaybackVolumeReady: Bool {
        hasReadyDevice && !viewModel.isRemotePlaybackActive
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

/// SwiftUI's macOS 26 button bridge does not publish its accessibility label
/// for ordinary hosted buttons. Keep the visual SwiftUI content and put a
/// transparent native button beside it so AppKit gets a real AXButton (#334).
private struct PlaybackTransportButton<Content: View>: View {
    let accessibilityLabel: String
    let accessibilityHint: String
    let size: CGSize
    let isEnabled: Bool
    let action: () -> Void
    let content: Content

    init(
        accessibilityLabel: String,
        accessibilityHint: String,
        size: CGSize = CGSize(width: 28, height: 28),
        isEnabled: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.size = size
        self.isEnabled = isEnabled
        self.action = action
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .accessibilityHidden(true)

            Button(action: {}) {
                EmptyView()
            }
            .frame(width: size.width, height: size.height)
            .hidden()
            .allowsHitTesting(false)
            .disabled(!isEnabled)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(accessibilityHint)
            .accessibilityHidden(true)

            PlaybackNativeButton(
                accessibilityLabel: accessibilityLabel,
                accessibilityHint: accessibilityHint,
                isEnabled: isEnabled,
                action: action
            )
            .frame(width: size.width, height: size.height)
            .opacity(0.001)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
    }
}

private struct PlaybackNativeButton: NSViewRepresentable {
    let accessibilityLabel: String
    let accessibilityHint: String
    let isEnabled: Bool
    let action: () -> Void

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction(_ sender: NSButton) {
            _ = sender
            action()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(frame: .zero)
        button.title = ""
        button.isBordered = false
        configure(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
        configure(nsView, coordinator: context.coordinator)
    }

    private func configure(_ button: NSButton, coordinator: Coordinator) {
        button.target = coordinator
        button.action = #selector(Coordinator.performAction(_:))
        button.isEnabled = isEnabled
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityHelp(accessibilityHint)
        button.toolTip = accessibilityHint
    }
}

private struct PlaybackArtistLineScrollTaskID: Equatable {
    let resetID: String
    let maxScrollOffset: CGFloat
    let reduceMotion: Bool
    let isUserInteracting: Bool

    /// Periphery cannot infer that SwiftUI consumes an Equatable task ID. Make
    /// the dependency explicit so every part of the key participates in task
    /// cancellation when the scroll state changes.
    var signature: String {
        "\(resetID)\u{1F}\(maxScrollOffset)\u{1F}\(reduceMotion)\u{1F}\(isUserInteracting)"
    }
}

/// A one-line artist credit surface that stays horizontally scrollable while
/// preserving each artist Button. Automatic movement pauses for real user
/// scrolling and is disabled entirely when Reduce Motion is enabled (#210).
private struct PlaybackArtistLine: View {
    let targets: [ArtistTapTarget]
    let resetID: String
    let openArtist: (ArtistTapTarget) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollPosition = ScrollPosition()
    @State private var maxScrollOffset: CGFloat = 0
    @State private var isUserInteracting = false

    private var autoScrollTaskID: String {
        PlaybackArtistLineScrollTaskID(
            resetID: resetID,
            maxScrollOffset: maxScrollOffset,
            reduceMotion: reduceMotion,
            isUserInteracting: isUserInteracting
        ).signature
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(Array(targets.enumerated()), id: \.element.stableID) { index, target in
                    if index > 0 {
                        Text(SpotiglassL10n.string("common.comma"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Button {
                        openArtist(target)
                    } label: {
                        Text(target.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            // Do not let the scroll view's viewport proposal
                            // ellipsize a credit that it is meant to reveal.
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(
                            format: SpotiglassL10n.string("playback.controls.openArtist"),
                            target.name
                        )
                    )
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                targets.map(\.name).joined(separator: SpotiglassL10n.string("common.comma"))
            )
        }
        // Changing identity is a second line of defence for track changes: it
        // prevents the native scroll view from retaining an old content offset
        // while the explicit reset below takes effect.
        .id(resetID)
        .frame(maxWidth: .infinity, alignment: .leading)
        .scrollPosition($scrollPosition)
        .scrollDisabled(maxScrollOffset <= 0)
        .transaction { transaction in
            // The marquee and content transition must not introduce motion when
            // Reduce Motion is enabled. User-driven scrolling also needs an
            // animation-free transaction so it cannot fight the gesture.
            if reduceMotion || isUserInteracting {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .animation(
            reduceMotion || isUserInteracting ? nil : .smooth(duration: 0.28),
            value: resetID
        )
        .onScrollGeometryChange(
            for: CGFloat.self,
            of: { geometry in
                PlaybackArtistLineScrollPolicy.maxScrollOffset(
                    contentWidth: geometry.contentSize.width,
                    viewportWidth: geometry.containerSize.width
                )
            }
        ) { _, newValue in
            guard newValue != maxScrollOffset else { return }
            maxScrollOffset = newValue
        }
        .onScrollPhaseChange { _, newPhase in
            switch newPhase {
            case .tracking, .interacting, .decelerating:
                isUserInteracting = true
            case .idle:
                isUserInteracting = false
            case .animating:
                // Programmatic marquee movement must not disable itself.
                break
            }
        }
        .onAppear {
            scrollPosition.scrollTo(x: 0)
        }
        .onChange(of: resetID) { oldID, newID in
            guard
                let resetOffset = PlaybackArtistLineScrollPolicy.resetOffset(
                    previousResetID: oldID,
                    resetID: newID
                )
            else { return }
            // Track changes should never inherit the previous song's offset.
            // Keep the measured range: a different track can have the same
            // content width, in which case GeometryChange quite correctly has
            // no new value to report.
            isUserInteracting = false
            scroll(to: resetOffset)
        }
        .onChange(of: reduceMotion) { _, nowReduced in
            guard nowReduced else { return }
            // Stop an in-flight marquee immediately and without an animated
            // jump when the system setting changes while the view is visible.
            scroll(to: 0)
        }
        .task(id: autoScrollTaskID) {
            guard
                PlaybackArtistLineScrollPolicy.shouldAutoScroll(
                    maxScrollOffset: maxScrollOffset,
                    reduceMotion: reduceMotion,
                    isUserInteracting: isUserInteracting
                )
            else { return }
            await autoScroll(to: maxScrollOffset)
        }
    }

    private func scroll(to requestedOffset: CGFloat, animation: Animation? = nil) {
        let offset = PlaybackArtistLineScrollPolicy.clampedScrollOffset(
            requestedOffset,
            maxScrollOffset: maxScrollOffset
        )
        if let animation {
            withAnimation(animation) {
                scrollPosition.scrollTo(x: offset)
            }
        } else {
            var transaction = Transaction()
            transaction.animation = nil
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollPosition.scrollTo(x: offset)
            }
        }
    }

    private func autoScroll(to maxOffset: CGFloat) async {
        let clampedMaxOffset = PlaybackArtistLineScrollPolicy.clampedScrollOffset(
            maxOffset,
            maxScrollOffset: maxScrollOffset
        )
        guard
            PlaybackArtistLineScrollPolicy.shouldAutoScroll(
                maxScrollOffset: clampedMaxOffset,
                reduceMotion: reduceMotion,
                isUserInteracting: isUserInteracting
            ),
            let animation = PlaybackArtistLineScrollPolicy.animation(
                duration: PlaybackArtistLineScrollPolicy.duration(for: clampedMaxOffset),
                reduceMotion: reduceMotion
            )
        else { return }

        let duration = PlaybackArtistLineScrollPolicy.duration(for: clampedMaxOffset)
        do {
            while !Task.isCancelled {
                try await Task.sleep(for: SpotiglassDesign.nowPlayingArtistLineScrollPause)
                guard !Task.isCancelled else { return }

                scroll(to: clampedMaxOffset, animation: animation)
                try await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }

                try await Task.sleep(for: SpotiglassDesign.nowPlayingArtistLineScrollPause)
                guard !Task.isCancelled else { return }

                scroll(to: 0, animation: animation)
                try await Task.sleep(for: .seconds(duration))
            }
        } catch {
            // Cancellation is the normal path when the user scrolls, the
            // track changes, the view disappears, or Reduce Motion is enabled.
        }
    }
}
