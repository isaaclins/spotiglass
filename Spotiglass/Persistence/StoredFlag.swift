import Combine
import Foundation

/// A yes/no setting kept in `UserDefaults` that tells its views only when its own value changes.
///
/// `@AppStorage` re-renders its view on every write to the defaults, whichever key it was and
/// even when it wrote the same value (#409). AppKit saves the main window's frame to the defaults
/// on every resize, so the queue flag in `@AppStorage` re-ran the whole browser, the window's
/// scene and its toolbar once per step: a window manager resizing the window from code waited
/// about 70 ms a step, ten times what Finder takes (#473).
@MainActor
final class StoredFlag: ObservableObject {
    let key: String
    /// `nil` keeps the value in memory only.
    private let defaults: UserDefaults?
    private var storedValue: Bool

    init(key: String, defaultValue: Bool, defaults: UserDefaults?) {
        self.key = key
        self.defaults = defaults
        storedValue = (defaults?.object(forKey: key) as? NSNumber)?.boolValue ?? defaultValue
    }

    /// The app's own flags live in the real defaults, and in memory only under the unit-test host,
    /// which shares the app's defaults domain and must never change the real preferences.
    static func app(key: String, defaultValue: Bool) -> StoredFlag {
        StoredFlag(key: key, defaultValue: defaultValue, defaults: AppMetadata.isRunningUnitTests ? nil : .standard)
    }

    var isOn: Bool {
        get { storedValue }
        set {
            guard newValue != storedValue else { return }
            objectWillChange.send()
            storedValue = newValue
            defaults?.set(newValue, forKey: key)
        }
    }

    /// Whether the queue panel is open. One flag for every window, the View menu and the window's
    /// minimum width, as the shared defaults key was.
    static let queuePanelVisible = StoredFlag.app(key: "queue.panel.visible", defaultValue: false)
}
