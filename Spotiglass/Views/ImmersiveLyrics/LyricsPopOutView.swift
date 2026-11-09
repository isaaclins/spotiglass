import SwiftUI

/// The lyric position for "now", shared by the lyrics view and the pop-out: it follows the
/// player's progress every frame while music plays and holds still while paused. Only this
/// content re-renders on a new position (#409).
struct LyricsPositionReader<Content: View>: View {
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    /// The user's lyric sync nudge, in milliseconds.
    let offsetMs: Int
    @ViewBuilder let content: (_ positionMs: Int) -> Content

    var body: some View {
        PlaybackProgressReader(progress: playbackViewModel.progress) { anchor in
            if let anchor, anchor.isAdvancing {
                TimelineView(.animation) { context in
                    content(
                        LrcLineParser.effectivePositionMs(
                            positionMs: anchor.interpolatedPositionMs(at: context.date),
                            offsetMs: offsetMs
                        )
                    )
                }
            } else {
                content(
                    LrcLineParser.effectivePositionMs(
                        positionMs: Self.staticPositionMs(
                            anchor: anchor,
                            connectionState: playbackViewModel.connectionState
                        ),
                        offsetMs: offsetMs
                    )
                )
            }
        }
    }

    /// Frozen position when paused or between anchors.
    static func staticPositionMs(
        anchor: PlaybackProgressAnchor?,
        connectionState: PlaybackConnectionState
    ) -> Int {
        if let anchor {
            return anchor.positionMilliseconds
        }
        switch connectionState {
        case let .playing(nowPlaying):
            return nowPlaying.positionMilliseconds
        case let .paused(nowPlaying):
            return nowPlaying?.positionMilliseconds ?? 0
        case .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            return 0
        }
    }
}

/// Content of the pop-out lyrics window (#439). It shows whatever the app is playing: the music
/// you hear, from the service on screen or the other one, through the same app-scoped players the
/// main window's player bar uses, so it never starts or owns a player of its own.
struct LyricsPopOutRoot: View {
    let playbackHosts: SpotiglassPlaybackHosts
    @ObservedObject var serviceStore: MusicServiceStore
    /// Space, Next and Previous as bound in Settings › Keyboard.
    let keymapStore: CommandPaletteKeymapStore

    var body: some View {
        Group {
            if let service = serviceStore.active {
                LyricsPopOutPlayerResolver(onScreenPlayer: player(for: service), keymapStore: keymapStore)
            } else {
                LyricsPopOutView(player: nil, keymapStore: keymapStore)
            }
        }
        // If every main window is closed, the Spotify player's page moves in here instead of
        // being torn down, so the music keeps playing. With a main window open this stays empty.
        .background {
            SpotiglassPlaybackHostView(host: playbackHosts.spotify)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)
        }
    }

    private func player(for service: MusicService) -> PlaybackSessionViewModel {
        switch service {
        case .spotify: playbackHosts.spotify.playbackViewModel
        // Apple Music is on screen, so its player already exists (the main window made it).
        case .appleMusic: playbackHosts.appleMusic.playbackViewModel
        }
    }
}

/// Follows the music you hear (``PlaybackSessionViewModel/audiblePlayer``): the on-screen player,
/// or the other service's while that one plays and this one doesn't (#396).
private struct LyricsPopOutPlayerResolver: View {
    @ObservedObject var onScreenPlayer: PlaybackSessionViewModel
    let keymapStore: CommandPaletteKeymapStore

    var body: some View {
        let player = onScreenPlayer.audiblePlayer
        LyricsPopOutView(player: player, keymapStore: keymapStore)
            .id(ObjectIdentifier(player))
    }
}

struct LyricsPopOutView: View {
    let player: PlaybackSessionViewModel?
    let keymapStore: CommandPaletteKeymapStore

    var body: some View {
        if let player {
            LyricsPopOutPlayerView(playbackViewModel: player)
                .background {
                    LyricsPopOutKeyMonitor(keymapStore: keymapStore, player: player)
                        .frame(width: 0, height: 0)
                }
        } else {
            LyricsPopOutChrome(track: nil) { _ in
                LyricsPopOutEmptyState()
            }
        }
    }
}

