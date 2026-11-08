import SwiftUI

/// The waveform on a dark chip in the bottom trailing corner of a cover, for a
/// row whose leading edge is its artwork (sidebar playlists, the queue). Putting
/// it on the cover rather than in a column of its own keeps the playing row's
/// artwork on the same edge as the rows around it.
struct PlayingArtworkBadge: View {
    var isPlaying: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        PlayingWaveformIcon(isPlaying: isPlaying)
            .padding(SpotiglassDesign.spacingXXS)
            .background(
                RoundedRectangle(cornerRadius: SpotiglassDesign.spacingXXS, style: .continuous)
                    .fill(SpotiglassDesign.mediaBadgeBackgroundColor(colorScheme: colorScheme))
            )
            .padding(SpotiglassDesign.spacingXXS)
    }
}

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

    static let barCount = 3
    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 2
    static let maxHeight: CGFloat = 14

    /// Height of each bar before scaling, and how its timing is offset from the others.
    static let bars: [(baseFraction: CGFloat, durationOffset: Double, durationScale: Double)] = [
        (0.50, 0.00, 1.00),
        (0.85, 0.15, 0.85),
        (0.35, 0.30, 1.10),
    ]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        // The bars move through Core Animation, which runs outside the app.
        // As a SwiftUI animation they redrew the window at the display's
        // refresh rate for as long as a row was playing, even a row scrolled
        // out of sight, and took most of a CPU core with it (#394). This icon
        // sits in every playing row, so a repeating animation is perpetual
        // motion in a list for someone who asked the system for less of it:
        // the bars hold their frozen state instead (#118).
        WaveformBars(
            isAnimating: Self.shouldAnimate(isPlaying: isPlaying, reduceMotion: reduceMotion),
            color: color ?? SpotiglassDesign.accent(appearsActive: appearsActive)
        )
        .frame(
            width: CGFloat(Self.barCount) * Self.barWidth + CGFloat(Self.barCount - 1) * Self.barSpacing,
            height: Self.maxHeight
        )
        .help(isPlaying ? SpotiglassL10n.string("playback.nowPlaying") : SpotiglassL10n.string("playback.paused"))
        .accessibilityLabel(isPlaying ? SpotiglassL10n.string("playback.nowPlaying") : SpotiglassL10n.string("playback.paused"))
        .accessibilityAddTraits(.isImage)
    }

    /// Whether the bars move at all.
    ///
    /// Kept as a named rule rather than an inline condition because the answer
    /// depends on a system setting that a hosted test cannot write.
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

    /// One swing of a bar from its frozen height to its extreme, and how long it
    /// waits before the first one. Nil when the bars are frozen.
    static func barTiming(
        isAnimating: Bool,
        durationScale: Double,
        durationOffset: Double
    ) -> (duration: Double, delay: Double)? {
        guard isAnimating else { return nil }
        return (0.45 * durationScale, durationOffset)
    }
}

/// The three bars as Core Animation layers.
private struct WaveformBars: NSViewRepresentable {
    var isAnimating: Bool
    var color: Color

    func makeNSView(context: Context) -> WaveformBarsView {
        WaveformBarsView()
    }

    func updateNSView(_ nsView: WaveformBarsView, context: Context) {
        // Resolved in this view's environment, so light, dark, increased
        // contrast and the inactive-window grey all come through.
        nsView.update(color: color.resolve(in: context.environment).cgColor, isAnimating: isAnimating)
    }
}

final class WaveformBarsView: NSView {
    static let animationKey = "waveform"
    /// The short ease from wherever a bar is to its paused height.
    static let settleKey = "waveform.settle"
    static let settleDuration: CFTimeInterval = 0.25

    private let barLayers: [CALayer] = PlayingWaveformIcon.bars.map { _ in CALayer() }
    private(set) var isAnimating = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for bar in barLayers {
            bar.cornerRadius = PlayingWaveformIcon.barWidth / 2
            bar.cornerCurve = .continuous
            layer?.addSublayer(bar)
        }
        applyFrozenScales()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Bars are decoration; the hosting SwiftUI view carries the label.
    override func isAccessibilityElement() -> Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(color: CGColor, isAnimating: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in barLayers {
            bar.backgroundColor = color
        }
        CATransaction.commit()
        guard isAnimating != self.isAnimating else { return }
        self.isAnimating = isAnimating
        if isAnimating {
            startAnimating()
        } else {
            stopAnimating()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = PlayingWaveformIcon.barWidth
        let step = width + PlayingWaveformIcon.barSpacing
        for (index, bar) in barLayers.enumerated() {
            let height = PlayingWaveformIcon.maxHeight * PlayingWaveformIcon.bars[index].baseFraction
            // Position and bounds, not frame, so the scale transform stays out of the size.
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            bar.position = CGPoint(x: CGFloat(index) * step + width / 2, y: bounds.midY)
        }
        CATransaction.commit()
    }

    private func applyFrozenScales() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in barLayers.enumerated() {
            let scale = PlayingWaveformIcon.barScale(
                index: index,
                baseFraction: PlayingWaveformIcon.bars[index].baseFraction,
                isAnimating: false
            )
            bar.transform = CATransform3DMakeScale(1, scale, 1)
        }
        CATransaction.commit()
    }

    private func startAnimating() {
        let now = CACurrentMediaTime()
        for (index, bar) in barLayers.enumerated() {
            bar.removeAnimation(forKey: Self.settleKey)
            let spec = PlayingWaveformIcon.bars[index]
            guard let timing = PlayingWaveformIcon.barTiming(
                isAnimating: true,
                durationScale: spec.durationScale,
                durationOffset: spec.durationOffset
            ) else { continue }
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = PlayingWaveformIcon.barScale(index: index, baseFraction: spec.baseFraction, isAnimating: false)
            animation.toValue = PlayingWaveformIcon.barScale(index: index, baseFraction: spec.baseFraction, isAnimating: true)
            animation.duration = timing.duration
            animation.beginTime = bar.convertTime(now, from: nil) + timing.delay
            animation.fillMode = .backwards
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(animation, forKey: Self.animationKey)
        }
    }

    /// Pausing eases each bar from where it is to its paused height, as the
    /// SwiftUI version did, instead of snapping there mid-swing.
    private func stopAnimating() {
        let current = barLayers.map { $0.presentation()?.value(forKeyPath: "transform.scale.y") as? CGFloat }
        for bar in barLayers {
            bar.removeAnimation(forKey: Self.animationKey)
        }
        applyFrozenScales()
        for (index, bar) in barLayers.enumerated() {
            let frozen = PlayingWaveformIcon.barScale(
                index: index,
                baseFraction: PlayingWaveformIcon.bars[index].baseFraction,
                isAnimating: false
            )
            // Off screen there is nothing to ease.
            guard let from = current[index], abs(from - frozen) > 0.01 else { continue }
            let settle = CABasicAnimation(keyPath: "transform.scale.y")
            settle.fromValue = from
            settle.toValue = frozen
            settle.duration = Self.settleDuration
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bar.add(settle, forKey: Self.settleKey)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        PlayingWaveformIcon(isPlaying: true)
        PlayingWaveformIcon(isPlaying: false)
    }
    .padding()
}
