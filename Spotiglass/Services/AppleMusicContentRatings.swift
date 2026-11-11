import Foundation
import MusicKit

/// Whether an Apple Music song is explicit: the one answer every label, filter and comparison
/// uses (#518).
///
/// MusicKit on macOS gives songs saved to the library no content rating, so read as they come
/// every saved explicit song would be clean: no Explicit label, and past the clean-only filter.
/// A saved song names its catalog release (`playParams.catalogId`), and that release's rating is
/// the real one. ``resolve(_:lookup:library:deadline:)`` looks those ratings up before songs are
/// shown or queued; ``isExplicit(_:)`` then answers from them. A song with a rating of its own
/// keeps it, and one without a catalog release (uploaded) stays as MusicKit gives it.
///
/// Library playlists and saved albums list their songs under the Music app's persistent ID
/// alone, with no catalog ID. The same song read from the library (`MusicLibraryRequest<Song>`)
/// carries both IDs, a song that is only in a playlist too (#401), so the release of such a row
/// comes from one read of the library, done when a row names a persistent ID no read has seen.
///
/// A song whose release's rating isn't known (the lookup failed, the catalog doesn't list it, or
/// the library read didn't list the row) shows no label, as before, and the clean-only filter
/// leaves it out: an unknown rating mustn't open up the restriction.
///
/// Bounded: past ``capacity`` the least recently used entries go first. Memory only. A failed
/// lookup isn't kept, so the next read asks again.
final class AppleMusicContentRatings: @unchecked Sendable {
    static let shared = AppleMusicContentRatings()

    /// The catalog's ratings for these catalog song IDs, `true` for explicit.
    typealias CatalogLookup = @Sendable (_ catalogIDs: [String]) async throws -> [String: Bool]
    /// One page of the library's songs, as `AppleMusicContentSource.librarySongs` reads them.
    typealias LibraryPage = @Sendable (_ limit: Int, _ offset: Int) async throws -> [Song]

    /// Lookups running at once, so a large library's first read doesn't wait on each in turn.
    static let parallelLookups = 4
    /// Songs per page of a library read, and the most one read covers (newest first, like
    /// Liked Songs). Tests make them small.
    let libraryPageSize: Int
    let maxLibrarySongs: Int

    /// Where an unrated song's rating comes from.
    private enum Release {
        /// The catalog release it names.
        case catalog(String)
        /// A library playlist or album row: the release the library song with its persistent ID names.
        case libraryRow
        /// Nothing to ask (an upload, or a catalog song, which carries its own rating).
        case none
    }

    /// What the library says about a persistent ID.
    private enum LibrarySong {
        /// The library song names this catalog release.
        case release(String)
        /// The library song names none (an upload).
        case noRelease
        /// A read of the library didn't list it (past ``maxLibrarySongs``, or gone): its rating
        /// is unknown, not clean, but reading the library again wouldn't find it either.
        case notListed
    }

    /// What the catalog answered for a release.
    private enum CatalogRating {
        case explicit, clean
        /// Not listed (gone from this storefront): shown unlabelled, but not known to be clean.
        case unlisted
    }

    let capacity: Int
    private let lock = NSLock()
    /// Worked out once per song, as encoding a song to read it costs time on a long list (#442).
    private var releasesBySongID: LRUDictionary<String, Release>
    private var librarySongsByPersistentID: LRUDictionary<String, LibrarySong>
    private var ratingsByCatalogID: LRUDictionary<String, CatalogRating>
    /// The lookup asking for each catalog ID now, so a read that comes along meanwhile waits for
    /// it instead of asking again.
    private var lookupsInFlight: [String: Task<Void, Never>] = [:]
    /// The library read running now, so lists opening together read it once.
    private var libraryRead: Task<Bool, Never>?
    private var startedLookups = 0
    /// Catalog lookups started, counted when they start (`SpotiglassTests` only).
    // periphery:ignore
    var lookupsStarted: Int { lock.withLock { startedLookups } }
    /// A read covered the library (all of it, or up to ``maxLibrarySongs``): what it didn't
    /// list can't be found by reading it all again, so later reads only look at the newest
    /// page, for songs added since.
    private var libraryWasReadInFull = false

