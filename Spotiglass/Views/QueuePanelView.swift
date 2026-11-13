import SwiftUI

struct QueuePanelView: View {
    @ObservedObject var queueViewModel: QueueViewModel
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    let openArtist: (ArtistTapTarget) -> Void
    /// Builds the shared Spotify track-operations menu for a queue row. The
    /// browser owns the mutation model, while the queue keeps its row design
    /// and selection logic independent of it.
    let trackOpsMenuItems: ((QueueItem) -> AnyView)?

    /// Drives the list's own selection, which is what makes the rows reachable
    /// with the arrow keys and gives them a de-emphasized highlight when the
    /// panel is not focused. Return plays whatever is selected (#123).
    @State private var selectedItemID: QueueItem.ID?

    init(
        queueViewModel: QueueViewModel,
        playbackViewModel: PlaybackSessionViewModel,
        openArtist: @escaping (ArtistTapTarget) -> Void,
        trackOpsMenuItems: ((QueueItem) -> AnyView)? = nil
    ) {
        _queueViewModel = ObservedObject(wrappedValue: queueViewModel)
        _playbackViewModel = ObservedObject(wrappedValue: playbackViewModel)
        self.openArtist = openArtist
        self.trackOpsMenuItems = trackOpsMenuItems
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let error = queueViewModel.lastError {
                errorBanner(error)
                    .transition(
                        .move(edge: .top).combined(with: .opacity)
                    )
            }

            queueList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: queueViewModel.lastError?.id)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
                Text(SpotiglassL10n.string("queue.title"))
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
                    .foregroundStyle(
                        playbackViewModel.shuffleEnabled
                            ? AnyShapeStyle(SpotiglassAccentStyle())
                            : AnyShapeStyle(.primary)
                    )
            }
            .disabled(!playbackViewModel.isTransportMutationReady)
            .accessibilityLabel(
                playbackViewModel.shuffleEnabled
                    ? SpotiglassL10n.string("queue.shuffle.on")
                    : SpotiglassL10n.string("queue.shuffle.off")
            )
            .accessibilityHint(PlaybackControlsView.serviceString("queue.shuffle.hint", appleMusic: "queue.shuffle.appleMusic.hint"))
            .help(PlaybackTransportTooltips.shuffleTooltip(isEnabled: playbackViewModel.shuffleEnabled))
        }
        .padding(SpotiglassDesign.Layout.panelMargin)
    }

    private var subtitleText: String {
        switch playbackViewModel.repeatMode {
        case .track:
            return SpotiglassL10n.string("queue.subtitle.repeatOne")
        case .off:
            return upcomingCountLine
        case .context:
            return String(format: SpotiglassL10n.string("queue.subtitle.repeatPlaylist"), upcomingCountLine)
        }
    }

    private var upcomingCountLine: String {
        Self.upcomingCountLine(count: queueViewModel.upcomingItems.count, limit: queueViewModel.maxUpcomingItems)
    }

    /// The panel shows at most `limit` upcoming tracks, and neither service reports how many
    /// are queued past that, so a full list says "Next 20 tracks" rather than claiming only
    /// 20 are queued (#400).
    static func upcomingCountLine(count: Int, limit: Int) -> String {
        if count >= limit {
            return SpotiglassL10n.format("queue.subtitle.upNextCapped", Int64(limit))
        }
        // The catalog owns the plural rule now, so this passes the count and
        // stops encoding a two-form model in Swift control flow (#156).
        return SpotiglassL10n.format("queue.subtitle.upNext", Int64(count))
    }

    private func errorBanner(_ error: BrowsingDisplayError) -> some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            // The list below takes every point the panel offers, so without a fixed vertical
            // size the banner got one line each and German sentences ended in "Prü…" (#470).
            Text(error.title)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(error.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(SpotiglassL10n.string("queue.dismiss")) {
                queueViewModel.clearError()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(SpotiglassDesign.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
        .padding(.horizontal, SpotiglassDesign.Layout.panelMargin)
    }

    /// One list owns the whole queue, so it also owns the scrolling. The panel
    /// used to be a `ScrollView` wrapping plain stacks, which meant the rows had
    /// no selection, no keyboard traversal and no row semantics for VoiceOver
    /// (#112, #123).
    private var queueList: some View {
        List(selection: $selectedItemID) {
            nowPlayingSection
            upNextSection
        }
        .listStyle(.inset)
        .onKeyPress(.return) {
            guard let selectedItemID,
                let item = queueViewModel.item(forSelectionID: selectedItemID),
                item.playableURI != nil
            else { return .ignored }
            Task { await queueViewModel.playItem(item) }
            return .handled
        }
    }

    @ViewBuilder
    private var nowPlayingSection: some View {
        Section(SpotiglassL10n.string("queue.nowPlaying")) {
            ZStack {
                if let item = queueViewModel.nowPlayingItem {
                    QueueRowView(
                        item: item,
                        isCurrent: true,
                        isPlaying: queueViewModel.isPlaybackPlaying,
                        onSelect: {
                            Task { await queueViewModel.playItem(item) }
                        },
                        openArtist: openArtist,
                        trackOpsMenuItems: trackOpsMenuItems.map { builder in
                            { builder(item) }
                        }
                    )
                    .id("now-playing-row:\(item.id)")
                    .tag(item.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    Text(SpotiglassL10n.string("queue.nothingPlaying"))
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
        Section(SpotiglassL10n.string("queue.upNext")) {
            if queueViewModel.upcomingItems.isEmpty {
                Text(upNextEmptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SpotiglassDesign.spacingM)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
                    .transition(.opacity)
            } else {
                ForEach(queueViewModel.upcomingItems) { item in
                    QueueRowView(
                        item: item,
                        isCurrent: false,
                        isPlaying: false,
                        onSelect: {
                            Task { await queueViewModel.playItem(item) }
                        },
                        openArtist: openArtist,
                        trackOpsMenuItems: trackOpsMenuItems.map { builder in
                            { builder(item) }
                        }
                    )
                    .tag(item.id)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity.combined(with: .scale(scale: 0.96))
                        )
                    )
                }
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: queueViewModel.upcomingItems.map(\.id))
    }

    private var upNextEmptyMessage: String {
        if playbackViewModel.repeatMode == .track {
            return SpotiglassL10n.string("queue.upNext.empty.repeat")
        }
        return SpotiglassL10n.string("queue.upNext.empty.default")
    }
}

private struct QueueRowView: View {
    let item: QueueItem
    let isCurrent: Bool
    let isPlaying: Bool
    let onSelect: () -> Void
    let openArtist: (ArtistTapTarget) -> Void
    let trackOpsMenuItems: (() -> AnyView)?

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            // Shared with the playlist row so the two cannot drift apart again (#140).
            // The playing row marks its cover instead of adding a column, so every
            // cover in the panel starts on the same edge (#428).
            ArtworkView(url: item.albumArtURL, size: TrackRowMetrics.artworkSize)
                .overlay(alignment: .bottomTrailing) {
                    if isCurrent {
                        PlayingArtworkBadge(isPlaying: isPlaying)
                    }
                }

            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXXS) {
                Text(item.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(TrackRowMetrics.titleLineLimit)
                subtitleLine
            }

            Spacer(minLength: SpotiglassDesign.spacingXS)

            Text(item.durationLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, TrackRowMetrics.verticalPadding)
        .padding(.horizontal, TrackRowMetrics.horizontalPadding)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
        .contentShape(Rectangle())
        // Single click selects, the way a Mac list row does; playing is the
        // double click, Return on the selection, or the VoiceOver action below.
        .modifier(QueueRowPlayInteractionModifier(
            isPlayable: item.playableURI != nil,
            action: onSelect,
            accessibilityLabel: SpotiglassL10n.string("queue.playNow")
        ))
        .contextMenu {
            if item.playableURI != nil {
                Button(SpotiglassL10n.string("queue.playNow"), action: onSelect)
            }
            if let trackOpsMenuItems {
                Divider()
                trackOpsMenuItems()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(format: SpotiglassL10n.string("queue.item.accessibility"), item.name, item.subtitleInAppLanguage)
        )
        .accessibilityValue(item.durationLabel)
    }

    @ViewBuilder
    private var subtitleLine: some View {
        if item.artistTapTargets.isEmpty {
            Text(item.subtitleInAppLanguage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(item.artistTapTargets.enumerated()), id: \.element.stableID) { index, target in
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
                    .buttonStyle(.spotiglassTextLink)
                    .accessibilityLabel(
                        String(format: SpotiglassL10n.string("queue.openArtist"), target.name)
                    )
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
        }
    }

    /// Only the currently playing row paints a background. Every other row now
    /// takes its highlight from the list's own selection, which also means it
    /// de-emphasizes when the panel is not the focused control.
    private var rowBackground: Color {
        isCurrent ? Color.primary.opacity(TrackRowMetrics.currentTintOpacity) : Color.clear
    }
}

private struct QueueRowPlayInteractionModifier: ViewModifier {
    let isPlayable: Bool
    let action: () -> Void
    let accessibilityLabel: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPlayable {
            content
                .onTapGesture(count: 2, perform: action)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: Text(accessibilityLabel), action)
        } else {
            content
        }
    }
}
