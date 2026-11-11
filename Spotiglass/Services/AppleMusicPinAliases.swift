import Foundation
import MusicKit

/// The other IDs of the Apple Music items the app has shown, so a pin knows a library item and
/// its catalog copy are one item (#487).
///
/// Home and catalog artist pages name an album by its catalog ID, Search and the library by its
/// library ID, and pins are keyed by that ID. Two ways tie them together:
/// - A saved song or artist carries its catalog ID, which only encoding the item reveals (about a
///   quarter of a millisecond), so those items are kept as they are mapped and their catalog ID
///   is read the first time a pin asks.
/// - A saved album doesn't: on macOS MusicKit lists it under the Music app's persistent ID and
///   writes no catalog ID at all, nor a rating. A saved album is matched to a catalog album by
///   title and artist instead (``AppleMusicItemMapping/albumPinKey(_:)``). A key alone doesn't
///   prove it: the catalog often has a clean and an explicit release, two different releases can
///   share a name (two "Greatest Hits"), and a saved album may not be in the catalog at all. So a
///   pair counts only once a search finds exactly one saved album under the key and the catalog
///   release it is: the only one, or the only one out on the saved album's release day, with the
///   same number of tracks when both say. Until then, and when it's ambiguous, they stay apart.
/// Bounded to `capacity` entries per table, least recently used first out; memory only.
final class AppleMusicPinAliasRegistry: @unchecked Sendable {
    static let shared = AppleMusicPinAliasRegistry()
    static let capacity = 20_000

    private enum Entry {
        /// A library item not asked about yet: reads the catalog ID it carries.
        case pending(@Sendable () -> String?)
        /// The other pin ID of the item, or `nil` when it has none.
        case resolved(String?)
    }

    private let lock = NSLock()
    /// Bumped whenever what the registry can answer changes, so callers can cache answers.
    private var changeCount = 0
    /// By pin ID; a worked-out pair is stored in both directions.
    private var entries: LRUDictionary<String, Entry>
    /// An album's match key, by pin ID.
    private var albumKeys: LRUDictionary<String, String>
    /// What is known under each album match key.
    private var albumsByKey: LRUDictionary<String, AlbumKey>

    private struct AlbumKey {
        /// The album pin IDs seen under the key: saved copies and catalog copies.
        var pinIDs: Set<String> = []
        /// What a search for it asks for.
        var query: AppleMusicAlbumQuery
        /// The catalog albums a search found under the key; `nil` until searched.
        var catalogPinIDs: Set<String>?
        /// The saved albums the same search found in the library; `nil` until searched.
        var libraryPinIDs: Set<String>?
        /// Track count and release day of the albums under the key, where known.
        var details: [String: AppleMusicAlbumDetail] = [:]
        /// True while (or once) a search was started, so it's asked for only once a session.
        var isSearching = false
    }

    init(capacity: Int = AppleMusicPinAliasRegistry.capacity) {
        entries = LRUDictionary(capacity: capacity)
        albumKeys = LRUDictionary(capacity: capacity)
        albumsByKey = LRUDictionary(capacity: capacity)
    }

    /// Keeps a library item whose catalog ID `catalogID` reads on demand. Catalog items are
    /// skipped: only the library side knows the pair.
    func register(kind: PinnedItemKind, itemID: String, catalogID: @escaping @Sendable () -> String?) {
        guard Self.isLibraryID(itemID) else { return }
        let pinID = PinnedItem.id(forKind: kind, spotifyID: itemID)
        lock.withLock {
            if entries.value(forKey: pinID) != nil { return }
            entries.setValue(.pending(catalogID), forKey: pinID)
            changeCount &+= 1
        }
    }

    /// Changes whenever an answer of ``aliases(ofPinID:)`` may have changed.
    var generation: Int {
        lock.withLock { changeCount }
    }

    /// Keeps an album, library or catalog, under its match key.
    func register(albumID: String, matchKey: String, query: AppleMusicAlbumQuery, detail: AppleMusicAlbumDetail) {
        let pinID = PinnedItem.id(forKind: .album, spotifyID: albumID)
        lock.withLock {
            if let old = albumKeys.value(forKey: pinID), old != matchKey,
               var oldKey = albumsByKey.value(forKey: old) {
                oldKey.pinIDs.remove(pinID)
                albumsByKey.setValue(oldKey, forKey: old)
            }
            albumKeys.setValue(matchKey, forKey: pinID)
            var key = albumsByKey.value(forKey: matchKey) ?? AlbumKey(query: query)
            let isNew = key.pinIDs.insert(pinID).inserted
            key.details[pinID] = detail
            albumsByKey.setValue(key, forKey: matchKey)
            if isNew { changeCount &+= 1 }
        }
    }

