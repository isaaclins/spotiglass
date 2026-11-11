#if DEBUG
/// Counts how often chosen view bodies run, so a test can tell what one change of the player
/// re-renders (#422), and how often a list looks for its playing row. Debug builds only: release
/// builds compile it and every call away.
@MainActor
enum ViewBodyTally {
    /// Runs per view name, or `nil` while nobody counts (the app itself never does).
    static var counts: [String: Int]?

    /// Views on screen per name, or `nil` while nobody counts. A row a list kept from an older
    /// list stays on screen under its old name (#499).
    static var onScreen: [String: Int]?

    static func record(_ name: String) {
        counts?[name, default: 0] += 1
    }

    static func appeared(_ name: String) {
        onScreen?[name, default: 0] += 1
    }

    static func disappeared(_ name: String) {
        onScreen?[name, default: 0] -= 1
        if onScreen?[name] == 0 {
            onScreen?[name] = nil
        }
    }
}
#endif