private struct LyricsPopOutPlayerView: View {
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    /// Its own phase, but the fetched lyrics are shared: the lyrics cache and in-flight requests
    /// are app-wide, so the main lyrics view and this window never fetch the same song twice.
    @StateObject private var lyricsModel = ImmersiveLyricsViewModel()
    @EnvironmentObject private var settingsStore: SpotiglassSettingsStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var track: PlaybackNowPlaying? {
        playbackViewModel.currentLyricTrack
    }

    var body: some View {
        LyricsPopOutChrome(track: track, controls: AnyView(controls)) { layout in
            if track == nil {
                LyricsPopOutEmptyState()
            } else if layout == .full {
                fullLyrics
            } else {
                EmptyView()
            }
        } stripLine: {
            if let track {
                LyricsPositionReader(
                    playbackViewModel: playbackViewModel,
                    offsetMs: settingsStore.settings.appearance.lyricsOffsetMilliseconds
                ) { positionMs in
                    LyricsPopOutStripLine(
                        phase: lyricsModel.phase,
                        track: track,
                        positionMs: positionMs
                    )
                }
            }
        }
        .task(id: track?.uri) {
            guard let track else { return }
            await lyricsModel.load(track: track)
        }
    }

    private var fullLyrics: some View {
        GeometryReader { geo in
            LyricsPositionReader(
                playbackViewModel: playbackViewModel,
                offsetMs: settingsStore.settings.appearance.lyricsOffsetMilliseconds
            ) { positionMs in
                ImmersiveLyricsLyricsPhaseColumn(
                    lyricsModel: lyricsModel,
                    currentTrack: track,
                    positionMs: positionMs,
                    reduceMotion: reduceMotion,
                    usesLyricsScrollEdgeFade: !reduceTransparency && !reduceMotion,
                    lyricsTextSize: settingsStore.settings.appearance.lyricsTextMetrics,
                    maxHeight: geo.size.height,
                    onSeek: { ms in
                        Task { await playbackViewModel.seek(to: ms) }
                    }
                )
            }
        }
        // The lyrics scroll draws past its frame (for the active line's glow); in this small
        // window that put scrolled-away lines under the title row.
        .clipped()
    }

    private var controls: some View {
        LyricsPopOutTransportControls(playbackViewModel: playbackViewModel)
    }
}

/// Background, header and pin, shared by every state of the window.
private struct LyricsPopOutChrome<Body: View, StripLine: View>: View {
    let track: PlaybackNowPlaying?
    let controls: AnyView?
    let content: (LyricsPopOutLayout) -> Body
    let stripLine: () -> StripLine

    init(
        track: PlaybackNowPlaying?,
        controls: AnyView?,
        @ViewBuilder content: @escaping (LyricsPopOutLayout) -> Body,
        @ViewBuilder stripLine: @escaping () -> StripLine
    ) {
        self.track = track
        self.controls = controls
        self.content = content
        self.stripLine = stripLine
    }

