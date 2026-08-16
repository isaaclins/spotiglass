import SwiftUI

/// A 3-bar animated waveform icon (system control accent) for the currently playing
/// playlist (sidebar) or track (track list).
///
/// When `isPlaying` is true the bars animate continuously up and down with
/// staggered phases. When false, the bars freeze at fixed mid-heights to
/// indicate that playback is paused. Reduce Motion also freezes them, since the
/// icon appears in every playing row and would otherwise be permanent motion in
/// a list.
struct PlayingWaveformIcon: View {
    var isPlaying: Bool
    /// Overrides the bar color. Left nil the bars use the shared accent, which greys
    /// itself out while the window is not the key window.
    var color: Color?

    private let barCount = 3
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2
    private let maxHeight: CGFloat = 14

    @State private var isAnimating: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            bar(index: 0, baseFraction: 0.50, durationOffset: 0.00, durationScale: 1.00)
            bar(index: 1, baseFraction: 0.85, durationOffset: 0.15, durationScale: 0.85)
            bar(index: 2, baseFraction: 0.35, durationOffset: 0.30, durationScale: 1.10)
        }
        .frame(width: CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing, height: maxHeight)
        // This icon sits in every playing row, so a repeatForever animation is
        // perpetual motion in a list for someone who asked the system for less
        // of it. The bars hold their frozen state instead (#118).
        .onAppear {
            isAnimating = Self.shouldAnimate(isPlaying: isPlaying, reduceMotion: reduceMotion)
        }
        .onChange(of: isPlaying) { _, nowPlaying in
            isAnimating = Self.shouldAnimate(isPlaying: nowPlaying, reduceMotion: reduceMotion)
        }
        .onChange(of: reduceMotion) { _, nowReduced in
            isAnimating = Self.shouldAnimate(isPlaying: isPlaying, reduceMotion: nowReduced)
        }
        .help(isPlaying ? SpotiglassL10n.string("playback.nowPlaying") : SpotiglassL10n.string("playback.paused"))
        .accessibilityLabel(isPlaying ? SpotiglassL10n.string("playback.nowPlaying") : SpotiglassL10n.string("playback.paused"))
        .accessibilityAddTraits(.isImage)
    }

    private func bar(index: Int, baseFraction: CGFloat, durationOffset: Double, durationScale: Double) -> some View {
        RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
            .fill(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(SpotiglassAccentStyle()))
            .frame(width: barWidth, height: maxHeight * baseFraction)
            .scaleEffect(
                y: Self.barScale(index: index, baseFraction: baseFraction, isAnimating: isAnimating),
                anchor: .center
            )
            .animation(
                Self.barAnimation(
                    isAnimating: isAnimating,
                    durationScale: durationScale,
                    durationOffset: durationOffset
                ),
                value: isAnimating
            )
    }

    /// Whether the bars move at all.
    ///
    /// Kept as a named rule rather than an inline condition because three
    /// separate places have to agree on it, and because the answer depends on a
    /// system setting that a hosted test cannot write.
    static func shouldAnimate(isPlaying: Bool, reduceMotion: Bool) -> Bool {
        isPlaying && !reduceMotion
    }

    /// The vertical scale of one bar.
    ///
    /// While animating, each bar targets a different extreme, which combined
    /// with the per-bar delays produces the staggered wave. Frozen, each bar
    /// holds a fixed mid-height so a paused row still reads as a waveform.
    static func barScale(index: Int, baseFraction: CGFloat, isAnimating: Bool) -> CGFloat {
        if isAnimating {
            let extremes: [CGFloat] = [1.8, 0.4, 1.6]
            return extremes[index % extremes.count]
        }
        let frozenFraction: CGFloat = [0.55, 0.85, 0.40][index % 3]
        return frozenFraction / baseFraction
    }

    /// The animation applied to one bar. `.default` when frozen, so settling
    /// into the held state is not itself a jump.
    static func barAnimation(isAnimating: Bool, durationScale: Double, durationOffset: Double) -> Animation {
        guard isAnimating else { return .default }
        return .easeInOut(duration: 0.45 * durationScale)
            .repeatForever(autoreverses: true)
            .delay(durationOffset)
    }
}

#Preview {
    VStack(spacing: 20) {
        PlayingWaveformIcon(isPlaying: true)
        PlayingWaveformIcon(isPlaying: false)
    }
    .padding()
}
