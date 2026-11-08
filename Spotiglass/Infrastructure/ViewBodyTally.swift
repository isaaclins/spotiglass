#if DEBUG
/// Counts how often chosen view bodies run, so a test can tell what one change of the player
/// re-renders (#422), and how often a list looks for its playing row. Debug builds only: release
/// builds compile it and every call away.
@MainActor
enum ViewBodyTally {
    /// Runs per view name, or `nil` while nobody counts (the app itself never does).
    static var counts: [String: Int]?

    static func record(_ name: String) {
        counts?[name, default: 0] += 1
    }
}
#endif
