import SwiftUI

/// What the scrubber shows at a given moment: the playing position, or the
/// position under the pointer while the listener drags.
struct ScrubberProgress: Equatable {
    var anchor: PlaybackProgressAnchor?
    var durationMilliseconds: Int
    var dragFraction: Double?

    init(anchor: PlaybackProgressAnchor?, durationMilliseconds: Int, dragFraction: Double? = nil) {
        self.anchor = anchor
        self.dragFraction = dragFraction
        if let anchor, anchor.isAdvancing {
            self.durationMilliseconds = anchor.durationMilliseconds
        } else {
            self.durationMilliseconds = max(durationMilliseconds, anchor?.durationMilliseconds ?? 0)
        }
    }

    /// Whether the position moves by itself. A drag holds it still.
    var isAdvancing: Bool { dragFraction == nil && anchor?.isAdvancing == true }

    func positionMilliseconds(at date: Date) -> Int {
        if let dragFraction, durationMilliseconds > 0 {
            return Int((dragFraction * Double(durationMilliseconds)).rounded())
        }
        return anchor?.interpolatedPositionMs(at: date) ?? 0
    }

    func fraction(at date: Date) -> Double {
        guard durationMilliseconds > 0 else { return 0 }
        return min(max(Double(positionMilliseconds(at: date)) / Double(durationMilliseconds), 0), 1)
    }

    /// The timeline for anything drawn from this progress, waking at most
    /// `ticksPerSecond` times a second (see `ScrubberTimelineSchedule`), with a
    /// tick right after the position passes each `boundaryMilliseconds` mod 1000.
    func schedule(trackWidth: CGFloat, boundaryMilliseconds: Int = 0) -> ScrubberTimelineSchedule {
        ScrubberTimelineSchedule(
            anchor: anchor,
            isPaused: !isAdvancing,
            trackWidth: trackWidth,
            boundaryMilliseconds: boundaryMilliseconds
        )
    }

    /// Where the remaining time changes its whole second: when the position
    /// passes the duration minus a whole number of seconds. A 4:03.4 track
    /// shows a new remaining time 0.4 s after each new elapsed time.
    var remainingBoundaryMilliseconds: Int { max(durationMilliseconds, 0) % 1_000 }
}

/// Scrubber plus elapsed/remaining labels driven by `PlaybackProgressAnchor` and `TimelineView`.
///
/// Two things here are deliberate (#394):
///
/// - The views a listener interacts with never change structure while a track
///   plays, pauses or is dragged. Swapping a ticking branch for a static one
///   when a drag began gave the scrubber a new identity mid-gesture, so SwiftUI
///   dropped the gesture: the click never seeked, and the drag position stayed
///   stuck on screen, even into the next track.
/// - Only pixels move. The times and the played part of the track are drawn in
///   a `Canvas` inside a `TimelineView`; the views around them are sized once
///   per track. When the moving parts were views, every tick re-ran layout for
///   the whole window, and redrawing at display rate kept a CPU core busy.
struct PlaybackProgressScrubberGroup: View {
    var progressAnchor: PlaybackProgressAnchor?
    var durationMilliseconds: Int
    var isEnabled: Bool
    var onSeek: (Int) -> Void

    @State private var dragFraction: Double?

    var body: some View {
        let progress = ScrubberProgress(
            anchor: progressAnchor,
            durationMilliseconds: durationMilliseconds,
            dragFraction: dragFraction
        )
        let durationMs = progress.durationMilliseconds
        HStack(spacing: SpotiglassDesign.spacingS) {
            ScrubberTimeLabel(
                progress: progress,
                widestText: Self.widestTime(durationMs: durationMs),
                boundaryMilliseconds: 0,
                minWidth: 36,
                alignment: .trailing
            ) { positionMs in
                Self.elapsedText(positionMs: positionMs)
            }

            // The track is the essential seeking surface. Its surrounding
            // timestamps must not consume its entire width (#329).
            ScrubberView(
                progress: progress,
                onSeek: onSeek,
                onDragUpdate: { fraction in
                    dragFraction = fraction
                }
            )
            .frame(
                minWidth: PlaybackTransportLayoutPolicy.scrubberMinimumWidth,
                maxWidth: .infinity
            )
            .opacity(isEnabled ? 1 : 0.4)
            .disabled(!isEnabled)

            ScrubberTimeLabel(
                progress: progress,
                widestText: Self.remainingText(Self.widestTime(durationMs: durationMs)),
                boundaryMilliseconds: progress.remainingBoundaryMilliseconds,
                minWidth: 40,
                alignment: .leading
            ) { positionMs in
                Self.remainingText(positionMs: positionMs, durationMs: durationMs)
            }
        }
        .animation(.smooth(duration: 0.24), value: isEnabled)
    }

