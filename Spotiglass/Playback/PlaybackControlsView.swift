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
    static func repeatTooltip(currentMode: MusicRepeatMode) -> String {
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
    /// The scrubber under the controls stops growing here, as Music's and
    /// Spotify's do: in a wide window it stays a reach of the hand under the
    /// buttons instead of running from edge to edge (#496).
    static let scrubberMaximumWidth: CGFloat = 640
    /// Where the song and the right side sit beside the scrubber, it keeps this
    /// share of the bar's width, as Spotify's middle column does (#538).
    static let scrubberShareOfBar: CGFloat = 0.4

    /// The summary keeps the artwork, its gap and a few letters of the title
    /// before the controls give up their place on the bar's centre. Past this
    /// floor the title truncates (#496).
    static let nowPlayingArtworkSize: CGFloat = SpotiglassDesign.Layout.nowPlayingArtworkSize
    static let nowPlayingSummaryTitleMinimumWidth: CGFloat = 56
    /// A title too long to show whole keeps this much beside Paused; in a
    /// narrower bar Paused waits and the title keeps the room (#496).
    static let titleBesidePausedMinimumWidth: CGFloat = 120
    static let nowPlayingSummaryMinimumWidth: CGFloat =
        nowPlayingArtworkSize + SpotiglassDesign.spacingS + nowPlayingSummaryTitleMinimumWidth

    /// The volume slider's width range.
    static let volumeSliderWidths: (minimum: CGFloat, ideal: CGFloat, maximum: CGFloat) = (100, 120, 140)
}

/// Lays the player bar out the way Music and Spotify do (#496): the transport
/// buttons centred on the bar, so play/pause sits on the window's centre line
/// at every width, the song on the left, the device menu and the volume on the
/// right, and the scrubber centred under the buttons. The song and the right
/// side sit on the middle line of those two rows together (#538).
///
/// The bar spans the window with equal margins, so its centre is the
/// window's whether the sidebar shows or not. The controls view is
/// symmetric around play/pause (Lyrics mirrors Repeat), so centring the view
/// centres the button. Each side gets the same half of what is left: the
/// summary and any Reconnect or Retry button share the left one, and the
/// title truncates before the controls move; the device menu and the volume
/// take the right one, the volume falling back to its compact button when the
/// slider no longer fits.
///
/// One set of subviews at every width, each carrying its `Part`, so a layout
/// pass only moves them and never rebuilds the scrubber (#394), and every
/// choice is a pure function of the offered width.
struct PlaybackTransportArrangementLayout: Layout {
    enum Part: Equatable {
        case summary, recovery, controls, device, volume, scrubber
    }

    struct PartKey: LayoutValueKey {
        static let defaultValue = Part.controls
    }

    var spacing: CGFloat
    var rowSpacing: CGFloat

