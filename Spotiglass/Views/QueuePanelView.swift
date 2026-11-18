import AppKit
import SwiftUI

struct QueuePanelView: View {
    @ObservedObject var queueViewModel: QueueViewModel
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    let openArtist: (ArtistTapTarget) -> Void
    /// Builds the shared track-operations menu for the rows a right-click acts on: the
    /// selection when the clicked row is in it, else the clicked row. The browser owns the
    /// mutation model, while the queue keeps its row design and selection logic independent of it.
    let trackOpsMenuItems: (([QueueItem]) -> AnyView)?

    /// Drives the list's own selection, which is what makes the rows reachable
    /// with the arrow keys and gives them a de-emphasized highlight when the
    /// panel is not focused. Return plays the first selected row (#123); several rows can be
    /// selected like in every other track list (click, shift-click, command-click, command-A),
    /// and Delete takes them out of the queue (#628).
    @State private var selectedItemIDs: Set<QueueItem.ID> = []
    /// A click on a row selects it without focusing the list (the row's double-click gesture
    /// takes the mouse-down), which left the selection grey and the keys unheard (#628).
    @FocusState private var isListFocused: Bool
    @Environment(\.undoManager) private var undoManager

    init(
        queueViewModel: QueueViewModel,
        playbackViewModel: PlaybackSessionViewModel,
        openArtist: @escaping (ArtistTapTarget) -> Void,
        trackOpsMenuItems: (([QueueItem]) -> AnyView)? = nil
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
                // Floats over the top of the list, right under Clear: at the panel's bottom the
                // player bar floating over that edge covered it. Over the list, so nothing
                // moves when it comes and goes.
                .overlay(alignment: .top) {
                    if let removal = queueViewModel.lastRemoval {
                        QueueRemovalNotice(removal: removal) {
                            undo(removal)
                        } dismiss: {
                            queueViewModel.dismissRemovalNotice()
                        }
                        .padding(.horizontal, SpotiglassDesign.Layout.panelMargin)
                        .padding(.top, SpotiglassDesign.spacingXS)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: queueViewModel.lastError?.id)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: queueViewModel.lastRemoval?.id)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            headerRow
            // The panel's whole width, on one line, so its height stays the same while the
            // status changes on every new song.
            QueueAutoplayStatusLine(autoplay: queueViewModel.autoplay)
        }
        .padding(SpotiglassDesign.Layout.panelMargin)
    }

    private var headerRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
                Text(SpotiglassL10n.string("queue.title"))
                    .font(.title2.weight(.semibold))
                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if queueViewModel.canEditQueue {
                Button(SpotiglassL10n.string("queue.clear")) {
                    remove { await queueViewModel.clearUpcoming() }
                }
                .disabled(queueViewModel.upcomingItems.isEmpty)
                .help(SpotiglassL10n.string("queue.clear.help"))
            }
            QueueAutoplayButton(autoplay: queueViewModel.autoplay)
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
        List(selection: $selectedItemIDs) {
            nowPlayingSection
            upNextSection
        }
        .listStyle(.inset)
        .focused($isListFocused)
        .onChange(of: selectedItemIDs) {
            if !selectedItemIDs.isEmpty { isListFocused = true }
        }
        .onKeyPress(.return) {
            guard let item = selectedItemsInOrder.first, item.playableURI != nil else { return .ignored }
            Task { await queueViewModel.playItem(item) }
            return .handled
        }
        .onDeleteCommand {
            removeSelection(including: nil)
        }
        // Rows are known by their place in the queue, so once the queue changed (a song ended,
        // a removal) a kept selection would point at other songs. Polls that find the same
        // queue keep it.
        .onChange(of: queueViewModel.upcomingItems.map(\.uri)) {
            selectedItemIDs = []
        }
    }

    /// The selected rows in list order, the playing row first.
    private var selectedItemsInOrder: [QueueItem] {
        ([queueViewModel.nowPlayingItem].compactMap { $0 } + queueViewModel.upcomingItems)
            .filter { selectedItemIDs.contains($0.id) }
    }

    /// The rows a right-click on `item` acts on: the whole selection when the row is part of
    /// it, else the row alone, like a Finder or Music list.
    private func menuTargets(for item: QueueItem) -> [QueueItem] {
        selectedItemIDs.contains(item.id) && selectedItemIDs.count > 1 ? selectedItemsInOrder : [item]
    }

    /// The upcoming rows Remove takes out for a right-click on `item` (or the selection for
    /// the Delete key, `item` nil).
    private func removalIDs(for item: QueueItem?) -> Set<QueueItem.ID> {
        let targets = item.map(menuTargets(for:)) ?? selectedItemsInOrder
        let upcoming = Set(queueViewModel.upcomingItems.map(\.id))
        return Set(targets.map(\.id)).intersection(upcoming)
    }

    private func removeSelection(including item: QueueItem?) {
        let ids = removalIDs(for: item)
        guard queueViewModel.canEditQueue, !ids.isEmpty else { return }
        selectedItemIDs.subtract(ids)
        remove { await queueViewModel.removeItems(withIDs: ids) }
    }

    /// Runs a removal and offers its Undo in the Edit menu (⌘Z) too. The undo is registered
    /// right away, inside the click or key press, on the undo manager of the window the Edit
    /// menu asks: registered after the player answered, it missed that event and ⌘Z found
    /// nothing to undo.
    private func remove(_ removal: @escaping () async -> QueueRemovalReceipt?) {
        let manager = windowUndoManager
        let pending = PendingQueueRemoval()
        manager?.registerUndo(withTarget: queueViewModel) { queue in
            guard let receipt = pending.receipt else { return }
            Task { @MainActor in await queue.undoRemoval(receipt) }
        }
        manager?.setActionName(SpotiglassL10n.string("queue.remove.undoName"))
        Task {
            pending.receipt = await removal()
            if pending.receipt == nil { manager?.removeAllActions(withTarget: queueViewModel) }
        }
    }

    private var windowUndoManager: UndoManager? {
        NSApp.keyWindow?.firstResponder?.undoManager ?? NSApp.keyWindow?.undoManager ?? undoManager
    }

    private func undo(_ receipt: QueueRemovalReceipt) {
        // The button and ⌘Z undo the same removal; whichever comes first, the other has nothing left.
        windowUndoManager?.removeAllActions(withTarget: queueViewModel)
        Task { await queueViewModel.undoRemoval(receipt) }
    }

    /// Remove for the queue's own rows: the item when the service can, else a line saying it
    /// can't, so there's no Remove that does nothing (Spotify, #628).
    @ViewBuilder
    private func removeMenuItem(for item: QueueItem) -> some View {
        if queueViewModel.canEditQueue {
            let count = removalIDs(for: item).count
            Button(SpotiglassL10n.format("queue.remove.selection", Int64(count))) {
                removeSelection(including: item)
            }
            .keyboardShortcut(.delete, modifiers: [])
        } else {
            Text(SpotiglassL10n.format("queue.remove.unavailable", queueViewModel.provider.service.displayName))
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
                            { builder(menuTargets(for: item)) }
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
                        removeMenuItem: { AnyView(removeMenuItem(for: item)) },
                        trackOpsMenuItems: trackOpsMenuItems.map { builder in
                            { builder(menuTargets(for: item)) }
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

/// The ∞ button beside Shuffle, like Autoplay at the top of the Music app's Playing Next
/// (#613): accent coloured while on. Hidden where the service offers no suggestions.
struct QueueAutoplayButton: View {
    @ObservedObject var autoplay: QueueAutoplay

    var body: some View {
        if autoplay.isAvailable {
            Button {
                autoplay.setEnabled(!autoplay.isEnabled)
            } label: {
                Image(systemName: "infinity")
                    .foregroundStyle(
                        autoplay.isEnabled
                            ? AnyShapeStyle(SpotiglassAccentStyle())
                            : AnyShapeStyle(.primary)
                    )
            }
            .accessibilityLabel(SpotiglassL10n.string("queue.autoplay.label"))
            .accessibilityValue(SpotiglassL10n.string(autoplay.isEnabled ? "queue.autoplay.on" : "queue.autoplay.off"))
            .help(SpotiglassL10n.string(autoplay.isEnabled ? "queue.autoplay.help.on" : "queue.autoplay.help.off"))
        }
    }
}

/// One line under the queue's header while Autoplay is on, saying what it does right now.
/// Always one line: the status changes on every new song, and the list below mustn't move.
struct QueueAutoplayStatusLine: View {
    @ObservedObject var autoplay: QueueAutoplay

    var body: some View {
        if let key = Self.key(for: autoplay.status), autoplay.isEnabled {
            let text = SpotiglassL10n.string(key)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(text)
        }
    }

    static func key(for status: QueueAutoplay.Status) -> String? {
        switch status {
        case .off: nil
        case .on: "queue.autoplay.status.on"
        case .finding: "queue.autoplay.status.finding"
        case .noMatches: "queue.autoplay.status.noMatches"
        case .failed: "queue.autoplay.status.failed"
        }
    }
}

private struct QueueRowView: View {
    let item: QueueItem
    let isCurrent: Bool
    let isPlaying: Bool
    let onSelect: () -> Void
    let openArtist: (ArtistTapTarget) -> Void
    /// Remove from Queue for an upcoming row; `nil` for the playing one.
    var removeMenuItem: (() -> AnyView)? = nil
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
            if let removeMenuItem {
                Divider()
                removeMenuItem()
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
                        Text(target.nameInAppLanguage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.spotiglassTextLink)
                    .accessibilityLabel(
                        String(format: SpotiglassL10n.string("queue.openArtist"), target.nameInAppLanguage)
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

/// The receipt of a removal whose undo was registered before the player answered.
@MainActor
private final class PendingQueueRemoval {
    var receipt: QueueRemovalReceipt?
}

/// The bar that says what a removal took out of the queue, with its Undo (#628). It goes by
/// itself after a while; ⌘Z still undoes it then.
struct QueueRemovalNotice: View {
    let removal: QueueRemovalReceipt
    let undo: () -> Void
    let dismiss: () -> Void

    static let visibleDuration: Duration = .seconds(6)

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Text(SpotiglassL10n.format("queue.removed.count", Int64(removal.count)))
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: SpotiglassDesign.spacingS)
            Button(SpotiglassL10n.string("queue.undo"), action: undo)
                .buttonStyle(.borderless)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.spotiglassAccent)
                .help(SpotiglassL10n.string("queue.undo.help"))
        }
        .padding(.horizontal, SpotiglassDesign.spacingM)
        .padding(.vertical, SpotiglassDesign.spacingS)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .task(id: removal.id) {
            try? await Task.sleep(for: Self.visibleDuration)
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }
}
