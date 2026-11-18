import Combine
import Foundation

/// A song in the recent queue that steers Autoplay (#613).
struct QueueAutoplaySeed: Equatable {
    let uri: String?
    let title: String
    let artists: [String]
    /// The service's artist IDs when known; a source may look the artists up by name otherwise.
    let artistIDs: [String]
    /// How much this song steers: songs the listener picked count fully, songs Autoplay
    /// added itself less, so a few songs added by hand turn the queue towards them.
    let weight: Double

    init(uri: String?, title: String, artists: [String], artistIDs: [String] = [], weight: Double = 1) {
        self.uri = uri
        self.title = title
        self.artists = artists
        self.artistIDs = artistIDs
        self.weight = weight
    }

    init(track: MusicTrack, weight: Double = 1) {
        self.init(
            uri: track.uri,
            title: track.name,
            artists: track.artists,
            artistIDs: track.artistRefs.map(\.id),
            weight: weight
        )
    }

    func weighted(_ weight: Double) -> QueueAutoplaySeed {
        QueueAutoplaySeed(uri: uri, title: title, artists: artists, artistIDs: artistIDs, weight: weight)
    }

    var identityKeys: Set<String> {
        QueueAutoplayIdentity.keys(uri: uri, title: title, artists: artists)
    }
}

/// A song a source suggests, with how strongly the recent queue points at it.
struct QueueAutoplayCandidate: Equatable {
    let track: MusicTrack
    let score: Double
}

/// Finds new songs in the style of the seeds. One per service; `nil` where a service offers
/// nothing to build it from.
protocol QueueAutoplaySource: AnyObject {
    func candidates(for seeds: [QueueAutoplaySeed]) async throws -> [QueueAutoplayCandidate]
}

/// What Autoplay needs from the player: what is queued after the current song, and a way to put
/// a song at the very end, after everything already queued.
@MainActor
protocol QueueAutoplayPlayer: AnyObject {
    func autoplayUpcomingTracks() async throws -> [MusicTrack]
    /// `isWanted` is asked right before the queue changes, so an add still waiting when
    /// Autoplay is turned off leaves the queue alone.
    func autoplayAppend(_ track: MusicTrack, isWanted: @escaping @MainActor () -> Bool) async throws
}

/// The same song under different IDs (a library copy and its catalog song, or another edition)
/// must count as heard, so a song is known by its URI and by its title and first artist.
enum QueueAutoplayIdentity {
    static func keys(uri: String?, title: String, artists: [String]) -> Set<String> {
        var keys: Set<String> = []
        if let uri = MusicPlayableURI.canonical(uri) { keys.insert("uri:\(uri)") }
        let normalizedTitle = normalizedTitle(title)
        if !normalizedTitle.isEmpty {
            keys.insert("song:\(normalizedTitle)|\(artists.first.map(normalized) ?? "")")
        }
        return keys
    }

    static func keys(_ track: MusicTrack) -> Set<String> {
        keys(uri: track.uri, title: track.name, artists: track.artists)
    }