    /// The summary's share of an ideal-size query.
    static let summaryIdealWidth: CGFloat = 280

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        frames(forWidth: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(forWidth: proposal.width ?? bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, frames.subviews) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private struct Frames {
        var size: CGSize
        /// One frame per subview, in subview order, relative to the layout's origin.
        var subviews: [CGRect]
    }

    private func frames(forWidth proposedWidth: CGFloat?, subviews: Subviews) -> Frames {
        func index(of part: Part) -> Int? { subviews.firstIndex { $0[PartKey.self] == part } }
        guard let summary = index(of: .summary),
              let controls = index(of: .controls),
              let scrubber = index(of: .scrubber)
        else {
            return Frames(size: .zero, subviews: subviews.map { _ in .zero })
        }
        let recovery = index(of: .recovery), device = index(of: .device), volume = index(of: .volume)

        func measuredWidth(_ index: Int?, _ offer: CGFloat?) -> CGFloat {
            guard let index else { return 0 }
            return subviews[index].sizeThatFits(ProposedViewSize(width: offer, height: nil)).width
        }
        func height(_ index: Int, _ width: CGFloat) -> CGFloat {
            subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        /// The gap before a part that takes room; a part with nothing to show takes none.
        func gap(_ width: CGFloat) -> CGFloat { width > 0 ? spacing : 0 }

        let controlsWidth = measuredWidth(controls, nil)
        // Offered its switch-over width (see `PlaybackTransportVolumeSlot`), the
        // volume shows the slider at its narrowest: that is the slider's floor.
        let sliderMinimum = measuredWidth(volume, PlaybackTransportVolumeSlot<EmptyView, EmptyView>.switchOverWidth)
        let sliderMaximum = measuredWidth(volume, .infinity)
        let compactVolume = measuredWidth(volume, 0)
        let deviceMinimum = measuredWidth(device, 0), deviceIdeal = measuredWidth(device, nil)

        // The narrowest each side can be: the summary's floor, or with a
        // Reconnect or Retry button, the artwork and the button's compact form.
        let recoveryMinimum = measuredWidth(recovery, 0)
        let leadingMinimum = recoveryMinimum > 0
            ? PlaybackTransportLayoutPolicy.nowPlayingArtworkSize + spacing + recoveryMinimum
            : PlaybackTransportLayoutPolicy.nowPlayingSummaryMinimumWidth
        let trailingMinimum = deviceMinimum + gap(compactVolume) + compactVolume
        let sliderIdeal = sliderMinimum
            + PlaybackTransportLayoutPolicy.volumeSliderWidths.ideal
            - PlaybackTransportLayoutPolicy.volumeSliderWidths.minimum
        let trailingIdeal = deviceIdeal + gap(sliderIdeal) + sliderIdeal

        func barWidth(side: CGFloat) -> CGFloat { controlsWidth + 2 * (spacing + side) }
        let minimumWidth = barWidth(side: max(leadingMinimum, trailingMinimum))
        let width = max(
            proposedWidth ?? barWidth(side: max(Self.summaryIdealWidth, trailingIdeal)),
            minimumWidth
        )
        // Where the bar stacks depends on the width and the service only, not on
        // what plays: Reconnect or Retry needs less room than a song, so without
        // the song's floor here a song starting in a bar just wide enough for
        // Reconnect would stack it, and the scrubber and the sides would move.
        let sideMinimum = max(
            leadingMinimum,
            PlaybackTransportLayoutPolicy.nowPlayingSummaryMinimumWidth,
            trailingMinimum
        )
        let scrubberMinimum = measuredWidth(scrubber, 0)

        // Where the bar has room, the song and the right side sit on the middle
        // of the bar, the middle line of the buttons and the scrubber together,
        // not on the buttons' row (#538). The scrubber then keeps to the middle
        // column between them, as Spotify's does: two fifths of the bar, so a
        // window half a screen wide still has a scrubber you can aim at. The
        // column depends on the width only, so a song starting or a long title
        // never moves it; the title truncates instead. In a bar too narrow for
        // that column beside both sides at their narrowest, the bar stacks: the
        // song and the right side join the buttons' row and the scrubber runs
        // under all of them.
        let centredScrubberWidth = min(
            max(width * PlaybackTransportLayoutPolicy.scrubberShareOfBar, scrubberMinimum),
            PlaybackTransportLayoutPolicy.scrubberMaximumWidth
        )
        let centredSide = (width - max(controlsWidth, centredScrubberWidth)) / 2 - spacing
        let isStacked = centredSide < sideMinimum
        // Stacked, each side keeps the room it has where the bar stops
        // stacking, so the title and the volume never lose room as the window
        // widens past that point.
        let side = isStacked
            ? min((width - controlsWidth) / 2 - spacing, sideMinimum)
            : centredSide

        var widths = [CGFloat](repeating: 0, count: subviews.count)
        widths[controls] = controlsWidth
        // The right side: the slider when it fits beside the device menu at its
        // narrowest, the compact volume button otherwise.
        if let volume {
            let sliderFits = side >= deviceMinimum + spacing + sliderMinimum
            widths[volume] = sliderFits
                ? measuredWidth(volume, min(max(side - deviceIdeal - spacing, sliderMinimum), sliderMaximum))
                : compactVolume
        }
        let volumeWidth = volume.map { widths[$0] } ?? 0
        if let device {
            widths[device] = measuredWidth(device, max(side - gap(volumeWidth) - volumeWidth, 0))
        }
        // The left side. The text that says what went wrong comes first: the
        // Reconnect or Retry button shows its title only once that text fits
        // whole beside it, its symbol alone otherwise. The summary then takes
        // only the room its text needs, so the button sits right after the
        // line it belongs to instead of at the far end of the left half.
        let summaryIdeal = measuredWidth(summary, nil)
        if let recovery {
            let fullFits = side >= summaryIdeal + spacing + measuredWidth(recovery, nil)
            widths[recovery] = measuredWidth(recovery, fullFits ? nil : 0)
        }
        let recoveryWidth = recovery.map { widths[$0] } ?? 0
        let summaryRoom = max(side - gap(recoveryWidth) - recoveryWidth, 0)
        widths[summary] = recoveryWidth > 0
            ? measuredWidth(summary, min(summaryIdeal, summaryRoom))
            : measuredWidth(summary, summaryRoom)

        let scrubberWidth = isStacked
            ? max(min(width, PlaybackTransportLayoutPolicy.scrubberMaximumWidth), scrubberMinimum)
            : centredScrubberWidth
        let controlsHeight = height(controls, controlsWidth)
        let scrubberHeight = height(scrubber, scrubberWidth)
        let sides = [summary, recovery, device, volume].compactMap { $0 }
        // The sides are as tall as the cover at least, so the bar keeps its
        // height when a song starts and its cover replaces the shorter status
        // line: nothing moves.
        let sidesHeight = max(
            sides.map { height($0, widths[$0]) }.max() ?? 0,
            PlaybackTransportLayoutPolicy.nowPlayingArtworkSize
        )
        // The bar is as tall at every width as it is stacked, its top row as
        // tall as its tallest part, so the bar and the buttons keep their
        // height when the window crosses the width where it stacks. Beside the
        // scrubber, the buttons and the scrubber sit on the bar's middle as one
        // block, and so do the sides.
        let topHeight = max(controlsHeight, sidesHeight)
        let barHeight = topHeight + rowSpacing + scrubberHeight
        let buttonsRowHeight = isStacked ? topHeight : controlsHeight
        let middleHeight = buttonsRowHeight + rowSpacing + scrubberHeight
        let middleTop = (barHeight - middleHeight) / 2
        // The line the sides are centred on.
        let sidesMidY = isStacked ? topHeight / 2 : barHeight / 2

        var frames = [CGRect](repeating: .zero, count: subviews.count)
        func placeSide(_ index: Int, x: CGFloat) {
            let partHeight = height(index, widths[index])
            frames[index] = CGRect(x: x, y: sidesMidY - partHeight / 2, width: widths[index], height: partHeight)
        }
        placeSide(summary, x: 0)
        if let recovery { placeSide(recovery, x: widths[summary] + gap(recoveryWidth)) }
        if let volume { placeSide(volume, x: width - volumeWidth) }
        if let device { placeSide(device, x: width - volumeWidth - gap(volumeWidth) - widths[device]) }
        frames[controls] = CGRect(
            x: (width - controlsWidth) / 2,
            y: middleTop + (buttonsRowHeight - controlsHeight) / 2,
            width: controlsWidth,
            height: controlsHeight
        )
        // Under the controls, centred on the same line as play/pause.
        frames[scrubber] = CGRect(
            x: (width - scrubberWidth) / 2,
            y: middleTop + buttonsRowHeight + rowSpacing,
            width: scrubberWidth,
            height: scrubberHeight
        )
        return Frames(size: CGSize(width: width, height: barHeight), subviews: frames)
    }
}

/// The volume as one part of `PlaybackTransportArrangementLayout`: the slider
/// whenever it is offered at least `switchOverWidth`, the compact button
/// otherwise.
///
/// `ViewThatFits` compares ideal widths, so the slider reports a width below
/// its real floor as its ideal here. That lets the arrangement give it any
/// width from its floor up without the button taking over.
struct PlaybackTransportVolumeSlot<Full: View, Compact: View>: View {
    /// The narrowest slider and its gap, less than the control's real floor
    /// whatever width the speaker icon takes.
    static var switchOverWidth: CGFloat {
        PlaybackTransportLayoutPolicy.volumeSliderWidths.minimum + SpotiglassDesign.spacingS
    }

    @ViewBuilder var full: Full
    @ViewBuilder var compact: Compact

    var body: some View {
        ViewThatFits(in: .horizontal) {
            full.frame(idealWidth: Self.switchOverWidth)
            compact
        }
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
    /// Set while the bar shows the other service's player because that is what you hear (#396):
    /// the bar says which service plays, and its artists, which belong to the other library,
    /// aren't offered here. Its Lyrics button opens that song's lyrics (#486).
    var otherService: MusicService? = nil
    @Environment(\.openSettings) private var openSettingsAction
    @State private var isVolumePopoverPresented = false

    var body: some View {
        #if DEBUG
        let _ = ViewBodyTally.record("PlaybackControlsView")
        #endif
        GlassPanel {
            adaptiveTransportLayout
                .padding(.horizontal, SpotiglassDesign.spacingM)
                .padding(.vertical, SpotiglassDesign.spacingS)
        }
        .padding(.horizontal, SpotiglassDesign.spacingM)
        .padding(.bottom, SpotiglassDesign.spacingM)
    }

    /// One set of views, moved by `PlaybackTransportArrangementLayout`: the
    /// summary, controls and scrubber keep their identity at every width, so a
    /// layout pass never rebuilds the scrubber (#394). They are declared in
    /// reading order, the scrubber under the controls last.
    private var adaptiveTransportLayout: some View {
        PlaybackTransportArrangementLayout(
            spacing: SpotiglassDesign.spacingM,
            rowSpacing: SpotiglassDesign.spacingS
        ) {
            nowPlayingSummary
                .frame(
                    minWidth: PlaybackTransportLayoutPolicy.nowPlayingArtworkSize,
                    maxWidth: .infinity,
                    alignment: .leading
                )
                .clipped()
                .layoutValue(key: PlaybackTransportArrangementLayout.PartKey.self, value: .summary)

            recoveryControl
                .animation(.smooth(duration: 0.22), value: recoveryControlKey)
                .layoutValue(key: PlaybackTransportArrangementLayout.PartKey.self, value: .recovery)

            controlsCluster
                .layoutValue(key: PlaybackTransportArrangementLayout.PartKey.self, value: .controls)
            connectDeviceMenuGroup
                .layoutValue(key: PlaybackTransportArrangementLayout.PartKey.self, value: .device)
            // A player without its own volume (Apple Music) follows the Mac's volume.
            if viewModel.supportsPlayerVolume {
                PlaybackTransportVolumeSlot {
                    volumeGroup
                } compact: {
                    compactVolumeGroup
                }
                .layoutValue(key: PlaybackTransportArrangementLayout.PartKey.self, value: .volume)
            }

            // No frame of its own: offered no width, the row reports its real
            // floor, the scrubber's and the times either side of it, which the
            // layout keeps clear of the song and the right side (#538).
            centerScrubberGroup
                .layoutValue(key: PlaybackTransportArrangementLayout.PartKey.self, value: .scrubber)
        }
    }

    private var pausedBadge: some View {
        Text(SpotiglassL10n.string("playback.paused.label"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private var titleText: some View {
        Text(title)
            .font(.headline)
            .lineLimit(1)
            .contentTransition(.opacity)
            .animation(.smooth(duration: 0.28), value: title)
            // A narrow bar truncates the title; hovering shows it whole.
            .help(title)
    }

    private var nowPlayingSummary: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            leadingNowPlayingVisual

            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXXS) {
                // The title takes the room its text needs and Paused follows it,
                // whole; the free room goes after both, so the badge never drifts
                // towards the play controls. Paused shows once the title fits whole
                // beside it, or a long title keeps its floor (the play button shows
                // the state either way), so a narrow bar never trades the song's
                // name for the badge (#496).
                if shouldShowPausedIndicator {
                    // The whole title with Paused, then a long title cut to the floor
                    // it had beside Paused before #496, then the title alone.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: SpotiglassDesign.spacingXS) {
                            titleText
                                .fixedSize()
                            pausedBadge
                            Spacer(minLength: 0)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: SpotiglassDesign.spacingXS) {
                            titleText
                                .frame(
                                    minWidth: PlaybackTransportLayoutPolicy.titleBesidePausedMinimumWidth,
                                    idealWidth: PlaybackTransportLayoutPolicy.titleBesidePausedMinimumWidth,
                                    alignment: .leading
                                )
                            pausedBadge
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 0) {
                            titleText
                            Spacer(minLength: 0)
                        }
                    }
                } else {
                    HStack(spacing: 0) {
                        titleText
                        Spacer(minLength: 0)
                    }
                }

                if artistTapTargets.isEmpty {
                    Text(summarySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(.smooth(duration: 0.28), value: summarySubtitle)
                        .help(viewModel.refusedPlayPause?.message ?? summarySubtitle)
                } else {
                    artistLine
                }
            }
        }
        // Keep the summary as an accessibility container, not a replacement
        // element. The artwork's Lyrics control and each artist are
        // real Buttons and must remain separate VoiceOver actions (#267).
        .accessibilityElement(children: .contain)
    }

    var lyricsButtonTooltip: String {
        isLyricsPresented
            ? SpotiglassL10n.string("browser.closeLyrics")
            : SpotiglassL10n.string("tooltip.playback.lyrics")
    }

    private var lyricsButtonHint: String {
        isLyricsPresented
            ? SpotiglassL10n.string("browser.closeLyrics.hint")
            : SpotiglassL10n.string("playback.controls.lyrics.hint")
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
                            accessibilityLabel: isLyricsPresented
                                ? SpotiglassL10n.string("browser.closeLyrics")
                                : SpotiglassL10n.string("playback.controls.openLyrics"),
                            accessibilityHint: lyricsButtonHint,
                            size: CGSize(
                                width: PlaybackTransportLayoutPolicy.nowPlayingArtworkSize,
                                height: PlaybackTransportLayoutPolicy.nowPlayingArtworkSize
                            ),
                            action: { isLyricsPresented.toggle() }
                        ) {
                            EmptyView()
                        }
                    }
                    .frame(
                        width: PlaybackTransportLayoutPolicy.nowPlayingArtworkSize,
                        height: PlaybackTransportLayoutPolicy.nowPlayingArtworkSize
                    )
                    .id("artwork:\(item.uri ?? item.name)")
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .help(lyricsButtonTooltip)
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
                    .frame(width: SpotiglassDesign.Layout.iconButtonSize)
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
        // Only the scrubber follows each new position; the rest of the bar re-renders when the
        // track or the play state changes (#409).
        PlaybackProgressReader(progress: viewModel.progress) { [viewModel] anchor in
            PlaybackProgressScrubberGroup(
                progressAnchor: anchor,
                durationMilliseconds: nowPlaying?.durationMilliseconds ?? 0,
                isEnabled: nowPlaying != nil,
                onSeek: { milliseconds in
                    Task { await viewModel.seek(to: milliseconds) }
                }
            )
        }
    }

