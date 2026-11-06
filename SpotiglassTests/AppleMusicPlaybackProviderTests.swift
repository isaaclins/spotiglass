import XCTest
@testable import Spotiglass

/// Apple Music playback: the provider's mapping onto MusicKit's `ApplicationMusicPlayer`
/// (through a scripted player), the session against the lag measured on a real Mac, the
/// neutral playback errors and the service-neutral lyrics key.
@MainActor
final class AppleMusicPlaybackProviderTests: XCTestCase {
    // MARK: - Provider

    func testProviderIsOneLocalPlayerWithoutPushedStateTransferOrVolume() async throws {
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player)
        var events: [MusicPlaybackEvent] = []
        provider.eventHandler = { events.append($0.event) }

        XCTAssertEqual(provider.capabilities, [])
        XCTAssertNil(provider.deviceTransfer)
        try await provider.connectPlayer(generation: .initial)
        try await provider.connectPlayer(generation: .initial.advanced())
        XCTAssertEqual(events, [
            .ready(deviceID: AppleMusicPlaybackProvider.deviceID),
            .ready(deviceID: AppleMusicPlaybackProvider.deviceID),
        ])

        let session = PlaybackSessionViewModel(provider: provider)
        XCTAssertFalse(session.supportsPlayerVolume)
        XCTAssertTrue(session.isPlayerStateRead)
        XCTAssertFalse(session.supportsDeviceTransfer)
    }

    func testConnectWithoutAppleMusicAccessFailsWithAnAppleMusicError() async {
        let player = ScriptedAppleMusicPlayer()
        player.authorized = false
        let provider = AppleMusicPlaybackProvider(player: player)
        do {
            try await provider.connectPlayer(generation: .initial)
            XCTFail("Expected a permission error")
        } catch {
            XCTAssertEqual(MusicPlaybackError.from(error)?.service, .appleMusic)
            XCTAssertEqual(MusicPlaybackError.from(error)?.reason, .missingPermission)
        }
    }

    func testPlayRequestsBecomeMusicKitQueues() throws {
        XCTAssertEqual(
            try AppleMusicPlaybackProvider.queueRequest(for: .item(uri: "applemusic:song:1")),
            .items(uris: ["applemusic:song:1"], startURI: "applemusic:song:1")
        )
        XCTAssertEqual(
            try AppleMusicPlaybackProvider.queueRequest(
                for: .items(uris: ["applemusic:song:1", "spotify:track:x", "applemusic:song:-2"], startURI: "applemusic:song:-2")
            ),
            .items(uris: ["applemusic:song:1", "applemusic:song:-2"], startURI: "applemusic:song:-2")
        )
        XCTAssertEqual(try AppleMusicPlaybackProvider.queueRequest(for: .context(uri: "applemusic:album:1440857781")), .album(id: "1440857781"))
        XCTAssertEqual(try AppleMusicPlaybackProvider.queueRequest(for: .context(uri: "applemusic:playlist:p.abc")), .playlist(id: "p.abc"))
        XCTAssertEqual(try AppleMusicPlaybackProvider.queueRequest(for: .context(uri: "applemusic:artist:42")), .artist(id: "42"))
        XCTAssertThrowsError(try AppleMusicPlaybackProvider.queueRequest(for: .context(uri: "spotify:album:abc"))) { error in
            XCTAssertEqual(MusicPlaybackError.from(error)?.service, .appleMusic)
            XCTAssertEqual(MusicPlaybackError.from(error)?.reason, .notFound)
        }
    }

    func testReadsMapThePlayerStateAndTheQueue() async throws {
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player)
        let noState = try await provider.fetchPlaybackState()
        XCTAssertNil(noState, "an empty queue reads as nothing active")

        try await provider.play(.items(uris: Self.uris, startURI: Self.uris[1]), deviceID: AppleMusicPlaybackProvider.deviceID)
        player.advance(by: 1)
        try await provider.setShuffle(enabled: true, deviceID: "x")
        try await provider.setRepeat(mode: .context, deviceID: "x")
        try await provider.seek(to: 61_500, deviceID: "x")

        let read = try await provider.fetchPlaybackState()
        let snapshot = try XCTUnwrap(read)
        XCTAssertTrue(snapshot.isPlaying)
        XCTAssertEqual(snapshot.playbackNowPlaying?.uri, Self.uris[1])
        XCTAssertEqual(snapshot.progressMilliseconds, 61_500)
        XCTAssertEqual(snapshot.transport, MusicPlaybackTransport(shuffle: true, repeatMode: .context))
        XCTAssertNil(snapshot.activeDevice)

        let queue = try await provider.fetchQueue()
        XCTAssertEqual(queue.queue.compactMap(Self.uri), Array(Self.uris[2...]))
    }

    func testAddToQueuePlaysInTheOrderAdded() async throws {
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player)
        let session = PlaybackSessionViewModel(provider: provider)
        let queue = QueueViewModel(provider: provider, playbackSession: session)
        session.deviceID = AppleMusicPlaybackProvider.deviceID
        session.setActivePlaybackDeviceID(AppleMusicPlaybackProvider.deviceID)
        try await provider.play(.items(uris: Self.uris, startURI: nil), deviceID: "x")

        await queue.addToQueue(uris: ["applemusic:song:a", "applemusic:song:b"])

        let upcoming = try await provider.fetchQueue().queue.compactMap(Self.uri)
        XCTAssertEqual(Array(upcoming.prefix(3)), ["applemusic:song:a", "applemusic:song:b", Self.uris[1]])
    }

    /// Spotify keeps added songs ahead of the rest in the order they were added, also once
    /// the first of them plays: adding a, b, playing a, then adding c plays b before c.
    func testAddedSongsStayInOrderAfterTheFirstOneStarts() throws {
        typealias Added = MusicKitApplicationPlayer.AddedEntries
        let place = MusicKitApplicationPlayer.addPlacement
        // Song 0 of [0 1 2] plays.
        let a = try XCTUnwrap(place(0, nil))
        XCTAssertEqual(a.index, 1, "the first add goes right after the current song")
        let b = try XCTUnwrap(place(0, a.added))
        XCTAssertEqual(b.index, 2, "the next goes after it")
        // [0 a b 1 2], a plays.
        let c = try XCTUnwrap(place(1, b.added))
        XCTAssertEqual(c.index, 3, "with a playing, c goes after b")
        XCTAssertEqual(c.added, Added(start: 1, count: 3))
        // [0 a b c 1 2], c plays: no added song is ahead any more.
        let d = try XCTUnwrap(place(3, c.added))
        XCTAssertEqual(d.index, 4)
        XCTAssertEqual(d.added, Added(start: 4, count: 1))
        // Back to 0 with previous: a, b and c are still ahead, so the next add goes after them.
        XCTAssertEqual(place(0, c.added)?.index, 4)
        XCTAssertNil(place(nil, c.added), "nothing is current: MusicKit starts a queue")
    }

    func testMusicKitFailuresSurfaceAsAppleMusicErrors() async {
        let player = ScriptedAppleMusicPlayer()
        player.failure = URLError(.notConnectedToInternet)
        let provider = AppleMusicPlaybackProvider(player: player)
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = AppleMusicPlaybackProvider.deviceID
        session.setActivePlaybackDeviceID(AppleMusicPlaybackProvider.deviceID)
        session.setConnectionState(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))

        await session.play(uri: Self.uris[0])

        guard case let .error(displayError) = session.connectionState else {
            return XCTFail("Expected an error, got \(session.connectionState)")
        }
        XCTAssertEqual(displayError.message, SpotiglassL10n.string("error.playback.appleMusic.failed"))
        XCTAssertFalse(displayError.message.contains("Spotify"))
    }

    // MARK: - Measured MusicKit lag

    /// Replays the lag measured on a Mac mini M4 (macOS 27, 2026-11-06): how long
    /// `ApplicationMusicPlayer` kept reporting the old state after each command returned.
    /// Pause up to 333 ms, play 297 ms, next 305 ms (old item at position 0), previous
    /// 189 ms. The session reads once right after a command and then every second, so
    /// its 2-read settle window has to hide the first, stale read and apply the second.
    func testSettleWindowCoversMeasuredPauseAndResumeLag() async throws {
        let (player, session) = try await Self.playingSession()

        await session.togglePlayPause()
        XCTAssertEqual(player.commands.last, "pause")
        try await Self.read(session, player, at: 0.07)
        XCTAssertTrue(Self.isPaused(session), "a read 70 ms after pause still says playing and must not undo it")
        try await Self.read(session, player, at: 1.07)
        XCTAssertTrue(Self.isPaused(session))
        XCTAssertEqual(session.localMutationSettleTicksRemaining, 0, "two reads end the window")
        try await Self.read(session, player, at: 2.07)
        XCTAssertTrue(Self.isPaused(session))

        await session.togglePlayPause()
        XCTAssertEqual(player.commands.last, "resume")
        try await Self.read(session, player, at: 0.07)
        XCTAssertTrue(Self.isPlaying(session), "a read 70 ms after play still says paused and must not undo it")
        try await Self.read(session, player, at: 1.07)
        XCTAssertTrue(Self.isPlaying(session))
        XCTAssertEqual(session.localMutationSettleTicksRemaining, 0)
    }

    /// Without the skip fence the first read after "next" put the old song back on screen
    /// at 0:00 for a second (seen on the real player). It must keep the old position until
    /// MusicKit reports the next song.
    func testStaleReadAfterNextDoesNotJumpTheOldSongToZero() async throws {
        let (player, session) = try await Self.playingSession()
        try await Self.read(session, player, at: 40)
        let before = try XCTUnwrap(session.currentNowPlaying)
        XCTAssertEqual(before.uri, Self.uris[0])

        await session.next()
        XCTAssertEqual(player.commands.last, "next")
        try await Self.read(session, player, at: 0.07)
        XCTAssertEqual(session.currentNowPlaying?.uri, Self.uris[0])
        XCTAssertGreaterThan(session.currentNowPlaying?.positionMilliseconds ?? 0, 30_000, "the stale position-0 read was applied")

        try await Self.read(session, player, at: 1.07)
        XCTAssertEqual(session.currentNowPlaying?.uri, Self.uris[1])
        XCTAssertTrue(Self.isPlaying(session))
    }

    func testStaleReadAfterPreviousIsIgnoredToo() async throws {
        let (player, session) = try await Self.playingSession(startIndex: 2)
        try await Self.read(session, player, at: 10)

        await session.previous()
        try await Self.read(session, player, at: 0.07)
        XCTAssertEqual(session.currentNowPlaying?.uri, Self.uris[2])
        try await Self.read(session, player, at: 1.07)
        XCTAssertEqual(session.currentNowPlaying?.uri, Self.uris[1])
    }

    /// Previous on the first song restarts it: the same item comes back, and once the settle
    /// window is over it is shown again.
    func testRestartOfTheSameSongIsShownAfterTheWindow() async throws {
        let (player, session) = try await Self.playingSession()
        try await Self.read(session, player, at: 20)
        await session.previous()
        try await Self.read(session, player, at: 0.07)
        try await Self.read(session, player, at: 1.07)
        try await Self.read(session, player, at: 1.0)
        XCTAssertEqual(session.currentNowPlaying?.uri, Self.uris[0])
        XCTAssertLessThan(session.currentNowPlaying?.positionMilliseconds ?? .max, 5_000)
    }

    // MARK: - Errors name the service

    func testSpotifyErrorsKeepTheirMessages() {
        let premium = PlaybackSessionViewModel.displayError(for: SpotifyAPIError.forbidden(message: nil, details: nil))
        XCTAssertEqual(premium.title, SpotiglassL10n.string("error.playback.premium.title"))
        let expired = PlaybackSessionViewModel.displayError(for: SpotifyAPIError.unauthorized)
        XCTAssertEqual(expired.recoveryAction, .reauthenticate)
        let failed = PlaybackSessionViewModel.displayError(for: SpotifyAPIError.server(statusCode: 502, message: nil, details: nil))
        XCTAssertEqual(
            failed.message,
            String(format: SpotiglassL10n.string("error.playback.commandFailed.message"), String(describing: SpotifyAPIError.server(statusCode: 502, message: nil, details: nil)))
        )
    }

    func testAppleMusicErrorsNameAppleMusic() {
        let subscription = PlaybackSessionViewModel.displayError(
            for: MusicPlaybackError(service: .appleMusic, reason: .subscriptionRequired(message: nil))
        )
        XCTAssertEqual(subscription.title, SpotiglassL10n.string("error.playback.appleMusic.subscription.title"))
        XCTAssertNil(subscription.recoveryAction)
        let permission = PlaybackSessionViewModel.displayError(
            for: MusicPlaybackError(service: .appleMusic, reason: .missingPermission)
        )
        XCTAssertEqual(permission.message, SpotiglassL10n.string("error.playback.appleMusic.permission.message"))
        XCTAssertNotEqual(permission.recoveryAction, .reauthenticate, "Apple Music has no Spotify sign-in to repeat")
        let queue = QueueViewModel.displayError(for: MusicPlaybackError(service: .appleMusic, reason: .missingPermission))
        XCTAssertEqual(queue?.message, SpotiglassL10n.string("error.playback.appleMusic.permission.message"))
    }

    // MARK: - Lyrics

    func testLyricsKeyCoversAppleMusicSongsAndKeepsSpotifyKeys() {
        XCTAssertEqual(Self.nowPlaying(uri: "spotify:track:4uLU6hMCjMI75M1A2tKUQC").lyricsTrackKey, "4uLU6hMCjMI75M1A2tKUQC")
        XCTAssertEqual(Self.nowPlaying(uri: "applemusic:song:1440857781").lyricsTrackKey, "applemusic-song-1440857781")
        XCTAssertEqual(Self.nowPlaying(uri: "applemusic:song:i.B0VNYlBtxzX7aak").lyricsTrackKey, "applemusic-song-i-B0VNYlBtxzX7aak")
        XCTAssertNil(Self.nowPlaying(uri: "applemusic:music-video:1").lyricsTrackKey)
        XCTAssertNil(Self.nowPlaying(uri: "spotify:episode:1").lyricsTrackKey)
    }

    func testAppleMusicTracksGetLyrics() async {
        let track = Self.nowPlaying(uri: "applemusic:song:1440857781")
        XCTAssertEqual(PlaybackConnectionState.playing(track).currentLyricTrack, track)

        let queued = QueueItem.from(playback: track)
        XCTAssertEqual(queued.playbackNowPlayingForLyricsPrefetch()?.uri, track.uri)

        var fetched: [String] = []
        let lyrics = ImmersiveLyricsViewModel { track in
            fetched.append(track.name)
            return .instrumental
        }
        await lyrics.load(track: track)
        XCTAssertEqual(fetched, ["Can't Hold Us"])
        XCTAssertEqual(lyrics.phase, .ready(.instrumental))
    }

    /// The transport bar's hints and connecting text name Apple Music in Apple Music mode, and
    /// Spotify keeps its own text.
    func testTransportTextNamesTheSelectedService() {
        let pairs = [
            ("playback.controls.previous.hint", "playback.controls.previous.appleMusic.hint"),
            ("playback.controls.playPause.hint", "playback.controls.playPause.appleMusic.hint"),
            ("playback.controls.next.hint", "playback.controls.next.appleMusic.hint"),
            ("playback.controls.reconnect.hint", "playback.controls.reconnect.appleMusic.hint"),
            ("playback.controls.reconnect.sdk.hint", "playback.controls.reconnect.appleMusic.hint"),
            ("playback.controls.state.connecting.title", "playback.controls.state.connecting.title.appleMusic"),
            ("playback.controls.state.connecting.subtitle", "playback.controls.state.connecting.subtitle.appleMusic"),
            ("playback.fallbackName", "playback.fallbackName.appleMusic"),
        ]
        for (spotifyKey, appleMusicKey) in pairs {
            let spotify = PlaybackControlsView.serviceString(spotifyKey, appleMusic: appleMusicKey, service: .spotify)
            let appleMusic = PlaybackControlsView.serviceString(spotifyKey, appleMusic: appleMusicKey, service: .appleMusic)
            XCTAssertEqual(spotify, SpotiglassL10n.string(spotifyKey), spotifyKey)
            XCTAssertTrue(spotify.contains("Spotify"), "\(spotifyKey): \(spotify)")
            XCTAssertFalse(appleMusic.contains("Spotify"), "\(appleMusicKey): \(appleMusic)")
            XCTAssertTrue(appleMusic.contains("Apple Music"), "\(appleMusicKey): \(appleMusic)")
        }
    }

    // MARK: - Playable registry

    func testMappingASongRemembersItForPlayback() throws {
        let song = try AppleMusicFixtures.song(id: "-7726707972698117572", title: "Can't Hold Us")
        let track = AppleMusicItemMapping.track(song)
        XCTAssertEqual(track.uri, "applemusic:song:-7726707972698117572")
        XCTAssertEqual(AppleMusicPlayableRegistry.shared.song(for: track.uri)?.id, song.id)
    }

    func testRegistryIsBounded() throws {
        let registry = AppleMusicPlayableRegistry(capacity: 4)
        let songs = try (1...5).map { try AppleMusicFixtures.song(id: "\($0)", title: "Song \($0)") }
        func uri(_ n: Int) -> String { "applemusic:song:\(n)" }
        for (index, song) in songs.enumerated() { registry.register(song, for: uri(index + 1)) }
        // Past the capacity the oldest half is dropped: 5 > 4 keeps the newest 2.
        for dropped in 1...3 { XCTAssertNil(registry.song(for: uri(dropped)), "song \(dropped)") }
        XCTAssertEqual(registry.song(for: uri(4))?.id, songs[3].id)
        XCTAssertEqual(registry.song(for: uri(5))?.id, songs[4].id)
        // Registering a URI again doesn't count as a new entry: two more re-registrations
        // and one new song (3 entries) stay under the capacity, so nothing is dropped.
        registry.register(songs[4], for: uri(5))
        registry.register(songs[4], for: uri(5))
        registry.register(songs[0], for: uri(1))
        XCTAssertEqual(registry.song(for: uri(4))?.id, songs[3].id)
        XCTAssertEqual(registry.song(for: uri(1))?.id, songs[0].id)
    }

    // MARK: - Header play

    func testDetailHeaderPlaysTheAppleMusicContext() {
        let album = PlaylistDetailViewModel(
            playlist: PlaylistRowViewModel(albumDisplayName: "Album", artistsDisplay: "A", totalTrackCount: 1, artworkURL: nil, albumID: "1440857781"),
            tracks: []
        )
        XCTAssertEqual(DetailHeaderPlayback.target(for: album, service: .appleMusic), .context(uri: "applemusic:album:1440857781"))
        XCTAssertEqual(DetailHeaderPlayback.target(for: album, service: .spotify), .context(uri: "spotify:album:1440857781"))
    }

    // MARK: - Fixtures

    static let uris = (1...6).map { "applemusic:song:\($0)" }

    private static func uri(_ item: MusicPlaybackItem) -> String? {
        if case let .track(track) = item { return track.uri }
        return nil
    }

    private static func nowPlaying(uri: String) -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: "Can't Hold Us",
            artists: ["Macklemore & Ryan Lewis"],
            albumName: "The Heist",
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 258_000,
            positionMilliseconds: 0,
            uri: uri
        )
    }

    private static func playingSession(startIndex: Int = 0) async throws -> (ScriptedAppleMusicPlayer, PlaybackSessionViewModel) {
        let player = ScriptedAppleMusicPlayer()
        let provider = AppleMusicPlaybackProvider(player: player)
        let session = PlaybackSessionViewModel(provider: provider)
        session.deviceID = AppleMusicPlaybackProvider.deviceID
        session.setActivePlaybackDeviceID(AppleMusicPlaybackProvider.deviceID)
        try await provider.play(.items(uris: uris, startURI: uris[startIndex]), deviceID: "x")
        player.advance(by: 1)
        await session.syncTransportFromSpotify()
        XCTAssertEqual(session.currentNowPlaying?.uri, uris[startIndex])
        return (player, session)
    }

    /// Moves the scripted player's clock forward and reads, like the session's poll does.
    private static func read(_ session: PlaybackSessionViewModel, _ player: ScriptedAppleMusicPlayer, at seconds: Double) async throws {
        player.advance(by: seconds)
        await session.syncTransportFromSpotify()
    }

    private static func isPaused(_ session: PlaybackSessionViewModel) -> Bool {
        if case .paused = session.connectionState { return true }
        return false
    }

    private static func isPlaying(_ session: PlaybackSessionViewModel) -> Bool {
        if case .playing = session.connectionState { return true }
        return false
    }
}

