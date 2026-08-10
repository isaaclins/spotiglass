import Foundation

/// Builds and mutates the visible row order for the Library sidebar section: Home and pinned entries.
enum LibrarySidebarOrder {
    static let searchToken = "library.search"
    static let homeToken = "library.home"
    private static let pinnedPrefix = "pinned:"

    static func pinnedToken(for itemID: String) -> String {
        "\(pinnedPrefix)\(itemID)"
    }

    static func pinnedItemID(from token: String) -> String? {
        guard token.hasPrefix(pinnedPrefix) else { return nil }
        return String(token.dropFirst(pinnedPrefix.count))
    }

    static func normalizedOrder(existing: [String], pinnedItemIDs: [String]) -> [String] {
        let allowed = Set([searchToken, homeToken] + pinnedItemIDs.map(pinnedToken(for:)))
        var filtered = existing.filter { allowed.contains($0) }
        var seen: Set<String> = []
        filtered = filtered.filter { seen.insert($0).inserted }

        let hasPinnedAlready = filtered.contains(where: { pinnedItemID(from: $0) != nil })
        if !hasPinnedAlready {
            // First synthesis after migration: preferred default is search, home, then pinned.
            filtered = [searchToken, homeToken] + pinnedItemIDs.map(pinnedToken(for:))
            seen = Set(filtered)
        }

        if !seen.contains(searchToken) {
            filtered.insert(searchToken, at: 0)
            seen.insert(searchToken)
        }

        if !seen.contains(homeToken) {
            let searchIdx = filtered.firstIndex(of: searchToken) ?? -1
            filtered.insert(homeToken, at: searchIdx + 1)
            seen.insert(homeToken)
        }

        // Pins not yet present in the row order (pinned via context menu or
        // the command palette) join the end of the existing pins group, so a
        // trailing Home row stays last instead of new pins landing below it.
        var insertionIndex = missingPinnedInsertionIndex(in: filtered)
        for id in pinnedItemIDs {
            let token = pinnedToken(for: id)
            if seen.insert(token).inserted {
                filtered.insert(token, at: insertionIndex)
                insertionIndex += 1
            }
        }
        return filtered
    }

    private static func missingPinnedInsertionIndex(in order: [String]) -> Int {
        if let lastPinned = order.lastIndex(where: { pinnedItemID(from: $0) != nil }) {
            return lastPinned + 1
        }
        if let homeIndex = order.firstIndex(of: homeToken) {
            return homeIndex
        }
        return order.count
    }
}
