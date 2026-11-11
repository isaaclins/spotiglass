import Combine
import Foundation

/// Other IDs a service knows one pinned item by. Apple Music names an album by its catalog ID
/// on Home and catalog artist pages and by its library ID in Search and the library; both must
/// be one pin (#487). Spotify has one ID per item and needs none of this.
@MainActor
protocol PinnedItemAliasResolving: AnyObject {
    /// True when `userID` is an account of this service; other accounts' pins are never asked about.
    func handles(userID: String) -> Bool
    /// Pin IDs of the same item known right now, without waiting. `checkingAlbum` lets it start
    /// the check that can prove two album copies are one (for a pinned item, not a row's query);
    /// ``aliasesDidChange`` reports what that check found.
    func knownAliases(ofPinID pinID: String, checkingAlbum: Bool) -> Set<String>
    /// Called on the main actor when a check found new IDs of an item.
    var aliasesDidChange: (() -> Void)? { get set }
    /// Changes whenever an answer of ``knownAliases(ofPinID:checkingAlbum:)`` may have changed.
    var aliasGeneration: Int { get }
    /// Looks the other IDs of these pins up, for pins the app hasn't shown both ways yet. One
    /// entry per pin it could check (empty when there are none); `nil` when `userID` is not an
    /// account of this service.
    func lookUpAliases(of pins: [PinnedItem], userID: String) async -> [String: Set<String>]?
}

/// Source of truth for the pinned-items sidebar list.
///
/// Persists per Spotify user ID so a single Mac running multiple accounts (or
/// signing in / out across accounts) keeps each account's pins isolated.
@MainActor
final class PinnedItemsStore: ObservableObject {
    @Published private(set) var items: [PinnedItem] = []
    /// True when the account lookup that the pinned list depends on failed, so
    /// an empty list means "could not load" rather than "no pins". The sidebar
    /// uses this to offer a retry instead of rendering as if the user had never
    /// pinned anything (#133).
    @Published private(set) var didFailToBind = false

    private let cache: PinnedItemsCache?
    private let resolver: PinnedItemAliasResolving?
    /// The resolver while the bound account is one of its service's; `nil` otherwise, so a
    /// Spotify list does exactly the work it did before.
    private var aliases: PinnedItemAliasResolving? {
        guard let resolver, let boundUserID, resolver.handles(userID: boundUserID) else { return nil }
        return resolver
    }
    private(set) var boundUserID: String?
    /// Invalidates profile lookups that started before a sign-out or reconnect.
    private(set) var bindingGeneration = 0
    /// The covers of the playlists listed or found so far, by playlist ID, so pins that are
    /// loaded after the list (the account is bound later, a service switch) get them too (#477).
    private var knownPlaylistCovers: [String: URL] = [:]
    /// Bounds `knownPlaylistCovers`: past it the map starts over from the next list.
    static let maxKnownPlaylistCovers = 10_000

    /// The cover the app knows for a pin ID from elsewhere, for a playlist pin saved without
    /// one that no list names by its ID: a shared Apple Music playlist pinned from Search is
    /// pinned under its catalog ID, which the library listing keeps its cover under (#477).
    private let knownArtwork: (String) -> URL?

    private var aliasLookup: Task<Void, Never>?
    /// Each pin's IDs, worked out once per pin and alias change instead of for every row that
    /// asks whether it's pinned. An entry holds the `aliasIDs` it was worked out from, so a pin
    /// whose aliases changed is worked out again; the rest stay as they are when pins are added.
    private var pinIdentityCache: [String: (aliasIDs: [String]?, keys: Set<String>)] = [:]
    private var pinIdentityGeneration = -1
    /// Pins made since the last lookup started: pinning a whole selection looks them up together.
    private var pendingPinLookups: [PinnedItem] = []
    private var isMergeScheduled = false