/// MusicKit's `ApplicationMusicPlayer` with the measured lag: a command takes effect only
/// after `lag` seconds of scripted time; until then reads still show the old state (and a
/// skip already reports position 0 for the old item, as the real player does).
@MainActor
final class ScriptedAppleMusicPlayer: AppleMusicPlayerControlling {
    static let lag: [String: Double] = ["pause": 0.333, "resume": 0.297, "next": 0.305, "previous": 0.189, "stop": 0.074]

    var authorized = true
    var failure: Error?
    private(set) var commands: [String] = []

    private var now = 0.0
    private var queue: [String] = []
    private var index = 0
    private var playing = false
    private var positionBase = 0.0
    private var positionAnchor = 0.0
    private var shuffle = false
    private var repeatMode: MusicRepeatMode = .off
    private var added: MusicKitApplicationPlayer.AddedEntries?
    private var pending: [(at: Double, apply: () -> Void)] = []

    func advance(by seconds: Double) {
        now += seconds
        let due = pending.filter { $0.at <= now }
        pending.removeAll { $0.at <= now }
        due.forEach { $0.apply() }
    }

    private func position() -> Double {
        playing ? positionBase + (now - positionAnchor) : positionBase
    }

    private func later(_ command: String, _ apply: @escaping () -> Void) {
        commands.append(command)
        pending.append((now + (Self.lag[command] ?? 0), apply))
    }

