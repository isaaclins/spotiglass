import SwiftUI

/// A horizontal scrubber for the now-playing bar.
///
/// - Always shows a circular thumb at the current position.
/// - Track expands from 4pt to 6pt on hover.
/// - Click to seek immediately, click-and-drag to scrub.
/// - During drag, `liveFraction` exposes the in-progress fraction so the parent
///   can update its elapsed/remaining timestamps live.
struct ScrubberView: View {
    /// Current playback position as a fraction in 0...1. Used when not dragging.
    var positionFraction: Double
    /// Total duration in milliseconds (for committing seek positions).
    var durationMilliseconds: Int
    /// Called when the user releases a drag/click; parameter is the new
    /// playback position in milliseconds.
    var onSeek: (Int) -> Void
    /// Called repeatedly during a drag so the parent can update timestamps.
    /// Argument is the in-progress fraction in 0...1, or nil when not dragging.
    var onDragUpdate: (Double?) -> Void

    private let restingHeight: CGFloat = 4
    private let hoverHeight: CGFloat = 6
    private let thumbDiameter: CGFloat = 12

    @State private var isHovering: Bool = false
    @State private var isDragging: Bool = false
    @State private var dragFraction: Double = 0

    var body: some View {
        let displayFraction = isDragging ? dragFraction : positionFraction
        let trackHeight = isHovering || isDragging ? hoverHeight : restingHeight

        GeometryReader { geometry in
            let width = geometry.size.width
            let clampedFraction = min(max(displayFraction, 0), 1)
            let filledWidth = width * CGFloat(clampedFraction)

            ZStack(alignment: .leading) {
                // Unfilled (background) track.
                RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                    .fill(Color.gray.opacity(0.35))
                    .frame(height: trackHeight)

                // Filled (elapsed) portion.
                RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                    .fill(SpotiglassDesign.controlAccent)
                    .frame(width: max(filledWidth, 0), height: trackHeight)

                // Always-visible circular thumb at the current position.
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .overlay {
                        Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
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
                        let positionMs = Int((fraction * Double(durationMilliseconds)).rounded())
                        isDragging = false
                        onDragUpdate(nil)
                        onSeek(positionMs)
                    }
            )
            .animation(.easeInOut(duration: 0.12), value: isHovering)
        }
        .frame(height: hoverHeight + thumbDiameter)
        .accessibilityElement()
        .accessibilityLabel("Playback progress")
        .accessibilityValue("\(Int(displayFraction * 100))%")
    }
}

#Preview {
    ScrubberView(
        positionFraction: 0.35,
        durationMilliseconds: 240_000,
        onSeek: { _ in },
        onDragUpdate: { _ in }
    )
    .frame(width: 400)
    .padding()
}
