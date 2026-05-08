import SwiftUI

// MARK: - Backdrop

struct CommandPaletteBackdropView: View {
    let backdropBlur: Bool
    let materialOpacity: CGFloat
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if backdropBlur {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(materialOpacity)
            } else {
                Color.clear
            }
        }
        .contentShape(Rectangle())
        .ignoresSafeArea()
        .onTapGesture(perform: onDismiss)
        .accessibilityHidden(true)
    }
}
