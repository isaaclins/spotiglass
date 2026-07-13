import Foundation
import XCTest

extension XCTestCase {
    /// A `UserDefaults` suite whose persistent domain is wiped from disk when
    /// the current test finishes. Use this instead of raw
    /// `UserDefaults(suiteName:)` so test runs stop leaking
    /// `SpotiglassTests-<UUID>.plist` files into `~/Library/Preferences`.
    func makeEphemeralDefaults() -> UserDefaults {
        let suiteName = "SpotiglassTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create UserDefaults suite \(suiteName)")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