    func isAuthorized() -> Bool { authorized }

    func play(_ request: AppleMusicQueueRequest) async throws {
        if let failure { throw MusicPlaybackError(service: .appleMusic, reason: .failed, detail: "\(failure)") }
        guard case let .items(uris, start) = request else { throw MusicPlaybackError(service: .appleMusic, reason: .notFound) }
        commands.append("play")
        queue = uris
        index = start.flatMap { uris.firstIndex(of: $0) } ?? 0
        playing = true
        positionBase = 0
        positionAnchor = now
        added = nil
    }

    func pause() {
        later("pause") { [self] in positionBase = position(); playing = false }
    }

    func resume() async throws {
        later("resume") { [self] in positionAnchor = now; playing = true }
    }

    func stop() {
        later("stop") { [self] in positionBase = position(); playing = false }
    }

    func seek(toMilliseconds milliseconds: Int) {
        commands.append("seek")
        positionBase = Double(milliseconds) / 1000
        positionAnchor = now
    }

    func skipToNext() async throws {
        positionBase = 0
        positionAnchor = now
        later("next") { [self] in index = min(index + 1, queue.count - 1); positionBase = 0; positionAnchor = now }
    }

    func skipToPrevious() async throws {
        let restart = index == 0
        positionBase = 0
        positionAnchor = now
        later("previous") { [self] in if !restart { index -= 1 }; positionBase = 0; positionAnchor = now }
    }

