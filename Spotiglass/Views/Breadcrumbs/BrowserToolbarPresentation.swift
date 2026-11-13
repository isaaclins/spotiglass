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
            return localizedName(breadcrumb.label, of: breadcrumb.kind, locale: locale)
        }
    }

    /// A crumb keeps the name it was opened with. A nameless item's stand-in and the "Playlist"
    /// and "Artist" fallbacks are the app's words, so they read in the current language (#548).
    static func localizedName(_ label: String, of kind: BrowserBreadcrumb.Kind, locale: Locale) -> String {
        switch kind {
        case .playlist:
            if SpotiglassL10n.isText(label, ofKey: "browser.breadcrumb.playlistFallback") {
                return SpotiglassL10n.string("browser.breadcrumb.playlistFallback", locale: locale)
            }
            return UnnamedMusicItem.displayName(label, kind: .playlist, locale: locale)
        case .artist:
            if SpotiglassL10n.isText(label, ofKey: "browser.breadcrumb.artistFallback") {
                return SpotiglassL10n.string("browser.breadcrumb.artistFallback", locale: locale)
            }
            return UnnamedMusicItem.displayName(label, kind: .artist, locale: locale)
        case .album:
            return UnnamedMusicItem.displayName(label, kind: .album, locale: locale)
        case .search, .likedSongs:
            return label
        }
    }

    /// An empty path is Home while something is selected: Home itself, or a pinned row that is
    /// still starting playback over Home. With nothing selected (a Command-click on the selected
    /// sidebar row, or before Home has loaded) the page is an empty placeholder, not Home: the
    /// window keeps the app's name there and the bar shows none, as on the cards.
    static func windowTitle(
        for path: [BrowserBreadcrumb],
        selection: SidebarSelection?,
        locale: Locale = SpotiglassL10n.locale
    ) -> String {
        guard let last = path.last else {
            return selection != nil
                ? SpotiglassL10n.string("browser.home", locale: locale)
                : AppMetadata.displayName
        }
        return localizedLabel(for: last, locale: locale)
    }

    /// Home has its own big greeting, so the bar above it stays empty, like Music's
    /// Home. Every other page keeps its name there (#495). The empty placeholder has no name
    /// of its own to show, so its bar stays empty too.
    static func showsTitleInToolbar(for path: [BrowserBreadcrumb]) -> Bool {
        !path.isEmpty
    }
}
