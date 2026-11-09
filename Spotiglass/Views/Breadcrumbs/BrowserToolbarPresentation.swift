import SwiftUI

/// Names the browser's current location for the window title. The last
/// breadcrumb is where you are; the back button names where you go (#443).
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
        guard let last = path.last else { return AppMetadata.displayName }
        return localizedLabel(for: last, locale: locale)
    }
}
