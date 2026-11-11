import AppKit
import SwiftUI

struct CommandPaletteEventMonitor: NSViewRepresentable {
    @ObservedObject var manager: CommandPaletteManager

    func makeCoordinator() -> Coordinator {
        Coordinator(manager: manager)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.start()
        manager.paletteWindow = { [weak view] in view?.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.manager = manager
        manager.paletteWindow = { [weak nsView] in nsView?.window }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var manager: CommandPaletteManager
        private var monitor: Any?

        init(manager: CommandPaletteManager) {
            self.manager = manager
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let handled = MainActor.assumeIsolated {
                    self.manager.handleKeyEvent(event)
                }
                return handled ? nil : event
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}
