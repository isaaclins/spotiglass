import SwiftUI

struct ImmersiveLyricsView: View {
    private enum FocusTarget: Hashable {
        case close
    }

    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    @ObservedObject var queueViewModel: QueueViewModel
    @ObservedObject var lyricsModel: ImmersiveLyricsViewModel
    let navigateToArtist: (ArtistTapTarget) -> Void
    let navigateToAlbum: (AlbumTapTarget, String, URL?) -> Void
    let onDismiss: () -> Void

    @EnvironmentObject private var settingsStore: SpotiglassSettingsStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedControl: FocusTarget?
    @AccessibilityFocusState private var accessibilityFocusedControl: FocusTarget?
    @Namespace private var focusNamespace

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
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Label(
                    SpotiglassL10n.string("browser.closeLyrics"),
                    systemImage: "xmark.circle"
                )
            }
            .buttonStyle(.borderless)
            .padding(.top, ImmersiveLyricsLayout.minimumTopClearance - 8)
            .padding(.trailing, SpotiglassDesign.spacingL)
            .focused($focusedControl, equals: .close)
            .accessibilityFocused($accessibilityFocusedControl, equals: .close)
            .accessibilityDefaultFocus($accessibilityFocusedControl, .close)
            .accessibilityHint(SpotiglassL10n.string("browser.closeLyrics.hint"))
            .accessibilitySortPriority(100)
        }
        .focusScope(focusNamespace)
        .defaultFocus($focusedControl, .close)
        // A modal trait tells VoiceOver that this surface owns navigation;
        // RootView separately hides the browser tree so the sidebar and
        // playback controls cannot remain in the accessibility hierarchy.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear {
            scheduleInitialFocus()
        }
        .task(id: currentTrack?.uri) {
            guard let track = currentTrack else {
                onDismiss()
                return
            }
            async let lyricsLoad: Void = lyricsModel.load(track: track)
            async let queuePrefetch: Void = queueViewModel.prefetchQueueForLyricsOverlay()
            await lyricsLoad
            await queuePrefetch
        }
        .onExitCommand(perform: onDismiss)
    }

    /// macOS can ignore a focus request made during the first appearance pass;
    /// the second main-queue pass makes opening lyrics deterministic without
    /// stealing focus again after the user starts navigating the overlay.
    private func scheduleInitialFocus() {
        DispatchQueue.main.async {
            focusedControl = .close
            accessibilityFocusedControl = .close
            DispatchQueue.main.async {
                focusedControl = .close
                accessibilityFocusedControl = .close
            }
        }
    }

    private var currentTrack: PlaybackNowPlaying? {
        playbackViewModel.currentLyricTrack
    }

    @ViewBuilder
    private var lyricsMainLayout: some View {
        if let anchor = playbackViewModel.progressAnchor, anchor.isAdvancing {
            TimelineView(.animation) { context in
                immersiveMainLayout(
                    positionMs: LrcLineParser.effectivePositionMs(
                        positionMs: anchor.interpolatedPositionMs(at: context.date),
                        offsetMs: lyricsOffsetMs
                    )
                )
            }
        } else {
            immersiveMainLayout(
                positionMs: LrcLineParser.effectivePositionMs(positionMs: staticPositionMs, offsetMs: lyricsOffsetMs)
            )
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
            positionMs: positionMs,
            reduceMotion: reduceMotion,
            usesLyricsScrollEdgeFade: usesLyricsScrollEdgeFade,
            lyricsTextSize: lyricsTextSize
        )
    }

    /// Frozen position when paused or between anchors; playback uses `progressAnchor` + `TimelineView` instead.
    private var staticPositionMs: Int {
        if let anchor = playbackViewModel.progressAnchor {
            return anchor.positionMilliseconds
        }
        switch playbackViewModel.connectionState {
        case let .playing(np):
            return np.positionMilliseconds
        case let .paused(opt):
            return opt?.positionMilliseconds ?? 0
        default:
            return 0
        }
    }
}