    /// The key and query of this album when a saved copy and a catalog copy were seen under it
    /// and no search has been asked for yet; marks the search as asked for.
    func takeUnsearchedKey(ofPinID pinID: String) -> (key: String, query: AppleMusicAlbumQuery)? {
        lock.withLock {
            guard let keyName = albumKeys.value(forKey: pinID),
                  var key = albumsByKey.value(forKey: keyName),
                  key.catalogPinIDs == nil, !key.isSearching,
                  key.pinIDs.contains(where: Self.isSavedAlbum),
                  key.pinIDs.contains(where: { !Self.isSavedAlbum($0) })
            else { return nil }
            key.isSearching = true
            albumsByKey.setValue(key, forKey: keyName)
            return (keyName, key.query)
        }
    }

    /// Records the albums a search found under `key`: catalog releases and saved albums, each
    /// with its track count and release day when known.
    func recordSearch(key keyName: String, catalog: [String: AppleMusicAlbumDetail], library: [String: AppleMusicAlbumDetail]) {
        func pinIDs(_ albums: [String: AppleMusicAlbumDetail]) -> [String: AppleMusicAlbumDetail] {
            Dictionary(albums.map { (PinnedItem.id(forKind: .album, spotifyID: $0.key), $0.value) }) { first, _ in first }
        }
        let catalog = pinIDs(catalog)
        let library = pinIDs(library)
        lock.withLock {
            guard var key = albumsByKey.value(forKey: keyName) else { return }
            key.catalogPinIDs = Set(catalog.keys)
            key.libraryPinIDs = Set(library.keys)
            for (pinID, detail) in catalog.merging(library, uniquingKeysWith: { first, _ in first }) {
                key.details[pinID] = detail
            }
            albumsByKey.setValue(key, forKey: keyName)
            changeCount &+= 1
        }
    }

    /// Records a pair found another way (a library lookup).
    func learn(pinID: String, alias: String) {
        guard pinID != alias else { return }
        lock.withLock {
            entries.setValue(.resolved(alias), forKey: pinID)
            entries.setValue(.resolved(pinID), forKey: alias)
            changeCount &+= 1
        }
    }

    /// Every other pin ID of the same item the registry knows or can work out.
    func aliases(ofPinID pinID: String) -> Set<String> {
        var result = lock.withLock {
            albumKeys.value(forKey: pinID).flatMap { albumsByKey.value(forKey: $0) }.map { Self.albumPair($0, for: pinID) } ?? []
        }
        if let alias = alias(ofPinID: pinID) { result.insert(alias) }
        result.remove(pinID)
        return result
    }

    /// The album pin IDs under one key that are one album, when `pinID` is one of them: the one
    /// saved album known under the key (from the search and from what the app showed) and the
    /// catalog release it is. That's the only release, or among several (clean and explicit) the
    /// only one out on the saved album's release day; with the same release day and number of
    /// tracks when both say. Before the search, or when it's still ambiguous, it pairs nothing: a release the
    /// search missed but the app showed counts too.
    private static func albumPair(_ key: AlbumKey, for pinID: String) -> Set<String> {
        guard let searchedCatalog = key.catalogPinIDs, let searchedLibrary = key.libraryPinIDs else { return [] }
        let seenSaved = key.pinIDs.filter(isSavedAlbum)
        let catalog = searchedCatalog.union(key.pinIDs.subtracting(seenSaved))
        let library = searchedLibrary.union(seenSaved)
        guard library.count == 1, let saved = library.first else { return [] }
        let savedDetail = key.details[saved]
        var releases = catalog
        if releases.count > 1, let day = savedDetail?.releaseDay {
            releases = releases.filter { key.details[$0]?.releaseDay == day }
        }
        guard releases.count == 1, let release = releases.first, pinID == release || pinID == saved else { return [] }
        // Even the only release must agree where both say: a search can miss the saved album's
        // own release and list just another one of that name.
        let releaseDetail = key.details[release]
        if let releaseTracks = releaseDetail?.trackCount, let savedTracks = savedDetail?.trackCount,
           releaseTracks != savedTracks {
            return []
        }
        if let releaseDay = releaseDetail?.releaseDay, let savedDay = savedDetail?.releaseDay, releaseDay != savedDay {
            return []
        }
        return [release, saved]
    }

    private static func isSavedAlbum(_ pinID: String) -> Bool {
        PinnedItem.itemID(ofPinID: pinID).map(isLibraryID) == true
    }