    static func artistKey(_ track: MusicTrack) -> String {
        track.artists.first.map(normalized) ?? ""
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Drops what editions add to a title ("(Remastered 2011)", "[Live]", "- Radio Edit").
    static func normalizedTitle(_ title: String) -> String {
        var base = title
        for (open, close) in [("(", ")"), ("[", "]")] {
            while let start = base.range(of: open),
                let end = base.range(of: close, range: start.upperBound..<base.endIndex)
            {
                base.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        if let dash = base.range(of: " - ") {
            base = String(base[..<dash.lowerBound])
        }
        return normalized(base)
    }
}

/// Orders the suggested songs Autoplay adds. Pure: the same input always gives the same order.
enum QueueAutoplayRanking {
    /// Playable suggestions, highest score first, without `excluded` songs and without the same
    /// song twice.
    static func ordered(_ candidates: [QueueAutoplayCandidate], excluded: Set<String>) -> [MusicTrack] {
        let ordered = candidates.enumerated()
            .filter { $0.element.track.isPlayable != false && MusicPlayableURI.canonical($0.element.track.uri) != nil }
            .sorted { lhs, rhs in
                lhs.element.score != rhs.element.score
                    ? lhs.element.score > rhs.element.score
                    : lhs.offset < rhs.offset
            }
            .map(\.element.track)

        var taken: Set<String> = excluded
        var remaining: [MusicTrack] = []
        for track in ordered {
            let keys = QueueAutoplayIdentity.keys(track)
            guard taken.isDisjoint(with: keys) else { continue }
            taken.formUnion(keys)
            remaining.append(track)
        }
        return remaining
    }

    /// Spreads artists over the songs queued one after another: the best song by an artist not
    /// just queued and not queued yet in this batch; then one only not just queued; then the
    /// best left. Moves on only for songs that really went in, so a refused song doesn't
    /// count.
    struct ArtistSpread {
        private var lastArtist: String?
        private var batchArtists: Set<String> = []

        init(lastArtistKey: String?) {
            lastArtist = lastArtistKey
        }

        func nextIndex(in remaining: [MusicTrack]) -> Int? {
            guard !remaining.isEmpty else { return nil }
            return remaining.firstIndex { track in
                let artist = QueueAutoplayIdentity.artistKey(track)
                return artist != lastArtist && !batchArtists.contains(artist)
            } ?? remaining.firstIndex { QueueAutoplayIdentity.artistKey($0) != lastArtist } ?? 0
        }

        mutating func queued(_ track: MusicTrack) {
            let artist = QueueAutoplayIdentity.artistKey(track)
            batchArtists.insert(artist)
            lastArtist = artist
        }
    }
}

/// Autoplay for the queue (#613), like Autoplay in the Music app: while it is on, the queue
/// never runs out. It fills the queue up to ``fillTarget`` songs from the recent queue's style,
/// then adds one new song at the end each time a new song starts. Songs only ever go at the
/// end, so what the listener queued stays where it was, and turning it off leaves the queue
/// as it is. Each service's playback host owns one (``forService(_:session:provider:)``).
@MainActor
final class QueueAutoplay: ObservableObject {
    enum Status: Equatable {
        case off
        /// On, nothing to do right now.
        case on
        /// Looking for songs or adding them.
        case finding
        /// The source had nothing new left in this style.
        case noMatches
        /// Reading the queue or adding failed; the next song tries again.
        case failed
    }

    @Published private(set) var status: Status

    /// `nil` when the service has nothing to build Autoplay from; the control is then hidden.
    private let source: (any QueueAutoplaySource)?
    /// The queue it reads and adds to. Holds the provider, never this object, so no cycle.
    var player: (any QueueAutoplayPlayer)?
    private var sessionChanges: AnyCancellable?
    private let flag: StoredFlag
    /// Songs kept queued after the current one while Autoplay is on.
    let fillTarget: Int
    /// How many of the most recent songs (played, playing and queued) steer the suggestions.
    let windowSize: Int
    /// The weight of a song Autoplay added itself, against 1 for one the listener picked.
    let addedSongWeight: Double
    /// Sends after songs were added, so every window's queue panel shows them.
    let queueChanged = PassthroughSubject<Void, Never>()

    /// Songs that started playing this session, oldest first, at most ``historyLimit``.
    private var played: [QueueAutoplaySeed] = []
    /// Every song heard this session, by identity key; Autoplay never adds one of them again.
    private var heardKeys: Set<String> = []
    /// Songs Autoplay added this session.
    private var addedKeys: Set<String> = []
    /// Songs that could not be added (not in the storefront, blocked as explicit).
    private var failedKeys: Set<String> = []
    /// Songs the listener took out of the queue this session (#628): Autoplay doesn't bring
    /// them back.
    private var removedKeys: Set<String> = []
    private var currentKeys: Set<String> = []
    private var currentSeed: QueueAutoplaySeed?
    /// The tracks the last queue read returned and the ones added since, by URI, so a song that
    /// starts keeps its artist IDs.
    private var knownTracks: [String: MusicTrack] = [:]
    private let historyLimit = 200

    /// New songs that started and are each owed one added song.
    private var owed = 0
    /// Set when Autoplay is turned on: fill up to ``fillTarget`` even if no song started yet.
    private var needsFill = false
    /// The running fill, if any; tests wait for it.
    private(set) var worker: Task<Void, Never>?
    private var workerGeneration: UInt64 = 0

    init(
        source: (any QueueAutoplaySource)?,
        flag: StoredFlag = .queueAutoplay,
        fillTarget: Int = 8,
        windowSize: Int = 20,
        addedSongWeight: Double = 0.5
    ) {
        self.source = source
        self.flag = flag
        self.fillTarget = fillTarget
        self.windowSize = windowSize
        self.addedSongWeight = addedSongWeight
        status = source != nil && flag.isOn ? .on : .off
        needsFill = source != nil && flag.isOn
    }

    /// The service's one Autoplay follows its player for the whole app, with or without a
    /// window open: every window's queue panel shows this same object, so two windows never
    /// add a song each for the same new song.
    static func forService(
        _ service: MusicService,
        session: PlaybackSessionViewModel,
        provider: any MusicPlaybackProvider
    ) -> QueueAutoplay {
        let autoplay = QueueAutoplay(source: source(for: service))
        autoplay.follow(session, provider: provider)
        return autoplay
    }

    /// Where each service's Autoplay songs come from. Spotify closed its recommendation and
    /// related-artist endpoints to apps like this one in November 2024, so it has none yet.
    static func source(for service: MusicService) -> (any QueueAutoplaySource)? {
        switch service {
        case .appleMusic: AppleMusicAutoplaySource()
        case .spotify: nil
        }
    }

    /// Tells Autoplay about every song the session plays, so each new one adds a song and
    /// steers the next ones.
    func follow(_ session: PlaybackSessionViewModel, provider: any MusicPlaybackProvider) {
        guard isAvailable else { return }
        player = ProviderQueueAutoplayPlayer(provider: provider) { [weak session] in
            session?.commandDeviceID
        }
        sessionChanges = session.connectionStatePublisher
            .sink { [weak self] state in self?.connectionChanged(state) }
    }

    private func connectionChanged(_ state: PlaybackConnectionState) {
        switch state {
        // Only a song that plays counts: a paused one (restored at launch, or skipped to while
        // paused) counts once it plays.
        case let .playing(item):
            nowPlayingChanged(QueueAutoplaySeed(uri: item.uri, title: item.name, artists: item.artists))
        case .disconnected, .unavailable:
            sessionEnded()
        case .connecting, .ready, .transferring, .paused, .error:
            break
        }
    }

    var isAvailable: Bool { source != nil }
    var isEnabled: Bool { isAvailable && flag.isOn }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable, enabled != flag.isOn else { return }
        objectWillChange.send()
        flag.isOn = enabled
        if enabled {
            status = .on
            needsFill = true
            kick()
        } else {
            stopWorker()
            owed = 0
            needsFill = false
            status = .off
        }
    }

    /// The player moved to another song (it finished or was skipped) or to none.
    func nowPlayingChanged(_ seed: QueueAutoplaySeed?) {
        guard let seed else { return }
        let keys = seed.identityKeys
        guard keys.isDisjoint(with: currentKeys) else { return }
        currentKeys = keys
        let enriched = seed.uri.flatMap { knownTracks[$0] }.map { QueueAutoplaySeed(track: $0) } ?? seed
        let wasAdded = !keys.isDisjoint(with: addedKeys)
        currentSeed = enriched.weighted(wasAdded ? addedSongWeight : 1)
        // Going back to a song heard before adds nothing: only new songs move the queue on.
        guard keys.isDisjoint(with: heardKeys) else { return }
        heardKeys.formUnion(keys)
        if let currentSeed { played.append(currentSeed) }
        if played.count > historyLimit { played.removeFirst(played.count - historyLimit) }
        guard isEnabled else { return }
        owed += 1
        kick()
    }

    /// The listener took these songs out of the queue.
    func listenerRemoved(_ tracks: [MusicTrack]) {
        for track in tracks { removedKeys.formUnion(QueueAutoplayIdentity.keys(track)) }
    }

    /// The listener's Undo put these songs back, so they count as queued again, not removed.
    func listenerRestored(_ tracks: [MusicTrack]) {
        for track in tracks { removedKeys.subtract(QueueAutoplayIdentity.keys(track)) }
    }

    /// Playback disconnected or the service changed: the next session starts fresh.
    func sessionEnded() {
        stopWorker()
        played = []
        heardKeys = []
        addedKeys = []
        failedKeys = []
        removedKeys = []
        currentKeys = []
        currentSeed = nil
        knownTracks = [:]
        owed = 0
        needsFill = isEnabled
        if isEnabled { status = .on }
    }

    private func kick() {
        guard worker == nil, isEnabled, player != nil else { return }
        workerGeneration &+= 1
        let generation = workerGeneration
        worker = Task { @MainActor [weak self] in
            await self?.work(generation: generation)
            guard let self, self.workerGeneration == generation else { return }
            self.worker = nil
        }
    }

    private func stopWorker() {
        worker?.cancel()
        worker = nil
        workerGeneration &+= 1
    }

    private func work(generation: UInt64) async {
        let isWanted: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.isEnabled && self.workerGeneration == generation
        }
        while isEnabled, !Task.isCancelled, owed > 0 || needsFill {
            guard let player, let source else { return }
            // Nothing plays yet: the fill waits for the first song, which also gives it a seed.
            guard currentSeed != nil else { return }
            status = .finding
            let owedNow = owed
            needsFill = false
            let upcoming: [MusicTrack]
            do {
                upcoming = try await player.autoplayUpcomingTracks()
            } catch {
                guard !Task.isCancelled else { return }
                status = .failed
                owed = 0
                return
            }
            guard isEnabled, !Task.isCancelled else { return }
            // Only queued songs can start next, so the table holds no more than the queue.
            knownTracks = Dictionary(upcoming.map { ($0.uri, $0) }, uniquingKeysWith: { first, _ in first })
            let want = max(owedNow, fillTarget - upcoming.count)
            guard want > 0 else {
                owed = max(0, owed - owedNow)
                continue
            }

            let seeds = recentSeeds(upcoming: upcoming)
            let candidates: [QueueAutoplayCandidate]
            do {
                candidates = try await source.candidates(for: seeds)
            } catch {
                guard !Task.isCancelled else { return }
                SpotiglassLog.error(.playback, "Autoplay suggestions failed: \(String(describing: error))")
                status = .failed
                owed = 0
                return
            }
            guard isEnabled, !Task.isCancelled else { return }
            var excluded = heardKeys.union(addedKeys).union(failedKeys).union(currentKeys).union(removedKeys)
            for track in upcoming { excluded.formUnion(QueueAutoplayIdentity.keys(track)) }
            let lastArtist = upcoming.last.map(QueueAutoplayIdentity.artistKey)
                ?? currentSeed.flatMap { $0.artists.first }.map(QueueAutoplayIdentity.normalized)
            // Every suggestion in order: the next one stands in for a song the player refuses,
            // chosen against the artist that really went in last.
            var remaining = QueueAutoplayRanking.ordered(candidates, excluded: excluded)
            guard !remaining.isEmpty else {
                status = .noMatches
                owed = 0
                return
            }

            var added = 0
            var spread = QueueAutoplayRanking.ArtistSpread(lastArtistKey: lastArtist)
            var stalled = false
            while added < want, let index = spread.nextIndex(in: remaining) {
                let track = remaining.remove(at: index)
                guard isEnabled, !Task.isCancelled else { return }
                // The queue may have changed while the suggestions loaded: a song added by hand
                // meanwhile, or a new song playing, isn't added again.
                if let queuedNow = try? await player.autoplayUpcomingTracks() {
                    guard isEnabled, !Task.isCancelled else { return }
                    let taken = queuedNow.reduce(into: heardKeys.union(currentKeys).union(removedKeys)) {
                        $0.formUnion(QueueAutoplayIdentity.keys($1))
                    }
                    if !taken.isDisjoint(with: QueueAutoplayIdentity.keys(track)) { continue }
                }
                do {
                    try await player.autoplayAppend(track, isWanted: isWanted)
                    addedKeys.formUnion(QueueAutoplayIdentity.keys(track))
                    knownTracks[track.uri] = track
                    spread.queued(track)
                    added += 1
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError) else { return }
                    // Only a refusal of this song rules it out. Anything else (no network, a
                    // server error) stops here and the next song tries again, the same songs
                    // included, instead of running through every suggestion.
                    guard Self.refusesSong(error) else {
                        stalled = true
                        break
                    }
                    failedKeys.formUnion(QueueAutoplayIdentity.keys(track))
                }
            }
            if added > 0 { queueChanged.send() }
            guard isEnabled, !Task.isCancelled else { return }
            owed = max(0, owed - owedNow)
            if added == 0 || stalled {
                status = .failed
                owed = 0
                return
            }
            status = added < want ? .noMatches : .on
            if added < want { owed = 0 }
        }
        if isEnabled, status == .finding { status = .on }
    }