    static func elapsedText(positionMs: Int) -> String {
        PlaybackNowPlaying.mmss(milliseconds: positionMs)
    }

    static func remainingText(positionMs: Int, durationMs: Int) -> String {
        remainingText(PlaybackNowPlaying.mmss(milliseconds: max(0, durationMs - positionMs)))
    }

    private static func remainingText(_ time: String) -> String {
        String(format: SpotiglassL10n.string("playback.scrubber.remaining"), time)
    }

    /// The track's duration with every digit replaced by 0. Digits are
    /// monospaced, so this is as wide as any time the track can show.
    static func widestTime(durationMs: Int) -> String {
        String(PlaybackNowPlaying.mmss(milliseconds: max(durationMs, 0)).map { $0.isNumber ? "0" : $0 })
    }
}

/// An elapsed or remaining time beside the scrubber.
///
/// Its size comes from a hidden copy of the widest time the track can show,
/// which only changes with the track; the live time is drawn on top once a
/// second. VoiceOver reads the time from the scrubber itself, whose value is
/// "1:24 of 4:00", so the drawn copy stays out of the accessibility tree.
private struct ScrubberTimeLabel: View {
    var progress: ScrubberProgress
    var widestText: String
    /// The label's text changes right after the position passes this, mod 1000.
    var boundaryMilliseconds: Int
    var minWidth: CGFloat
    var alignment: Alignment
    var text: (Int) -> String

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Text(widestText)
            .hidden()
            .frame(minWidth: minWidth, alignment: alignment)
            .overlay {
                // A width of 0 asks the schedule for its slowest rate: one
                // tick each time this label's whole second changes.
                TimelineView(progress.schedule(trackWidth: 0, boundaryMilliseconds: boundaryMilliseconds)) { context in
                    let label = Text(text(progress.positionMilliseconds(at: context.date)))
                    Canvas { canvas, size in
                        let resolved = canvas.resolve(label)
                        let textSize = resolved.measure(in: size)
                        // Whole pixels: on a 1x display a half-pixel origin blurs
                        // the one-pixel minus of the remaining time away.
                        let snap = { (value: CGFloat) in (value * displayScale).rounded() / displayScale }
                        let x = alignment == .trailing ? size.width - textSize.width : 0
                        let origin = CGPoint(x: snap(x), y: snap((size.height - textSize.height) / 2))
                        canvas.draw(resolved, in: CGRect(origin: origin, size: textSize))
                    }
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

/// A horizontal scrubber for the now-playing bar.
///
/// - Always shows a circular thumb at the current position.
/// - Track expands from 4pt to 6pt on hover.
/// - Click to seek immediately, click-and-drag to scrub.
/// - During drag, `onDragUpdate` exposes the in-progress fraction for timestamp labels.
struct ScrubberView: View {
    var progress: ScrubberProgress
    var onSeek: (Int) -> Void
    var onDragUpdate: (Double?) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private let restingHeight: CGFloat = 4
    private let hoverHeight: CGFloat = 6
    private let thumbDiameter: CGFloat = 12

    @State private var isHovering: Bool = false
    /// Resets to nil by itself when the drag ends or the system cancels it, so
    /// an interrupted gesture can never leave a stale position behind (#394).
    @GestureState private var liveDragFraction: Double?

    private var isDragging: Bool { liveDragFraction != nil }
    private var durationMilliseconds: Int { progress.durationMilliseconds }

    var body: some View {
        // The accessibility value is the only part of this view that reads the
        // clock. It refreshes whenever the view updates (every new position from
        // the player) and, while VoiceOver runs, once a second. Without
        // VoiceOver this timeline never ticks.
        TimelineView(
            ScrubberTimelineSchedule(
                anchor: progress.anchor,
                isPaused: !voiceOverEnabled || !progress.isAdvancing || isDragging,
                trackWidth: 0
            )
        ) { context in
            scrubberTrack(accessibilityPositionMs: progress.positionMilliseconds(at: context.date))
        }
        .onChange(of: liveDragFraction) { _, fraction in
            onDragUpdate(fraction)
        }
    }

    static func fraction(atX x: CGFloat, width: CGFloat) -> Double {
        Double(min(max(x, 0), width) / max(width, 1))
    }

    private func scrubberTrack(accessibilityPositionMs: Int) -> some View {
        // The drawing and the surface that takes the pointer are siblings. With
        // the canvas inside the hover, tooltip and accessibility modifiers,
        // every tick also refreshed the platform views AppKit keeps for them.
        ZStack {
            ScrubberTrackDrawing(
                trackHeight: isHovering || isDragging ? hoverHeight : restingHeight,
                progress: progress,
                dragFraction: liveDragFraction,
                thumbDiameter: thumbDiameter,
                colors: ScrubberTrackDrawing.Colors(
                    track: SpotiglassDesign.scrubberTrackColor(
                        colorScheme: colorScheme,
                        contrast: colorSchemeContrast
                    ),
                    played: SpotiglassDesign.accent(appearsActive: appearsActive),
                    thumbFill: SpotiglassDesign.scrubberThumbFillColor(colorScheme: colorScheme),
                    thumbBorder: SpotiglassDesign.scrubberThumbBorderColor(colorScheme: colorScheme)
                )
            )
            .animation(.easeInOut(duration: 0.12), value: isHovering)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            GeometryReader { geometry in
                let width = geometry.size.width
                Color.clear
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        isHovering = hovering
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($liveDragFraction) { value, state, _ in
                                state = Self.fraction(atX: value.location.x, width: width)
                            }
                            .onEnded { value in
                                let fraction = Self.fraction(atX: value.location.x, width: width)
                                let positionMs = Int((fraction * Double(max(durationMilliseconds, 0))).rounded())
                                onSeek(positionMs)
                            }
                    )
            }
            .accessibilityElement()
            .help(SpotiglassL10n.string("tooltip.playback.scrubber"))
            .accessibilityLabel(SpotiglassL10n.string("playback.scrubber.progress"))
            // Elapsed of total, not a bare percentage: "1:24 of 4:00" is what a
            // listener needs, and it matches the sighted labels either side of the
            // bar, which already use mmss (#110).
            .accessibilityValue(
                SpotiglassL10n.format(
                    "playback.scrubber.accessibilityValue",
                    PlaybackNowPlaying.mmss(milliseconds: accessibilityPositionMs),
                    PlaybackNowPlaying.mmss(milliseconds: max(durationMilliseconds, 0))
                )
            )
            // Without this the element is inert to VoiceOver: it reads a value it
            // cannot change. The EQ fader in this same codebase already pairs
            // .accessibilityElement() with an adjustable action (#110, #126).
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: seekBy(PlaybackSeekStep.milliseconds)
                case .decrement: seekBy(-PlaybackSeekStep.milliseconds)
                @unknown default: break
                }
            }
        }
        .frame(height: hoverHeight + thumbDiameter)
    }

