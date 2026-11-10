import SwiftUI

struct ImmersiveLyricsView: View {
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    @ObservedObject var queueViewModel: QueueViewModel
    @ObservedObject var lyricsModel: ImmersiveLyricsViewModel
    let navigateToArtist: (ArtistTapTarget) -> Void
    let navigateToAlbum: (AlbumTapTarget, String, URL?) -> Void
    let onDismiss: () -> Void
    /// The bar shows the other service's song (#486): its queue, artists and album are not in
    /// the library on screen, so the lyrics show the song without them.
    var followsOtherService = false

    @EnvironmentObject private var settingsStore: SpotiglassSettingsStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isLyricsListFocused: Bool
    /// Focus goes to each lyrics list once; a later song must not take it back from wherever
    /// the user moved it (``LyricsKeyboardFocusProbe``).
    @State private var hasPlacedInitialFocus = false
    @Environment(\.lyricsKeyboardFocus) private var keyboardFocus

    /// Soft fade at scroll top/bottom; off when legibility or calm motion is preferred.
    private var usesLyricsScrollEdgeFade: Bool {
        !reduceTransparency && !reduceMotion
    }

    private var lyricsTextSize: LyricsTextMetrics {
        settingsStore.settings.appearance.lyricsTextMetrics
    }

    /// User's manual lyric sync nudge, in milliseconds.
    private var lyricsOffsetMs: Int {
        settingsStore.settings.appearance.lyricsOffsetMilliseconds
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
                .ignoresSafeArea()

            ImmersiveLyricsBackgroundLayer(
                reduceTransparency: reduceTransparency,
                albumArtURL: currentTrack?.albumArtURL
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                lyricsMainLayout
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The lyrics fill the main column only: the sidebar, the toolbar (with Close lyrics) and
        // the player bar stay usable next to them, so this is not a modal surface (#438).
        .accessibilityElement(children: .contain)
        .environment(\.lyricsListFocus, $isLyricsListFocused)
        .onAppear { placeInitialFocusIfReady() }
        .onChange(of: lyricsModel.phase) { _, phase in
            // A new song loads its lyrics in place of the list, which takes the keyboard with
            // it; the next list gets it back unless the user moved it elsewhere meanwhile.
            if !Self.showsLyricsList(phase) { hasPlacedInitialFocus = false }
            placeInitialFocusIfReady()
        }
        .task(id: isAwaitingSong ? Self.awaitingSongTaskID : currentTrack?.uri) {
            guard let track = currentTrack else {
                // Starting music on the on-screen service makes it the one you hear before its
                // song arrives (#486): the lyrics wait for that song instead of closing. A play
                // that fails or times out ends the wait, and the lyrics close.
                if isAwaitingSong {
                    lyricsModel.waitForTrack()
                } else {
                    onDismiss()
                }
                return
            }
            guard !followsOtherService else {
                await lyricsModel.load(track: track)
                return
            }
            async let lyricsLoad: Void = lyricsModel.load(track: track)
            async let queuePrefetch: Void = queueViewModel.prefetchQueueForLyricsOverlay()
            await lyricsLoad
            await queuePrefetch
        }
        .onExitCommand(perform: onDismiss)
    }

    /// The lyrics list exists only once lyrics are ready (not while loading or for an
    /// instrumental), so focus is placed when it first appears. A request made while the
    /// lyrics are still being laid out is dropped, so it is repeated for a moment until the
    /// list has the keyboard, unless the user has moved it somewhere else meanwhile.
    private func placeInitialFocusIfReady() {
        guard !hasPlacedInitialFocus, Self.showsLyricsList(lyricsModel.phase) else { return }
        hasPlacedInitialFocus = true
        let probe = keyboardFocus
        Task { @MainActor in
            await Self.requestListFocus(
                isFocused: { isLyricsListFocused },
                // The lyrics can take seconds to load; by then you may be typing in the
                // sidebar or the queue, and the keyboard stays there.
                movedAway: { probe?.userMovedFocusAway == true },
                focus: { isLyricsListFocused = true }
            )
        }
    }

    /// A focus request made while the list is still being laid out is dropped, so it is
    /// repeated for a moment until the list has the keyboard or the user put it elsewhere.
    static func requestListFocus(
        isFocused: () -> Bool,
        movedAway: () -> Bool,
        focus: () -> Void
    ) async {
        for delay in [0, 150, 400, 800] {
            try? await Task.sleep(for: .milliseconds(delay))
            if isFocused() || movedAway() { return }
            focus()
        }
    }

    static func showsLyricsList(_ phase: ImmersiveLyricsViewModel.Phase) -> Bool {
        guard case let .ready(lyrics) = phase else { return false }
        if case .instrumental = lyrics { return false }
        return true
    }

    private var currentTrack: PlaybackNowPlaying? {
        playbackViewModel.currentLyricTrack
    }

    /// A play started on this player is on its way and nothing is loaded yet.
    private var isAwaitingSong: Bool {
        playbackViewModel.connectionState.currentTrack == nil
            && playbackViewModel.pendingPlayTransition != nil
    }

    /// Not a song URI: the lyrics task runs again when the wait for a song starts or ends.
    private static let awaitingSongTaskID = "awaiting-song"

    /// Follows each new position from the player; the session publishes only track and state
    /// changes (#409).
    private var lyricsMainLayout: some View {
        LyricsPositionReader(playbackViewModel: playbackViewModel, offsetMs: lyricsOffsetMs) { positionMs in
            immersiveMainLayout(positionMs: positionMs)
        }
    }

    private func immersiveMainLayout(positionMs: Int) -> some View {
        ImmersiveLyricsMainLayout(
            playbackViewModel: playbackViewModel,
            queueViewModel: queueViewModel,
            lyricsModel: lyricsModel,
            navigateToArtist: navigateToArtist,
            navigateToAlbum: navigateToAlbum,
            currentTrack: currentTrack,
            followsOtherService: followsOtherService,
            positionMs: positionMs,
            reduceMotion: reduceMotion,
            usesLyricsScrollEdgeFade: usesLyricsScrollEdgeFade,
            lyricsTextSize: lyricsTextSize
        )
    }
}
