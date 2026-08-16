import SwiftUI

/// Principal toolbar breadcrumb for the browser shell (`Spotiglass` + typed segments).
struct BreadcrumbToolbarView: View {
    private static let segmentFont = Font.system(size: 13)

    @ObservedObject var viewModel: PlaylistBrowserViewModel

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

            ForEach(Array(viewModel.breadcrumbPath.enumerated()), id: \.element.id) { index, crumb in
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                crumbRow(
                    crumb: crumb,
                    isLeaf: index == viewModel.breadcrumbPath.count - 1,
                    breadcrumbIndex: index
                )
            }
        }
        .padding(.vertical, 2)
        .padding(.trailing, 4)
        .fixedSize(horizontal: true, vertical: false)
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
                .font(Self.segmentFont)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppMetadata.displayName)
        .accessibilityHint(SpotiglassL10n.string("breadcrumb.home.hint"))
        .help(SpotiglassL10n.string("tooltip.breadcrumb.home"))
    }

    @ViewBuilder
    private func crumbRow(crumb: BrowserBreadcrumb, isLeaf: Bool, breadcrumbIndex index: Int) -> some View {
        if isLeaf {
            crumbLabel(crumb: crumb, isLeaf: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(crumb.label)
                // Without this the hosted leaf reports AXUnknown, which reads as
                // an anonymous element rather than the current location.
                .accessibilityAddTraits(.isStaticText)
                // Segments truncate at 220pt, so even the leaf earns a tooltip: it
                // is the only way to read a long playlist or album name in full.
                .help(crumb.label)
        } else {
            Button {
                Task { await viewModel.jumpToBreadcrumb(at: index) }
            } label: {
                crumbLabel(crumb: crumb, isLeaf: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(crumb.label)
            .accessibilityHint(SpotiglassL10n.string("breadcrumb.hint"))
            .help(SpotiglassL10n.format("tooltip.breadcrumb.jump", crumb.label))
        }
    }

    private func crumbLabel(crumb: BrowserBreadcrumb, isLeaf: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: crumb.systemImage)
                .font(Self.segmentFont)

            Text(crumb.label)
                .font(Self.segmentFont)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: 220, alignment: .leading)
        .foregroundStyle(isLeaf ? Color.primary : Color.secondary)
        .contentShape(Rectangle())
    }
}