    /// The other pin ID a library item's catalog ID names, when known or readable.
    private func alias(ofPinID pinID: String) -> String? {
        let thunk: @Sendable () -> String?
        switch lock.withLock({ entries.value(forKey: pinID) }) {
        case nil: return nil
        case let .resolved(alias): return alias
        case let .pending(read): thunk = read
        }
        // Read outside the lock: encoding the item is the slow part.
        let alias = PinnedItem.kind(ofPinID: pinID).flatMap { kind in
            thunk().flatMap { $0.isEmpty ? nil : PinnedItem.id(forKind: kind, spotifyID: $0) }
        }
        lock.withLock {
            entries.setValue(.resolved(alias), forKey: pinID)
            if let alias { entries.setValue(.resolved(pinID), forKey: alias) }
        }
        return alias
    }

    /// Library IDs start with `i.`, `l.`, `p.` or `r.`, or are a long persistent ID; catalog IDs
    /// are short numbers (`pl.…` for catalog playlists).
    static func isLibraryID(_ id: String) -> Bool {
        if MusicKitLibraryLookup.isCatalogID(id) || id.hasPrefix("pl.") { return false }
        return ["i.", "l.", "p.", "r."].contains { id.hasPrefix($0) } || MusicKitLibraryLookup.isPersistentID(id)
    }
}

/// What an album search asks for: its title and artist.
struct AppleMusicAlbumQuery: Sendable, Equatable {
    var title: String
    var artist: String
}

/// What tells two releases of one name apart: track count and release day, where known.
struct AppleMusicAlbumDetail: Sendable, Equatable {
    var trackCount: Int?
    /// `yyyy-MM-dd` in UTC: a saved album and its catalog release share it, while a clean and an
    /// explicit release of one album are often a day apart.
    var releaseDay: String?

    init(_ album: Album) {
        trackCount = album.trackCount
        releaseDay = album.releaseDate.map { Self.dayFormat.string(from: $0) }
    }

    private static let dayFormat: DateFormatter = {
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd"
        return format
    }()
}

/// What one album search found: catalog releases and saved albums.
struct AppleMusicAlbumSearch: Sendable {
    var catalog: [Album]
    var library: [Album]
}

/// Apple Music's side of one pin identity: the registry for items on screen, the library and the
/// catalog for pins the app hasn't shown since launch.
@MainActor
final class AppleMusicPinAliases: PinnedItemAliasResolving {
    let registry: AppleMusicPinAliasRegistry
    /// Looks song, artist or playlist pins of one kind up in the library, up to
    /// ``MusicKitLibraryLookup/batchSize`` IDs at a time: the other ID of each it found (one it
    /// didn't find has none). Throws when the library couldn't be asked, so those pins are asked
    /// again next launch instead of counting as checked. Replaced in tests.
    let lookUp: @Sendable (PinnedItemKind, [String]) async throws -> [String: String]
    /// Loads pinned albums by ID, from the library and the catalog; replaced in tests.
    let albums: @Sendable ([String]) async throws -> [Album]
    /// Searches the catalog and the library for albums by a title and artist; replaced in tests.
    let searchAlbums: @Sendable (AppleMusicAlbumQuery) async throws -> AppleMusicAlbumSearch
    /// The other IDs of songs the app read from library playlists and albums (#401): those rows
    /// are keyed by a persistent ID that often carries no catalog ID of its own.
    let songReferences: AppleMusicSongReferenceRegistry
    var aliasesDidChange: (() -> Void)?
    /// Catalog searches run one after another, so browsing a page of albums never fires a burst.
    private var searches: Task<Void, Never>?

    init(
        registry: AppleMusicPinAliasRegistry = .shared,
        lookUp: @escaping @Sendable (PinnedItemKind, [String]) async throws -> [String: String] = { kind, itemIDs in
            try await MusicKitContentSource.pinAliases(kind: kind, itemIDs: itemIDs)
        },
        albums: @escaping @Sendable ([String]) async throws -> [Album] = { ids in
            try await MusicKitContentSource.pinnedAlbums(ids: ids)
        },
        searchAlbums: @escaping @Sendable (AppleMusicAlbumQuery) async throws -> AppleMusicAlbumSearch = { query in
            try await MusicKitContentSource.albums(matching: query)
        },
        songReferences: AppleMusicSongReferenceRegistry = .shared
    ) {
        self.registry = registry
        self.lookUp = lookUp
        self.albums = albums
        self.searchAlbums = searchAlbums
        self.songReferences = songReferences
    }

    func handles(userID: String) -> Bool {
        userID == AppleMusicBrowsingProvider.libraryUserID
    }

    var aliasGeneration: Int {
        registry.generation
    }

