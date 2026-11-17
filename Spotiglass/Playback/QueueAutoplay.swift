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
    func autoplayAppend(uri: String) async throws
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

/// Picks which suggested songs Autoplay adds. Pure: the same input always gives the same songs.
enum QueueAutoplayRanking {
    /// Highest score first, never a song in `excluded` (heard, queued or added before), never
    /// the same song twice, and no artist twice in a row (nor right after `lastArtistKey`)
    /// while another artist is left.
    static func pick(
        _ candidates: [QueueAutoplayCandidate],
        count: Int,
        excluded: Set<String>,
        lastArtistKey: String?
    ) -> [MusicTrack] {
        guard count > 0 else { return [] }
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

        var picks: [MusicTrack] = []
        var previousArtist = lastArtistKey
        var pickedArtists: [String: Int] = [:]
        while picks.count < count, !remaining.isEmpty {
            // The best song by an artist not just played and not picked yet in this batch; then
            // one only not just played; then the best left.
            let index = remaining.firstIndex { track in
                let artist = QueueAutoplayIdentity.artistKey(track)
                return artist != previousArtist && pickedArtists[artist] == nil
            } ?? remaining.firstIndex { QueueAutoplayIdentity.artistKey($0) != previousArtist } ?? 0
            let track = remaining.remove(at: index)
            let artist = QueueAutoplayIdentity.artistKey(track)
            pickedArtists[artist, default: 0] += 1
            previousArtist = artist
            picks.append(track)
        }
        return picks
    }
}

/// Autoplay for the queue (#613), like Autoplay in the Music app: while it is on, the queue
/// never runs out. It fills the queue up to ``fillTarget`` songs from the recent queue's style,
/// then adds one new song at the end each time a new song starts. Songs only ever go at the
/// end, so what the listener queued stays where it was, and turning it off leaves the queue
/// as it is.
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
    weak var player: (any QueueAutoplayPlayer)?
    private let flag: StoredFlag
    /// Songs kept queued after the current one while Autoplay is on.
    let fillTarget: Int
    /// How many of the most recent songs (played, playing and queued) steer the suggestions.
    let windowSize: Int
    /// The weight of a song Autoplay added itself, against 1 for one the listener picked.
    let addedSongWeight: Double
    /// Called after songs were added, so the panel shows them.
    var onQueueChanged: (() async -> Void)?

    /// Songs that started playing this session, oldest first, at most ``historyLimit``.
    private var played: [QueueAutoplaySeed] = []
    /// Every song heard this session, by identity key; Autoplay never adds one of them again.
    private var heardKeys: Set<String> = []
    /// Songs Autoplay added this session.
    private var addedKeys: Set<String> = []
    /// Songs that could not be added (not in the storefront, blocked as explicit).
    private var failedKeys: Set<String> = []
    private var currentKeys: Set<String> = []
    private var currentSeed: QueueAutoplaySeed?
    /// Tracks the queue reads returned, by URI, so a playing song keeps its artist IDs.
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

    /// Playback disconnected or the service changed: the next session starts fresh.
    func sessionEnded() {
        stopWorker()
        played = []
        heardKeys = []
        addedKeys = []
        failedKeys = []
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
            await self?.work()
            guard let self, self.workerGeneration == generation else { return }
            self.worker = nil
        }
    }

    private func stopWorker() {
        worker?.cancel()
        worker = nil
        workerGeneration &+= 1
    }

    private func work() async {
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
            for track in upcoming { knownTracks[track.uri] = track }
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
            var excluded = heardKeys.union(addedKeys).union(failedKeys).union(currentKeys)
            for track in upcoming { excluded.formUnion(QueueAutoplayIdentity.keys(track)) }
            let lastArtist = upcoming.last.map(QueueAutoplayIdentity.artistKey)
                ?? currentSeed.flatMap { $0.artists.first }.map(QueueAutoplayIdentity.normalized)
            // A few spare picks stand in for songs the player refuses.
            let picks = QueueAutoplayRanking.pick(
                candidates,
                count: want + 3,
                excluded: excluded,
                lastArtistKey: lastArtist
            )
            guard !picks.isEmpty else {
                status = .noMatches
                owed = 0
                return
            }

            var added = 0
            for track in picks where added < want {
                guard isEnabled, !Task.isCancelled else { return }
                do {
                    try await player.autoplayAppend(uri: track.uri)
                    addedKeys.formUnion(QueueAutoplayIdentity.keys(track))
                    knownTracks[track.uri] = track
                    added += 1
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError) else { return }
                    failedKeys.formUnion(QueueAutoplayIdentity.keys(track))
                }
            }
            if added > 0 { await onQueueChanged?() }
            guard isEnabled, !Task.isCancelled else { return }
            owed = max(0, owed - owedNow)
            if added == 0 {
                status = .failed
                owed = 0
                return
            }
            status = added < want ? .noMatches : .on
            if added < want { owed = 0 }
        }
        if isEnabled, status == .finding { status = .on }
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

    func autoplayAppend(uri: String) async throws {
        guard let deviceID = deviceID() else {
            throw MusicPlaybackError(service: provider.service, reason: .failed, detail: "No player to add to")
        }
        try await provider.appendToQueueEnd(uri: uri, deviceID: deviceID)
    }
}

extension StoredFlag {
    /// Whether Autoplay is on. Off until the listener turns it on.
    static let queueAutoplay = StoredFlag.app(key: "queue.autoplay.enabled", defaultValue: false)
}
