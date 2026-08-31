import SwiftUI

/// Keeps the browser's visible breadcrumb path separate from its window title.
/// The last breadcrumb is the current location and belongs to the title; only
/// its ancestors remain as actionable toolbar controls.
enum BrowserToolbarPresentation {
    static func ancestors(of path: [BrowserBreadcrumb]) -> [BrowserBreadcrumb] {
        Array(path.dropLast())
    }

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

/// Principal toolbar breadcrumb for the browser shell (`Spotiglass` + navigable ancestors).
/// The current location is the window title, so it is not repeated as a leaf.
struct BreadcrumbToolbarView: View {
    @ObservedObject var viewModel: PlaylistBrowserViewModel
    @Environment(\.spotiglassLocale) private var spotiglassLocale
    private let explicitLocale: Locale?

    init(viewModel: PlaylistBrowserViewModel, locale: Locale? = nil) {
        self.viewModel = viewModel
        self.explicitLocale = locale
    }

    private var activeLocale: Locale {
        explicitLocale ?? spotiglassLocale
    }

    var body: some View {
        if viewModel.breadcrumbPath.isEmpty {
            // Nothing to show at the root: the window title already names the
            // app, and an empty padded container leaves a stray capsule in the
            // toolbar.
            EmptyView()
        } else {
            trail
        }
    }

    private var trail: some View {
        HStack(spacing: 8) {
            homeCrumb

            ForEach(Array(ancestorPath.enumerated()), id: \.element.id) { index, crumb in
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                crumbRow(crumb: crumb, breadcrumbIndex: index)
            }
        }
        .padding(.vertical, 2)
        .padding(.trailing, 4)
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The navigation title owns the current location. Only its ancestors stay
    /// in the breadcrumb so the same label is not printed twice in the toolbar.
    private var ancestorPath: [BrowserBreadcrumb] {
        BrowserToolbarPresentation.ancestors(of: viewModel.breadcrumbPath)
    }

    /// At the root there is nowhere to go, so the app name is plain text. Once a
    /// path exists it becomes a real button: previously it advertised a hint but
    /// navigated from a tap gesture, which VoiceOver and the keyboard cannot
    /// reach (#113, #127).
    /// Only rendered when there is a trail, so it is always actionable.
    private var homeCrumb: some View {
        Button {
            Task { await viewModel.jumpToHome() }
        } label: {
            Text(AppMetadata.displayName)
                .font(SpotiglassDesign.Typography.breadcrumb)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppMetadata.displayName)
        .accessibilityHint(SpotiglassL10n.string("breadcrumb.home.hint", locale: activeLocale))
        .help(SpotiglassL10n.string("tooltip.breadcrumb.home", locale: activeLocale))
    }

    private func crumbRow(crumb: BrowserBreadcrumb, breadcrumbIndex index: Int) -> some View {
        let label = BrowserToolbarPresentation.localizedLabel(
            for: crumb,
            locale: activeLocale
        )
        return Button {
            Task { await viewModel.jumpToBreadcrumb(at: index) }
        } label: {
            crumbLabel(crumb: crumb, label: label)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(SpotiglassL10n.string("breadcrumb.hint", locale: activeLocale))
        .help(SpotiglassL10n.format("tooltip.breadcrumb.jump", locale: activeLocale, label))
    }

    private func crumbLabel(crumb: BrowserBreadcrumb, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: crumb.systemImage)
                .font(SpotiglassDesign.Typography.breadcrumb)

            Text(label)
                .font(SpotiglassDesign.Typography.breadcrumb)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: 220, alignment: .leading)
        .foregroundStyle(Color.secondary)
        .contentShape(Rectangle())
    }
}
