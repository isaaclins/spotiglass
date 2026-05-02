import SwiftUI

/// A 3-bar animated waveform icon (system control accent) for the currently playing
/// playlist (sidebar) or track (track list).
///
/// When `isPlaying` is true the bars animate continuously up and down with
/// staggered phases. When false, the bars freeze at fixed mid-heights to
/// indicate that playback is paused.
struct PlayingWaveformIcon: View {
    var isPlaying: Bool
    var color: Color = SpotiglassDesign.controlAccent

    private let barCount = 3
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2
    private let maxHeight: CGFloat = 14

    @State private var isAnimating: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            bar(index: 0, baseFraction: 0.50, durationOffset: 0.00, durationScale: 1.00)
            bar(index: 1, baseFraction: 0.85, durationOffset: 0.15, durationScale: 0.85)
            bar(index: 2, baseFraction: 0.35, durationOffset: 0.30, durationScale: 1.10)
        }
        .frame(width: CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing, height: maxHeight)
        .onAppear {
            isAnimating = isPlaying
        }
        .onChange(of: isPlaying) { _, nowPlaying in
            isAnimating = nowPlaying
        }
        .accessibilityHidden(true)
    }

    private func bar(index: Int, baseFraction: CGFloat, durationOffset: Double, durationScale: Double) -> some View {
        let frozenFraction: CGFloat = [0.55, 0.85, 0.40][index % 3]
        let scale: CGFloat = isAnimating ? 1.0 : frozenFraction / baseFraction

        return RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
            .fill(color)
            .frame(width: barWidth, height: maxHeight * baseFraction)
            .scaleEffect(y: isAnimating ? animatedScale(index: index) : scale, anchor: .center)
            .animation(
                isAnimating
                    ? .easeInOut(duration: 0.45 * durationScale).repeatForever(autoreverses: true).delay(durationOffset)
                    : .default,
                value: isAnimating
            )
    }

    /// When animating, each bar oscillates between two scale extremes.
    /// We toggle the target scale via the `isAnimating` flag; the per-bar
    /// extremes differ to create the offset waveform effect.
    private func animatedScale(index: Int) -> CGFloat {
        // Different bars target different extremes when isAnimating is true,
        // producing a staggered wave when combined with the per-bar delays.
        let extremes: [CGFloat] = [1.8, 0.4, 1.6]
        return extremes[index % extremes.count]
    }
}

#Preview {
    VStack(spacing: 20) {
        PlayingWaveformIcon(isPlaying: true)
        PlayingWaveformIcon(isPlaying: false)
    }
    .padding()
}