    /// The bar stays under the open lyrics (#438), so the button toggles them and
    /// shows when they are open, like Repeat shows its state.
    private var lyricsButton: some View {
        PlaybackTransportButton(
            accessibilityLabel: SpotiglassL10n.string("playback.controls.lyrics"),
            accessibilityHint: lyricsButtonHint,
            size: SpotiglassDesign.Layout.iconButtonFrame,
            action: { isLyricsPresented.toggle() }
        ) {
            Image(systemName: "music.note.list")
                .foregroundStyle(
                    isLyricsPresented
                        ? AnyShapeStyle(SpotiglassAccentStyle())
                        : AnyShapeStyle(.secondary)
                )
        }
        .frame(width: SpotiglassDesign.Layout.iconButtonSize, height: SpotiglassDesign.Layout.iconButtonSize)
        .accessibilityAddTraits(isLyricsPresented ? .isSelected : [])
        .help(lyricsButtonTooltip)
    }

    private var controlsCluster: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            // Lyrics mirrors Repeat, so play/pause is the middle of the cluster and
            // the bar centres it on the window (#496). Its slot keeps the room
            // while no song has lyrics to show, so play/pause never moves.
            ZStack {
                if showsLyricsButton {
                    lyricsButton
                }
            }
            .frame(width: SpotiglassDesign.Layout.iconButtonSize, height: SpotiglassDesign.Layout.iconButtonSize)

