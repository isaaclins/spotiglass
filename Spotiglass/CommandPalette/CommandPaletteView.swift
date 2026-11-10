import AppKit
import SwiftUI

enum CommandPaletteSearchFocusField {
    case query
}

extension EnvironmentValues {
    /// True while this window's command palette is open. A surface with its own search field
    /// (the Search page) hides that field so the palette never stacks a second one over it (#472).
    @Entry var isCommandPalettePresented = false
}

/// The command palette: one panel near the top of the window, like Spotlight, holding the
/// field, the filters, the results and a footer with the key hints (#472).
struct CommandPaletteView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    @EnvironmentObject private var settingsStore: SpotiglassSettingsStore

    @FocusState private var focusedField: CommandPaletteSearchFocusField?
    @State private var previousResponder: NSResponder?
    @State private var previousWindow: NSWindow?
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    /// Height the palette can use; starts tall so the first frame sits at the full inset.
    @State private var availableHeight: CGFloat = .infinity

    /// Space above the panel: the Spotlight-like top inset in a tall window, shrinking to
    /// `spacingS` as the window gets short, so the space gives way before the results do.
    static func topInset(forAvailableHeight height: CGFloat) -> CGFloat {
        min(SpotiglassDesign.Layout.paletteTopInset, max(SpotiglassDesign.spacingS, ((height - 300) / 4).rounded()))
    }

    var body: some View {
        ZStack(alignment: .top) {
            CommandPaletteBackdropView(
                backdropBlur: settingsStore.settings.commandPalette.backdropBlur,
                onDismiss: { viewModel.hide() }
            )

            VStack(spacing: 0) {
                // The space above follows the window's height only, never the panel's: when it
                // depended on what was left over, a short window moved the panel down each time
                // the results got shorter.
                Color.clear
                    .frame(height: Self.topInset(forAvailableHeight: availableHeight))
                    .allowsHitTesting(false)
                CommandPalettePanelView(
                    viewModel: viewModel,
                    focusedField: $focusedField,
                    accessibilityReduceMotion: accessibilityReduceMotion
                )
                .frame(maxWidth: SpotiglassDesign.Layout.paletteMaxWidth)
                .layoutPriority(1)
                Spacer(minLength: SpotiglassDesign.spacingS)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, SpotiglassDesign.spacingXL)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
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
}

// MARK: - Panel

struct CommandPalettePanelView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    var focusedField: FocusState<CommandPaletteSearchFocusField?>.Binding
    let accessibilityReduceMotion: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SpotiglassDesign.cornerL, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            CommandPaletteSearchCardView(viewModel: viewModel, focusedField: focusedField)
            if viewModel.currentScope == .songs {
                CommandPaletteCategoryPillsRowView(viewModel: viewModel)
                    .padding(.horizontal, SpotiglassDesign.spacingM)
                    .padding(.bottom, SpotiglassDesign.spacingS)
            }
            if shouldShowResults {
                Divider()
                CommandPaletteResultsCardView(
                    viewModel: viewModel,
                    accessibilityReduceMotion: accessibilityReduceMotion
                )
            }
            Divider()
            CommandPaletteFooterView(viewModel: viewModel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.28), radius: SpotiglassDesign.spacingL, x: 0, y: SpotiglassDesign.spacingS)
        .animation(accessibilityReduceMotion ? nil : .smooth(duration: 0.24), value: shouldShowResults)
    }

    /// The results area shows whenever there is something in it: results, the recent searches and
    /// quick actions before typing, a loading or error state, or a "no results" line.
    private var shouldShowResults: Bool {
        if viewModel.prefetchProgress != nil { return true }
        if !viewModel.sections.isEmpty || viewModel.isLoading || viewModel.errorText != nil { return true }
        let parsed = CommandPaletteScope.parse(viewModel.query)
        let stripped = parsed.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return false }
        if parsed.scope == .songs, stripped.count < CommandPaletteViewModel.minimumPaletteSearchQueryCharacters {
            return false
        }
        return true
    }
}