    init(
        cache: PinnedItemsCache?,
        aliases: PinnedItemAliasResolving? = nil,
        knownArtwork: @escaping (String) -> URL? = { _ in nil }
    ) {
        self.cache = cache
        self.knownArtwork = knownArtwork
        self.resolver = aliases
        aliases?.aliasesDidChange = { [weak self] in self?.aliasesChanged() }
    }

    /// Bind the store to a Spotify user ID. Loads that account's pinned list
    /// from disk; passing `nil` clears the in-memory list (used at sign-out).
    /// An optional generation rejects a result from an older account lookup.
    func bind(userID: String?, bindingGeneration: Int? = nil) {
        if let bindingGeneration, bindingGeneration != self.bindingGeneration {
            return
        }
        boundUserID = userID
        didFailToBind = false
        aliasLookup?.cancel()
        pendingPinLookups = []
        guard let userID, let cache else {
            items = []
            return
        }
        if let loaded = try? cache.loadPinnedItems(userID: userID) {
            let migrated = mergingSameItems(PinnedItem.migrateLegacyTrackPins(loaded))
            let filled = fillingMissingPlaylistArtwork(migrated, from: knownPlaylistCovers)
            items = filled
            if filled != loaded {
                persist()
            }
            aliasLookup = lookUpAliases(of: items)
        } else {
            items = []
            SpotiglassLog.error(SpotiglassLog.pinning, "Failed to load pinned items for user")
        }
    }

    /// Records that the account could not be resolved, after the caller has
    /// exhausted its retries.
    func reportBindingFailure() {
        guard boundUserID == nil else { return }
        didFailToBind = true
    }

    /// Returns `true` if the item was newly pinned, `false` if it was already
    /// pinned. Optional ``index`` inserts at a specific position; clamping is
    /// applied so callers don't have to bounds-check.
    @discardableResult
    func pin(_ item: PinnedItem, at index: Int? = nil) -> Bool {
        var normalizedItem = item.migratedLegacyTrackPin()
        let known = normalizedItem.identityIDs.union(aliases?.knownAliases(ofPinID: normalizedItem.id, checkingAlbum: false) ?? [])
        guard !known.contains(where: isPinned(id:)) else { return false }
        let others = known.subtracting([normalizedItem.id])
        if !others.isEmpty { normalizedItem.aliasIDs = others.sorted() }
        let clamped: Int
        if let index {
            clamped = max(0, min(index, items.count))
        } else {
            clamped = items.count
        }
        items.insert(normalizedItem, at: clamped)
        persist()
        // Its own lookup, not the launch one (cancelling that would drop the pins it was
        // checking), shared with the other pins made in the same pass.
        lookUpAliasesSoon(normalizedItem)
        return true
    }

    /// Removes the pin `id` names, by any of the item's IDs.
    func unpin(id: String) {
        let queryKeys = identityKeys(ofQuery: id)
        let kind = PinnedItem.kind(ofPinID: id)
        let matches: (PinnedItem) -> Bool = { $0.answers(to: id) || ($0.kind == kind && self.isSameItem($0, queryKeys)) }
        guard items.contains(where: matches) else { return }
        items.removeAll(where: matches)
        persist()
    }

    /// Direct-index move used by drop targets that compute insertion indices
    /// against the current (post-removal) array layout. Avoids the +/-1
    /// bookkeeping callers would otherwise have to do themselves.
    func reorder(itemID: String, toInsertionIndex insertionIndex: Int) {
        guard let source = items.firstIndex(where: { $0.id == itemID }) else { return }
        let withoutSource = items.enumerated().filter { $0.offset != source }.map(\.element)
        let clamped = max(0, min(insertionIndex, withoutSource.count))
        var next = withoutSource
        next.insert(items[source], at: clamped)
        guard next != items else { return }
        items = next
        persist()
    }