            PlaybackTransportButton(
                accessibilityLabel: SpotiglassL10n.string("playback.controls.previous"),
                accessibilityHint: Self.serviceString("playback.controls.previous.hint", appleMusic: "playback.controls.previous.appleMusic.hint", service: shownService),
                size: SpotiglassDesign.Layout.iconButtonFrame,
                isEnabled: canSkip && !viewModel.isSkipCommandPending,
                action: { Task { await viewModel.previous() } }
            ) {
                Image(systemName: "backward.fill")
                    // Nothing loaded, nothing to skip from (#500): off, and it looks off like Play.
                    .opacity(canSkip ? 1 : 0.45)
            }
            .frame(width: SpotiglassDesign.Layout.iconButtonSize, height: SpotiglassDesign.Layout.iconButtonSize)
            .help(SpotiglassL10n.string("tooltip.playback.previous"))

            PlaybackTransportButton(
                accessibilityLabel: playPauseAccessibilityLabel,
                accessibilityHint: Self.serviceString("playback.controls.playPause.hint", appleMusic: "playback.controls.playPause.appleMusic.hint", service: shownService),
                size: SpotiglassDesign.Layout.iconButtonFrame,
                isEnabled: viewModel.isPlaybackToggleReady,
                action: { viewModel.requestTogglePlayPause() }
            ) {
                Image(systemName: playPauseIcon)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.smooth(duration: 0.18), value: playPauseIcon)
                    // Apple Music's Play is off while nothing is loaded (#396): it must look off.
                    .opacity(viewModel.isPlaybackToggleReady ? 1 : 0.45)
            }
            .frame(width: SpotiglassDesign.Layout.iconButtonSize, height: SpotiglassDesign.Layout.iconButtonSize)
            // Label and tooltip agree here: the state and the next action are
            // the same word, so "Pause" shows while something is playing.
            .help(playPauseAccessibilityLabel)

            PlaybackTransportButton(
                accessibilityLabel: SpotiglassL10n.string("playback.controls.next"),
                accessibilityHint: Self.serviceString("playback.controls.next.hint", appleMusic: "playback.controls.next.appleMusic.hint", service: shownService),
                size: SpotiglassDesign.Layout.iconButtonFrame,
                isEnabled: canSkip
                    && !viewModel.isSkipCommandPending
                    && !viewModel.isNextCommandLockedOut,
                action: { Task { await viewModel.next() } }
            ) {
                Image(systemName: "forward.fill")
                    .opacity(canSkip ? 1 : 0.45)
            }
            .frame(width: SpotiglassDesign.Layout.iconButtonSize, height: SpotiglassDesign.Layout.iconButtonSize)
            .help(SpotiglassL10n.string("tooltip.playback.next"))

            PlaybackTransportButton(
                accessibilityLabel: repeatAccessibilityLabel,
                accessibilityHint: SpotiglassL10n.string("playback.controls.repeat.hint"),
                size: SpotiglassDesign.Layout.iconButtonFrame,
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
            .frame(width: SpotiglassDesign.Layout.iconButtonSize, height: SpotiglassDesign.Layout.iconButtonSize)
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
                    if viewModel.supportsDeviceTransfer {
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
                    } else {
                        // Services without device transfer only list Mac outputs.
                        EmptyView()
                    }

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
                .frame(width: SpotiglassDesign.Layout.iconButtonSize, height: SpotiglassDesign.Layout.iconButtonSize)
            }
            .menuIndicator(.hidden)
            .disabled(!hasReadyDevice)
            .opacity(hasReadyDevice ? 1 : 0.45)
            .help(SpotiglassL10n.string("tooltip.playback.device"))
            .accessibilityLabel(SpotiglassL10n.string("playback.controls.device"))
            .accessibilityHint(Self.serviceString("playback.controls.device.hint", appleMusic: "playback.controls.device.appleMusic.hint", service: shownService))
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

    private func connectDeviceRowSymbol(for device: MusicPlaybackDevice) -> String {
        PlaybackOutputSFResolver.symbolName(deviceName: device.name, spotifyDeviceType: device.type)
    }

    private func macAudioOutputRowSymbol(for device: MacAudioOutputDevice) -> String {
        PlaybackOutputSFResolver.symbolName(deviceName: device.name, spotifyDeviceType: nil)
    }

    private var compactVolumeGroup: some View {
        PlaybackTransportButton(
            accessibilityLabel: SpotiglassL10n.string("playback.controls.volume"),
            accessibilityHint: SpotiglassL10n.string("playback.controls.volume.hint"),
            size: SpotiglassDesign.Layout.iconButtonFrame,
            isEnabled: isPlaybackVolumeReady,
            action: { isVolumePopoverPresented.toggle() }
        ) {
            Image(systemName: "speaker.wave.2")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: SpotiglassDesign.Layout.iconButtonSize, height: SpotiglassDesign.Layout.iconButtonSize)
        .popover(isPresented: $isVolumePopoverPresented) {
            Slider(value: playbackVolumeBinding, in: 0 ... 1)
                .controlSize(.small)
                .frame(width: PlaybackTransportLayoutPolicy.volumeSliderWidths.maximum)
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
                .frame(
                    minWidth: PlaybackTransportLayoutPolicy.volumeSliderWidths.minimum,
                    idealWidth: PlaybackTransportLayoutPolicy.volumeSliderWidths.ideal,
                    maxWidth: PlaybackTransportLayoutPolicy.volumeSliderWidths.maximum
                )
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

    /// Reconnect or Retry beside the line that says what went wrong, or the
    /// spinner while the player connects. Off the transport cluster, so it
    /// never pushes play/pause off the bar's centre (#496).
    @ViewBuilder
    private var recoveryControl: some View {
        switch viewModel.connectionState {
        case .disconnected, .unavailable:
            // Apple Music's player is this Mac: there is no connection to restore (#430).
            if viewModel.canReconnectPlayer {
                recoveryButton(
                    title: SpotiglassL10n.string("playback.controls.reconnect"),
                    systemImage: "dot.radiowaves.left.and.right",
                    accessibilityLabel: SpotiglassL10n.string("playback.controls.reconnect.label"),
                    accessibilityHint: SpotiglassL10n.string("playback.controls.reconnect.hint"),
                    action: { viewModel.start() }
                )
            }
        case .connecting:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(SpotiglassL10n.string("playback.controls.connecting"))
        case let .error(error):
            switch error.recoveryAction {
            case .reconnect:
                recoveryButton(
                    title: SpotiglassL10n.string("playback.controls.reconnect"),
                    systemImage: "dot.radiowaves.left.and.right",
                    accessibilityLabel: SpotiglassL10n.string("playback.controls.reconnect.label"),
                    accessibilityHint: SpotiglassL10n.string("playback.controls.reconnect.sdk.hint"),
                    action: { viewModel.start() }
                )
            case .retryTransfer:
                recoveryButton(
                    title: SpotiglassL10n.string("playback.controls.retry"),
                    systemImage: "arrow.clockwise",
                    accessibilityLabel: SpotiglassL10n.string("playback.controls.retry.label"),
                    accessibilityHint: SpotiglassL10n.string("playback.controls.retry.hint"),
                    action: { Task { await viewModel.retryPlaybackTransfer() } }
                )
            case .reauthenticate:
                recoveryButton(
                    title: SpotiglassL10n.string("auth.reconnect.button"),
                    systemImage: "gear",
                    accessibilityLabel: SpotiglassL10n.string("auth.reconnect.button"),
                    accessibilityHint: error.message,
                    action: { openSettingsAction() }
                )
            case .none:
                EmptyView()
            }
        case .ready, .transferring, .playing, .paused:
            EmptyView()
        }
    }

    /// The button with its title while the left half of the bar has room for
    /// it beside the summary, its symbol alone otherwise; the tooltip and
    /// VoiceOver keep the title either way.
    private func recoveryButton(
        title: String,
        systemImage: String,
        accessibilityLabel: String,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            PlaybackTransportButton(
                accessibilityLabel: accessibilityLabel,
                accessibilityHint: accessibilityHint,
                size: SpotiglassDesign.Layout.wideButtonFrame,
                action: action
            ) {
                Label(title, systemImage: systemImage)
            }
            .frame(width: SpotiglassDesign.Layout.wideButtonWidth, height: SpotiglassDesign.Layout.iconButtonSize)

            PlaybackTransportButton(
                accessibilityLabel: accessibilityLabel,
                accessibilityHint: accessibilityHint,
                action: action
            ) {
                Image(systemName: systemImage)
            }
            .frame(width: SpotiglassDesign.Layout.iconButtonSize, height: SpotiglassDesign.Layout.iconButtonSize)
        }
        .help(title)
    }

    /// The Apple Music wording for text whose Spotify version names Spotify's player.
    static func serviceString(
        _ spotifyKey: String,
        appleMusic appleMusicKey: String,
        service: MusicService = MusicServiceSelection.current
    ) -> String {
        SpotiglassL10n.string(service == .appleMusic ? appleMusicKey : spotifyKey)
    }

    private var title: String {
        if let status = Self.statusLines(for: viewModel.connectionState, playerPushesState: viewModel.playerPushesState, service: shownService) {
            return status.title
        }
        return viewModel.connectionState.currentTrack?.name ?? ""
    }

    /// The bar's two lines while no song is there to name them: connecting, nothing loaded, an
    /// error. `nil` while a song plays or is paused. The pop-out lyrics window shows the same (#439).
    static func statusLines(
        for state: PlaybackConnectionState,
        playerPushesState: Bool,
        service: MusicService
    ) -> (title: String, subtitle: String)? {
        switch state {
        case .playing, .paused(.some):
            nil
        case .paused(.none):
            (
                SpotiglassL10n.string("playback.controls.state.paused.title"),
                SpotiglassL10n.string("playback.controls.state.paused.subtitle")
            )
        case .disconnected:
            (
                SpotiglassL10n.string("playback.controls.state.disconnected.title"),
                serviceString("playback.controls.state.disconnected.subtitle", appleMusic: "playback.controls.state.disconnected.subtitle.appleMusic", service: service)
            )
        case .connecting:
            (
                serviceString("playback.controls.state.connecting.title", appleMusic: "playback.controls.state.connecting.title.appleMusic", service: service),
                serviceString("playback.controls.state.connecting.subtitle", appleMusic: "playback.controls.state.connecting.subtitle.appleMusic", service: service)
            )
        case .ready:
            (
                SpotiglassL10n.string("playback.controls.state.ready.title"),
                // MusicKit's player has nothing to resume, so its Play is off until a track is chosen (#396).
                playerPushesState
                    ? SpotiglassL10n.string("playback.controls.state.ready.subtitle")
                    : SpotiglassL10n.string("playback.controls.state.ready.subtitle.appleMusic")
            )
        case .transferring:
            (
                SpotiglassL10n.string("playback.controls.state.transferring.title"),
                SpotiglassL10n.string("playback.controls.state.transferring.subtitle")
            )
        case let .unavailable(message):
            (SpotiglassL10n.string("playback.controls.state.unavailable.title"), message)
        case let .error(error):
            (error.title, error.message)
        }
    }

    private var shouldShowPausedIndicator: Bool {
        if case let .paused(item) = viewModel.connectionState {
            return item != nil
        }
        return false
    }

    /// The lyrics follow the song the bar shows, whichever service plays it (#486).
    private var showsLyricsButton: Bool {
        viewModel.currentLyricTrack != nil
    }

    /// The service whose player the bar shows.
    private var shownService: MusicService {
        otherService ?? MusicServiceSelection.current
    }

    /// The line under the title. With the other service's player in the bar it
    /// starts with that service ("In Apple Music · M83"): at the start of its own
    /// line it shows at every width and takes no room from the title (#396, #496).
    private var summarySubtitle: String {
        guard let otherService else { return subtitle }
        let service = SpotiglassL10n.format("playback.controls.otherService.label", otherService.displayName)
        return subtitle.isEmpty ? service : "\(service) · \(subtitle)"
    }

    private var subtitle: String {
        // A refused play / pause went back to the state before it; the line says so, and why
        // on hover (#437).
        if let refused = viewModel.refusedPlayPause {
            return refused.title
        }
        if let status = Self.statusLines(for: viewModel.connectionState, playerPushesState: viewModel.playerPushesState, service: shownService) {
            return status.subtitle
        }
        return viewModel.connectionState.currentTrack?.artistText ?? ""
    }

    private var artistTapTargets: [ArtistTapTarget] {
        guard otherService == nil, viewModel.refusedPlayPause == nil, let nowPlaying else { return [] }
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
        case .disconnected: viewModel.canReconnectPlayer ? "disconnected" : "transport"
        case .unavailable: viewModel.canReconnectPlayer ? "unavailable" : "transport"
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
        viewModel.connectionState.hasReadyDevice
    }

    private var canSkip: Bool {
        viewModel.connectionState.hasTrackToSkipFrom
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
/// The pop-out lyrics window uses it too (#439).
struct PlaybackTransportButton<Content: View>: View {
    let accessibilityLabel: String
    let accessibilityHint: String
    let size: CGSize
    let isEnabled: Bool
    let action: () -> Void
    let content: Content

    init(
        accessibilityLabel: String,
        accessibilityHint: String,
        size: CGSize = SpotiglassDesign.Layout.iconButtonFrame,
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

            // The native button is borderless and titleless, so it is already
            // visually transparent. A near-zero opacity here makes SwiftUI's
            // AppKit bridge swallow mouse events before they reach the button.
            PlaybackNativeButton(
                accessibilityLabel: accessibilityLabel,
                accessibilityHint: accessibilityHint,
                isEnabled: isEnabled,
                action: action
            )
            .frame(width: size.width, height: size.height)
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
                    .buttonStyle(.spotiglassTextLink)
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
