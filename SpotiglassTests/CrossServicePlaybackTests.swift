import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Spotiglass

/// Playback across Spotify and Apple Music (#396), one rule: what you hear is what the bar and
/// Space control, and signing out of a service stops its player.
@MainActor
final class CrossServicePlaybackTests: XCTestCase {
    private static func song(_ name: String, uri: String, positionMilliseconds: Int = 0) -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: name, artists: [], albumName: nil, albumID: nil, albumArtURL: nil,
            durationMilliseconds: 240_000, positionMilliseconds: positionMilliseconds, uri: uri
        )
    }

    /// Spotify's player, connected and paused on Midnight City (the handover paused it).
    private func pausedSpotify() -> (SpotiglassPlaybackHost, MockWebPlaybackCommander) {
        _ = NSApplication.shared
        let commander = MockWebPlaybackCommander()
        let host = SpotiglassPlaybackHost(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: commander)
        )
        let playback = host.playbackViewModel
        playback.deviceID = "device-1"
        playback.hasTransferredPlaybackToCurrentDevice = true
        playback.setTransportStateKnown(true)
        playback.setConnectionState(.paused(Self.song("Midnight City", uri: "spotify:track:1", positionMilliseconds: 197_000)))
        return (host, commander)
    }

    private func toggles(_ commander: MockWebPlaybackCommander) -> Int {
        commander.commands.filter { $0.command == .togglePlay }.count
    }

    private func hosts(
        spotify: SpotiglassPlaybackHost,
        player: ScriptedAppleMusicPlayer
    ) -> SpotiglassPlaybackHosts {
        SpotiglassPlaybackHosts(spotify: spotify) {
            SpotiglassPlaybackHost(provider: AppleMusicPlaybackProvider(player: player))
        }
    }

    /// Apple Music's player, playing Piranguera for real (the scripted MusicKit player has it
    /// queued and playing).
    private func playingAppleMusic(in hosts: SpotiglassPlaybackHosts, player: ScriptedAppleMusicPlayer) async throws -> PlaybackSessionViewModel {
        let appleMusic = hosts.appleMusic.playbackViewModel
        appleMusic.handle(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))
        try await hosts.appleMusic.playbackProvider.play(
            .items(uris: ["applemusic:song:piranguera", "applemusic:song:next"], startURI: nil),
            deviceID: AppleMusicPlaybackProvider.deviceID
        )
        player.advance(by: 1)
        appleMusic.setConnectionState(.playing(Self.song("Piranguera", uri: "applemusic:song:piranguera", positionMilliseconds: 25_000)))
        return appleMusic
    }

    // MARK: - 1. Signing out of Apple Music stops its player

    /// The log of the report: after "Music services: added=[] active=none" the Apple Music
    /// player went on playing through its queue with nothing on screen to stop it, and adding
    /// Apple Music again showed the same song still playing. MusicKit keeps its queue after a
    /// stop (checked on a real library: re-adding showed the stopped song as paused), like the
    /// scripted player here.
    func testSigningOutOfAppleMusicStopsItsPlayerAndForgetsTheSong() async throws {
        let (spotify, _) = pausedSpotify()
        let player = ScriptedAppleMusicPlayer()
        let hosts = hosts(spotify: spotify, player: player)
        let services = CurrentValueSubject<[MusicService], Never>([.appleMusic, .spotify])
        hosts.follow(addedServices: services)
        let appleMusic = try await playingAppleMusic(in: hosts, player: player)
        let provider = hosts.appleMusic.playbackProvider

        services.send([.spotify])
        for _ in 0..<40 where !player.commands.contains("stop") {
            try await Task.sleep(for: .milliseconds(25))
        }
        player.advance(by: 1)

        XCTAssertEqual(appleMusic.connectionState, .disconnected)
        XCTAssertEqual(player.readState().status, .paused, "the music stops with the sign-out")
        let afterSignOut = try await provider.fetchPlaybackState()
        XCTAssertNil(afterSignOut, "adding Apple Music again starts with nothing loaded")
        let upcoming = try await provider.fetchQueue().queue
        XCTAssertTrue(upcoming.isEmpty)

        // Playing again after adding it back reports the new song as usual.
        try await provider.play(.items(uris: ["applemusic:song:new"], startURI: nil), deviceID: AppleMusicPlaybackProvider.deviceID)
        player.advance(by: 1)
        let afterPlay = try await provider.fetchPlaybackState()
        XCTAssertEqual(afterPlay?.isPlaying, true)
    }

    /// Spotify's sign-out already disconnects its own player; a switch or an addition stops
    /// nothing.
    func testOnlyRemovingAppleMusicStopsItsPlayer() async throws {
        let (spotify, _) = pausedSpotify()
        let player = ScriptedAppleMusicPlayer()
        let hosts = hosts(spotify: spotify, player: player)
        let services = CurrentValueSubject<[MusicService], Never>([.appleMusic])
        hosts.follow(addedServices: services)
        let appleMusic = try await playingAppleMusic(in: hosts, player: player)

        services.send([.appleMusic, .spotify])
        services.send([.appleMusic])
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(player.commands.contains("stop"))
        XCTAssertTrue(PlaylistBrowserPlaybackHelpers.isCurrentlyPlaying(connectionState: appleMusic.connectionState))
    }

    // MARK: - 2. The bar and Space follow the music you hear

    /// The report: Spotify's bar said "Midnight City · Paused" while Apple Music played, and
    /// Space resumed Midnight City and silently paused Apple Music.
    func testSpacePausesTheOtherServicesMusicInsteadOfResumingThisOne() async throws {
        let (spotify, commander) = pausedSpotify()
        let player = ScriptedAppleMusicPlayer()
        let hosts = hosts(spotify: spotify, player: player)
        hosts.gate(activeService: .appleMusic)
        let appleMusic = try await playingAppleMusic(in: hosts, player: player)
        hosts.gate(activeService: .spotify) // ⌃2

        let playback = spotify.playbackViewModel
        XCTAssertTrue(playback.isOtherServicePlaying)
        XCTAssertTrue(playback.audiblePlayer === appleMusic, "the bar shows what you hear")

        let manager = wirePalette(to: playback)
        XCTAssertTrue(manager.canTogglePlayback, "Playback › Play/Pause can pause what you hear")
        XCTAssertTrue(manager.playbackTogglePrerequisite?() ?? false)
        await manager.togglePlayback?()
        player.advance(by: 1)

        XCTAssertEqual(toggles(commander), 0, "Midnight City stays paused")
        XCTAssertTrue(player.commands.contains("pause"), "Space pauses Piranguera")
        XCTAssertEqual(player.readState().status, .paused)
        XCTAssertEqual(appleMusic.connectionState.nowPlayingName, "Piranguera")
        XCTAssertFalse(PlaylistBrowserPlaybackHelpers.isCurrentlyPlaying(connectionState: appleMusic.connectionState))
        XCTAssertFalse(playback.isOtherServicePlaying)
        XCTAssertTrue(playback.audiblePlayer === playback, "with nothing playing the bar is Spotify's again")
    }

    /// The mirror case: on Apple Music while Spotify plays, Apple Music's bar follows Spotify.
    func testAppleMusicsBarFollowsSpotifyWhileSpotifyPlays() async throws {
        let (spotify, _) = pausedSpotify()
        let hosts = hosts(spotify: spotify, player: ScriptedAppleMusicPlayer())
        let appleMusic = hosts.appleMusic.playbackViewModel
        appleMusic.handle(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))
        appleMusic.setConnectionState(.paused(Self.song("Piranguera", uri: "applemusic:song:piranguera")))

        spotify.playbackViewModel.setConnectionState(.playing(Self.song("Midnight City", uri: "spotify:track:1")))

        XCTAssertTrue(appleMusic.audiblePlayer === spotify.playbackViewModel)
        XCTAssertEqual(appleMusic.audiblePlayer.service, .spotify)
        XCTAssertTrue(spotify.playbackViewModel.audiblePlayer === spotify.playbackViewModel, "Spotify plays: its own bar")
    }

    /// Nothing changes for one service alone: the bar is always its own player.
    func testASingleServiceAlwaysControlsItsOwnPlayer() {
        let (spotify, _) = pausedSpotify()
        _ = hosts(spotify: spotify, player: ScriptedAppleMusicPlayer())
        XCTAssertNil(spotify.playbackViewModel.otherServicePlayer, "Apple Music's player was never created")
        XCTAssertTrue(spotify.playbackViewModel.audiblePlayer === spotify.playbackViewModel)
        XCTAssertEqual(spotify.playbackViewModel.service, .spotify)
    }

    private func wirePalette(to playback: PlaybackSessionViewModel) -> CommandPaletteManager {
        let manager = CommandPaletteManager()
        PlaylistBrowserCommandPaletteConfiguration.apply(
            to: manager,
            dependencies: .init(
                viewModel: PlaylistBrowserViewModel(
                    api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
                    cache: MockBrowsingCache()
                ),
                playbackViewModel: playback,
                queueViewModel: QueueViewModel(provider: playback.provider, playbackSession: playback),
                commandPaletteManager: manager,
                pinnedStore: PinnedItemsStore(cache: InMemoryPinnedItemsCache()),
                catalogProvider: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
                signOut: {},
                syncUnifiedRefreshRouting: {}
            ),
            queueVisible: .constant(false),
            lyricsPresented: .constant(false)
        )
        return manager
    }

    // MARK: - 3. "Ready to play" with nothing loaded

    /// The report: Play on "Ready to play" resumed an empty MusicKit queue and showed
    /// "Playback command failed". With nothing loaded there is nothing to resume, so Play is
    /// off until a track is chosen. Spotify's ready player keeps its Play.
    func testAppleMusicPlayIsOffWhileNothingIsLoaded() async throws {
        let player = ScriptedAppleMusicPlayer()
        let appleMusic = PlaybackSessionViewModel(provider: AppleMusicPlaybackProvider(player: player))
        appleMusic.handle(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))
        XCTAssertEqual(appleMusic.connectionState, .ready(deviceID: AppleMusicPlaybackProvider.deviceID))

        XCTAssertFalse(appleMusic.isPlaybackToggleReady)
        let manager = CommandPaletteManager()
        manager.bindPlaybackReadiness(to: appleMusic)
        XCTAssertFalse(manager.canTogglePlayback)

        appleMusic.setConnectionState(.paused(Self.song("Piranguera", uri: "applemusic:song:piranguera")))
        XCTAssertTrue(appleMusic.isPlaybackToggleReady, "a loaded song can be resumed")
        XCTAssertTrue(manager.canTogglePlayback)

        let (spotify, _) = pausedSpotify()
        spotify.playbackViewModel.setConnectionState(.ready(deviceID: "device-1"))
        XCTAssertTrue(spotify.playbackViewModel.isPlaybackToggleReady, "Spotify resumes the account's last item")
    }

    // MARK: - 4. Header Play and Shuffle mark the sidebar row

    /// The report: header Shuffle (or Play) on 18P1 started it but the sidebar row had no
    /// playing badge; double-clicking a row did.
    func testHeaderPlayAndShuffleMarkThePlaylistInTheSidebar() async {
        func connected() -> (PlaybackSessionViewModel, MockPlaybackAPI) {
            let playbackAPI = MockPlaybackAPI()
            let playback = PlaybackSessionViewModel(
                provider: SpotifyPlaybackProvider(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander()),
                postShuffleSyncDelay: .seconds(60)
            )
            playback.deviceID = "device-1"
            playback.hasTransferredPlaybackToCurrentDevice = true
            playback.setTransportStateKnown(true)
            return (playback, playbackAPI)
        }
        let playlist = PlaylistDetailViewModel(
            playlist: PlaylistRowViewModel(PlaylistBrowsingTestFixtures.playlist(id: "18P1", name: "18P1")),
            tracks: []
        )
        let target = DetailHeaderPlayback.target(for: playlist)

        let (shuffled, _) = connected()
        await DetailHeaderPlayback.shuffleAndPlay(target: target, using: shuffled)
        XCTAssertEqual(shuffled.activePlaylistID, "18P1", "Shuffle")

        let (played, playbackAPI) = connected()
        await DetailHeaderPlayback.play(target: target, using: played)
        XCTAssertEqual(played.activePlaylistID, "18P1", "Play")
        XCTAssertEqual(playbackAPI.actions.filter { $0.hasPrefix("play-context:") }, ["play-context:device-1:spotify:playlist:18P1"])

        // An artist's Play has no sidebar row.
        let (artist, _) = connected()
        await DetailHeaderPlayback.play(target: .context(uri: "spotify:artist:a1"), using: artist)
        XCTAssertNil(artist.activePlaylistID)
    }

    // MARK: - 5. A song started elsewhere is marked in the list

    private static func row(_ name: String, uri: String, artists: [String] = ["Rihanna"], durationMilliseconds: Int = 200_000) -> MusicTrack {
        MusicTrack(
            id: uri, name: name, artists: artists, albumArtworkURL: nil,
            durationMilliseconds: durationMilliseconds, isExplicit: false, isPlayable: true,
            linkedFromID: nil, uri: uri
        )
    }

    private static func album(_ tracks: [MusicTrack]) -> BrowsingDetailContent {
        .playlist(PlaylistDetailViewModel(
            playlist: PlaylistRowViewModel(
                albumDisplayName: "Good Girl Gone Bad: Reloaded", artistsDisplay: "Rihanna",
                totalTrackCount: tracks.count, artworkURL: nil, albumID: "1440857781"
            ),
            tracks: TrackRowViewModel.numberedTopTracks(tracks)
        ))
    }

    /// The report: "Breakin' Dishes" started from ⌘K played under its library id
    /// (`applemusic:song:i.B0VN4RQfxzX7aak`, from the log), while the album lists the same song
    /// under the id MusicKit gives it inside the album, so the row showed a plain "1".
    func testASongStartedFromSearchIsMarkedInItsAlbum() {
        let playing = PlaybackConnectionState.playing(PlaybackNowPlaying(
            name: "Breakin' Dishes", artists: ["Rihanna"], albumName: nil, albumID: nil, albumArtURL: nil,
            durationMilliseconds: 200_093, positionMilliseconds: 57_396, uri: "applemusic:song:i.B0VN4RQfxzX7aak"
        ))
        let album = Self.album([
            Self.row("Breakin' Dishes", uri: "applemusic:song:-6046431734389870155", durationMilliseconds: 200_000),
            Self.row("Shut Up and Drive", uri: "applemusic:song:-6046431734389870154"),
        ])

        XCTAssertEqual(
            PlaylistBrowserPlaybackHelpers.currentPlaybackURI(connectionState: playing, detailContent: album),
            "applemusic:song:-6046431734389870155"
        )
        // Same title by someone else, or another length (a remix, a live take): not this song.
        XCTAssertEqual(
            PlaylistBrowserPlaybackHelpers.currentPlaybackURI(
                connectionState: playing,
                detailContent: Self.album([
                    Self.row("Breakin' Dishes", uri: "applemusic:song:1", artists: ["Ely Oaks"]),
                    Self.row("Breakin' Dishes", uri: "applemusic:song:2", durationMilliseconds: 260_000),
                ])
            ),
            "applemusic:song:i.B0VN4RQfxzX7aak"
        )
    }

    /// A row with the playing URI wins: the same song twice in a list stays marked once.
    func testARowWithThePlayingURIIsTheOneMarked() {
        let playing = PlaybackConnectionState.playing(PlaybackNowPlaying(
            name: "Breakin' Dishes", artists: ["Rihanna"], albumName: nil, albumID: nil, albumArtURL: nil,
            durationMilliseconds: 200_000, positionMilliseconds: 0, uri: "applemusic:song:b"
        ))
        let list = Self.album([
            Self.row("Breakin' Dishes", uri: "applemusic:song:a"),
            Self.row("Breakin' Dishes", uri: "applemusic:song:b"),
        ])
        XCTAssertEqual(
            PlaylistBrowserPlaybackHelpers.currentPlaybackURI(connectionState: playing, detailContent: list),
            "applemusic:song:b"
        )
    }

    /// Spotify names a track by one id everywhere: its rows match by URI only, as before.
    func testSpotifyRowsMatchByURIOnly() {
        let playing = PlaybackConnectionState.playing(PlaybackNowPlaying(
            name: "Breakin' Dishes", artists: ["Rihanna"], albumName: nil, albumID: nil, albumArtURL: nil,
            durationMilliseconds: 200_000, positionMilliseconds: 0, uri: "spotify:track:original"
        ))
        let reloaded = Self.album([Self.row("Breakin' Dishes", uri: "spotify:track:reloaded")])
        XCTAssertEqual(
            PlaylistBrowserPlaybackHelpers.currentPlaybackURI(connectionState: playing, detailContent: reloaded),
            "spotify:track:original"
        )
    }
}

private extension PlaybackConnectionState {
    var nowPlayingName: String? {
        switch self {
        case let .playing(nowPlaying): nowPlaying.name
        case let .paused(nowPlaying): nowPlaying?.name
        default: nil
        }
    }
}
