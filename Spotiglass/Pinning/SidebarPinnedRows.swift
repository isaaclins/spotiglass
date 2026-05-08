import SwiftUI
import AppKit

/// Builds and mutates the visible row order for the Library sidebar section: Home and pinned entries.
enum LibrarySidebarOrder {
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
        let allowed = Set([homeToken] + pinnedItemIDs.map(pinnedToken(for:)))
        var filtered = existing.filter { allowed.contains($0) }
        var seen: Set<String> = []
        filtered = filtered.filter { seen.insert($0).inserted }

        let hasPinnedAlready = filtered.contains(where: { pinnedItemID(from: $0) != nil })
        if !hasPinnedAlready {
            // First synthesis after migration: preferred default is pinned first.
            filtered = pinnedItemIDs.map(pinnedToken(for:)) + [homeToken]
            seen = Set(filtered)
        }

        if !seen.contains(homeToken) {
            filtered.append(homeToken)
            seen.insert(homeToken)
        }

        for id in pinnedItemIDs {
            let token = pinnedToken(for: id)
            if seen.insert(token).inserted {
                filtered.append(token)
            }
        }
        return filtered
    }

    static func moved(order: [String], movingToken: String, toInsertionIndex insertionIndex: Int) -> [String] {
        guard let source = order.firstIndex(of: movingToken) else { return order }
        var without = order
        without.remove(at: source)
        let clamped = max(0, min(insertionIndex, without.count))
        without.insert(movingToken, at: clamped)
        return without
    }

    static func pinnedInsertionIndex(
        order: [String],
        movingPinnedToken: String?,
        toInsertionIndex insertionIndex: Int
    ) -> Int {
        var normalized = order
        if let movingPinnedToken, let idx = normalized.firstIndex(of: movingPinnedToken) {
            normalized.remove(at: idx)
        }
        let clamped = max(0, min(insertionIndex, normalized.count))
        return normalized.prefix(clamped).reduce(into: 0) { count, token in
            if pinnedItemID(from: token) != nil {
                count += 1
            }
        }
    }
}

/// Full row-shaped placeholder rendered at the prospective drop slot while a
/// pin drag is in progress. Displays a faded copy of the dragged item using
/// ``PinnedRowView``'s layout so the skeleton matches the live row, wrapped in
/// a dotted accent outline. Falls back to a content-less wireframe if the
/// active dragged item has not been published (first frame of the drag, or
/// macOS dropping the preview view tree before publication).
struct PinnedDropSkeletonRow: View {
    let item: PinnedItem?

    var body: some View {
        ZStack {
            if let item {
                PinnedRowView(
                    item: item,
                    isSelected: false,
                    onUnpin: {}
                )
                .opacity(0.45)
            } else {
                Color.clear
                    .frame(height: 56)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay {
            RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                .strokeBorder(
                    SpotiglassDesign.controlAccent.opacity(0.85),
                    style: StrokeStyle(
                        lineWidth: 1.5,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: [0.1, 5]
                    )
                )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
