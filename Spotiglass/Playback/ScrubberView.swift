import SwiftUI

/// Scrubber plus elapsed/remaining labels driven by `PlaybackProgressAnchor` and `TimelineView`.
struct PlaybackProgressScrubberGroup: View {
    var progressAnchor: PlaybackProgressAnchor?
    var durationMilliseconds: Int
    var isEnabled: Bool
    var onSeek: (Int) -> Void
    @Binding var dragFraction: Double?

    var body: some View {
        Group {
            if let anchor = progressAnchor, anchor.isAdvancing, dragFraction == nil {
                TimelineView(.animation) { context in
                    let positionMs = anchor.interpolatedPositionMs(at: context.date)
                    scrubberRow(
                        positionMs: positionMs,
                        durationMs: anchor.durationMilliseconds,
                        displayFraction: anchor.fraction(at: context.date)
                    )
                }
            } else {
                let durationMs = max(durationMilliseconds, progressAnchor?.durationMilliseconds ?? 0)
                let positionMs = staticPositionMs(durationMs: durationMs)
                let fraction = durationMs > 0
                    ? min(max(Double(positionMs) / Double(durationMs), 0), 1)
                    : 0
                scrubberRow(positionMs: positionMs, durationMs: durationMs, displayFraction: fraction)
            }
        }
        .animation(.smooth(duration: 0.24), value: isEnabled)
    }

    private func staticPositionMs(durationMs: Int) -> Int {
        if let dragFraction, durationMs > 0 {
            return Int((dragFraction * Double(durationMs)).rounded())
        }
        if let anchor = progressAnchor {
            return anchor.positionMilliseconds
        }
        return 0
    }

    private func scrubberRow(positionMs: Int, durationMs: Int, displayFraction: Double) -> some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Text(PlaybackNowPlaying.mmss(milliseconds: positionMs))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 36, alignment: .trailing)
                .monospacedDigit()

            ScrubberView(
                displayFraction: displayFraction,
                durationMilliseconds: durationMs,
                onSeek: onSeek,
                onDragUpdate: { fraction in
                    dragFraction = fraction
                }
            )
            .frame(maxWidth: .infinity)
            .opacity(isEnabled ? 1 : 0.4)
            .disabled(!isEnabled)

            Text(String(format: SpotiglassL10n.string("playback.scrubber.remaining"), PlaybackNowPlaying.mmss(milliseconds: max(0, durationMs - positionMs))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .leading)
                .monospacedDigit()
        }
    }
}

/// A horizontal scrubber for the now-playing bar.
///
/// - Always shows a circular thumb at the current position.
/// - Track expands from 4pt to 6pt on hover.
/// - Click to seek immediately, click-and-drag to scrub.
/// - During drag, `onDragUpdate` exposes the in-progress fraction for timestamp labels.
struct ScrubberView: View {
    var displayFraction: Double
    var durationMilliseconds: Int
    var onSeek: (Int) -> Void
    var onDragUpdate: (Double?) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private let restingHeight: CGFloat = 4
    private let hoverHeight: CGFloat = 6
    private let thumbDiameter: CGFloat = 12

    @State private var isHovering: Bool = false
    @State private var isDragging: Bool = false
    @State private var dragFraction: Double = 0

    var body: some View {
        scrubberTrack(displayFraction: isDragging ? dragFraction : displayFraction)
    }

    private func scrubberTrack(displayFraction: Double) -> some View {
        let trackHeight = isHovering || isDragging ? hoverHeight : restingHeight

        return GeometryReader { geometry in
            let width = geometry.size.width
            let clampedFraction = min(max(displayFraction, 0), 1)
            let filledWidth = width * CGFloat(clampedFraction)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                    .fill(
                        SpotiglassDesign.scrubberTrackColor(
                            colorScheme: colorScheme,
                            contrast: colorSchemeContrast
                        )
                    )
                    .frame(height: trackHeight)

                RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                    .fill(.spotiglassAccent)
                    .frame(width: max(filledWidth, 0), height: trackHeight)

                Circle()
                    .fill(SpotiglassDesign.scrubberThumbFillColor(colorScheme: colorScheme))
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .overlay {
                        Circle().strokeBorder(
                            SpotiglassDesign.scrubberThumbBorderColor(colorScheme: colorScheme),
                            lineWidth: 0.5
                        )
                    }
                    .shadow(color: Color.black.opacity(0.25), radius: 1.5, y: 0.5)
                    .offset(x: max(0, filledWidth - thumbDiameter / 2))
            }
            .frame(height: hoverHeight + thumbDiameter, alignment: .center)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let fraction = Double(min(max(value.location.x, 0), width) / max(width, 1))
                        dragFraction = fraction
                        onDragUpdate(fraction)
                    }
                    .onEnded { value in
                        let fraction = Double(min(max(value.location.x, 0), width) / max(width, 1))
                        let positionMs = Int((fraction * Double(max(durationMilliseconds, 0))).rounded())
                        isDragging = false
                        onDragUpdate(nil)
                        onSeek(positionMs)
                    }
            )
            .animation(.easeInOut(duration: 0.12), value: isHovering)
        }
        .frame(height: hoverHeight + thumbDiameter)
        .accessibilityElement()
        .help(SpotiglassL10n.string("tooltip.playback.scrubber"))
        .accessibilityLabel(SpotiglassL10n.string("playback.scrubber.progress"))
        .accessibilityValue("\(Int(displayFraction * 100))%")
    }
}

#Preview {
    PlaybackProgressScrubberGroup(
        progressAnchor: PlaybackProgressAnchor(
            positionMilliseconds: 84_000,
            anchorDate: Date(),
            durationMilliseconds: 240_000,
            isAdvancing: true
        ),
        durationMilliseconds: 240_000,
        isEnabled: true,
        onSeek: { _ in },
        dragFraction: .constant(nil as Double?)
    )
    .frame(width: 400)
    .padding()
}