    @AppStorage(LyricsPopOutWindow.pinnedStorageKey) private var isPinned = LyricsPopOutWindow.isPinnedByDefault
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geo in
            let layout = LyricsPopOutLayout.layout(for: geo.size)
            let showsSkip = LyricsPopOutLayout.showsSkipButtons(width: geo.size.width)
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
                header(layout: layout)
                    .environment(\.lyricsPopOutShowsSkipButtons, showsSkip)
                if layout == .full {
                    content(layout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            // The strip's one row sits in the middle of the room under the window buttons.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: layout == .full ? .topLeading : .leading)
            .padding(.top, Self.titleBarClearance)
            .padding(.horizontal, SpotiglassDesign.spacingM)
            .padding(.bottom, layout == .full ? 0 : SpotiglassDesign.spacingS)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background {
            ImmersiveLyricsBackgroundLayer(
                reduceTransparency: reduceTransparency,
                albumArtURL: track?.albumArtURL
            )
            .ignoresSafeArea()
        }
        // The lyrics surface is always light text on the dimmed artwork, in light and dark mode
        // alike, so its controls render for a dark background.
        .environment(\.colorScheme, .dark)
        // The minimum is the whole window, title bar included: applied inside the safe area, the
        // hidden title bar's height was added on top and the strip couldn't get below 116 pt.
        .frame(
            minWidth: LyricsPopOutWindow.minimumSize.width,
            minHeight: LyricsPopOutWindow.minimumSize.height
        )
        .ignoresSafeArea()
        .background {
            LyricsPopOutWindowConfigurator(isPinned: isPinned)
                .frame(width: 0, height: 0)
        }
    }

    /// The hidden title bar still holds the window buttons: content starts below them.
    static var titleBarClearance: CGFloat { SpotiglassDesign.Layout.lyricsPopOutTitleBarClearance }

    private func header(layout: LyricsPopOutLayout) -> some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            ArtworkView(
                url: track?.albumArtURL,
                size: layout == .full
                    ? SpotiglassDesign.Layout.nowPlayingArtworkSize
                    : SpotiglassDesign.Layout.compactRowArtworkSize
            )
            .accessibilityHidden(true)

            Group {
                if layout == .strip, track != nil {
                    stripLine()
                } else {
                    LyricsPopOutTitleBlock(
                        title: track?.name ?? SpotiglassL10n.string("lyrics.popOut.nothingPlaying"),
                        subtitle: track?.artistText
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let controls {
                controls
            }

            pinButton
        }
    }

    private var pinButton: some View {
        Button {
            isPinned.toggle()
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.body.weight(.medium))
                .foregroundStyle(
                    isPinned ? AnyShapeStyle(SpotiglassAccentStyle()) : AnyShapeStyle(.white.opacity(0.6))
                )
                .frame(
                    width: SpotiglassDesign.Layout.iconButtonSize,
                    height: SpotiglassDesign.Layout.iconButtonSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
            isPinned
                ? SpotiglassL10n.string("lyrics.popOut.unpin.help")
                : SpotiglassL10n.string("lyrics.popOut.pin.help")
        )
        .accessibilityLabel(SpotiglassL10n.string("lyrics.popOut.pin"))
        .accessibilityAddTraits(isPinned ? [.isToggle, .isSelected] : .isToggle)
    }
}

extension LyricsPopOutChrome where StripLine == EmptyView {
    init(
        track: PlaybackNowPlaying?,
        @ViewBuilder content: @escaping (LyricsPopOutLayout) -> Body
    ) {
        self.init(track: track, controls: nil, content: content, stripLine: { EmptyView() })
    }
}

private struct LyricsPopOutShowsSkipButtonsKey: EnvironmentKey {
    static let defaultValue = true
}

private extension EnvironmentValues {
    var lyricsPopOutShowsSkipButtons: Bool {
        get { self[LyricsPopOutShowsSkipButtonsKey.self] }
        set { self[LyricsPopOutShowsSkipButtonsKey.self] = newValue }
    }
}

/// Previous, Play/Pause and Next, enabled by the same rules as the player bar's.
private struct LyricsPopOutTransportControls: View {
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    @Environment(\.lyricsPopOutShowsSkipButtons) private var showsSkipButtons

    private func canRun(_ commandID: String) -> Bool {
        LyricsPopOutTransport.canRun(commandID, on: playbackViewModel)
    }

    private func run(_ commandID: String) {
        LyricsPopOutTransport.run(commandID, on: playbackViewModel)
    }

    private var isPlaying: Bool {
        if case .playing = playbackViewModel.connectionState { return true }
        return false
    }

    private var service: MusicService {
        playbackViewModel.service
    }

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingHalf) {
            if showsSkipButtons {
                PlaybackTransportButton(
                    accessibilityLabel: SpotiglassL10n.string("playback.controls.previous"),
                    accessibilityHint: PlaybackControlsView.serviceString(
                        "playback.controls.previous.hint",
                        appleMusic: "playback.controls.previous.appleMusic.hint",
                        service: service
                    ),
                    isEnabled: canRun(CommandPaletteCommandID.previousTrack),
                    action: { run(CommandPaletteCommandID.previousTrack) }
                ) {
                    Image(systemName: "backward.fill")
                }
                .help(SpotiglassL10n.string("tooltip.playback.previous"))
            }

            PlaybackTransportButton(
                accessibilityLabel: playPauseLabel,
                accessibilityHint: PlaybackControlsView.serviceString(
                    "playback.controls.playPause.hint",
                    appleMusic: "playback.controls.playPause.appleMusic.hint",
                    service: service
                ),
                isEnabled: canRun(CommandPaletteCommandID.togglePlayback),
                action: { run(CommandPaletteCommandID.togglePlayback) }
            ) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .opacity(playbackViewModel.isPlaybackToggleReady ? 1 : 0.45)
            }
            .help(playPauseLabel)

            if showsSkipButtons {
                PlaybackTransportButton(
                    accessibilityLabel: SpotiglassL10n.string("playback.controls.next"),
                    accessibilityHint: PlaybackControlsView.serviceString(
                        "playback.controls.next.hint",
                        appleMusic: "playback.controls.next.appleMusic.hint",
                        service: service
                    ),
                    isEnabled: canRun(CommandPaletteCommandID.nextTrack),
                    action: { run(CommandPaletteCommandID.nextTrack) }
                ) {
                    Image(systemName: "forward.fill")
                }
                .help(SpotiglassL10n.string("tooltip.playback.next"))
            }
        }
        .foregroundStyle(.white)
    }

    private var playPauseLabel: String {
        isPlaying ? SpotiglassL10n.string("playback.pause") : SpotiglassL10n.string("playback.play")
    }
}

