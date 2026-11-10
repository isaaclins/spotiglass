import SwiftUI

/// Names the browser's current location for the window title. The last
/// breadcrumb is where you are; the back button names where you go (#443).
/// Home is a place too: the window is named after it for the Window menu,
/// Mission Control and VoiceOver (#161), never after the app (#495).
enum BrowserToolbarPresentation {
    static func localizedLabel(
        for breadcrumb: BrowserBreadcrumb,
        locale: Locale = SpotiglassL10n.locale
    ) -> String {
        switch breadcrumb.kind {
        case .search:
            return SpotiglassL10n.string("browser.search", locale: locale)
        case .likedSongs:
            return SpotiglassL10n.string("browser.likedSongs.title", locale: locale)
        case .playlist, .artist, .album:
            return breadcrumb.label
        }
    }

    static func windowTitle(
        for path: [BrowserBreadcrumb],
        locale: Locale = SpotiglassL10n.locale
    ) -> String {
        guard let last = path.last else { return SpotiglassL10n.string("browser.home", locale: locale) }
        return localizedLabel(for: last, locale: locale)
    }

    /// Home has its own big greeting, so the bar above it stays empty, like Music's
    /// Home. Every other page keeps its name there (#495).
    static func showsTitleInToolbar(for path: [BrowserBreadcrumb]) -> Bool {
        !path.isEmpty
    }
}
