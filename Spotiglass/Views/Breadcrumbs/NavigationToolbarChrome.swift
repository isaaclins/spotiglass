import SwiftUI

/// The browser's back button, as a plain toolbar button so macOS draws it the
/// way Finder, Music and System Settings draw theirs: a chevron in the
/// system's own toolbar chrome, sized and aligned with the window title.
///
/// It used to be a hand-made AppKit stack with the app name as a tiny text
/// crumb beside the chevron, which read as "back to Spotiglass" (#443). The
/// button now names nothing on screen and says where it goes in its tooltip
/// and to VoiceOver. Like Finder, Music and System Settings there is no
/// breadcrumb row: the title names where you are, Home is in the sidebar.
struct NavigationToolbarChrome: View {
    @ObservedObject var viewModel: PlaylistBrowserViewModel
    @Environment(\.spotiglassLocale) private var spotiglassLocale

    var body: some View {
        Button {
            Task { await viewModel.navigateBack() }
        } label: {
            // The title is what VoiceOver reads for a toolbar button (an
            // accessibilityLabel modifier is ignored there), so the label
            // itself names the destination, not just "Back".
            Label(destinationDescription, systemImage: "chevron.left")
        }
        .labelStyle(.iconOnly)
        .disabled(!viewModel.canNavigateBack)
        .help(destinationDescription)
    }

    /// "Go back to Home", "Go back to Malcolm Todd": the place a click opens.
    var destinationDescription: String {
        Self.destinationDescription(for: viewModel, locale: spotiglassLocale)
    }

    static func destinationDescription(
        for viewModel: PlaylistBrowserViewModel,
        locale: Locale
    ) -> String {
        guard let destination = viewModel.backDestination else {
            return SpotiglassL10n.string("breadcrumb.back", locale: locale)
        }
        return SpotiglassL10n.format(
            "tooltip.breadcrumb.jump",
            locale: locale,
            viewModel.displayName(for: destination, locale: locale)
        )
    }
}
