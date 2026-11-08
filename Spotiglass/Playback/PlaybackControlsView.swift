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
    static let compactVolumeBreakpoint: CGFloat = 760
    static let stackedScrubberBreakpoint: CGFloat = 680

    /// A playing summary always keeps the artwork, its gap, and enough title
    /// width to remain readable. The title is allowed to truncate beyond this
    /// floor rather than forcing the scrubber or timestamps off the bar.
    static let nowPlayingArtworkSize: CGFloat = 44
    static let nowPlayingSummaryTitleMinimumWidth: CGFloat = 120
    static let nowPlayingSummaryMinimumWidth: CGFloat =
        nowPlayingArtworkSize + SpotiglassDesign.spacingS + nowPlayingSummaryTitleMinimumWidth

    struct TransportLayoutCandidate: Equatable {
        let useCompactVolume: Bool
        /// Minimum proposal width at which this candidate can be selected.
        let minimumWidth: CGFloat
    }

    /// Candidate order is the order `PlaybackTransportArrangementLayout` tries
    /// them in: full horizontal, compact horizontal, then stacked compact. The
    /// layout takes the first whose minimum width and ideal row both fit the
    /// width it is offered, so the choice never depends on a stored measurement.
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

    /// The volume slider's width range, and the full volume control's floor:
    /// its speaker icon, the gap and the narrowest slider.
    static let volumeSliderWidths: (minimum: CGFloat, ideal: CGFloat, maximum: CGFloat) = (100, 120, 140)
    static let fullVolumeMinimumWidth: CGFloat = 16 + SpotiglassDesign.spacingS + volumeSliderWidths.minimum

    /// The fixed trailing controls' floor, including the two gaps between the
    /// controls cluster, device picker, and volume control.
    static func transportActionsMinimumWidth(useCompactVolume: Bool) -> CGFloat {
        let controlsClusterWidth =
            (4 * 28)
            + (3 * SpotiglassDesign.spacingS)
        let volumeWidth = useCompactVolume ? 28 : fullVolumeMinimumWidth
        return controlsClusterWidth
            + (2 * SpotiglassDesign.spacingM)
            + 28
            + volumeWidth
    }
}

/// Lays the transport out as one row, or as two rows (summary and controls
/// above the scrubber) once the row no longer fits (#394).
///
/// It replaced a `ViewThatFits` over three complete copies of the transport,
/// which builds a copy anew whenever its pick changes. In the app's window,
/// whose minimum size SwiftUI measures from its content, the pick kept
/// changing: traces of a paused Apple Music track showed the scrubber rebuilt
/// about 120 times a second, each new scrubber's timeline asking for the next
/// layout pass, and a CPU core busy. Here the same subviews only move, and the
/// choice is a pure function of the offered width.
///
/// Each subview carries its `Part`. Within an arrangement the space is shared
/// out the way the stacks this replaced shared it, so the bar looks the same:
/// least flexible part first, each offered an even share of what is left.
struct PlaybackTransportArrangementLayout: Layout {
    enum Part: Equatable {
        case summary, scrubber, controls, device, volume
    }

    struct PartKey: LayoutValueKey {
        static let defaultValue = Part.controls
    }

    enum Arrangement: Equatable {
        case row(compactVolume: Bool)
        case stacked
    }

    var spacing: CGFloat
    var rowSpacing: CGFloat

    static let summaryIdealWidth: CGFloat = 280
    static let summaryMaximumWidth: CGFloat = 320

    /// The arrangement for an offered width: the first candidate whose minimum
    /// and ideal row both fit, the stacked one otherwise. No width (an ideal-size
    /// query) means the full row, as the first candidate always was.
    static func arrangement(
        forWidth width: CGFloat?,
        idealRowWidth: (_ compactVolume: Bool) -> CGFloat
    ) -> Arrangement {
        guard let width else { return .row(compactVolume: false) }
        for candidate in PlaybackTransportLayoutPolicy.transportLayoutCandidates() where candidate.minimumWidth > 0 {
            if width >= max(candidate.minimumWidth, idealRowWidth(candidate.useCompactVolume)) {
                return .row(compactVolume: candidate.useCompactVolume)
            }
        }
        return .stacked
    }

    /// One child of a stack: how far it can stretch, and how wide it is when
    /// offered a width.
    struct Sizing {
        var flexibility: CGFloat
        var width: (CGFloat) -> CGFloat
    }