    /// Whether the player turned down this one song (not in the storefront, blocked as explicit,
    /// queued meanwhile), so the next suggestion takes its place.
    static func refusesSong(_ error: Error) -> Bool {
        if error is QueueAppendSkipped { return true }
        guard let error = error as? MusicPlaybackError else { return false }
        switch error.reason {
        case .notFound, .explicitContentRestricted: return true
        default: return false
        }
    }

    /// The last ``windowSize`` songs of played, playing and queued, in order. A song the
    /// listener picked steers more than one Autoplay added, and newer songs more than older.
    private func recentSeeds(upcoming: [MusicTrack]) -> [QueueAutoplaySeed] {
        var seeds = played
        if let currentSeed, seeds.last?.identityKeys != currentSeed.identityKeys {
            seeds.append(currentSeed)
        }
        for track in upcoming {
            let wasAdded = !QueueAutoplayIdentity.keys(track).isDisjoint(with: addedKeys)
            seeds.append(QueueAutoplaySeed(track: track, weight: wasAdded ? addedSongWeight : 1))
        }
        let window = seeds.suffix(windowSize)
        let count = window.count
        return window.enumerated().map { index, seed in
            // From 0.5 for the oldest song in the window to 1 for the newest.
            let recency = count > 1 ? 0.5 + 0.5 * Double(index) / Double(count - 1) : 1
            return seed.weighted(seed.weight * recency)
        }
    }
}

/// Autoplay's view of a ``MusicPlaybackProvider``: the queue it reads and the end it adds to.
@MainActor
final class ProviderQueueAutoplayPlayer: QueueAutoplayPlayer {
    private let provider: any MusicPlaybackProvider
    private let deviceID: () -> String?

    init(provider: any MusicPlaybackProvider, deviceID: @escaping () -> String?) {
        self.provider = provider
        self.deviceID = deviceID
    }

    func autoplayUpcomingTracks() async throws -> [MusicTrack] {
        try await provider.fetchQueue().queue.compactMap { item in
            if case let .track(track) = item { return track }
            return nil
        }
    }

    func autoplayAppend(_ track: MusicTrack, isWanted: @escaping @MainActor () -> Bool) async throws {
        guard let deviceID = deviceID() else {
            throw MusicPlaybackError(service: provider.service, reason: .failed, detail: "No player to add to")
        }
        try await provider.appendToQueueEnd(track, deviceID: deviceID, isWanted: isWanted)
    }
}

extension StoredFlag {
    /// Whether Autoplay is on. Off until the listener turns it on.
    static let queueAutoplay = StoredFlag.app(key: "queue.autoplay.enabled", defaultValue: false)
}
