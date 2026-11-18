import AppKit
import SwiftUI

/// Selection for track rows stacked outside a `List` (search results, Home's top tracks), so they
/// select like every table in the app (#628): click selects one row, shift-click extends the
/// range from the last clicked row, command-click adds or removes one row, ⌘A selects all, the
/// arrow keys move the selection (with shift they extend it). The right-click menu then acts on
/// the selection when the clicked row is part of it.
struct TrackStackSelection: Equatable {
    private(set) var ids: Set<String> = []
    /// The row a shift-click extends from: the last row clicked without shift.
    private(set) var anchor: String?
    /// The row the arrow keys move from: the last row clicked or reached with an arrow key.
    private(set) var cursor: String?

    /// What a click on `id` does, in `order` (the rows as listed).
    mutating func click(_ id: String, in order: [String], modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let anchor,
           let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            let range = order[min(from, to)...max(from, to)]
            ids = modifiers.contains(.command) ? ids.union(range) : Set(range)
            cursor = id
            return
        }
        if modifiers.contains(.command) {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        } else {
            ids = [id]
        }
        anchor = id
        cursor = id
    }

    /// ⌘A: every listed row.
    mutating func selectAll(in order: [String]) {
        ids = Set(order)
        anchor = order.first
        cursor = order.last
    }

    /// An arrow key: the row `step` places from the cursor alone, or with `extending` (shift)
    /// the range from the anchor to it. Without a cursor the first or last row.
    mutating func move(_ step: Int, in order: [String], extending: Bool) {
        guard !order.isEmpty else { return }
        let from = cursor.flatMap(order.firstIndex(of:))
        let to = from.map { min(max($0 + step, 0), order.count - 1) } ?? (step > 0 ? 0 : order.count - 1)
        let id = order[to]
        if extending, let anchor, let start = order.firstIndex(of: anchor) {
            ids = Set(order[min(start, to)...max(start, to)])
        } else {
            ids = [id]
            anchor = id
        }
        cursor = id
    }

    /// Drops rows that are no longer listed (new results).
    mutating func keep(only order: [String]) {
        ids.formIntersection(order)
        if let anchor, !order.contains(anchor) { self.anchor = nil }
        if let cursor, !order.contains(cursor) { self.cursor = nil }
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
        // The id lets the arrow keys scroll a row they reach into view.
        self.id(id).simultaneousGesture(
            TapGesture().onEnded {
                selection.wrappedValue.click(id, in: order, modifiers: NSEvent.modifierFlags)
            }
        )
    }

    /// The keys of a selectable stack of track rows: ⌘A, the arrow keys and Return (plays the
    /// first selected row), like a table. A new selection gives the stack keyboard focus, as a
    /// click on a table row does.
    func trackStackKeyboard(
        order: [String],
        selection: Binding<TrackStackSelection>,
        play: @escaping (String) -> Void
    ) -> some View {
        modifier(TrackStackKeyboard(order: order, selection: selection, play: play))
    }
}

private struct TrackStackKeyboard: ViewModifier {
    let order: [String]
    @Binding var selection: TrackStackSelection
    let play: (String) -> Void
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                // Edit as well as activate, so Edit > Select All (⌘A) reaches the stack.
                .focusable(interactions: [.activate, .edit])
                .focusEffectDisabled()
                .focused($isFocused)
                .onChange(of: selection.ids) {
                    if !selection.ids.isEmpty { isFocused = true }
                }
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    selection.move(press.key == .upArrow ? -1 : 1, in: order, extending: press.modifiers.contains(.shift))
                    if let cursor = selection.cursor { proxy.scrollTo(cursor) }
                    return .handled
                }
                // ⌘A: Edit > Select All sends selectAll: to the focused view; when the menu
                // doesn't take it, the key press itself arrives.
                .onCommand(#selector(NSText.selectAll(_:))) {
                    selection.selectAll(in: order)
                }
                .onKeyPress(.return) {
                    guard let first = order.first(where: selection.contains) else { return .ignored }
                    play(first)
                    return .handled
                }
                .onKeyPress(characters: ["a"]) { press in
                    guard press.modifiers == .command else { return .ignored }
                    selection.selectAll(in: order)
                    return .handled
                }
        }
    }
}
