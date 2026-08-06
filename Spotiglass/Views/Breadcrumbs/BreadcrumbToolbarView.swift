import SwiftUI

/// Principal toolbar breadcrumb for the browser shell (`Spotiglass` + typed segments).
struct BreadcrumbToolbarView: View {
    private static let segmentFont = Font.system(size: 13)

    @ObservedObject var viewModel: PlaylistBrowserViewModel

    var body: some View {
        HStack(spacing: 8) {
            Text(AppMetadata.displayName)
                .font(Self.segmentFont)
                .foregroundStyle(viewModel.breadcrumbPath.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(1)
                .accessibilityLabel(AppMetadata.displayName)
                .accessibilityHint(
                    viewModel.breadcrumbPath.isEmpty
                        ? ""
                        : SpotiglassL10n.string("breadcrumb.home.hint")
                )
                .help(
                    viewModel.breadcrumbPath.isEmpty
                        ? ""
                        : SpotiglassL10n.string("tooltip.breadcrumb.home")
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !viewModel.breadcrumbPath.isEmpty else { return }
                    Task { await viewModel.jumpToHome() }
                }

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

    private func crumbRow(crumb: BrowserBreadcrumb, isLeaf: Bool, breadcrumbIndex index: Int) -> some View {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(crumb.label)
        .accessibilityAddTraits(isLeaf ? [] : .isButton)
        .accessibilityHint(isLeaf ? "" : SpotiglassL10n.string("breadcrumb.hint"))
        // Segments truncate at 220pt, so even the leaf earns a tooltip: it is
        // the only way to read a long playlist or album name in full.
        .help(isLeaf ? crumb.label : SpotiglassL10n.format("tooltip.breadcrumb.jump", crumb.label))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isLeaf else { return }
            Task { await viewModel.jumpToBreadcrumb(at: index) }
        }
    }
}
