import AppKit
import SwiftUI

enum CommandPaletteSearchFocusField {
    case query
}

struct CommandPaletteView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    @EnvironmentObject private var settingsStore: SpotiglassSettingsStore

    @FocusState private var focusedField: CommandPaletteSearchFocusField?
    @State private var previousResponder: NSResponder?
    @State private var previousWindow: NSWindow?
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Namespace private var paletteGlass

    /// Full-strength `Material` reads heavy; partial opacity keeps the frosted hint while leaving more detail visible behind the palette.
    private static let backdropMaterialOpacity: CGFloat = 0.55

    var body: some View {
        ZStack {
            CommandPaletteBackdropView(
                backdropBlur: settingsStore.settings.commandPalette.backdropBlur,
                materialOpacity: Self.backdropMaterialOpacity,
                onDismiss: { viewModel.hide() }
            )

            GlassEffectContainer(spacing: SpotiglassDesign.spacingS) {
                VStack(spacing: SpotiglassDesign.spacingS) {
                    CommandPaletteSearchCardView(
                        viewModel: viewModel,
                        focusedField: $focusedField,
                        paletteGlass: paletteGlass
                    )
                    if shouldShowResultsCard {
                        CommandPaletteResultsCardView(
                            viewModel: viewModel,
                            accessibilityReduceMotion: accessibilityReduceMotion,
                            paletteGlass: paletteGlass
                        )
                    }
                    CommandPaletteFooterView(viewModel: viewModel, paletteGlass: paletteGlass)
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(SpotiglassDesign.spacingXL)
                .animation(
                    accessibilityReduceMotion ? nil : .smooth(duration: 0.30),
                    value: shouldShowResultsCard
                )
            }
        }
        .onAppear {
            previousWindow = NSApp.keyWindow
            previousResponder = NSApp.keyWindow?.firstResponder
            viewModel.restoreFocus = { [weakWindow = previousWindow, weakResponder = previousResponder] in
                if let window = weakWindow, let responder = weakResponder {
                    window.makeFirstResponder(responder)
                }
            }
            scheduleSearchFieldFocus()
        }
        .onChange(of: viewModel.isLoading) { _, isLoading in
            if !isLoading {
                scheduleSearchFieldFocus()
            }
        }
    }

    /// SwiftUI on macOS often ignores immediate `@FocusState` updates in `onAppear`; deferring fixes typing-at-open.
    private func scheduleSearchFieldFocus() {
        DispatchQueue.main.async {
            focusedField = .query
            DispatchQueue.main.async {
                focusedField = .query
            }
        }
    }

    /// Hides the results panel while the palette is "idle" (empty query or only a scope prefix) so the footer chips
    /// sit directly under the search field. Loading and error states still surface so user feedback is never dropped.
    private var shouldShowResultsCard: Bool {
        if viewModel.prefetchProgress != nil { return true }
        let trimmed = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let onlyPrefix = trimmed == ">" || trimmed == "@"
        if trimmed.isEmpty || onlyPrefix {
            return viewModel.isLoading || viewModel.errorText != nil
        }
        let parsed = CommandPaletteScope.parse(viewModel.query)
        let stripped = parsed.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if parsed.scope == .songs,
           !stripped.isEmpty,
           stripped.count < CommandPaletteViewModel.minimumPaletteSearchQueryCharacters {
            return viewModel.isLoading || viewModel.errorText != nil
        }
        return true
    }
}