    private func seekBy(_ deltaMilliseconds: Int) {
        guard durationMilliseconds > 0 else { return }
        // Read the clock now: the value VoiceOver last heard may be a second old.
        let target = progress.positionMilliseconds(at: Date()) + deltaMilliseconds
        onSeek(min(max(target, 0), durationMilliseconds))
    }
}

/// The track, its played part and the thumb, drawn rather than laid out.
///
/// A tick repaints these pixels and nothing else. `trackHeight` is animatable,
/// so the hover growth still eases in the 0.12 s the track always used.
private struct ScrubberTrackDrawing: View, Animatable {
    struct Colors: Equatable {
        var track: Color
        var played: Color
        var thumbFill: Color
        var thumbBorder: Color
    }

    var trackHeight: CGFloat
    var progress: ScrubberProgress
    var dragFraction: Double?
    var thumbDiameter: CGFloat
    var colors: Colors

    var animatableData: CGFloat {
        get { trackHeight }
        set { trackHeight = newValue }
    }

    /// How far the canvas reaches past each end of the track: the thumb hangs
    /// half its width past the end at 100 %, and its shadow a little further.
    /// A canvas clips to its bounds, so without this the thumb was cut in half
    /// near the end of a track.
    private var overhang: CGFloat { thumbDiameter / 2 + 2 }

    var body: some View {
        GeometryReader { geometry in
            let isPaused = dragFraction != nil || !progress.isAdvancing
            TimelineView(
                ScrubberTimelineSchedule(
                    anchor: progress.anchor,
                    isPaused: isPaused,
                    trackWidth: geometry.size.width
                )
            ) { context in
                let fraction = dragFraction.map { min(max($0, 0), 1) } ?? progress.fraction(at: context.date)
                Canvas { canvas, size in
                    canvas.translateBy(x: overhang, y: 0)
                    draw(
                        in: &canvas,
                        size: CGSize(width: size.width - 2 * overhang, height: size.height),
                        fraction: fraction
                    )
                }
                .padding(.horizontal, -overhang)
            }
        }
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, fraction: Double) {
        let midY = size.height / 2
        let radius = trackHeight / 2
        let track = CGRect(x: 0, y: midY - radius, width: size.width, height: trackHeight)
        canvas.fill(
            Path(roundedRect: track, cornerRadius: radius, style: .continuous),
            with: .color(colors.track)
        )

        let filledWidth = size.width * CGFloat(fraction)
        var played = track
        played.size.width = max(filledWidth, 0)
        canvas.fill(
            Path(roundedRect: played, cornerRadius: radius, style: .continuous),
            with: .color(colors.played)
        )

        let thumb = CGRect(
            x: max(0, filledWidth - thumbDiameter / 2),
            y: midY - thumbDiameter / 2,
            width: thumbDiameter,
            height: thumbDiameter
        )
        canvas.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.25), radius: 1.5, x: 0, y: 0.5))
            layer.fill(Path(ellipseIn: thumb), with: .color(colors.thumbFill))
            layer.stroke(
                Path(ellipseIn: thumb.insetBy(dx: 0.25, dy: 0.25)),
                with: .color(colors.thumbBorder),
                lineWidth: 0.5
            )
        }
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
        onSeek: { _ in }
    )
    .frame(width: 400)
    .padding()
}

