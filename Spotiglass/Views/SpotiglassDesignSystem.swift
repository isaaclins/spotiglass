import SwiftUI

enum SpotiglassDesign {
    static let spacingXS: CGFloat = 6
    static let spacingS: CGFloat = 10
    static let spacingM: CGFloat = 16
    static let spacingL: CGFloat = 24
    static let spacingXL: CGFloat = 36

    static let cornerS: CGFloat = 8
    static let cornerM: CGFloat = 14
    static let cornerL: CGFloat = 22

    static let sidebarWidth: CGFloat = 320
}

struct GlassPanel<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: SpotiglassDesign.cornerL, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SpotiglassDesign.cornerL, style: .continuous)
                    .strokeBorder(borderStyle, lineWidth: contrast == .increased ? 1.5 : 1)
            }
            .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.12), radius: 18, y: 10)
    }

    @ViewBuilder
    private var panelBackground: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }

    private var borderStyle: Color {
        contrast == .increased ? .primary.opacity(0.35) : .white.opacity(0.18)
    }
}

struct ShellBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Color(nsColor: reduceTransparency ? .windowBackgroundColor : .underPageBackgroundColor)
        .ignoresSafeArea()
    }
}

struct StatusPill: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, SpotiglassDesign.spacingS)
            .padding(.vertical, SpotiglassDesign.spacingXS)
            .background(.secondary.opacity(0.14), in: Capsule())
    }
}
