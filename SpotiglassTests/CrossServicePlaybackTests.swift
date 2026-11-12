import AppKit
import Combine
import SwiftUI
import ViewInspector
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
    private func pausedSpotify(api: MockPlaybackAPI = MockPlaybackAPI()) -> (SpotiglassPlaybackHost, MockWebPlaybackCommander) {
        _ = NSApplication.shared
        let commander = MockWebPlaybackCommander()
        let host = SpotiglassPlaybackHost(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: commander)
        )
        let playback = host.playbackViewModel
        playback.deviceID = "device-1"
        playback.hasTransferredPlaybackToCurrentDevice = true
        playback.setTransportStateKnown(true)
        playback.setConnectionState(.paused(Self.song("Midnight City", uri: "spotify:track:1", positionMilliseconds: 197_000)))
        return (host, commander)
    }

    /// Play / pause commands Spotify's page got: a toggle, or the pause / resume a press sends
    /// when it knows the state it wants (#437).
    private func toggles(_ commander: MockWebPlaybackCommander) -> Int {
        commander.commands.filter { [.togglePlay, .pause, .resume].contains($0.command) }.count
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
        await waitUntil("the sign-out's stop", changes: player.changes) { player.commands.contains("stop") }
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

        XCTAssertNil(hosts.appleMusicStop, "adding or keeping Apple Music started a stop of its player")
        XCTAssertFalse(player.commands.contains("stop"))
        XCTAssertTrue(PlaylistBrowserPlaybackHelpers.isCurrentlyPlaying(connectionState: appleMusic.connectionState))

        // Removing it is what stops it.
        services.send([.spotify])
        await hosts.appleMusicStop?.value
        XCTAssertTrue(player.commands.contains("stop"))
    }

    /// Signing out while a play is still looking up its songs: when the lookup returns, the
    /// song must not start, or it plays with nothing on screen to stop it.
    func testSigningOutDuringASlowPlayKeepsItFromStarting() async throws {
        let (spotify, _) = pausedSpotify()
        let player = ScriptedAppleMusicPlayer()
        let hosts = hosts(spotify: spotify, player: player)
        let services = CurrentValueSubject<[MusicService], Never>([.appleMusic, .spotify])
        hosts.follow(addedServices: services)
        let provider = hosts.appleMusic.playbackProvider
        hosts.appleMusic.playbackViewModel.handle(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))

        player.holdLookups = true
        let play = Task {
            try await provider.play(.items(uris: ["applemusic:song:slow"], startURI: nil), deviceID: AppleMusicPlaybackProvider.deviceID)
        }
        await waitUntil("a lookup waiting", changes: player.changes) { !player.waitingLookups.isEmpty }
        XCTAssertEqual(player.waitingLookups, ["play applemusic:song:slow"])

        services.send([.spotify])
        await waitUntil("the sign-out's stop", changes: player.changes) { player.commands.contains("stop") }
        player.releaseLookups()
        _ = try? await play.value
        player.advance(by: 1)

        XCTAssertFalse(player.commands.contains("play"), "the play from the ended session never starts")
        XCTAssertNotEqual(player.readState().status, .playing)
    }

    /// Played a queue with a song added to it, signed out, added Apple Music again: Add to
    /// Queue must not bring back the old songs (MusicKit still holds that queue), and the next
    /// play must not carry the old added song over.
    func testAfterSigningOutAddToQueueDoesNotBringBackTheOldQueue() async throws {
        let (spotify, _) = pausedSpotify()
        let player = ScriptedAppleMusicPlayer()
        let hosts = hosts(spotify: spotify, player: player)
        let services = CurrentValueSubject<[MusicService], Never>([.appleMusic, .spotify])
        hosts.follow(addedServices: services)
        let appleMusic = try await playingAppleMusic(in: hosts, player: player)
        let provider = hosts.appleMusic.playbackProvider
        try await provider.enqueue(uri: "applemusic:song:added-before", deviceID: AppleMusicPlaybackProvider.deviceID)

        services.send([.spotify])
        await waitUntil("the sign-out's stop", changes: player.changes) { player.commands.contains("stop") }
        player.advance(by: 1)
        // Apple Music added again: its player is ready, with nothing loaded.
        appleMusic.handle(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))
        XCTAssertNotNil(appleMusic.commandDeviceID)
        XCTAssertTrue(appleMusic.hasNothingLoaded)

        let queue = QueueViewModel(provider: provider, playbackSession: appleMusic)
        await queue.addToQueue(uri: "applemusic:song:new-add")

        XCTAssertFalse(player.commands.contains("enqueue applemusic:song:new-add"))
        XCTAssertEqual(queue.lastError?.title, SpotiglassL10n.string("error.queue.nothingLoaded.title"))
        let afterAdd = try await provider.fetchPlaybackState()
        XCTAssertNil(afterAdd, "the signed-out song doesn't come back")

        try await provider.play(.items(uris: ["applemusic:song:fresh"], startURI: nil), deviceID: AppleMusicPlaybackProvider.deviceID)
        player.advance(by: 1)
        let upcoming = try await provider.fetchQueue().queue.compactMap { item -> String? in
            guard case let .track(track) = item else { return nil }
            return track.uri
        }
        XCTAssertFalse(upcoming.contains("applemusic:song:added-before"), "the old added song isn't carried into the new queue")
    }

    /// Signed out, added Apple Music again, then a play that fails (a song MusicKit can't
    /// find): the signed-out song must not come back as paused and resumable.
    func testAPlayThatFailsAfterSigningOutKeepsTheOldSongHidden() async throws {
        let (spotify, _) = pausedSpotify()
        let player = ScriptedAppleMusicPlayer()
        let hosts = hosts(spotify: spotify, player: player)
        let services = CurrentValueSubject<[MusicService], Never>([.appleMusic, .spotify])
        hosts.follow(addedServices: services)
        _ = try await playingAppleMusic(in: hosts, player: player)
        let provider = hosts.appleMusic.playbackProvider

        services.send([.spotify])
        await waitUntil("the sign-out's stop", changes: player.changes) { player.commands.contains("stop") }
        player.advance(by: 1)
        player.failure = NSError(domain: "MusicKit", code: 404)
        _ = try? await provider.play(.items(uris: ["applemusic:song:missing"], startURI: nil), deviceID: AppleMusicPlaybackProvider.deviceID)

        let afterFailedPlay = try await provider.fetchPlaybackState()
        XCTAssertNil(afterFailedPlay, "the signed-out song stays hidden")
        let upcoming = try await provider.fetchQueue().queue
        XCTAssertTrue(upcoming.isEmpty)
    }

    /// Add to Queue while its lookup is slow, then signing out before it returns: the add
    /// belongs to the session that ended, so it must not land in the queue the next play
    /// carries over.
    func testAnAddStillLookingUpWhenSigningOutIsDropped() async throws {
        let (spotify, _) = pausedSpotify()
        let player = ScriptedAppleMusicPlayer()
        let hosts = hosts(spotify: spotify, player: player)
        let services = CurrentValueSubject<[MusicService], Never>([.appleMusic, .spotify])
        hosts.follow(addedServices: services)
        _ = try await playingAppleMusic(in: hosts, player: player)
        let provider = hosts.appleMusic.playbackProvider

        player.holdLookups = true
        let add = Task {
            try await provider.enqueue(uri: "applemusic:song:slow-add", deviceID: AppleMusicPlaybackProvider.deviceID)
        }
        await waitUntil("a lookup waiting", changes: player.changes) { !player.waitingLookups.isEmpty }
        XCTAssertEqual(player.waitingLookups, ["enqueue applemusic:song:slow-add"])
        services.send([.spotify])
        await waitUntil("the sign-out's stop", changes: player.changes) { player.commands.contains("stop") }
        player.holdLookups = false
        player.releaseLookups()
        _ = try? await add.value
        player.advance(by: 1)

        XCTAssertFalse(player.commands.contains("enqueue applemusic:song:slow-add"))
        try await provider.play(.items(uris: ["applemusic:song:fresh"], startURI: nil), deviceID: AppleMusicPlaybackProvider.deviceID)
        player.advance(by: 1)
        let upcoming = try await provider.fetchQueue().queue.compactMap { item -> String? in
            guard case let .track(track) = item else { return nil }
            return track.uri
        }
        XCTAssertFalse(upcoming.contains("applemusic:song:slow-add"))
    }

    /// Signed out, Apple Music added again, a song started and Add to Queue pressed while
    /// that first play still runs: the add waits for the play and must go through, every time.
    /// Run many times, because the play and the waiting add finish in the same turn.
    func testAnAddMadeDuringTheFirstPlayAfterSigningOutGoesThrough() async throws {
        for attempt in 0..<300 {
            let player = ScriptedAppleMusicPlayer()
            let provider = AppleMusicPlaybackProvider(player: player)
            try await provider.disconnectPlayer(generation: .initial)
            player.holdLookups = true
            let play = Task {
                try await provider.play(.items(uris: ["applemusic:song:first"], startURI: nil), deviceID: AppleMusicPlaybackProvider.deviceID)
            }
            await waitUntil("a lookup waiting", changes: player.changes) { !player.waitingLookups.isEmpty }
            // The add takes the running play to wait for before it first suspends; this goes on
            // only once it has, however late a busy machine starts it (#535).
            let addStarted = AsyncSignal()
            let add = Task { @MainActor in
                addStarted.signal()
                try await provider.enqueue(uri: "applemusic:song:added", deviceID: AppleMusicPlaybackProvider.deviceID)
            }
            await addStarted.wait()
            player.holdLookups = false
            player.releaseLookups()
            try await play.value
            do {
                try await add.value
            } catch {
                XCTFail("attempt \(attempt): the add was dropped (\(error))")
                return
            }
            XCTAssertTrue(player.commands.contains("enqueue applemusic:song:added"))
        }
    }

    /// After a sign-out, song A starts and, while MusicKit's play of A is still finishing,
    /// song B is asked for and fails: A plays, so it must show in the bar.
    func testASongThatStartedShowsEvenWhenANewerPlayFails() async throws {
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player)
        try await provider.disconnectPlayer(generation: .initial)

        player.holdAfterQueueSet = true
        let playA = Task {
            try await provider.play(.items(uris: ["applemusic:song:a"], startURI: nil), deviceID: AppleMusicPlaybackProvider.deviceID)
        }
        await waitUntil("a lookup waiting", changes: player.changes) { !player.waitingLookups.isEmpty }
        XCTAssertEqual(player.waitingLookups, ["started applemusic:song:a"])
        player.holdAfterQueueSet = false
        player.failure = NSError(domain: "MusicKit", code: 404)
        _ = try? await provider.play(.items(uris: ["applemusic:song:b"], startURI: nil), deviceID: AppleMusicPlaybackProvider.deviceID)
        player.releaseLookups()
        _ = try? await playA.value

        let state = try await provider.fetchPlaybackState()
        XCTAssertEqual(state?.playbackNowPlaying?.uri, "applemusic:song:a", "A plays, so the bar shows it")
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
        XCTAssertTrue(playback.isOtherServiceHeard)
        XCTAssertTrue(playback.audiblePlayer === appleMusic, "the bar shows what you hear")

        let manager = wirePalette(to: playback)
        XCTAssertTrue(manager.canTogglePlayback, "Playback › Play/Pause can pause what you hear")
        XCTAssertTrue(manager.playbackTogglePrerequisite?() ?? false)
        manager.togglePlayback?()
        await appleMusic.playPauseCommandTail?.value
        player.advance(by: 1)

        XCTAssertEqual(toggles(commander), 0, "Midnight City stays paused")
        XCTAssertTrue(player.commands.contains("pause"), "Space pauses Piranguera")
        XCTAssertEqual(player.readState().status, .paused)
        XCTAssertEqual(appleMusic.connectionState.nowPlayingName, "Piranguera")
        XCTAssertFalse(PlaylistBrowserPlaybackHelpers.isCurrentlyPlaying(connectionState: appleMusic.connectionState))
        XCTAssertTrue(playback.isOtherServiceHeard)
        XCTAssertTrue(playback.audiblePlayer === appleMusic, "the bar stays on the song you paused (#468)")
    }

    /// The report (#468): Apple Music played, Spotify was on screen, and pausing moved the bar to
    /// Spotify's paused song; Play then started Midnight City instead of resuming Piranguera.
    func testPlayAfterPausingResumesTheSongYouPausedNotTheOnScreenServicesSong() async throws {
        let (spotify, commander) = pausedSpotify()
        let player = ScriptedAppleMusicPlayer()
        let hosts = hosts(spotify: spotify, player: player)
        hosts.gate(activeService: .appleMusic)
        let appleMusic = try await playingAppleMusic(in: hosts, player: player)
        hosts.gate(activeService: .spotify) // ⌃2
        let playback = spotify.playbackViewModel
        let manager = wirePalette(to: playback)

        // Pause from the bar: it controls the player you hear.
        _ = playback.audiblePlayer.requestTogglePlayPause()
        await appleMusic.playPauseCommandTail?.value
        player.advance(by: 1)
        XCTAssertEqual(player.readState().status, .paused)

        XCTAssertTrue(playback.audiblePlayer === appleMusic, "the bar stays on Piranguera")
        XCTAssertEqual(playback.audiblePlayer.connectionState.nowPlayingName, "Piranguera")
        XCTAssertTrue(manager.canTogglePlayback, "Play resumes what you paused")

        // Play, as Space / Playback › Play would.
        manager.togglePlayback?()
        await appleMusic.playPauseCommandTail?.value
        player.advance(by: 1)

        XCTAssertEqual(toggles(commander), 0, "Midnight City stays paused")
        XCTAssertEqual(player.commands.filter { $0 == "pause" }.count, 1)
        XCTAssertEqual(player.readState().status, .playing, "Piranguera resumes")
        XCTAssertEqual(appleMusic.connectionState.nowPlayingName, "Piranguera")
        XCTAssertTrue(playback.audiblePlayer === appleMusic)
    }

    /// The report (#486): Piranguera from Apple Music in the bar, Spotify on screen paused on
    /// Midnight City. The bar's Lyrics button and View › Show Lyrics opened Midnight City's
    /// lyrics. They open the lyrics of the song in the bar, playing or paused.
    func testTheLyricsFollowTheSongInTheBarNotTheOnScreenService() async throws {
        let (spotify, _) = pausedSpotify()
        let player = ScriptedAppleMusicPlayer()
        let hosts = hosts(spotify: spotify, player: player)
        hosts.gate(activeService: .appleMusic)
        let appleMusic = try await playingAppleMusic(in: hosts, player: player)
        hosts.gate(activeService: .spotify) // ⌃2
        let playback = spotify.playbackViewModel
        let manager = wirePalette(to: playback)
        manager.bindPlaybackReadiness(to: playback)
        // A song of its own: the lyrics cache is app-wide.
        let piranguera = Self.song("Piranguera", uri: "applemusic:song:piranguera-\(UUID().uuidString)", positionMilliseconds: 25_000)
        appleMusic.setConnectionState(.playing(piranguera))

        // The Lyrics view in the main window loads the song in the bar while it plays.
        var looked: [String] = []
        let lookups = TestChanges()
        let lyricsOverlay = try hostLyricsOverlay(onScreenPlayer: playback) { looked.append($0); lookups.send() }
        defer { ViewTestHost.tearDownAll() }
        await waitUntil("the lyrics looked up", changes: lookups) { !looked.isEmpty }
        XCTAssertEqual(looked, ["Piranguera"], "not Midnight City, Spotify's paused song on screen")

        // Pause from the bar: the bar stays on Piranguera (#468), and so do the lyrics.
        _ = playback.audiblePlayer.requestTogglePlayPause()
        await appleMusic.playPauseCommandTail?.value
        player.advance(by: 1)
        appleMusic.setConnectionState(.paused(piranguera))
        XCTAssertTrue(playback.audiblePlayer === appleMusic, "the bar shows Piranguera")
        await ViewTestHost.renderPendingUpdates()
        XCTAssertTrue(lyricsOverlay.isPresented, "the lyrics closed when Piranguera paused")
        XCTAssertEqual(looked, ["Piranguera"], "the paused lyrics went to another song")
        lyricsOverlay.presentedBinding {}.wrappedValue = false
        lyricsOverlay.presentedBinding {}.wrappedValue = true
        XCTAssertTrue(lyricsOverlay.isPresented, "the bar's Lyrics button doesn't open Piranguera's paused lyrics")

        // View › Show Lyrics follows the bar too, even with no Spotify song to fall back on.
        XCTAssertTrue(manager.canToggleLyrics)
        playback.setConnectionState(.paused(nil))
        XCTAssertTrue(playback.audiblePlayer === appleMusic)
        XCTAssertTrue(manager.canToggleLyrics, "Show Lyrics opens Piranguera's lyrics")
        lyricsOverlay.presentedBinding {}.wrappedValue = false
        lyricsOverlay.presentedBinding {}.wrappedValue = true
        XCTAssertTrue(lyricsOverlay.isPresented, "the bar's Lyrics button opens Piranguera's lyrics")
    }

    /// Starting a Spotify song while the lyrics show Apple Music's paused Piranguera: Spotify is
    /// the one you hear at once, but its song only comes when Spotify's page reports it. The
    /// lyrics used to close in that moment. They wait for the song, like the bar, then show it,
    /// and Hide Lyrics keeps working meanwhile. A play that fails or gives up waiting ends the
    /// wait, and the lyrics close.
    func testStartingASongOnScreenKeepsTheLyricsOpen() async throws {
        enum Ending { case reported, fails, timesOut }
        let runs: [(start: PlaybackConnectionState, ending: Ending)] = [
            (.paused(nil), .reported),
            (.ready(deviceID: "device-1"), .reported), // connected after launch, nothing loaded
            (.paused(nil), .fails),
            (.paused(nil), .timesOut),
        ]
        for (start, ending) in runs {
            let label = "\(start), \(ending)"
            let api = MockPlaybackAPI()
            if ending == .fails { api.playErrors = [URLError(.notConnectedToInternet)] }
            let (spotify, _) = pausedSpotify(api: api)
            let player = ScriptedAppleMusicPlayer()
            let hosts = hosts(spotify: spotify, player: player)
            hosts.gate(activeService: .appleMusic)
            let appleMusic = try await playingAppleMusic(in: hosts, player: player)
            hosts.gate(activeService: .spotify)
            let playback = spotify.playbackViewModel
            let piranguera = Self.song("Piranguera", uri: "applemusic:song:piranguera-\(UUID().uuidString)", positionMilliseconds: 25_000)
            appleMusic.setConnectionState(.playing(piranguera))
            _ = playback.audiblePlayer.requestTogglePlayPause()
            await appleMusic.playPauseCommandTail?.value
            player.advance(by: 1)
            appleMusic.setConnectionState(.paused(piranguera))
            playback.setConnectionState(start)
            XCTAssertTrue(playback.audiblePlayer === appleMusic, label)

            var looked: [String] = []
            let lookups = TestChanges()
            let lyricsOverlay = try hostLyricsOverlay(onScreenPlayer: playback) { looked.append($0); lookups.send() }
            let manager = wirePalette(
                to: playback,
                lyricsPresented: lyricsOverlay.presentedBinding {}
            )
            manager.bindPlaybackReadiness(to: playback)
            await waitUntil("Piranguera's lyrics looked up, \(label)", changes: lookups) { looked == ["Piranguera"] }
            // Piranguera's own load ends first, so the `.loading` below can only be the wait for
            // the next song.
            let lyricsModel = try XCTUnwrap(lyricsOverlay.lyricsModel, label)
            await waitUntil("Piranguera's lyrics loaded, \(label)", changes: lyricsModel.$phase) { lyricsModel.phase != .loading }

            // Play a Spotify song from the palette.
            let strobeURI = "spotify:track:strobe-\(UUID().uuidString)"
            let play = Task { await playback.play(uri: strobeURI) }
            await waitUntil("the play under way, \(label)", changes: playback.objectWillChange) {
                if case .error = playback.connectionState { return true }
                return playback.pendingPlayTransition != nil
            }
            if ending == .fails {
                await play.value
                await waitUntil("the lyrics closed, \(label)", changes: lyricsOverlay.$isPresented) { !lyricsOverlay.isPresented }
                XCTAssertFalse(lyricsOverlay.isPresented, "the play failed: no song to show the lyrics of, \(label)")
                ViewTestHost.tearDownAll()
                continue
            }
            XCTAssertTrue(playback.audiblePlayer === playback, "Spotify is the one you hear now, in the bar too, \(label)")
            // The lyrics take up the wait for Spotify's song: the same step closes them when no
            // song is coming. It ends on that, or at once on the lyrics closing, which fails below.
            await waitUntil(
                "the lyrics waiting for the song, \(label)",
                changes: lyricsModel.$phase.map { _ in }.merge(with: lyricsOverlay.$isPresented.map { _ in })
            ) { lyricsModel.phase == .loading || !lyricsOverlay.isPresented }
            await ViewTestHost.renderPendingUpdates()
            XCTAssertTrue(lyricsOverlay.isPresented, "the lyrics closed while Spotify's song was on its way, \(label)")
            XCTAssertEqual(lyricsOverlay.lyricsModel?.phase, .loading, "the lyrics wait for the song, like the bar, \(label)")
            XCTAssertTrue(manager.isLyricsToggleAllowed, "Hide Lyrics doesn't work while the lyrics wait, \(label)")
            await play.value

            if ending == .timesOut {
                // What the session does when no report came in time (`pendingPlayURITimeout`).
                playback.clearPendingPlay()
                await waitUntil("the lyrics closed, \(label)", changes: lyricsOverlay.$isPresented) { !lyricsOverlay.isPresented }
                XCTAssertFalse(lyricsOverlay.isPresented, "the wait for the song never ended, \(label)")
                ViewTestHost.tearDownAll()
                continue
            }

            // Spotify's page reports the song.
            playback.handle(.stateChanged(Self.song("Strobe", uri: strobeURI), isPaused: false, nextTracks: []))
            await waitUntil("Strobe's lyrics looked up, \(label)", changes: lookups) { looked.last == "Strobe" }
            XCTAssertEqual(looked, ["Piranguera", "Strobe"], label)
            XCTAssertNil(playback.pendingPlayTransition, "the report is the song the play asked for, \(label)")
            XCTAssertTrue(lyricsOverlay.isPresented, label)
            ViewTestHost.tearDownAll()
        }
    }

    /// The lyrics view as the main window shows it: the overlay layer on the browser's
    /// (on-screen) player, opened.
    private func hostLyricsOverlay(
        onScreenPlayer playback: PlaybackSessionViewModel,
        lookedUp: @escaping (String) -> Void
    ) throws -> LyricsOverlayController {
        let settings = try ViewTestHost.makeSettingsStore()
        let lyricsOverlay = LyricsOverlayController()
        var willOpen = 0
        lyricsOverlay.presentedBinding { willOpen += 1 }.wrappedValue = true
        XCTAssertFalse(lyricsOverlay.isPresented, "the lyrics opened with no song to show")
        XCTAssertEqual(willOpen, 0, "a refused open saved the playlist's scroll position")
        lyricsOverlay.attach(
            playback: playback,
            queue: QueueViewModel(provider: playback.provider, playbackSession: playback),
            lyrics: ImmersiveLyricsViewModel(fetchLyrics: { track in
                lookedUp(track.name)
                return .instrumental
            }),
            navigateToArtist: { _ in },
            navigateToAlbum: { _, _, _ in }
        )
        // What the bar's Lyrics button and View › Show Lyrics toggle.
        lyricsOverlay.presentedBinding { willOpen += 1 }.wrappedValue = true
        lyricsOverlay.presentedBinding { willOpen += 1 }.wrappedValue = true
        XCTAssertEqual(willOpen, 1, "opening the lyrics again saved the playlist's scroll position again")
        XCTAssertTrue(lyricsOverlay.isPresented, "the lyrics didn't open for the song in the bar")
        ViewTestHost.host(
            LyricsOverlayLayer(lyricsOverlay: lyricsOverlay, keymapStore: CommandPaletteKeymapStore(settingsStore: settings))
                .environmentObject(settings),
            size: CGSize(width: 960, height: 640)
        )
        return lyricsOverlay
    }

    /// The mirror: Spotify played, Apple Music is on screen with its own paused song. After
    /// Spotify pauses, the bar stays on Spotify's song, and Play resumes it, not Apple Music's.
    func testAppleMusicsBarStaysOnSpotifysPausedSong() async throws {
        let (spotify, commander) = pausedSpotify()
        let player = ScriptedAppleMusicPlayer()
        let hosts = hosts(spotify: spotify, player: player)
        let appleMusic = hosts.appleMusic.playbackViewModel
        appleMusic.handle(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))
        appleMusic.setConnectionState(.paused(Self.song("Piranguera", uri: "applemusic:song:piranguera")))
        hosts.gate(activeService: .appleMusic)
        let spotifyPlayer = spotify.playbackViewModel
        spotifyPlayer.setConnectionState(.playing(Self.song("Midnight City", uri: "spotify:track:1")))
        XCTAssertTrue(appleMusic.audiblePlayer === spotifyPlayer)

        // Spotify's page reports the pause.
        spotifyPlayer.setConnectionState(.paused(Self.song("Midnight City", uri: "spotify:track:1", positionMilliseconds: 60_000)))

        XCTAssertTrue(appleMusic.audiblePlayer === spotifyPlayer, "the bar stays on Midnight City")
        let manager = wirePalette(to: appleMusic)
        manager.togglePlayback?()
        await waitUntil("Spotify's page told to play", changes: commander.changes) { toggles(commander) > 0 }
        XCTAssertEqual(toggles(commander), 1, "Play resumes Midnight City")
        XCTAssertFalse(player.commands.contains("play"), "Piranguera stays paused")
    }

    /// From launch: Spotify played and paused before I opened Apple Music for the first time,
    /// which is when its player is made. The bar stays on Spotify's paused song.
    func testSpotifyPausedBeforeAppleMusicsPlayerExistsKeepsTheBar() async throws {
        let (spotify, _) = pausedSpotify()
        let player = ScriptedAppleMusicPlayer()
        let hosts = hosts(spotify: spotify, player: player)
        hosts.gate(activeService: .spotify)
        let spotifyPlayer = spotify.playbackViewModel
        spotifyPlayer.setConnectionState(.playing(Self.song("Midnight City", uri: "spotify:track:1")))
        spotifyPlayer.setConnectionState(.paused(Self.song("Midnight City", uri: "spotify:track:1", positionMilliseconds: 60_000)))
        XCTAssertNil(hosts.appleMusicIfCreated)

        // ⌃2 to Apple Music for the first time.
        let appleMusic = hosts.appleMusic.playbackViewModel
        appleMusic.handle(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))
        hosts.gate(activeService: .appleMusic)

        XCTAssertTrue(appleMusic.isOtherServiceHeard)
        XCTAssertTrue(appleMusic.audiblePlayer === spotifyPlayer, "the bar stays on Midnight City")
    }

    /// A pause that leaves the other player with no song (its queue ran out, the page lost the
    /// track) gives nothing to follow: the bar goes back to the on-screen service's paused song.
    func testAppleMusicsBarComesBackWhenSpotifyPausesWithNoSong() async throws {
        let (spotify, _) = pausedSpotify()
        let player = ScriptedAppleMusicPlayer()
        let hosts = hosts(spotify: spotify, player: player)
        let appleMusic = hosts.appleMusic.playbackViewModel
        appleMusic.handle(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))
        appleMusic.setConnectionState(.paused(Self.song("Piranguera", uri: "applemusic:song:piranguera")))
        hosts.gate(activeService: .appleMusic)
        let spotifyPlayer = spotify.playbackViewModel
        spotifyPlayer.setConnectionState(.playing(Self.song("Midnight City", uri: "spotify:track:1")))
        XCTAssertTrue(appleMusic.audiblePlayer === spotifyPlayer)

        spotifyPlayer.setConnectionState(.paused(nil))

        XCTAssertFalse(appleMusic.isOtherServiceHeard)
        XCTAssertTrue(appleMusic.audiblePlayer === appleMusic, "the bar shows Piranguera, not an empty bar")
    }

    /// "Until I play something else": music started from the on-screen library takes the bar.
    func testStartingMusicOnScreenMovesTheBarBackToThisService() async throws {
        let (spotify, _) = pausedSpotify()
        let player = ScriptedAppleMusicPlayer()
        let hosts = hosts(spotify: spotify, player: player)
        hosts.gate(activeService: .appleMusic)
        let appleMusic = try await playingAppleMusic(in: hosts, player: player)
        hosts.gate(activeService: .spotify)
        appleMusic.setConnectionState(.paused(Self.song("Piranguera", uri: "applemusic:song:piranguera")))
        let playback = spotify.playbackViewModel
        XCTAssertTrue(playback.audiblePlayer === appleMusic)

        // Starting Spotify music (a row, the header's Play) pauses Apple Music first.
        playback.onWillStartPlayback?()
        XCTAssertFalse(playback.isOtherServiceHeard)
        XCTAssertTrue(playback.audiblePlayer === playback)
        playback.setConnectionState(.playing(Self.song("Midnight City", uri: "spotify:track:1")))
        XCTAssertTrue(playback.audiblePlayer === playback)
        XCTAssertTrue(appleMusic.isOtherServiceHeard, "Apple Music's own bar follows Spotify now")
    }

    /// Playback › Repeat while the bar shows Apple Music playing and Spotify sits paused on
    /// screen: Repeat sets Apple Music's repeat, like the bar's Repeat button, and the menu's
    /// checkmark shows it. Spotify's repeat stays as it was.
    func testPlaybackMenuRepeatSetsTheRepeatOfTheMusicYouHear() async throws {
        let (spotify, _) = pausedSpotify()
        let player = ScriptedAppleMusicPlayer()
        let hosts = hosts(spotify: spotify, player: player)
        let appleMusic = try await playingAppleMusic(in: hosts, player: player)
        appleMusic.setTransportStateKnown(true)
        let playback = spotify.playbackViewModel
        let manager = wirePalette(to: playback)
        manager.bindPlaybackReadiness(to: playback)

        manager.requestRepeatMode(.track)
        await waitUntil("Apple Music's repeat set", changes: player.changes) { player.readState().repeatMode == .track }

        XCTAssertEqual(player.readState().repeatMode, .track, "Apple Music repeats the song you hear")
        XCTAssertEqual(appleMusic.repeatMode, .track)
        XCTAssertEqual(playback.repeatMode, .off, "Spotify's repeat is untouched")
        XCTAssertEqual(manager.repeatMode, .track, "the menu's checkmark is the repeat you hear")
    }

    /// Apple Music on screen with nothing loaded while Spotify plays: the bar controls
    /// Spotify, so the menu's Repeat is enabled by Spotify's player. Shuffle, which goes
    /// through the on-screen queue, stays off.
    func testPlaybackMenuRepeatIsEnabledByThePlayerYouHear() {
        let (spotify, _) = pausedSpotify()
        let hosts = hosts(spotify: spotify, player: ScriptedAppleMusicPlayer())
        let appleMusic = hosts.appleMusic.playbackViewModel
        appleMusic.handle(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))
        let manager = CommandPaletteManager()
        manager.bindPlaybackReadiness(to: appleMusic)
        XCTAssertFalse(manager.canMutateRepeat, "nothing plays anywhere: Apple Music's own player, nothing loaded")

        spotify.playbackViewModel.setConnectionState(.playing(Self.song("Midnight City", uri: "spotify:track:1")))

        XCTAssertTrue(appleMusic.audiblePlayer === spotify.playbackViewModel)
        XCTAssertTrue(manager.canMutateRepeat, "Repeat sets Spotify's repeat, like the bar")
        XCTAssertFalse(manager.canMutatePlaybackTransport, "Shuffle stays with Apple Music's empty queue")
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

    private func wirePalette(
        to playback: PlaybackSessionViewModel,
        lyricsPresented: Binding<Bool> = .constant(false)
    ) -> CommandPaletteManager {
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
            lyricsPresented: lyricsPresented
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

    /// The report (#500): right after launch, with Apple Music signed in and nothing loaded,
    /// ⌘K offered Next Track first; running it closed the palette and the bar still said
    /// "Ready to play". Next and Previous are left out until a song is loaded, then come back
    /// without moving the highlight, like Play/Pause.
    func testAppleMusicPaletteLeavesOutNextTrackWhileNothingIsLoaded() async throws {
        let (spotify, _) = pausedSpotify()
        spotify.playbackViewModel.setConnectionState(.ready(deviceID: "device-1"))
        let player = ScriptedAppleMusicPlayer()
        let hosts = hosts(spotify: spotify, player: player)
        let appleMusic = hosts.appleMusic.playbackViewModel
        appleMusic.handle(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))
        try await assertSkipFollowsWhatIsLoaded(on: appleMusic, expectPlayPauseWhileEmpty: false) {
            appleMusic.setConnectionState(.playing(Self.song("Piranguera", uri: "applemusic:song:piranguera")))
        }
    }

    /// Spotify mode had the same gap: its ready player keeps Play/Pause (it resumes the
    /// account's last item), but Next Track skipped from nothing.
    func testSpotifyPaletteLeavesOutNextTrackWhileNothingIsLoaded() async throws {
        let (spotify, _) = pausedSpotify()
        let playback = spotify.playbackViewModel
        playback.setConnectionState(.ready(deviceID: "device-1"))
        try await assertSkipFollowsWhatIsLoaded(on: playback, expectPlayPauseWhileEmpty: true) {
            playback.setConnectionState(.playing(Self.song("Midnight City", uri: "spotify:track:1")))
        }
    }

    /// Skipping goes to the music you hear (#396): with Spotify on screen and nothing loaded
    /// there, but Apple Music playing, Next and Previous skip Apple Music, so ⌘K, the menu and
    /// the bar keep them (#500 must not take them away).
    func testSkipStaysWhileTheOtherServicesMusicIsWhatYouHear() async throws {
        let (spotify, _) = pausedSpotify()
        let playback = spotify.playbackViewModel
        playback.setConnectionState(.ready(deviceID: "device-1"))
        let player = ScriptedAppleMusicPlayer()
        let hosts = hosts(spotify: spotify, player: player)
        hosts.gate(activeService: .appleMusic)
        let appleMusic = try await playingAppleMusic(in: hosts, player: player)
        hosts.gate(activeService: .spotify)

        XCTAssertFalse(playback.connectionState.hasTrackToSkipFrom, "nothing loaded on Spotify itself")
        XCTAssertTrue(playback.isOtherServiceHeard)
        XCTAssertTrue(playback.audiblePlayer === appleMusic)
        XCTAssertTrue(playback.audiblePlayer.connectionState.hasTrackToSkipFrom, "the bar's skip buttons are on")

        let manager = wirePalette(to: playback)
        manager.isSignedIn = true
        manager.bindPlaybackReadiness(to: playback)
        manager.viewModel.show()
        await manager.viewModel.waitForSearchCompletion()
        XCTAssertTrue(manager.canSkipTrack, "the Playback menu's Next and Previous are on")
        let quickActions = manager.viewModel.sections.first { $0.section == .quickActions }?.items.map(\.id) ?? []
        XCTAssertTrue(quickActions.contains(CommandPaletteCommandID.nextTrack), "\(quickActions)")
        XCTAssertTrue(manager.viewModel.staticItemsProvider().map(\.id).contains(CommandPaletteCommandID.previousTrack))
    }

    private func assertSkipFollowsWhatIsLoaded(
        on playback: PlaybackSessionViewModel,
        expectPlayPauseWhileEmpty: Bool,
        startSong: () -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let manager = wirePalette(to: playback)
        manager.isSignedIn = true
        manager.bindPlaybackReadiness(to: playback)
        manager.viewModel.show()
        func quickActionIDs() -> [String] {
            manager.viewModel.sections.first { $0.section == .quickActions }?.items.map(\.id) ?? []
        }
        func commandIDs() -> [String] {
            manager.viewModel.staticItemsProvider().map(\.id)
        }

        XCTAssertFalse(quickActionIDs().contains(CommandPaletteCommandID.nextTrack), "nothing to skip from", file: file, line: line)
        XCTAssertFalse(commandIDs().contains(CommandPaletteCommandID.previousTrack), "nothing to go back from", file: file, line: line)
        XCTAssertFalse(manager.canSkipTrack, "the Playback menu's Next and Previous are off too", file: file, line: line)
        XCTAssertEqual(
            quickActionIDs().contains(CommandPaletteCommandID.togglePlayback), expectPlayPauseWhileEmpty,
            file: file, line: line
        )

        let highlighted = try XCTUnwrap(
            manager.viewModel.visibleItems.firstIndex { $0.id == CommandPaletteCommandID.openSettings },
            file: file, line: line
        )
        manager.viewModel.selectedIndex = highlighted

        startSong()
        await manager.viewModel.waitForSearchCompletion()

        XCTAssertTrue(quickActionIDs().contains(CommandPaletteCommandID.nextTrack), "a song plays: Next is back", file: file, line: line)
        XCTAssertTrue(commandIDs().contains(CommandPaletteCommandID.previousTrack), file: file, line: line)
        XCTAssertTrue(manager.canSkipTrack, file: file, line: line)
        XCTAssertEqual(
            manager.viewModel.visibleItems[manager.viewModel.selectedIndex].id, CommandPaletteCommandID.openSettings,
            "the highlight stays on the row it was on", file: file, line: line
        )
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

    /// "Breakin' Dishes" played from its album (the album's id for it), then found in search
    /// (the library `i.` id): the search row is marked, so its button pauses instead of
    /// starting the song again. Home's top tracks mark it the same way.
    func testASongPlayingFromItsAlbumIsMarkedInSearchAndHome() async throws {
        let fromAlbum = "applemusic:song:-6046431734389870155"
        let inLibrary = "applemusic:song:i.B0VN4RQfxzX7aak"
        let found = Self.row("Breakin' Dishes", uri: inLibrary, durationMilliseconds: 200_093)
        let playback = PlaybackSessionViewModel(provider: AppleMusicPlaybackProvider(player: ScriptedAppleMusicPlayer()))
        playback.setConnectionState(.playing(PlaybackNowPlaying(
            name: "Breakin' Dishes", artists: ["Rihanna"], albumName: nil, albumID: nil, albumArtURL: nil,
            durationMilliseconds: 200_000, positionMilliseconds: 1_000, uri: fromAlbum
        )))
        let queue = QueueViewModel(provider: playback.provider, playbackSession: playback)
        let browser = PlaylistBrowserViewModel(api: MockBrowsingAPI(playlistResults: [], trackResults: [:]), cache: MockBrowsingCache())
        let pins = PinnedItemsStore(cache: InMemoryPinnedItemsCache())

        let search = CatalogSearchViewModel()
        search.searchProvider = { _, offset, _ in
            MusicSearchResults(tracks: offset == 0 ? [found] : [], artists: [], albums: [], playlists: [])
        }
        search.query = "breakin"
        search.queryDidChange()
        await search.waitForSearchCompletion()
        let searchView = CatalogSearchView(
            viewModel: browser, searchViewModel: search, playbackViewModel: playback, queueViewModel: queue,
            hasPlaybackDevice: true
        )
        .environmentObject(pins)
        let searchRows = try searchView.inspect().findAll(TrackListRow.self)
        XCTAssertEqual(try searchRows.map { try $0.actualView().isCurrent }, [true], "search")

        browser.homeTopTracks = .loaded(TrackRowViewModel.numberedTopTracks([found]))
        let homeView = HomeView(
            viewModel: browser, playbackViewModel: playback, queueViewModel: queue,
            hasPlaybackDevice: true
        )
        .environmentObject(pins)
        let homeRows = try homeView.inspect().findAll(TrackListRow.self)
        XCTAssertEqual(try homeRows.map { try $0.actualView().isCurrent }, [true], "Home")
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