/// Wakes the scrubber only when something on screen can change (#394).
///
/// `.animation` redrew the row at the display's refresh rate, up to 120 times a
/// second, while the labels change once a second and the filled track moves a
/// fraction of a point per second. That kept a whole CPU core busy during
/// playback. This schedule ticks just often enough for the fill to move half a
/// point (about one pixel on a Retina display) per tick, never faster than 30
/// times a second and never slower than once a second. Ticks are aligned so one
/// lands right after each change of a label's whole second (the elapsed time's
/// by default, the remaining time's with its `boundaryMilliseconds`), which keeps
/// both labels on time. A paused track, a drag in progress or a finished
/// track produces a single entry and no further wakeups.
struct ScrubberTimelineSchedule: TimelineSchedule {
    var anchor: PlaybackProgressAnchor?
    var isPaused: Bool
    var trackWidth: CGFloat
    /// Ticks land right after the position passes this many milliseconds past a
    /// whole second: 0 for the elapsed time, the duration's leftover
    /// milliseconds for the remaining time.
    var boundaryMilliseconds: Int = 0

    static let maximumTicksPerSecond = 30
    /// The fill may move at most this far between two ticks.
    static let maximumPointsPerTick: CGFloat = 0.5

    /// Ticks per second for a track of `durationMilliseconds` drawn `trackWidth` points wide.
    static func ticksPerSecond(durationMilliseconds: Int, trackWidth: CGFloat) -> Int {
        guard durationMilliseconds > 0, trackWidth > 0 else { return 1 }
        let pointsPerSecond = trackWidth / (CGFloat(durationMilliseconds) / 1_000)
        let needed = Int((pointsPerSecond / maximumPointsPerTick).rounded(.up))
        return min(max(needed, 1), maximumTicksPerSecond)
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        guard !isPaused, let anchor, anchor.isAdvancing, anchor.durationMilliseconds > 0 else {
            return Self.single(startDate)
        }
        let duration = anchor.durationMilliseconds
        let base = min(max(0, anchor.positionMilliseconds), duration)
        // Wall-clock time at which the position reaches the end of the track.
        let endDate = anchor.anchorDate.addingTimeInterval(Double(duration - base) / 1_000)
        guard startDate < endDate else { return Self.single(startDate) }

        let ticks = mode == .lowFrequency
            ? 1
            : Self.ticksPerSecond(durationMilliseconds: duration, trackWidth: trackWidth)
        let interval = 1 / Double(ticks)
        // First wall-clock moment the position crosses the boundary, plus 2 ms.
        // The elapsed time changes at the boundary, the remaining time 1 ms past
        // it (both round down), and `interpolatedPositionMs` truncates a date
        // that floating point can put a hair early.
        let boundary = ((boundaryMilliseconds % 1_000) + 1_000) % 1_000
        let phase = Double((boundary - base % 1_000 + 1_000) % 1_000 + 2) / 1_000
        let origin = anchor.anchorDate.addingTimeInterval(phase)
        // Ticks sit at origin + k * interval; computing each from k (instead of
        // adding the interval repeatedly) keeps them from drifting off the second.
        var step = (startDate.timeIntervalSince(origin) / interval).rounded(.down)
        var emittedStart = false
        var finished = false
        return AnyIterator {
            if !emittedStart {
                emittedStart = true
                return startDate
            }
            guard !finished else { return nil }
            var next: Date
            repeat {
                step += 1
                next = origin.addingTimeInterval(step * interval)
            } while next <= startDate
            if next >= endDate {
                // One last tick so the row settles on the final position.
                finished = true
                return endDate
            }
            return next
        }
    }

    private static func single(_ date: Date) -> AnyIterator<Date> {
        var done = false
        return AnyIterator {
            guard !done else { return nil }
            done = true
            return date
        }
    }
}
