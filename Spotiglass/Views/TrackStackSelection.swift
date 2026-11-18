import AppKit
import SwiftUI

/// Selection for track rows stacked outside a `List` (search results, Home's top tracks), so they
/// select like every table in the app (#628): click selects one row, shift-click extends the
/// range from the last clicked row, command-click adds or removes one row. The right-click menu
/// then acts on the selection when the clicked row is part of it.
struct TrackStackSelection: Equatable {
    private(set) var ids: Set<String> = []
    /// The row a shift-click extends from: the last row clicked without shift.
    private(set) var anchor: String?

    /// What a click on `id` does, in `order` (the rows as listed).
    mutating func click(_ id: String, in order: [String], modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let anchor,
           let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            let range = order[min(from, to)...max(from, to)]
            ids = modifiers.contains(.command) ? ids.union(range) : Set(range)
            return
        }
        if modifiers.contains(.command) {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        } else {
            ids = [id]
        }
        anchor = id
    }

    /// Drops rows that are no longer listed (new results).
    mutating func keep(only order: [String]) {
        ids.formIntersection(order)
        if let anchor, !order.contains(anchor) { self.anchor = nil }
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// The rows a right-click on `track` acts on: the selection in list order when the row is
    /// part of a selection of several, else the row alone.
    func menuTargets(for track: TrackRowViewModel, in tracks: [TrackRowViewModel]) -> [TrackRowViewModel] {
        guard ids.count > 1, ids.contains(track.id) else { return [track] }
        return tracks.filter { ids.contains($0.id) }
    }
}

extension View {
    /// Makes a stacked track row selectable through `selection`; the double click that plays
    /// stays the row's own.
    func trackStackSelectable(
        _ id: String,
        in order: [String],
        selection: Binding<TrackStackSelection>
    ) -> some View {
        simultaneousGesture(
            TapGesture().onEnded {
                selection.wrappedValue.click(id, in: order, modifiers: NSEvent.modifierFlags)
            }
        )
    }
}
