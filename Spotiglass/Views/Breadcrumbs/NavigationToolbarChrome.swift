import AppKit
import SwiftUI

/// Hosts back + breadcrumbs in **plain AppKit controls** (`NSButton.isBordered = false`) inside one
/// `NSToolbarItem`, avoiding SwiftUI toolbar control chrome (capsule / pill grouping) on macOS.
struct NavigationToolbarChrome: NSViewRepresentable {
    @ObservedObject var viewModel: PlaylistBrowserViewModel
    @Environment(\.spotiglassLocale) private var spotiglassLocale

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)

        let back = NSButton()
        back.bezelStyle = .shadowlessSquare
        back.isBordered = false
        // Keep the focus ring. Removing it hid the only indication that the
        // control had keyboard focus, which is the whole point of Tab (#127).
        back.focusRingType = .default
        let backSymbol = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let backLabel = SpotiglassL10n.string("breadcrumb.back", locale: spotiglassLocale)
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: backLabel)?
            .withSymbolConfiguration(backSymbol)
        back.imagePosition = .imageOnly
        back.target = context.coordinator
        back.action = #selector(Coordinator.didTapBack)
        back.toolTip = backLabel
        back.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            back.widthAnchor.constraint(equalToConstant: 32),
            back.heightAnchor.constraint(equalToConstant: 32)
        ])

        let hosting = NSHostingView(
            rootView: BreadcrumbToolbarView(viewModel: viewModel, locale: spotiglassLocale)
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false

        stack.wantsLayer = true
        stack.layer?.isOpaque = false
        stack.layer?.backgroundColor = NSColor.clear.cgColor

        hosting.wantsLayer = true
        hosting.layer?.isOpaque = false
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        stack.addArrangedSubview(back)
        stack.addArrangedSubview(hosting)

        context.coordinator.backButton = back
        context.coordinator.breadcrumbHostingView = hosting

        return stack
    }

    func updateNSView(_ nsView: NSStackView, context: Context) {
        context.coordinator.viewModel = viewModel
        context.coordinator.backButton?.isHidden = !viewModel.canNavigateBack
        context.coordinator.updateBackButton(locale: spotiglassLocale)
        context.coordinator.breadcrumbHostingView?.rootView = BreadcrumbToolbarView(
            viewModel: viewModel,
            locale: spotiglassLocale
        )
    }

    final class Coordinator {
        var viewModel: PlaylistBrowserViewModel
        weak var backButton: NSButton?
        weak var breadcrumbHostingView: NSHostingView<BreadcrumbToolbarView>?

        init(viewModel: PlaylistBrowserViewModel) {
            self.viewModel = viewModel
        }

        func updateBackButton(locale: Locale) {
            let backLabel = SpotiglassL10n.string("breadcrumb.back", locale: locale)
            let backSymbol = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            backButton?.image = NSImage(
                systemSymbolName: "chevron.left",
                accessibilityDescription: backLabel
            )?.withSymbolConfiguration(backSymbol)
            backButton?.toolTip = backLabel
        }

        @objc func didTapBack() {
            Task { @MainActor in
                await viewModel.navigateBack()
            }
        }
    }
}
