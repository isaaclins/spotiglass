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
    static let libraryPageSize = AppleMusicBrowsingProvider.librarySongsPageSize
    static let maxLibrarySongs = AppleMusicBrowsingProvider.maxLibrarySongs

    /// Where an unrated song's rating comes from.
    private enum Release {
        /// The catalog release it names.
        case catalog(String)
        /// A library playlist or album row: the release the library song with its persistent ID names.
        case libraryRow
        /// Nothing to ask (an upload, or a catalog song, which carries its own rating).
        case none
    }

    let capacity: Int
    private let lock = NSLock()
    /// Worked out once per song, as encoding a song to read it costs time on a long list (#442).
    private var releasesBySongID: LRUDictionary<String, Release>
    /// The catalog ID of each library song by its persistent ID, "" for a song without one.
    private var catalogIDsByPersistentID: LRUDictionary<String, String>
    private var explicitByCatalogID: LRUDictionary<String, Bool>
    /// The library read running now, so lists opening together read it once.
    private var libraryRead: Task<Bool, Never>?

    init(capacity: Int = 20_000) {
        self.capacity = max(2, capacity)
        releasesBySongID = LRUDictionary(capacity: self.capacity)
        catalogIDsByPersistentID = LRUDictionary(capacity: self.capacity)
        explicitByCatalogID = LRUDictionary(capacity: self.capacity)
    }

    func isExplicit(_ song: Song) -> Bool {
        rating(of: song) ?? false
    }

    /// `true` for explicit, `nil` while the song's release is known but its rating isn't (not
    /// looked up yet, or the lookup failed).
    func rating(of song: Song) -> Bool? {
        if let rating = song.contentRating { return rating == .explicit }
        guard let catalogID = catalogID(of: song) else {
            return isUnmappedLibraryRow(song) ? nil : false
        }
        return lock.withLock { explicitByCatalogID.value(forKey: catalogID) }
    }

    /// Looks up the catalog rating of each unrated song in `songs` that isn't known yet. With a
    /// `deadline`, returns when it passes even if the lookups haven't finished: they carry on,
    /// and the next read finds their ratings.
    func resolve(
        _ songs: some Sequence<Song>,
        lookup: @escaping CatalogLookup,
        library: LibraryPage?,
        deadline: (@Sendable () async -> Void)? = nil
    ) async {
        let songs = Array(songs)
        guard let deadline else {
            await resolveNow(songs, lookup: lookup, library: library)
            return
        }
        let work = Task { await self.resolveNow(songs, lookup: lookup, library: library) }
        await Self.first(of: work, or: deadline)
    }

    private func resolveNow(_ songs: [Song], lookup: @escaping CatalogLookup, library: LibraryPage?) async {
        var seen: Set<String> = []
        var missing: [String] = []
        func ask(_ catalogID: String) {
            guard seen.insert(catalogID).inserted else { return }
            if lock.withLock({ explicitByCatalogID.value(forKey: catalogID) }) == nil { missing.append(catalogID) }
        }
        var unmapped: [String] = []
        for song in songs where song.contentRating == nil {
            if let catalogID = catalogID(of: song) {
                ask(catalogID)
            } else if isUnmappedLibraryRow(song) {
                unmapped.append(song.id.rawValue)
            }
        }
        if !unmapped.isEmpty, let library, await readLibrary(library) {
            for persistentID in unmapped {
                let catalogID: String = lock.withLock {
                    if let known = catalogIDsByPersistentID.value(forKey: persistentID) { return known }
                    // The library has no such song: nothing to ask, and no reason to read it again.
                    catalogIDsByPersistentID.setValue("", forKey: persistentID)
                    return ""
                }
                if !catalogID.isEmpty { ask(catalogID) }
            }
        }
        guard !missing.isEmpty else { return }
        // As many IDs per lookup as MusicKit's ID filter takes elsewhere.
        let batches = MusicKitLibraryLookup.batches(missing)
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
    }

    private func store(_ batch: [String], lookup: CatalogLookup) async {
        guard let ratings = try? await lookup(batch) else { return }
        lock.withLock {
            // An ID the catalog doesn't list (gone from this storefront) reads as clean, as
            // before, and isn't asked about again.
            for id in batch { explicitByCatalogID.setValue(ratings[id] ?? false, forKey: id) }
        }
    }

    // MARK: - Releases

    /// The catalog release a song names, directly or through the library song with its
    /// persistent ID; `nil` for a catalog song, an upload, and a library row not mapped yet.
    private func catalogID(of song: Song) -> String? {
        switch release(of: song) {
        case let .catalog(id): return id
        case .none: return nil
        case .libraryRow:
            let id = lock.withLock { catalogIDsByPersistentID.value(forKey: song.id.rawValue) }
            return id?.isEmpty == false ? id : nil
        }
    }

    private func isUnmappedLibraryRow(_ song: Song) -> Bool {
        guard case .libraryRow = release(of: song) else { return false }
        return lock.withLock { catalogIDsByPersistentID.value(forKey: song.id.rawValue) } == nil
    }

    private func release(of song: Song) -> Release {
        let songID = song.id.rawValue
        // Catalog songs carry their own rating (or have none to give).
        guard !MusicKitLibraryLookup.isCatalogID(songID) else { return .none }
        if let known = lock.withLock({ releasesBySongID.value(forKey: songID) }) { return known }
        let parameters = Self.identifiers(of: song.playParameters)
        let catalogID = (parameters.catalogID ?? AppleMusicSongIdentity(encoding: song).catalogID)
            .flatMap { $0 != songID && MusicKitLibraryLookup.isCatalogID($0) ? $0 : nil }
        let release: Release = if let catalogID {
            .catalog(catalogID)
        } else if MusicKitLibraryLookup.isPersistentID(songID) {
            .libraryRow
        } else {
            .none
        }
        lock.withLock {
            releasesBySongID.setValue(release, forKey: songID)
            // A library song tells what its playlist and album rows name.
            if let persistentID = parameters.persistentID, persistentID != songID {
                catalogIDsByPersistentID.setValue(catalogID ?? "", forKey: persistentID)
            }
        }
        return release
    }

    // MARK: - Reading the library

    /// Reads the whole library once for the catalog ID behind each persistent ID; `false` when
    /// it failed, so nothing is concluded from it.
    private func readLibrary(_ page: @escaping LibraryPage) async -> Bool {
        let read: Task<Bool, Never> = lock.withLock {
            if let running = libraryRead { return running }
            let read = Task { await self.readWholeLibrary(page) }
            libraryRead = read
            return read
        }
        let succeeded = await read.value
        lock.withLock { if libraryRead == read { libraryRead = nil } }
        return succeeded
    }

    private func readWholeLibrary(_ page: LibraryPage) async -> Bool {
        var offset = 0
        while offset < Self.maxLibrarySongs {
            guard let songs = try? await page(min(Self.libraryPageSize, Self.maxLibrarySongs - offset), offset) else { return false }
            var learned: [(persistentID: String, catalogID: String)] = []
            for song in songs {
                let ids = Self.identifiers(of: song.playParameters)
                guard let persistentID = ids.persistentID else { continue }
                let catalogID = ids.catalogID.flatMap { MusicKitLibraryLookup.isCatalogID($0) ? $0 : nil }
                learned.append((persistentID, catalogID ?? ""))
            }
            lock.withLock {
                for (persistentID, catalogID) in learned {
                    catalogIDsByPersistentID.setValue(catalogID, forKey: persistentID)
                }
            }
            offset += songs.count
            if songs.count < Self.libraryPageSize { break }
        }
        return true
    }

    /// `catalogId` and `musicKit_persistentID` from the play parameters alone: much cheaper than
    /// encoding the whole song, which is only needed when they don't carry the catalog ID.
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
    }

    /// Resumes a continuation once, from whichever side gets there first.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        func hold(_ continuation: CheckedContinuation<Void, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func open() {
            let continuation = lock.withLock {
                let held = self.continuation
                self.continuation = nil
                return held
            }
            continuation?.resume()
        }
    }
}
