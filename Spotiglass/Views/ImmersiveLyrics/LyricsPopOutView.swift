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
    /// Where the window's lyrics come from: LRCLIB through the app-wide cache, or a stand-in in tests.
    var makeLyricsModel: @MainActor () -> ImmersiveLyricsViewModel = { ImmersiveLyricsViewModel() }
    /// Counts Apple Music's player coming into being, so the window looks again once a main
    /// window has made it.
    @State private var appleMusicCreations = 0

    var body: some View {
        let _ = appleMusicCreations
        Group {
            if let service = serviceStore.active, let onScreenPlayer = player(for: service) {
                LyricsPopOutPlayerResolver(
                    onScreenPlayer: onScreenPlayer,
                    keymapStore: keymapStore,
                    makeLyricsModel: makeLyricsModel
                )
            } else {
                LyricsPopOutView(player: nil, keymapStore: keymapStore, makeLyricsModel: makeLyricsModel)
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
        .onReceive(playbackHosts.appleMusicCreated) { appleMusicCreations += 1 }
    }

    private func player(for service: MusicService) -> PlaybackSessionViewModel? {
        switch service {
        case .spotify: playbackHosts.spotify.playbackViewModel
        // Only a player a main window made: this window never creates (or connects) one, so with
        // none made yet there is nothing to follow.
        case .appleMusic: playbackHosts.appleMusicIfCreated?.playbackViewModel
        }
    }
}

/// Follows the music you hear (``PlaybackSessionViewModel/audiblePlayer``): the on-screen player,
/// or the other service's while that one plays and this one doesn't (#396).
private struct LyricsPopOutPlayerResolver: View {
    @ObservedObject var onScreenPlayer: PlaybackSessionViewModel
    let keymapStore: CommandPaletteKeymapStore
    let makeLyricsModel: @MainActor () -> ImmersiveLyricsViewModel

    var body: some View {
        let player = onScreenPlayer.audiblePlayer
        LyricsPopOutView(player: player, keymapStore: keymapStore, makeLyricsModel: makeLyricsModel)
            .id(ObjectIdentifier(player))
    }
}

struct LyricsPopOutView: View {
    let player: PlaybackSessionViewModel?
    let keymapStore: CommandPaletteKeymapStore
    var makeLyricsModel: @MainActor () -> ImmersiveLyricsViewModel = { ImmersiveLyricsViewModel() }

    var body: some View {
        if let player {
            LyricsPopOutPlayerView(playbackViewModel: player, lyricsModel: makeLyricsModel())
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
    @StateObject private var lyricsModel: ImmersiveLyricsViewModel
    @EnvironmentObject private var settingsStore: SpotiglassSettingsStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(playbackViewModel: PlaybackSessionViewModel, lyricsModel: @autoclosure @escaping () -> ImmersiveLyricsViewModel) {
        self.playbackViewModel = playbackViewModel
        // Made once for the life of this view, like any `@StateObject`.
        _lyricsModel = StateObject(wrappedValue: lyricsModel())
    }

    private var content: LyricsPopOutContent {
        .of(
            playbackViewModel.connectionState,
            playerPushesState: playbackViewModel.playerPushesState,
            service: playbackViewModel.service
        )
    }

    /// What plays, shown in the header whether or not it has lyrics.
    private var track: PlaybackNowPlaying? {
        content.track
    }

    /// What plays when it can have lyrics: a song, not a podcast episode or a local file.
    private var lyricTrack: PlaybackNowPlaying? {
        if case let .lyrics(track) = content { track } else { nil }
    }

    var body: some View {
        LyricsPopOutChrome(
            track: track,
            status: content.status,
            notice: playbackViewModel.refusedPlayPause,
            controls: AnyView(controls)
        ) { layout in
            switch content {
            case .nothingPlaying:
                LyricsPopOutEmptyState()
            case let .status(_, _, invitesPlay):
                // The header says what's going on, as the player bar does; the hint to play
                // something only fits when nothing is loaded.
                if invitesPlay {
                    LyricsPopOutEmptyState()
                }
            case .noLyrics:
                if layout == .full {
                    LyricsPopOutEmptyState(message: SpotiglassL10n.string("lyrics.error.noLyrics"))
                }
            case .lyrics:
                if layout == .full {
                    fullLyrics
                }
            }
        } stripLine: {
            if let track {
                LyricsPositionReader(
                    playbackViewModel: playbackViewModel,
                    offsetMs: settingsStore.settings.appearance.lyricsOffsetMilliseconds
                ) { positionMs in
                    LyricsPopOutStripLine(
                        // Without lyrics there's no line to show, whatever the last song left.
                        phase: lyricTrack == nil ? .idle : lyricsModel.phase,
                        track: track,
                        notice: playbackViewModel.refusedPlayPause,
                        positionMs: positionMs
                    )
                }
            }
        }
        .task(id: lyricTrack?.uri) {
            guard let lyricTrack else { return }
            await lyricsModel.load(track: lyricTrack)
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
                    currentTrack: lyricTrack,
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
    /// The player bar's two lines while no song is there to name them (connecting, an error).
    let status: (title: String, subtitle: String)?
    /// A refused play / pause (#437): its title replaces the artist line for a moment, as on the
    /// player bar, with the reason on hover.
    let notice: PlaybackDisplayError?
    let controls: AnyView?
    let content: (LyricsPopOutLayout) -> Body
    let stripLine: () -> StripLine

    init(
        track: PlaybackNowPlaying?,
        status: (title: String, subtitle: String)?,
        notice: PlaybackDisplayError?,
        controls: AnyView?,
        @ViewBuilder content: @escaping (LyricsPopOutLayout) -> Body,
        @ViewBuilder stripLine: @escaping () -> StripLine
    ) {
        self.track = track
        self.status = status
        self.notice = notice
        self.controls = controls
        self.content = content
        self.stripLine = stripLine
    }

    /// Not `@AppStorage`, which re-ran this view on every write to the defaults, a resize of any
    /// window included (#473).
    @ObservedObject private var pin = StoredFlag.lyricsPopOutPinned
    private var isPinned: Bool {
        get { pin.isOn }
        nonmutating set { pin.isOn = newValue }
    }
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
        .ignoresSafeArea()
        // SwiftUI adds the hidden title bar's height to the content's minimum, so the content asks
        // for the window's minimum less that bar; otherwise the strip couldn't get below 116 pt.
        .frame(
            minWidth: LyricsPopOutWindow.minimumSize.width,
            minHeight: LyricsPopOutWindow.minimumSize.height - Self.titleBarClearance
        )
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
                        title: track?.name ?? status?.title ?? SpotiglassL10n.string("lyrics.popOut.nothingPlaying"),
                        subtitle: notice?.title ?? track?.artistText ?? status?.subtitle
                    )
                    .help(notice?.message ?? "")
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
        self.init(track: track, status: nil, notice: nil, controls: nil, content: content, stripLine: { EmptyView() })
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
    let notice: PlaybackDisplayError?
    let positionMs: Int

    var body: some View {
        let lyric = LyricsPopOutStripText.lyric(
            phase: phase,
            trackDurationMs: track.durationMilliseconds,
            positionMs: positionMs
        )
        LyricsPopOutTitleBlock(
            title: lyric ?? track.name,
            subtitle: LyricsPopOutStripText.subtitle(track: track, lyric: lyric, notice: notice)
        )
        .help(notice?.message ?? "")
        .contentTransition(.opacity)
        .animation(.smooth(duration: 0.25), value: lyric)
    }
}

/// What the strip says, kept apart from the view so it can be tested. It runs on every frame while
/// music plays, so it finds the one line it needs instead of laying out the whole song.
enum LyricsPopOutStripText {
    /// Under the line: title · artist under a lyric, the artist under the title, and a refused
    /// play / pause's title in place of either for a moment (#437).
    static func subtitle(track: PlaybackNowPlaying, lyric: String?, notice: PlaybackDisplayError?) -> String {
        if let notice { return notice.title }
        return lyric == nil ? track.artistText : "\(track.name) · \(track.artistText)"
    }

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
    var message = SpotiglassL10n.string("lyrics.popOut.nothingPlaying.message")

    var body: some View {
        Text(message)
            .font(.body)
            .foregroundStyle(.white.opacity(0.72))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .padding(.bottom, SpotiglassDesign.spacingL)
    }
}

/// What the window has to show for the player's state.
enum LyricsPopOutContent: Equatable {
    /// No player to follow: no service is signed in.
    case nothingPlaying
    /// No song to name: connecting, nothing loaded, an error. The player bar's two lines; the hint
    /// to play something only when nothing is loaded.
    case status(title: String, subtitle: String, invitesPlay: Bool)
    /// Something plays that has no lyrics to look up: a podcast episode, a local file.
    case noLyrics(PlaybackNowPlaying)
    case lyrics(PlaybackNowPlaying)

    static func of(
        _ state: PlaybackConnectionState,
        playerPushesState: Bool = true,
        service: MusicService = .spotify
    ) -> Self {
        if let track = state.currentLyricTrack { return .lyrics(track) }
        if let track = state.currentTrack { return .noLyrics(track) }
        guard let lines = PlaybackControlsView.statusLines(for: state, playerPushesState: playerPushesState, service: service) else {
            return .nothingPlaying
        }
        let invitesPlay: Bool = switch state {
        case .ready, .paused: true
        case .disconnected, .connecting, .transferring, .playing, .unavailable, .error: false
        }
        return .status(title: lines.title, subtitle: lines.subtitle, invitesPlay: invitesPlay)
    }

    var track: PlaybackNowPlaying? {
        switch self {
        case .nothingPlaying, .status: nil
        case let .noLyrics(track), let .lyrics(track): track
        }
    }

    var status: (title: String, subtitle: String)? {
        if case let .status(title, subtitle, _) = self { (title, subtitle) } else { nil }
    }
}
