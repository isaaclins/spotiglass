import SwiftUI

/// Shared state that exposes the ``PinnedItem`` currently underneath the
/// user's cursor while a pin drag is in flight.
///
/// `dropDestination(for:isTargeted:)` only delivers the drag payload at
/// commit time, so the pinned-sidebar drop-slot skeleton cannot read the
/// dragged item directly. Every pin-drag source already renders
/// ``PinnedItemDragPill`` as its `.draggable { ... }` preview; the pill
/// publishes itself here on appear, giving the skeleton a "drag in
/// progress" signal across all drag sources without per-site changes.
///
/// Exposed as a singleton so it can be reached from inside the `.draggable`
/// preview view tree on macOS, where SwiftUI does not always propagate
/// `@EnvironmentObject` down into the detached drag-image view tree. We
/// intentionally do NOT clear `activeItem` from the preview's
/// `.onDisappear`: SwiftUI may render the preview as a brief snapshot and
/// tear it down before the actual drag finishes, which would clear the
/// state too early. Stale values are harmless because the skeleton only
/// renders while a drop slot is being targeted; the next drag overwrites
/// the value before it is read again.
@MainActor
final class PinnedDragPreviewState: ObservableObject {
    static let shared = PinnedDragPreviewState()

    @Published var activeItem: PinnedItem?

    init(activeItem: PinnedItem? = nil) {
        self.activeItem = activeItem
    }

    func beginDrag(item: PinnedItem) {
        activeItem = item
    }

    func endDrag() {
        activeItem = nil
    }
}
