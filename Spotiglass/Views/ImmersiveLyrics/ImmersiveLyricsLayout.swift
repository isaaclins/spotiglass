import SwiftUI

enum ImmersiveLyricsLayout {
    /// Full-window overlays often report `safeAreaInsets.top == 0`; still clear title bar + unified toolbar.
    static let minimumTopClearance: CGFloat = 52
    static let lyricsInnerTopPadding: CGFloat = SpotiglassDesign.spacingXS
    static let lyricsInnerBottomPadding: CGFloat = SpotiglassDesign.spacingXL + SpotiglassDesign.spacingXXS

    /// Idle window after the user stops scrolling before auto-centering re-engages.
    static let autoCenterResumeDelay: Duration = .seconds(2)

    static let resumePillBottomInset: CGFloat = SpotiglassDesign.spacingM
    static let resumePillCornerRadius: CGFloat = 999
    static let resumePillHorizontalPadding: CGFloat = SpotiglassDesign.spacingS
    static let resumePillVerticalPadding: CGFloat = SpotiglassDesign.spacingXS

    static let scrollEdgeFadeGradient = LinearGradient(
        stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.07),
            .init(color: .black, location: 0.93),
            .init(color: .clear, location: 1)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Opaque down to the last few points, which fade out: content that runs past the bottom
    /// of its frame softens away instead of ending in a cut.
    static var bottomEdgeFade: some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: SpotiglassDesign.spacingL)
        }
    }
}
