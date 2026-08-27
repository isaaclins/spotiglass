import AppKit

/// Opts a focused responder into precedence over the app-wide command monitor.
///
/// Local event monitors run before AppKit dispatches a key event to the focused
/// responder. A responder that handles a particular event can return `true` so
/// the command dispatcher leaves it untouched. Event-specific ownership keeps
/// unrelated global shortcuts available while a control is focused, and gives
/// modal surfaces a reusable seam for claiming their key input.
@MainActor
protocol FocusedKeyEventOwner: AnyObject {
    func ownsKeyEvent(_ event: NSEvent) -> Bool
}

/// Resolves key ownership from the focused responder through its responder
/// chain. Walking the chain lets a focused child delegate ownership to a
/// containing control or modal host without coupling the command manager to a
/// concrete view type.
@MainActor
enum FocusedKeyEventDispatcher {
    static func shouldDeferGlobalDispatch(for event: NSEvent) -> Bool {
        var responder = event.window?.firstResponder
        var visited = Set<ObjectIdentifier>()
        while let current = responder {
            // AppKit can expose a responder cycle through a window/delegate
            // chain. Never let an ownership lookup hang the app-wide monitor.
            guard visited.insert(ObjectIdentifier(current)).inserted else { break }
            if let owner = current as? FocusedKeyEventOwner, owner.ownsKeyEvent(event) {
                return true
            }
            responder = current.nextResponder
        }
        return false
    }
}