    init(
        capacity: Int = 20_000,
        libraryPageSize: Int = AppleMusicBrowsingProvider.librarySongsPageSize,
        maxLibrarySongs: Int = AppleMusicBrowsingProvider.maxLibrarySongs
    ) {
        self.capacity = max(2, capacity)
        self.libraryPageSize = max(1, libraryPageSize)
        self.maxLibrarySongs = max(1, maxLibrarySongs)
        releasesBySongID = LRUDictionary(capacity: self.capacity)
        librarySongsByPersistentID = LRUDictionary(capacity: self.capacity)
        ratingsByCatalogID = LRUDictionary(capacity: self.capacity)
    }

    /// Forgets everything known (`SpotiglassTests` only: the shared instance outlives a test).
    // periphery:ignore
    internal func resetSharedStateForTesting() {
        lock.withLock {
            releasesBySongID = LRUDictionary(capacity: capacity)
            librarySongsByPersistentID = LRUDictionary(capacity: capacity)
            ratingsByCatalogID = LRUDictionary(capacity: capacity)
            lookupsInFlight.removeAll()
            libraryRead = nil
            libraryWasReadInFull = false
            startedLookups = 0
        }
    }

    /// For the Explicit label: a song whose rating isn't known shows none, as before.
    func isExplicit(_ song: Song) -> Bool {
        rating(of: song) ?? false
    }

    /// `true` for explicit, `false` for clean or for a song with no catalog release, `nil` when
    /// the song has a release whose rating isn't known (not looked up yet, the lookup failed,
    /// the catalog doesn't list it, or the library read didn't list the row). The clean-only
    /// filter treats `nil` as explicit.
    func rating(of song: Song) -> Bool? {
        if let rating = song.contentRating { return rating == .explicit }
        let catalogID: String
        switch release(of: song) {
        case .none: return false
        case let .catalog(id): catalogID = id
        case .libraryRow:
            switch lock.withLock({ librarySongsByPersistentID.value(forKey: song.id.rawValue) }) {
            case let .release(id)?: catalogID = id
            case .noRelease?: return false
            case .notListed?, nil: return nil
            }
        }
        switch lock.withLock({ ratingsByCatalogID.value(forKey: catalogID) }) {
        case .explicit?: return true
        case .clean?: return false
        case .unlisted?, nil: return nil
        }
    }

    /// Looks up the catalog rating of each unrated song in `songs` that isn't known yet. With a
    /// `deadline`, returns when it passes even if the lookups haven't finished: they carry on,
    /// and the next read finds their ratings (or waits for the lookup still asking).
    func resolve(
        _ songs: some Sequence<Song>,
        lookup: @escaping CatalogLookup,
        library: LibraryPage?,
        deadline: (@Sendable () async -> Void)? = nil
    ) async {
        var catalogIDs: [String] = []
        var unmapped: [String] = []
        for song in songs where song.contentRating == nil {
            switch release(of: song) {
            case .none: continue
            case let .catalog(id): catalogIDs.append(id)
            case .libraryRow:
                switch lock.withLock({ librarySongsByPersistentID.value(forKey: song.id.rawValue) }) {
                case let .release(id)?: catalogIDs.append(id)
                case .noRelease?, .notListed?: continue
                case nil: unmapped.append(song.id.rawValue)
                }
            }
        }
        // Started before any waiting, so a read right behind this one finds them in flight.
        let started = startLookups(catalogIDs, lookup: lookup)
        let work = Task {
            for lookup in started { await lookup.value }
            // A read of another list may have mapped them while this one waited.
            let stillUnmapped = self.lock.withLock {
                unmapped.filter { self.librarySongsByPersistentID.value(forKey: $0) == nil }
            }
            guard !stillUnmapped.isEmpty, let library, await self.readLibrary(library) else { return }
            for lookup in self.startLookups(self.releasesAfterLibraryRead(unmapped), lookup: lookup) {
                await lookup.value
            }
        }
        guard let deadline else {
            await work.value
            return
        }
        await Self.first(of: work, or: deadline)
    }