    /// How a stack shares `total` among its children: the least flexible first,
    /// each offered an even share of what is still left.
    static func distribute(_ total: CGFloat, spacing: CGFloat, among children: [Sizing]) -> [CGFloat] {
        var remaining = total - spacing * CGFloat(max(children.count - 1, 0))
        var widths = [CGFloat](repeating: 0, count: children.count)
        let order = children.indices.sorted { children[$0].flexibility < children[$1].flexibility }
        for (position, index) in order.enumerated() {
            let offer = max(remaining / CGFloat(children.count - position), 0)
            widths[index] = children[index].width(offer)
            remaining -= widths[index]
        }
        return widths
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        frames(forWidth: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // The offered width decides, as it did for the stacks this replaced; the
        // bounds are wider only when the content cannot shrink to the offer.
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
        guard let summaryIndex = index(of: .summary), let scrubberIndex = index(of: .scrubber) else {
            return Frames(size: .zero, subviews: subviews.map { _ in .zero })
        }
        let summary = subviews[summaryIndex], scrubber = subviews[scrubberIndex]
        // The trailing controls in their order: transport buttons, device menu, volume.
        let trailing = [Part.controls, .device, .volume].compactMap(index(of:))

        func measuredWidth(_ subview: LayoutSubview, _ offer: CGFloat?) -> CGFloat {
            subview.sizeThatFits(ProposedViewSize(width: offer, height: nil)).width
        }
        // Offered its switch-over width (see `PlaybackTransportVolumeSlot`), the
        // volume shows the slider at its narrowest: that is its floor. Its
        // ideal is the slider's own ideal on top.
        let sliderWidths = PlaybackTransportLayoutPolicy.volumeSliderWidths
        let fullVolumeMinimum = index(of: .volume).map {
            measuredWidth(subviews[$0], PlaybackTransportVolumeSlot<EmptyView, EmptyView>.switchOverWidth)
        } ?? 0
        let fullVolumeIdeal = fullVolumeMinimum + sliderWidths.ideal - sliderWidths.minimum
        func sizing(_ index: Int, compactVolume: Bool) -> Sizing {
            let subview = subviews[index]
            if subview[PartKey.self] == .volume {
                // The volume offers its slider or its compact button by the width
                // it gets: the arrangement decides which by what it offers.
                if compactVolume {
                    let compact = measuredWidth(subview, 0)
                    return Sizing(flexibility: 0) { _ in compact }
                }
                let maximum = measuredWidth(subview, .infinity)
                return Sizing(flexibility: maximum - fullVolumeMinimum) { offer in
                    measuredWidth(subview, max(offer, fullVolumeMinimum))
                }
            }
            let minimum = measuredWidth(subview, 0), maximum = measuredWidth(subview, .infinity)
            return Sizing(flexibility: maximum - minimum) { offer in measuredWidth(subview, offer) }
        }
        func trailingIdeal(compactVolume: Bool) -> CGFloat {
            let widths = trailing.map { index -> CGFloat in
                if subviews[index][PartKey.self] == .volume {
                    return compactVolume ? measuredWidth(subviews[index], 0) : fullVolumeIdeal
                }
                return measuredWidth(subviews[index], nil)
            }
            return widths.reduce(0, +) + spacing * CGFloat(max(widths.count - 1, 0))
        }
        let scrubberIdeal = measuredWidth(scrubber, nil)
        func idealRowWidth(compactVolume: Bool) -> CGFloat {
            let floor = PlaybackTransportLayoutPolicy.transportActionsMinimumWidth(useCompactVolume: compactVolume)
            return Self.summaryIdealWidth + scrubberIdeal + max(floor, trailingIdeal(compactVolume: compactVolume)) + 2 * spacing
        }

        var frames = [CGRect](repeating: .zero, count: subviews.count)
        func height(_ index: Int, _ width: CGFloat) -> CGFloat {
            subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }

        switch Self.arrangement(forWidth: proposedWidth, idealRowWidth: { idealRowWidth(compactVolume: $0) }) {
        case .row(let compactVolume):
            let width = proposedWidth ?? max(
                PlaybackTransportLayoutPolicy.compactVolumeBreakpoint,
                idealRowWidth(compactVolume: false)
            )
            // The actions keep their reserved floor and sit at its trailing end.
            let floor = PlaybackTransportLayoutPolicy.transportActionsMinimumWidth(useCompactVolume: compactVolume)
            let trailingSizings = trailing.map { sizing($0, compactVolume: compactVolume) }
            func trailingWidths(_ offer: CGFloat) -> [CGFloat] {
                Self.distribute(max(floor, offer), spacing: spacing, among: trailingSizings)
            }
            func trailingTotal(_ widths: [CGFloat]) -> CGFloat {
                widths.reduce(0, +) + spacing * CGFloat(max(widths.count - 1, 0))
            }
            let trailingMaximum = trailingTotal(trailingWidths(.infinity))
            // The share the controls were offered, to place them as measured.
            var actionsOffer: CGFloat = 0
            let row = Self.distribute(width, spacing: spacing, among: [
                Sizing(flexibility: Self.summaryMaximumWidth - PlaybackTransportLayoutPolicy.nowPlayingSummaryMinimumWidth) {
                    min(max($0, PlaybackTransportLayoutPolicy.nowPlayingSummaryMinimumWidth), Self.summaryMaximumWidth)
                },
                Sizing(flexibility: .infinity) { max($0, measuredWidth(scrubber, 0)) },
                Sizing(flexibility: max(floor, trailingMaximum) - floor) { offer in
                    actionsOffer = offer
                    return max(floor, trailingTotal(trailingWidths(offer)))
                },
            ])
            let actionsWidths = trailingWidths(actionsOffer)
            let actionsHeights: [CGFloat] = zip(trailing, actionsWidths).map { height($0, $1) }
            let summaryHeight = height(summaryIndex, row[0])
            let scrubberHeight = height(scrubberIndex, row[1])
            let rowHeight = max(summaryHeight, scrubberHeight, actionsHeights.max() ?? 0)
            frames[summaryIndex] = CGRect(x: 0, y: (rowHeight - summaryHeight) / 2, width: row[0], height: summaryHeight)
            frames[scrubberIndex] = CGRect(
                x: row[0] + spacing,
                y: (rowHeight - scrubberHeight) / 2,
                width: row[1],
                height: scrubberHeight
            )
            var x = row[0] + spacing + row[1] + spacing + row[2] - trailingTotal(actionsWidths)
            for (index, partWidth) in zip(trailing, actionsWidths) {
                let partHeight = height(index, partWidth)
                frames[index] = CGRect(x: x, y: (rowHeight - partHeight) / 2, width: partWidth, height: partHeight)
                x += partWidth + spacing
            }
            return Frames(size: CGSize(width: width, height: rowHeight), subviews: frames)

        case .stacked:
            let summaryMinimum = PlaybackTransportLayoutPolicy.nowPlayingSummaryMinimumWidth
            let topSizings = [Sizing(flexibility: .infinity) { max($0, summaryMinimum) }]
                + trailing.map { sizing($0, compactVolume: true) }
            func topTotal(_ widths: [CGFloat]) -> CGFloat {
                widths.reduce(0, +) + spacing * CGFloat(trailing.count)
            }
            // The row is shared out over the offered width, as the stack did; when
            // its parts cannot shrink that far it reports the width they take.
            let top = Self.distribute(proposedWidth ?? 0, spacing: spacing, among: topSizings)
            let width = max(proposedWidth ?? 0, topTotal(top), measuredWidth(scrubber, 0))
            let topParts = [summaryIndex] + trailing
            let topHeight = zip(topParts, top).map { height($0, $1) }.max() ?? 0
            var x: CGFloat = 0
            for (index, partWidth) in zip(topParts, top) {
                let partHeight = height(index, partWidth)
                frames[index] = CGRect(x: x, y: (topHeight - partHeight) / 2, width: partWidth, height: partHeight)
                x += partWidth + spacing
            }
            // The scrubber takes the offered width, even when the row above
            // overflows it, as it did in the stack this replaced.
            let scrubberWidth = max(proposedWidth ?? width, measuredWidth(scrubber, 0))
            let scrubberHeight = height(scrubberIndex, scrubberWidth)
            frames[scrubberIndex] = CGRect(x: 0, y: topHeight + rowSpacing, width: scrubberWidth, height: scrubberHeight)
            return Frames(size: CGSize(width: width, height: topHeight + rowSpacing + scrubberHeight), subviews: frames)
        }
    }
}

/// The volume as one part of `PlaybackTransportArrangementLayout`: the slider
/// whenever it is offered at least `switchOverWidth`, the compact button
/// otherwise.
///
/// `ViewThatFits` compares ideal widths, so the slider reports a width below
/// its real floor as its ideal here. That lets the arrangement give it any
/// width from its floor up, as the row it replaced did, without the button
/// taking over.
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
    /// the bar says which service plays, and its artists and lyrics, which belong to the other
    /// library, aren't offered here.
    var otherService: MusicService? = nil
    @Environment(\.openSettings) private var openSettingsAction
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