    func setShuffle(_ enabled: Bool) { shuffle = enabled }
    func setRepeat(_ mode: MusicRepeatMode) { repeatMode = mode }

    func enqueue(uri: String) async throws {
        commands.append("enqueue \(uri)")
        // The live player's placement rule, on this queue.
        let placement = MusicKitApplicationPlayer.addPlacement(
            currentIndex: queue.indices.contains(index) ? index : nil, added: added
        )
        queue.insert(uri, at: min(placement?.index ?? queue.count, queue.count))
        added = placement?.added
    }

    func readState() -> AppleMusicPlayerState {
        guard queue.indices.contains(index) else {
            return AppleMusicPlayerState(status: .stopped, current: nil, positionMilliseconds: 0, shuffle: shuffle, repeatMode: repeatMode)
        }
        return AppleMusicPlayerState(
            status: playing ? .playing : .paused,
            current: Self.track(queue[index]),
            positionMilliseconds: Int(position() * 1000),
            shuffle: shuffle,
            repeatMode: repeatMode
        )
    }

    func readUpcoming() -> [MusicTrack] {
        guard queue.indices.contains(index) else { return [] }
        return queue[(index + 1)...].map(Self.track)
    }

    private static func track(_ uri: String) -> MusicTrack {
        MusicTrack(
            id: uri,
            name: uri,
            artists: ["Artist"],
            albumArtworkURL: nil,
            durationMilliseconds: 240_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: uri
        )
    }
}
