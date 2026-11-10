import AppKit
import SwiftUI

/// Where a horizontal shelf (Home's Recently played, an artist's album rows) comes
/// to rest after a scroll.
///
/// The shelves used `.viewAligned`, which settles on a card edge after every
/// scroll. A trackpad swipe is one scroll with momentum, so that worked. A mouse
/// wheel sends one scroll per notch, so every notch was snapped on its own: a
/// short notch was pulled back to the card it started on and a long one jumped a
/// whole card, and Shift + wheel moved the row in jerks or not at all (#475).
///
/// A wheel now moves the shelf by exactly what it sends, like every vertical list
/// in the app. Trackpad swipes, and anything that isn't a wheel, still settle on
/// a whole card, so a swipe never leaves a card cut in half at rest.
struct ShelfScrollTargetBehavior: ScrollTargetBehavior {
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let input = ShelfScrollInputMonitor.shared.lastInput
        var rect = target.rect
        Self.settle(&rect, after: input) { snapped in
            var aligned = target
            aligned.rect = snapped
            ViewAlignedScrollTargetBehavior().updateTarget(&aligned, context: context)
            snapped = aligned.rect
        }
        target.rect = rect
    }

    /// Leaves a wheel's target where the wheel put it and lets `snapToCard` align
    /// every other one.
    static func settle(
        _ target: inout CGRect,
        after input: ShelfScrollInput?,
        snapToCard: (inout CGRect) -> Void
    ) {
        guard input != .wheel else { return }
        snapToCard(&target)
    }
}

/// The device behind a scroll event.
enum ShelfScrollInput: Equatable {
    /// A notched mouse wheel (with Shift for sideways): separate events without phases.
    case wheel
    /// A trackpad or Magic Mouse: one gesture with began/changed/ended phases, then momentum.
    case gesture

    init(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) {
        self = phase.isEmpty && momentumPhase.isEmpty ? .wheel : .gesture
    }

    init?(event: NSEvent) {
        guard event.type == .scrollWheel else { return nil }
        self.init(phase: event.phase, momentumPhase: event.momentumPhase)
    }
}

/// Remembers which device sent the latest scroll. SwiftUI doesn't say, and it asks
/// a scroll target behavior for a target outside the scroll event (`NSApp.currentEvent`
/// is a mouse-exited or layout event by then), so the event is read as it arrives.
final class ShelfScrollInputMonitor {
    static let shared = ShelfScrollInputMonitor()

    private(set) var lastInput: ShelfScrollInput?
    private var monitor: Any?

    /// Starts listening once; shelves call it when they appear.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.record(event)
            return event
        }
    }

    func record(_ event: NSEvent) {
        if let input = ShelfScrollInput(event: event) {
            lastInput = input
        }
    }
}

extension View {
    /// Scroll behavior for a horizontal shelf of cards marked with `.scrollTargetLayout()`.
    func shelfScrollBehavior() -> some View {
        scrollTargetBehavior(ShelfScrollTargetBehavior())
            .onAppear { ShelfScrollInputMonitor.shared.start() }
    }
}