/// Title over artist: the header of the full window, and the strip while no line is being sung.
private struct LyricsPopOutTitleBlock: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingHalf) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
        }
    }
}

/// The strip's text: the line being sung over "title · artist", or, with no line to show, the
/// usual title over artist (never the title twice).
private struct LyricsPopOutStripLine: View {
    let phase: ImmersiveLyricsViewModel.Phase
    let track: PlaybackNowPlaying
    let positionMs: Int

    var body: some View {
        let lyric = LyricsPopOutStripText.lyric(
            phase: phase,
            trackDurationMs: track.durationMilliseconds,
            positionMs: positionMs
        )
        LyricsPopOutTitleBlock(
            title: lyric ?? track.name,
            subtitle: lyric == nil ? track.artistText : "\(track.name) · \(track.artistText)"
        )
        .contentTransition(.opacity)
        .animation(.smooth(duration: 0.25), value: lyric)
    }
}

/// What the strip says, kept apart from the view so it can be tested. It runs on every frame while
/// music plays, so it finds the one line it needs instead of laying out the whole song.
enum LyricsPopOutStripText {
    /// The line to show for this moment, or nil when there is none (loading, no lyrics, an intro).
    static func lyric(
        phase: ImmersiveLyricsViewModel.Phase,
        trackDurationMs: Int?,
        positionMs: Int
    ) -> String? {
        guard case let .ready(lyrics) = phase else { return nil }
        let line: String
        switch lyrics {
        case .instrumental:
            return SpotiglassL10n.string("lyrics.instrumental")
        case let .synced(lines):
            // Before the first line is sung (an intro), the title shows, not a line still to come.
            guard let first = lines.first, positionMs >= first.startTimeMs else { return nil }
            line = lines[LrcLineParser.activeTimedLineIndex(positionMs: positionMs, lines: lines)].words
        case let .unsyncedPlain(lines):
            guard !lines.isEmpty else { return nil }
            line = lines[
                LrcLineParser.activePlainLineIndex(
                    positionMs: positionMs,
                    durationMs: trackDurationMs ?? 1,
                    lineCount: lines.count
                )
            ]
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct LyricsPopOutEmptyState: View {
    var body: some View {
        Text(SpotiglassL10n.string("lyrics.popOut.nothingPlaying.message"))
            .font(.body)
            .foregroundStyle(.white.opacity(0.72))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .padding(.bottom, SpotiglassDesign.spacingL)
    }
}