    /// Reorders the pinned list to match ``orderedIDs`` (the visible Library
    /// row order). Items missing from ``orderedIDs`` keep their relative order
    /// at the end; unknown IDs are ignored, so a stale order can never drop
    /// or invent pins.
    func applyOrder(_ orderedIDs: [String]) {
        var next: [PinnedItem] = []
        for id in orderedIDs {
            if let item = items.first(where: { $0.id == id }) {
                next.append(item)
            }
        }
        next.append(contentsOf: items.filter { item in !orderedIDs.contains(item.id) })
        guard next != items else { return }
        items = next
        persist()
    }

    /// True when `id` or another ID of the same item is pinned.
    func isPinned(id: String) -> Bool {
        if items.contains(where: { $0.answers(to: id) }) { return true }
        guard aliases != nil, let kind = PinnedItem.kind(ofPinID: id) else { return false }
        let queryKeys = identityKeys(ofQuery: id)
        // Only pins of the same kind can be the same item.
        return items.contains { $0.kind == kind && isSameItem($0, queryKeys) }
    }

    /// The other pin IDs the service knows for `id` right now, pinned or not: a saved Apple
    /// Music playlist's catalog copy. Lets a list that shows both copies show the item once (#523).
    /// Empty for Spotify.
    func otherPinIDs(ofPinID id: String) -> Set<String> {
        aliases?.knownAliases(ofPinID: id, checkingAlbum: false).subtracting([id]) ?? []
    }

    // MARK: - One identity per item (#487)

    /// `id` and the other IDs the service knows for it right now. Only asked when a pin of the
    /// same kind exists, so a long track list without track pins never works anything out.
    private func identityKeys(ofQuery id: String) -> Set<String> {
        guard let aliases,
              let kind = PinnedItem.kind(ofPinID: id),
              items.contains(where: { $0.kind == kind })
        else { return [id] }
        return aliases.knownAliases(ofPinID: id, checkingAlbum: false).union([id])
    }

    /// A pin's IDs. Asking about a pinned album may start the check that pairs it with the other
    /// copy on screen; when that finds a pair, ``aliasesChanged()`` refreshes the list.
    private func identityKeys(of item: PinnedItem, checkingAlbum: Bool = true) -> Set<String> {
        guard let aliases else { return item.identityIDs }
        guard checkingAlbum else {
            return item.identityIDs.union(aliases.knownAliases(ofPinID: item.id, checkingAlbum: false))
        }
        if pinIdentityGeneration != aliases.aliasGeneration || pinIdentityCache.count > 2 * items.count + 16 {
            pinIdentityCache = [:]
            pinIdentityGeneration = aliases.aliasGeneration
        }
        if let cached = pinIdentityCache[item.id], cached.aliasIDs == item.aliasIDs { return cached.keys }
        let keys = item.identityIDs.union(aliases.knownAliases(ofPinID: item.id, checkingAlbum: true))
        pinIdentityCache[item.id] = (item.aliasIDs, keys)
        // A pin that turns out to name another pin (a playlist row read since launch tells a
        // song's other IDs): fold them together once this pass is over.
        if keys.count > item.identityIDs.count, items.contains(where: { $0.id != item.id && keys.contains($0.id) }) {
            mergeSoon()
        }
        return keys
    }

    private func isSameItem(_ item: PinnedItem, _ queryKeys: Set<String>) -> Bool {
        !identityKeys(of: item).isDisjoint(with: queryKeys)
    }

    /// Folds pins of the same item into the first one, which keeps its place and gains the
    /// others' IDs. One pass with an index by ID, so a long list isn't compared pin by pin, and
    /// a pin that ties two earlier ones together folds all three.
    private func mergingSameItems(_ list: [PinnedItem]) -> [PinnedItem] {
        var groups: [(item: PinnedItem, keys: Set<String>, absorbed: Bool)?] = []
        var groupOfKey: [String: Int] = [:]
        for item in list {
            let itemKeys = identityKeys(of: item, checkingAlbum: false)
            let hits = Set(itemKeys.compactMap { groupOfKey[$0] }).sorted()
            guard let target = hits.first, var group = groups[target] else {
                groups.append((item, itemKeys, false))
                for key in itemKeys { groupOfKey[key] = groups.count - 1 }
                continue
            }
            group.keys.formUnion(itemKeys)
            group.absorbed = true
            // Stale only when every copy is: a copy that still opens keeps the pin working.
            group.item.isStale = group.item.isStale && item.isStale
            for other in hits.dropFirst() {
                guard let folded = groups[other] else { continue }
                group.keys.formUnion(folded.keys)
                group.item.isStale = group.item.isStale && folded.item.isStale
                groups[other] = nil
            }
            groups[target] = group
            for key in group.keys { groupOfKey[key] = target }
        }
        return groups.compactMap { group in
            guard var group else { return nil }
            if group.absorbed { group.item.aliasIDs = group.keys.subtracting([group.item.id]).sorted() }
            return group.item
        }
    }