    /// One set of views, moved by `PlaybackTransportArrangementLayout`: the
    /// summary, scrubber and controls keep their identity at every width, so a
    /// layout pass never rebuilds the scrubber (#394).
    private var adaptiveTransportLayout: some View {
        PlaybackTransportArrangementLayout(
            spacing: SpotiglassDesign.spacingM,
            rowSpacing: SpotiglassDesign.spacingS
        ) {
            nowPlayingSummary
                .frame(
                    minWidth: PlaybackTransportLayoutPolicy.nowPlayingSummaryMinimumWidth,
                    maxWidth: .infinity,
                    alignment: .leading
                )
                .clipped()
                .layoutValue(key: PlaybackTransportArrangementLayout.PartKey.self, value: .summary)

            centerScrubberGroup
                .frame(
                    minWidth: PlaybackTransportLayoutPolicy.scrubberMinimumWidth,
                    maxWidth: .infinity
                )
                .layoutValue(key: PlaybackTransportArrangementLayout.PartKey.self, value: .scrubber)

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
                    if let otherService {
                        Text(SpotiglassL10n.format("playback.controls.otherService.label", otherService.displayName))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                            .transition(.opacity)
                    } else if shouldShowPausedIndicator {
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

            // A sibling of the title and artist block, not part of the title's
            // row: there it sat on the title's baseline, above the centre line
            // every other part of the bar shares (#427).
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

    private var controlsCluster: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            recoveryLeadingControl
                .animation(.smooth(duration: 0.22), value: recoveryControlKey)

            PlaybackTransportButton(
                accessibilityLabel: SpotiglassL10n.string("playback.controls.previous"),
                accessibilityHint: Self.serviceString("playback.controls.previous.hint", appleMusic: "playback.controls.previous.appleMusic.hint", service: shownService),
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
                accessibilityHint: Self.serviceString("playback.controls.playPause.hint", appleMusic: "playback.controls.playPause.appleMusic.hint", service: shownService),
                size: CGSize(width: 28, height: 28),
                isEnabled: viewModel.isPlaybackToggleReady,
                action: { Task { await viewModel.togglePlayPause() } }
            ) {
                Image(systemName: playPauseIcon)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.smooth(duration: 0.18), value: playPauseIcon)
                    // Apple Music's Play is off while nothing is loaded (#396): it must look off.
                    .opacity(viewModel.isPlaybackToggleReady ? 1 : 0.45)
            }
            .frame(width: 28, height: 28)
            // Label and tooltip agree here: the state and the next action are
            // the same word, so "Pause" shows while something is playing.
            .help(playPauseAccessibilityLabel)

            PlaybackTransportButton(
                accessibilityLabel: SpotiglassL10n.string("playback.controls.next"),
                accessibilityHint: Self.serviceString("playback.controls.next.hint", appleMusic: "playback.controls.next.appleMusic.hint", service: shownService),
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
                .frame(width: 28, height: 28)
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

    @ViewBuilder
    private var recoveryLeadingControl: some View {
        switch viewModel.connectionState {
        case .disconnected, .unavailable:
            // Apple Music's player is this Mac: there is no connection to restore (#430).
            if viewModel.canReconnectPlayer {
                PlaybackTransportButton(
                    accessibilityLabel: SpotiglassL10n.string("playback.controls.reconnect.label"),
                    accessibilityHint: SpotiglassL10n.string("playback.controls.reconnect.hint"),
                    size: CGSize(width: 170, height: 28),
                    action: { viewModel.start() }
                ) {
                    Label(SpotiglassL10n.string("playback.controls.reconnect"), systemImage: "dot.radiowaves.left.and.right")
                }
                .frame(width: 170, height: 28)
            }
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

    /// The Apple Music wording for text whose Spotify version names Spotify's player.
    static func serviceString(
        _ spotifyKey: String,
        appleMusic appleMusicKey: String,
        service: MusicService = MusicServiceSelection.current
    ) -> String {
        SpotiglassL10n.string(service == .appleMusic ? appleMusicKey : spotifyKey)
    }

    private var title: String {
        switch viewModel.connectionState {
        case .disconnected:
            SpotiglassL10n.string("playback.controls.state.disconnected.title")
        case .connecting:
            Self.serviceString("playback.controls.state.connecting.title", appleMusic: "playback.controls.state.connecting.title.appleMusic", service: shownService)
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
        otherService == nil && viewModel.currentLyricTrack != nil
    }

    /// The service whose player the bar shows.
    private var shownService: MusicService {
        otherService ?? MusicServiceSelection.current
    }

    private var subtitle: String {
        switch viewModel.connectionState {
        case .disconnected:
            SpotiglassL10n.string("playback.controls.state.disconnected.subtitle")
        case .connecting:
            Self.serviceString("playback.controls.state.connecting.subtitle", appleMusic: "playback.controls.state.connecting.subtitle.appleMusic", service: shownService)
        case .ready:
            // MusicKit's player has nothing to resume, so its Play is off until a track is chosen (#396).
            viewModel.playerPushesState
                ? SpotiglassL10n.string("playback.controls.state.ready.subtitle")
                : SpotiglassL10n.string("playback.controls.state.ready.subtitle.appleMusic")
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
        guard otherService == nil, let nowPlaying else { return [] }
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
