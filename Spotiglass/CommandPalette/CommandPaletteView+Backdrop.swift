import SwiftUI

// MARK: - Backdrop

/// Dims the window behind the palette, and blurs it unless the user turned the blur off, so
/// nothing from the page reads through next to the panel (#472).
struct CommandPaletteBackdropView: View {
    let backdropBlur: Bool
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if backdropBlur {
                Rectangle().fill(.ultraThinMaterial)
            }
            Rectangle().fill(Color.black.opacity(dimOpacity))
        }
        .contentShape(Rectangle())
        .ignoresSafeArea()
        .onTapGesture(perform: onDismiss)
        .accessibilityHidden(true)
    }

    /// Without the blur the dim does all the work, so it is stronger.
    private var dimOpacity: Double {
        switch (backdropBlur, colorScheme) {
        case (true, .dark): 0.35
        case (true, _): 0.18
        case (false, .dark): 0.55
        case (false, _): 0.35
        }
    }
}