    /// Merges pins found to be one item while drawing, after the current pass: never in the middle
    /// of a view update.
    private func mergeSoon() {
        guard !isMergeScheduled else { return }
        isMergeScheduled = true
        let generation = bindingGeneration
        Task { [weak self] in
            guard let self else { return }
            self.isMergeScheduled = false
            guard self.bindingGeneration == generation else { return }
            self.aliasesChanged()
        }
    }

    /// Looks this pin up together with the other pins made before the main actor is free again,
    /// so pinning a whole selection is one lookup and one merge, not one per row.
    private func lookUpAliasesSoon(_ pin: PinnedItem) {
        guard aliases != nil else { return }
        pendingPinLookups.append(pin)
        guard pendingPinLookups.count == 1 else { return }
        let generation = bindingGeneration
        Task { [weak self] in
            // After a sign-out the list was emptied, and pins made since belong to the task the
            // next pin started: leave them to it.
            guard let self, self.bindingGeneration == generation else { return }
            let pins = self.pendingPinLookups
            self.pendingPinLookups = []
            self.lookUpAliases(of: pins)
        }
    }

    /// Asks the service for the other IDs of these pins, then merges pins that turn out to be
    /// the same item. Pins of another service are left untouched.
    @discardableResult
    private func lookUpAliases(of pins: [PinnedItem]) -> Task<Void, Never>? {
        guard let aliases, let userID = boundUserID else { return nil }
        let pins = pins.filter { $0.kind != .likedSongs }
        guard !pins.isEmpty else { return nil }
        let generation = bindingGeneration
        return Task { [weak self] in
            guard let found = await aliases.lookUpAliases(of: pins, userID: userID),
                  !Task.isCancelled, let self,
                  self.boundUserID == userID, self.bindingGeneration == generation
            else { return }
            self.applyLookedUpAliases(found)
        }
    }

    /// A check proved two copies of an item are one: record the new IDs on the pins, merge pins
    /// that turn out to be the same item, and redraw rows that now show as pinned.
    private func aliasesChanged() {
        guard let aliases else { return }
        var found: [String: Set<String>] = [:]
        for item in items {
            let known = aliases.knownAliases(ofPinID: item.id, checkingAlbum: false)
            if !known.isEmpty { found[item.id] = known }
        }
        if !applyLookedUpAliases(found) { objectWillChange.send() }
    }

    /// Records looked-up IDs (an empty list marks a pin as checked) and merges duplicates.
    /// True when the list changed.
    @discardableResult
    private func applyLookedUpAliases(_ found: [String: Set<String>]) -> Bool {
        var next = items
        for index in next.indices {
            guard let more = found[next[index].id] else { continue }
            let all = Set(next[index].aliasIDs ?? []).union(more).subtracting([next[index].id])
            next[index].aliasIDs = all.sorted()
        }
        next = mergingSameItems(next)
        guard next != items else { return false }
        items = next
        persist()
        return true
    }

    /// Convenience: stable-id lookup for source surfaces that only know their
    /// Spotify ID + kind (track row, album card, artist header, …).
    func isPinned(spotifyID: String, kind: PinnedItemKind) -> Bool {
        let pinID = PinnedItem.id(forKind: kind, spotifyID: spotifyID)
        if isPinned(id: pinID) { return true }
        guard kind == .track else { return false }
        return items.contains {
            $0.kind == .track
                && PinnedItem.canonicalTrackID(fromSpotifyURI: $0.spotifyURI) == spotifyID
        }
    }

