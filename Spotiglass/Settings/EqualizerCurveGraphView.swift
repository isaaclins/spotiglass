import AppKit
import SwiftUI

/// Log-scaled frequency response graph with a smooth curve through the ten EQ band gains.
/// Control points are draggable vertically; X positions match ``EqualizerSettings/bandFrequenciesHz``.
struct EqualizerCurveGraphView: View {
    let bandGainsDB: [Double]
    let onBandGainChange: (Int, Double) -> Void

    @State private var activeDrag: ActiveDrag?

    private struct ActiveDrag {
        let bandIndex: Int
        let startGainDB: Double
    }

    var body: some View {
        GeometryReader { geo in
            let layout = PlotLayout(size: geo.size)
            let anchors = anchorPoints(layout: layout)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                    .fill(Color.primary.opacity(0.04))

                gridAndAxes(layout: layout)
                fillPath(anchors: anchors, layout: layout)
                curveStroke(anchors: anchors)

                ForEach(0..<EqualizerSettings.bandCount, id: \.self) { index in
                    bandHandle(
                        index: index,
                        layout: layout,
                        anchor: anchors[index]
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: plotSpaceName)
        }
        .frame(minHeight: 240)
        .accessibilityElement(children: .contain)
    }

    private let plotSpaceName = "equalizerPlot"

    // MARK: - Layers

    private func gridAndAxes(layout: PlotLayout) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())

            // Vertical grid at each band frequency
            ForEach(0..<EqualizerSettings.bandCount, id: \.self) { index in
                let hz = EqualizerSettings.bandFrequenciesHz[index]
                let x = layout.x(forFrequencyHz: hz)
                Path { path in
                    path.move(to: CGPoint(x: x, y: layout.plotRect.minY))
                    path.addLine(to: CGPoint(x: x, y: layout.plotRect.maxY))
                }
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }

