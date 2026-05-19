import SwiftUI

enum ImmersiveLyricsLayout {
    /// Full-window overlays often report `safeAreaInsets.top == 0`; still clear title bar + unified toolbar.
    static let minimumTopClearance: CGFloat = 52
    static let lyricsInnerTopPadding: CGFloat = 8
    static let lyricsInnerBottomPadding: CGFloat = 36

    /// Idle window after the user stops scrolling before auto-centering re-engages.
    static let autoCenterResumeDelay: Duration = .seconds(2)

    static let resumePillBottomInset: CGFloat = 18
    static let resumePillCornerRadius: CGFloat = 999
    static let resumePillHorizontalPadding: CGFloat = 14
    static let resumePillVerticalPadding: CGFloat = 8

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
}