    func markStale(id: String, _ stale: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == id }), items[idx].isStale != stale else { return }
        items[idx].isStale = stale
        persist()
    }

    /// Gives playlist pins saved without a cover the one their playlist has now. Apple Music
    /// playlists without a picture of their own were once listed without Apple's generated
    /// cover, so pins made then kept the placeholder for good (#477). A pin that has a cover
    /// keeps it, unless it's a `musicKit://` one and a cover that loads on its own is offered.
    func fillMissingPlaylistArtwork(from playlists: [PlaylistRowViewModel]) {
        fillMissingPlaylistArtwork(covers: playlists.map { ($0.id, $0.artworkURL) })
    }

    /// The same for playlists found by a search, which names a shared playlist by its catalog
    /// ID, the one pins made from Search carry.
    func fillMissingPlaylistArtwork(from playlists: [MusicPlaylistSummary]) {
        fillMissingPlaylistArtwork(covers: playlists.map { ($0.id, $0.imageURL) })
    }

    private func fillMissingPlaylistArtwork(covers: [(id: String, url: URL?)]) {
        var artworkByID = Dictionary(
            covers.compactMap { cover in cover.url.map { (cover.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        // Search lists a saved Apple Music playlist by its library ID only, while a pin made from
        // Search before may carry its catalog ID: the cover counts for the playlist's other IDs
        // too (#524). A row that names that ID itself keeps its own cover.
        if let aliases {
            for (id, url) in artworkByID {
                for alias in aliases.knownAliases(ofPinID: PinnedItem.id(forKind: .playlist, spotifyID: id), checkingAlbum: false) {
                    guard let aliasID = PinnedItem.itemID(ofPinID: alias), artworkByID[aliasID] == nil else { continue }
                    artworkByID[aliasID] = url
                }
            }
        }
        if knownPlaylistCovers.count + artworkByID.count > Self.maxKnownPlaylistCovers {
            knownPlaylistCovers = [:]
        }
        knownPlaylistCovers.merge(artworkByID) { _, new in new }
        let next = fillingMissingPlaylistArtwork(items, from: artworkByID)
        guard next != items else { return }
        items = next
        persist()
    }

    private func fillingMissingPlaylistArtwork(_ items: [PinnedItem], from artworkByID: [String: URL]) -> [PinnedItem] {
        var next = items
        for index in next.indices where next[index].kind == .playlist {
            guard let id = next[index].spotifyID else { continue }
            if let saved = next[index].artworkURL {
                // A `musicKit://` cover only draws while the library has the playlist. One a list
                // offers that loads on its own (a shared playlist's catalog cover from Search)
                // takes its place, so the pin keeps its cover if the playlist leaves the library.
                guard AppleMusicArtworkRegistry.needsMusicKit(saved),
                      let durable = artworkByID[id], !AppleMusicArtworkRegistry.needsMusicKit(durable)
                else { continue }
                next[index].artworkURL = durable
            } else if let url = artworkByID[id] ?? knownArtwork(next[index].id) {
                next[index].artworkURL = url
            }
        }
        return next
    }

    /// Clears the in-memory list without touching disk. Used at sign-out so
    /// that signing back into the same account restores the pins, while
    /// signing into a different account swaps to that account's list cleanly.
    func clearForSignOut() {
        bindingGeneration &+= 1
        aliasLookup?.cancel()
        pendingPinLookups = []
        items = []
        boundUserID = nil
    }

    private func persist() {
        guard let userID = boundUserID, let cache else { return }
        do {
            try cache.savePinnedItems(items, userID: userID)
        } catch {
            SpotiglassLog.error(SpotiglassLog.pinning, "Failed to save pinned items: \(error.localizedDescription)")
        }
    }
}