            // 0 dB reference
            Path { path in
                path.move(to: CGPoint(x: layout.plotRect.minX, y: layout.y(forGainDB: 0)))
                path.addLine(to: CGPoint(x: layout.plotRect.maxX, y: layout.y(forGainDB: 0)))
            }
            .stroke(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))

            // Y-axis labels (+12, -12)
            VStack(alignment: .leading, spacing: 0) {
                Text("+\(Int(EqualizerSettings.gainRangeDB.upperBound)) dB")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(Int(EqualizerSettings.gainRangeDB.lowerBound)) dB")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: layout.leftGutter - 4, height: layout.plotRect.height, alignment: .topLeading)
            .offset(x: 0, y: layout.plotRect.minY)

            // Frequency labels (aligned to log-spaced band centers)
            ZStack(alignment: .topLeading) {
                ForEach(0..<EqualizerSettings.bandCount, id: \.self) { index in
                    let hz = EqualizerSettings.bandFrequenciesHz[index]
                    Text(formattedFrequency(hz))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .frame(width: 44, alignment: .center)
                        .position(
                            x: layout.x(forFrequencyHz: hz),
                            y: layout.bottomGutter / 2
                        )
                }
            }
            .frame(width: layout.size.width, height: layout.bottomGutter, alignment: .topLeading)
            .offset(y: layout.plotRect.maxY + 4)
        }
    }

    private func fillPath(anchors: [CGPoint], layout: PlotLayout) -> some View {
        let bottomY = layout.plotRect.maxY
        let fillShape = EqualizerCurvePaths.closedFill(points: anchors, bottomY: bottomY)

        return fillShape
            .fill(
                LinearGradient(
                    colors: [
                        SpotiglassDesign.controlAccent.opacity(0.45),
                        SpotiglassDesign.controlAccent.opacity(0.08),
                        SpotiglassDesign.controlAccent.opacity(0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    private func curveStroke(anchors: [CGPoint]) -> some View {
        EqualizerCurvePaths.smoothCurve(points: anchors)
            .stroke(SpotiglassDesign.controlAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }

    private func bandHandle(index: Int, layout: PlotLayout, anchor: CGPoint) -> some View {
        let hz = EqualizerSettings.bandFrequenciesHz[index]
        let gain = bandGainsDB[index]
        let label = "\(formattedFrequency(hz)), \(formatGainAccessibility(gain))"
        let bandTitle = hz >= 1000
            ? String(format: "%.1f kilohertz band", hz / 1000)
            : String(format: "%.0f hertz band", hz)

        return ZStack {
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    Circle()
                        .stroke(SpotiglassDesign.controlAccent, lineWidth: 2)
                }
                .frame(width: 14, height: 14)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        }
        .frame(width: 32, height: 32)
        .contentShape(Circle())
        .position(anchor)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(plotSpaceName))
                .onChanged { value in
                    if activeDrag == nil {
                        activeDrag = ActiveDrag(bandIndex: index, startGainDB: bandGainsDB[index])
                    }
                    guard let drag = activeDrag, drag.bandIndex == index else { return }
                    let proposed = drag.startGainDB + layout.gainDelta(forVerticalTranslation: value.translation.height)
                    let stepped = EqualizerSettings.clampGain((proposed / 0.5).rounded() * 0.5)
                    onBandGainChange(index, stepped)
                }
                .onEnded { _ in
                    if activeDrag?.bandIndex == index {
                        activeDrag = nil
                    }
                }
        )
        .accessibilityLabel(Text(bandTitle))
        .accessibilityValue(Text(label))
        .accessibilityAdjustableAction { direction in
            let step = 0.5
            let current = bandGainsDB[index]
            let next: Double
            switch direction {
            case .increment:
                next = EqualizerSettings.clampGain(current + step)
            case .decrement:
                next = EqualizerSettings.clampGain(current - step)
            @unknown default:
                next = current
            }
            onBandGainChange(index, next)
        }
    }

    private func anchorPoints(layout: PlotLayout) -> [CGPoint] {
        (0..<EqualizerSettings.bandCount).map { index in
            let hz = EqualizerSettings.bandFrequenciesHz[index]
            let gain = bandGainsDB[index]
            return CGPoint(
                x: layout.x(forFrequencyHz: hz),
                y: layout.y(forGainDB: gain)
            )
        }
    }

    private func formattedFrequency(_ frequencyHz: Double) -> String {
        if frequencyHz >= 1000 {
            return String(format: "%.0fk", frequencyHz / 1000)
        }
        return String(format: "%.0f", frequencyHz)
    }

    private func formatGainAccessibility(_ gain: Double) -> String {
        String(format: "%.1f decibels", gain)
    }
}

// MARK: - Plot layout

private struct PlotLayout {
    let size: CGSize
    let leftGutter: CGFloat = 40
    let bottomGutter: CGFloat = 22
    let topPadding: CGFloat = 6

    var plotRect: CGRect {
        let w = size.width - leftGutter
        let h = size.height - bottomGutter - topPadding
        return CGRect(
            x: leftGutter,
            y: topPadding,
            width: max(1, w),
            height: max(1, h)
        )
    }

    private var logMin: Double { log10(EqualizerSettings.bandFrequenciesHz[0]) }
    private var logMax: Double { log10(EqualizerSettings.bandFrequenciesHz[EqualizerSettings.bandCount - 1]) }

    func x(forFrequencyHz hz: Double) -> CGFloat {
        let t = (log10(hz) - logMin) / (logMax - logMin)
        return plotRect.minX + CGFloat(t) * plotRect.width
    }

    func y(forGainDB gain: Double) -> CGFloat {
        let g = EqualizerSettings.clampGain(gain)
        let minG = EqualizerSettings.gainRangeDB.lowerBound
        let maxG = EqualizerSettings.gainRangeDB.upperBound
        let t = (g - minG) / (maxG - minG)
        return plotRect.maxY - CGFloat(t) * plotRect.height
    }

    /// Dragging down (positive translation height) lowers gain.
    func gainDelta(forVerticalTranslation height: CGFloat) -> Double {
        let range = EqualizerSettings.gainRangeDB.upperBound - EqualizerSettings.gainRangeDB.lowerBound
        return -Double(height / plotRect.height) * range
    }
}

// MARK: - Paths (Catmull–Rom → cubic Bézier)

private enum EqualizerCurvePaths {
    /// Open smooth curve through `points` (at least two points).
    static func smoothCurve(points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count >= 2 else { return path }
        path.move(to: points[0])
        appendCatmullRomCentripetal(to: &path, points: points)
        return path
    }

    /// Closed region: under the curve down to `bottomY`.
    static func closedFill(points: [CGPoint], bottomY: CGFloat) -> Path {
        var path = Path()
        guard points.count >= 2 else { return path }
        path.move(to: CGPoint(x: points[0].x, y: bottomY))
        path.addLine(to: points[0])
        appendCatmullRomCentripetal(to: &path, points: points)
        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: bottomY))
        path.closeSubpath()
        return path
    }

    private static func appendCatmullRomCentripetal(to path: inout Path, points: [CGPoint]) {
        let n = points.count
        for i in 0..<(n - 1) {
            let p0 = i > 0 ? points[i - 1] : points[i]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = i + 2 < n ? points[i + 2] : points[i + 1]

            let (c1, c2) = catmullRomToBezierControlPoints(p0: p0, p1: p1, p2: p2, p3: p3)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
    }

    /// Uniform Catmull–Rom (alpha=0.5 chordal blend) as cubic Bézier from `p1` to `p2`.
    private static func catmullRomToBezierControlPoints(
        p0: CGPoint,
        p1: CGPoint,
        p2: CGPoint,
        p3: CGPoint
    ) -> (CGPoint, CGPoint) {
        let c1 = CGPoint(
            x: p1.x + (p2.x - p0.x) / 6,
            y: p1.y + (p2.y - p0.y) / 6
        )
        let c2 = CGPoint(
            x: p2.x - (p3.x - p1.x) / 6,
            y: p2.y - (p3.y - p1.y) / 6
        )
        return (c1, c2)
    }
}