    func knownAliases(ofPinID pinID: String, checkingAlbum: Bool) -> Set<String> {
        if checkingAlbum, let (key, query) = registry.takeUnsearchedKey(ofPinID: pinID) {
            let search = enqueueSearch(key: key, query: query)
            Task { [weak self] in
                guard await search.value else { return }
                self?.aliasesDidChange?()
            }
        }
        var aliases = registry.aliases(ofPinID: pinID)
        if PinnedItem.kind(ofPinID: pinID) == .track, let itemID = PinnedItem.itemID(ofPinID: pinID),
           let reference = songReferences.reference(for: itemID) {
            aliases.formUnion(reference.matchKeys.map { PinnedItem.id(forKind: .track, spotifyID: $0) })
            aliases.remove(pinID)
        }
        return aliases
    }

    /// Starts a search after the ones already waiting, so they never run side by side.
    private func enqueueSearch(key: String, query: AppleMusicAlbumQuery) -> Task<Bool, Never> {
        let previous = searches
        let search = Task { [weak self] () -> Bool in
            await previous?.value
            guard let self else { return false }
            return await self.searchAlbums(key: key, query: query)
        }
        searches = Task { _ = await search.value }
        return search
    }

    /// Asks the catalog and the library which albums they have under a key. True when they
    /// answered.
    private func searchAlbums(key: String, query: AppleMusicAlbumQuery) async -> Bool {
        func underKey(_ albums: [Album]) -> [String: AppleMusicAlbumDetail] {
            Dictionary(
                albums.filter { AppleMusicItemMapping.albumPinKey($0) == key }
                    .map { ($0.id.rawValue, AppleMusicAlbumDetail($0)) }
            ) { first, _ in first }
        }
        do {
            let found = try await searchAlbums(query)
            registry.recordSearch(key: key, catalog: underKey(found.catalog), library: underKey(found.library))
            return true
        } catch {
            // Left unsearched for this session: the two copies stay apart, which loses nothing.
            SpotiglassLog.error(SpotiglassLog.pinning, "Album identity search failed: \(error.localizedDescription)")
            return false
        }
    }

    func lookUpAliases(of pins: [PinnedItem], userID: String) async -> [String: Set<String>]? {
        // Spotify pins have one ID each and are left exactly as they are.
        guard handles(userID: userID) else { return nil }
        var found: [String: Set<String>] = [:]

        // Every album pin, checked or not: loading them teaches the registry their match keys,
        // so the other copy shows as pinned wherever it appears.
        let albumPins = pins.filter { $0.kind == .album }
        let albumIDs = albumPins.compactMap { PinnedItem.itemID(ofPinID: $0.id) }
        if !albumIDs.isEmpty {
            do {
                for album in try await albums(albumIDs) {
                    AppleMusicItemMapping.registerAlbumPin(album, in: registry)
                }
                // Pinned albums that share a key with another copy: the search decides.
                for pin in albumPins {
                    guard !Task.isCancelled else { break }
                    if let (key, query) = registry.takeUnsearchedKey(ofPinID: pin.id) {
                        _ = await enqueueSearch(key: key, query: query).value
                    }
                }
                for pin in albumPins { found[pin.id] = registry.aliases(ofPinID: pin.id) }
            } catch {
                SpotiglassLog.error(SpotiglassLog.pinning, "Pinned album lookup failed: \(error.localizedDescription)")
            }
        }

        // Songs, artists and playlists never checked: the library, one request per kind and batch.
        var unchecked: [PinnedItemKind: [String]] = [:]
        for pin in pins where pin.kind != .album && pin.kind != .likedSongs && pin.aliasIDs == nil {
            guard let itemID = PinnedItem.itemID(ofPinID: pin.id) else { continue }
            let known = registry.aliases(ofPinID: pin.id)
            if known.isEmpty {
                unchecked[pin.kind, default: []].append(itemID)
            } else {
                found[pin.id] = known
            }
        }
        for kind in [PinnedItemKind.track, .artist, .playlist] {
            for batch in MusicKitLibraryLookup.batches(unchecked[kind] ?? []) {
                guard !Task.isCancelled else { return found }
                let others: [String: String]
                do {
                    others = try await lookUp(kind, batch)
                } catch {
                    SpotiglassLog.error(SpotiglassLog.pinning, "Pin identity lookup failed: \(error.localizedDescription)")
                    continue
                }
                for itemID in batch {
                    let pinID = PinnedItem.id(forKind: kind, spotifyID: itemID)
                    guard let other = others[itemID], other != itemID else {
                        found[pinID] = []
                        continue
                    }
                    let alias = PinnedItem.id(forKind: kind, spotifyID: other)
                    registry.learn(pinID: pinID, alias: alias)
                    found[pinID] = [alias]
                }
            }
        }
        return found
    }
}