    /// The lookups to wait for: one started now for the IDs no one has asked about, and those
    /// already asking for the rest.
    private func startLookups(_ catalogIDs: [String], lookup: @escaping CatalogLookup) -> [Task<Void, Never>] {
        lock.withLock {
            var seen: Set<String> = []
            var waits: [Task<Void, Never>] = []
            var missing: [String] = []
            for id in catalogIDs where seen.insert(id).inserted {
                guard ratingsByCatalogID.value(forKey: id) == nil else { continue }
                if let running = lookupsInFlight[id] {
                    if !waits.contains(running) { waits.append(running) }
                } else {
                    missing.append(id)
                }
            }
            guard !missing.isEmpty else { return waits }
            let started = Task { await self.lookUp(missing, lookup: lookup) }
            startedLookups += 1
            for id in missing { lookupsInFlight[id] = started }
            return waits + [started]
        }
    }

    private func lookUp(_ catalogIDs: [String], lookup: @escaping CatalogLookup) async {
        // As many IDs per lookup as MusicKit's ID filter takes elsewhere.
        let batches = MusicKitLibraryLookup.batches(catalogIDs)
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func addNext() {
                guard next < batches.count else { return }
                let batch = batches[next]
                next += 1
                group.addTask { await self.store(batch, lookup: lookup) }
            }
            for _ in 0..<Self.parallelLookups { addNext() }
            while await group.next() != nil { addNext() }
        }
        // Only this lookup is registered for these IDs: others wait for it rather than asking.
        lock.withLock { for id in catalogIDs { lookupsInFlight[id] = nil } }
    }

    private func store(_ batch: [String], lookup: CatalogLookup) async {
        guard let ratings = try? await lookup(batch) else { return }
        lock.withLock {
            for id in batch {
                let rating: CatalogRating = switch ratings[id] {
                case true?: .explicit
                case false?: .clean
                // Gone from this storefront: no label, as before, and not asked about again.
                case nil: .unlisted
                }
                ratingsByCatalogID.setValue(rating, forKey: id)
            }
        }
    }

    /// The releases of `persistentIDs` after a library read; those it didn't list are noted, so
    /// they don't start another read.
    private func releasesAfterLibraryRead(_ persistentIDs: [String]) -> [String] {
        lock.withLock {
            persistentIDs.compactMap { persistentID in
                switch librarySongsByPersistentID.value(forKey: persistentID) {
                case let .release(id)?: return id
                case .noRelease?, .notListed?: return nil
                case nil:
                    librarySongsByPersistentID.setValue(.notListed, forKey: persistentID)
                    return nil
                }
            }
        }
    }

    // MARK: - Releases

    private func release(of song: Song) -> Release {
        let songID = song.id.rawValue
        // Catalog songs carry their own rating (or have none to give).
        guard !MusicKitLibraryLookup.isCatalogID(songID) else { return .none }
        if let known = lock.withLock({ releasesBySongID.value(forKey: songID) }) { return known }
        let isLibraryRow = MusicKitLibraryLookup.isPersistentID(songID)
        // A library row's IDs come from the cache the playlist reads fill ahead of time, as
        // encoding each row on the instant playlist view cost time (#442).
        let ids = Self.identifiers(of: song) {
            isLibraryRow ? AppleMusicSongReferenceRegistry.shared.identity(of: song) : AppleMusicSongIdentity(encoding: song)
        }
        let catalogID = ids.catalogID.flatMap { $0 != songID && MusicKitLibraryLookup.isCatalogID($0) ? $0 : nil }
        let release: Release = if let catalogID {
            .catalog(catalogID)
        } else if isLibraryRow {
            .libraryRow
        } else {
            .none
        }
        lock.withLock {
            releasesBySongID.setValue(release, forKey: songID)
            // A library song tells what its playlist and album rows name.
            if let persistentID = ids.persistentID, persistentID != songID {
                learn(catalogID.map(LibrarySong.release) ?? .noRelease, persistentID: persistentID)
            }
        }
        return release
    }

    /// Records what the library says about a persistent ID (call with the lock held). A read
    /// that names no release doesn't undo one another read found: some reads carry fewer IDs,
    /// and taking the song for an upload would make it read as clean.
    private func learn(_ song: LibrarySong, persistentID: String) {
        if case .noRelease = song, case .release? = librarySongsByPersistentID.value(forKey: persistentID) { return }
        librarySongsByPersistentID.setValue(song, forKey: persistentID)
    }

    // MARK: - Reading the library

    /// Reads the library for the catalog ID behind each persistent ID: all of it up to
    /// ``maxLibrarySongs`` the first time, then only the newest page. `false` when it
    /// failed, so nothing is concluded from it.
    private func readLibrary(_ page: @escaping LibraryPage) async -> Bool {
        let read: Task<Bool, Never> = lock.withLock {
            if let running = libraryRead { return running }
            let limit = libraryWasReadInFull ? libraryPageSize : maxLibrarySongs
            let read = Task { await self.readWholeLibrary(page, upTo: limit) }
            libraryRead = read
            return read
        }
        let succeeded = await read.value
        lock.withLock { if libraryRead == read { libraryRead = nil } }
        return succeeded
    }

    private func readWholeLibrary(_ page: LibraryPage, upTo limit: Int) async -> Bool {
        var offset = 0
        while offset < limit {
            guard let songs = try? await page(min(libraryPageSize, limit - offset), offset) else { return false }
            var learned: [(persistentID: String, song: LibrarySong)] = []
            for song in songs {
                let ids = Self.identifiers(of: song) { AppleMusicSongIdentity(encoding: song) }
                guard let persistentID = ids.persistentID else { continue }
                let catalogID = ids.catalogID.flatMap { MusicKitLibraryLookup.isCatalogID($0) ? $0 : nil }
                learned.append((persistentID, catalogID.map(LibrarySong.release) ?? .noRelease))
            }
            lock.withLock {
                for (persistentID, song) in learned {
                    learn(song, persistentID: persistentID)
                }
            }
            offset += songs.count
            if songs.count < libraryPageSize { break }
        }
        lock.withLock { libraryWasReadInFull = true }
        return true
    }

    /// A song's catalog and persistent IDs: from the play parameters when they carry both, which
    /// is much cheaper; otherwise also from `identity`, which reads MusicKit's identifier set too
    /// (a song MusicKit has only on this Mac names its release only there).
    private static func identifiers(
        of song: Song,
        identity: () -> AppleMusicSongIdentity
    ) -> (catalogID: String?, persistentID: String?) {
        let parameters = identifiers(of: song.playParameters)
        guard parameters.catalogID == nil || parameters.persistentID == nil else { return parameters }
        let identity = identity()
        return (parameters.catalogID ?? identity.catalogID, parameters.persistentID ?? identity.musicKitPersistentID)
    }

    /// `catalogId` and `musicKit_persistentID` from the play parameters alone.
    private static func identifiers(of parameters: PlayParameters?) -> (catalogID: String?, persistentID: String?) {
        guard let parameters,
              let data = try? JSONEncoder().encode(parameters),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil) }
        func string(_ value: Any?) -> String? {
            switch value {
            case let id as String: id.isEmpty ? nil : id
            case let id as NSNumber: id.stringValue
            default: nil
            }
        }
        return (string(object["catalogId"]), string(object["musicKit_persistentID"]))
    }

    // MARK: - Deadline

    /// Waits for `work` or `deadline`, whichever ends first; `work` carries on either way.
    private static func first(of work: Task<Void, Never>, or deadline: @escaping @Sendable () async -> Void) async {
        let gate = Gate()
        // A read that is cancelled (another search keystroke, another list) stops waiting too.
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gate.hold(continuation)
                let timer = Task {
                    await deadline()
                    gate.open()
                }
                Task {
                    await work.value
                    timer.cancel()
                    gate.open()
                }
            }
        } onCancel: {
            gate.open()
        }
    }

    /// Resumes a continuation once, from whichever side gets there first; opened before it holds
    /// one (a read cancelled before it started waiting), it lets the continuation go at once.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func hold(_ continuation: CheckedContinuation<Void, Never>) {
            let resumeNow = lock.withLock {
                if isOpen { return true }
                self.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }

        func open() {
            let continuation = lock.withLock {
                isOpen = true
                let held = self.continuation
                self.continuation = nil
                return held
            }
            continuation?.resume()
        }
    }
}
