import SwiftUI

// MARK: - Motion design constants

enum LyricsMotion {
    /// Long, organic spring that drives the scroll position. No overshoot, settles softly.
    static let centerSpring: Animation = .spring(response: 0.72, dampingFraction: 0.86)

    /// Fast, slightly bouncy spring for per-line styling transitions (font, opacity, scale).
    static let lineSpring: Animation = .spring(response: 0.42, dampingFraction: 0.78)

    /// Spring for the resume pill enter/exit.
    static let pillSpring: Animation = .spring(response: 0.46, dampingFraction: 0.82)

    /// Spring for lyrics-text-size changes — slightly longer to let typography settle.
    static let sizeSpring: Animation = .spring(response: 0.48, dampingFraction: 0.82)

    /// Engage/disengage state crossfade.
    static let engageSpring: Animation = .spring(response: 0.35, dampingFraction: 0.9)

    static func shouldAnimate(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        shouldAnimate(reduceMotion: reduceMotion) ? animation : nil
    }
}

/// The semantic output of a lyrics scroll view, kept separate from SwiftUI's
/// realised container tree. Both scroll views render this model, so tests can
/// verify line order and emphasis without depending on OS-specific ViewInspector
/// traversal of `ScrollView`/`LazyVStack`.
struct LyricsScrollRenderModel: Equatable {
    struct Line: Equatable, Identifiable {
        let id: Int
        let text: String
        let distance: Int
        let seekPositionMs: Int?

        var isActive: Bool { distance == 0 }
    }

    let activeID: Int
    let lines: [Line]

    static func timed(
        lines: [SyncedLyricLine],
        positionMs: Int
    ) -> Self {
        let activeIndex = LrcLineParser.activeTimedLineIndex(positionMs: positionMs, lines: lines)
        let activeID = lines.indices.contains(activeIndex) ? lines[activeIndex].id : (lines.first?.id ?? 0)
        let renderLines = lines.enumerated().map { _, line in
            Line(
                id: line.id,
                text: line.words,
                distance: line.id - activeID,
                seekPositionMs: line.startTimeMs
            )
        }
        return Self(activeID: activeID, lines: renderLines)
    }

    static func plain(
        lines: [String],
        positionMs: Int,
        durationMs: Int?
    ) -> Self {
        let duration = max(durationMs ?? 1, 1)
        let activeIndex = LrcLineParser.activePlainLineIndex(
            positionMs: positionMs,
            durationMs: duration,
            lineCount: lines.count
        )
        let renderLines = lines.enumerated().map { index, text in
            Line(
                id: index,
                text: text,
                distance: index - activeIndex,
                seekPositionMs: nil
            )
        }
        return Self(activeID: activeIndex, lines: renderLines)
    }
}

enum ImmersiveLyricsReadyContentModel: Equatable {
    case instrumental
    case timed(LyricsScrollRenderModel)
    case plain(LyricsScrollRenderModel)

    static func renderModel(
        for lyrics: FetchedLyrics,
        positionMs: Int,
        trackDurationMs: Int?
    ) -> Self {
        switch lyrics {
        case .instrumental:
            .instrumental
        case .synced(let lines):
            .timed(.timed(lines: lines, positionMs: positionMs))
        case .unsyncedPlain(let lines):
            .plain(.plain(lines: lines, positionMs: positionMs, durationMs: trackDurationMs))
        }
    }
}

// MARK: - Auto-center controller

/// Drives teleprompter-style auto-centering for the immersive lyrics scroll view.
///
/// While `isAutoCentering` is `true`, the scroll view locks the active line to the
/// vertical center. The first real user scroll gesture flips it to `false`, freezing
/// the view under the user's control. After `ImmersiveLyricsLayout.autoCenterResumeDelay`
/// of no further scroll-phase activity, it re-engages.
@MainActor
@Observable
final class LyricsAutoCenterController {
    var isAutoCentering: Bool = true
    private var idleTask: Task<Void, Never>?

    /// Called from `.onScrollPhaseChange` when the user is actively scrolling
    /// (tracking / interacting / decelerating). Hover events don't reach here.
    func noteUserScrollActivity() {
        isAutoCentering = false
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: ImmersiveLyricsLayout.autoCenterResumeDelay)
            guard !Task.isCancelled else { return }
            self?.isAutoCentering = true
        }
    }

    /// Tapped via the "Return to current line" pill — re-engages immediately.
    func engageImmediately() {
        idleTask?.cancel()
        idleTask = nil
        isAutoCentering = true
    }
}

// MARK: - Generic teleprompter scroll core

/// Shared scroll container that locks `activeID` to the vertical center while
/// `controller.isAutoCentering` is `true`, freezes under the user when they scroll,
/// and re-engages after the idle timeout.
///
/// Note: hover/cursor movement does NOT trigger `ScrollPhase` transitions, so it
/// will not disengage auto-centering. Only real scroll/drag gestures do.
struct ImmersiveLyricsScrollCore<ID: Hashable, Content: View>: View {
    let activeID: ID
    let reduceMotion: Bool
    let usesLyricsScrollEdgeFade: Bool
    /// Content closure receives an `engageAutoCenter` callback so tappable
    /// lines inside can re-engage the auto-center on tap (mirrors what the
    /// "Return to current line" pill does), letting the scroll position
    /// follow the seek.
    @ViewBuilder var content: (_ engageAutoCenter: @escaping () -> Void) -> Content

    @State private var controller = LyricsAutoCenterController()
    @State private var scrolledID: ID?

    var body: some View {
        ZStack(alignment: .bottom) {
            scrollView
                .scrollPosition(id: $scrolledID, anchor: .center)
                .scrollClipDisabled()
                .onScrollPhaseChange { _, newPhase in
                    switch newPhase {
                    case .tracking, .interacting, .decelerating:
                        controller.noteUserScrollActivity()
                    default:
                        break
                    }
                }
                .onAppear {
                    // First show: snap (no animation) so we don't see a long scroll-in.
                    scrolledID = activeID
                }
                .onChange(of: activeID) { _, new in
                    guard controller.isAutoCentering else { return }
                    centerOn(new, animated: !reduceMotion)
                }
                .onChange(of: controller.isAutoCentering) { _, engaged in
                    guard engaged else { return }
                    centerOn(activeID, animated: !reduceMotion)
                }

            if !controller.isAutoCentering {
                LyricsReturnToCurrentLinePill {
                    controller.engageImmediately()
                    centerOn(activeID, animated: !reduceMotion)
                }
                .padding(.bottom, ImmersiveLyricsLayout.resumePillBottomInset)
                .transition(resumePillTransition)
            }
        }
        .animation(
            LyricsMotion.animation(LyricsMotion.engageSpring, reduceMotion: reduceMotion),
            value: controller.isAutoCentering
        )
    }

    private var resumePillTransition: AnyTransition {
        guard LyricsMotion.shouldAnimate(reduceMotion: reduceMotion) else { return .identity }
        return .asymmetric(
            insertion: .scale(scale: 0.85, anchor: .bottom)
                .combined(with: .opacity)
                .combined(with: .offset(y: 12)),
            removal: .scale(scale: 0.9, anchor: .bottom)
                .combined(with: .opacity)
                .combined(with: .offset(y: 6))
        )
    }

    @ViewBuilder
    private var scrollView: some View {
        let inner = ScrollView {
            content(engageAutoCenter)
                .padding(.top, ImmersiveLyricsLayout.lyricsInnerTopPadding)
                .padding(.bottom, ImmersiveLyricsLayout.lyricsInnerBottomPadding)
        }
        if usesLyricsScrollEdgeFade {
            inner.mask { ImmersiveLyricsLayout.scrollEdgeFadeGradient }
        } else {
            inner
        }
    }

    private func engageAutoCenter() {
        controller.engageImmediately()
        centerOn(activeID, animated: !reduceMotion)
    }

    private func centerOn(_ id: ID, animated: Bool) {
        if animated {
            withAnimation(LyricsMotion.centerSpring) {
                scrolledID = id
            }
        } else {
            scrolledID = id
        }
    }
}

// MARK: - Timed lyrics

struct ImmersiveLyricsTimedLyricsScrollView: View {
    let renderModel: LyricsScrollRenderModel
    let maxHeight: CGFloat
    let reduceMotion: Bool
    let usesLyricsScrollEdgeFade: Bool
    let lyricsTextSize: LyricsTextMetrics
    /// Called with `startTimeMs` of the tapped line. When non-nil, lines
    /// become tappable buttons that seek playback there.
    var onSeek: ((Int) -> Void)? = nil

    init(
        renderModel: LyricsScrollRenderModel,
        maxHeight: CGFloat,
        reduceMotion: Bool,
        usesLyricsScrollEdgeFade: Bool,
        lyricsTextSize: LyricsTextMetrics,
        onSeek: ((Int) -> Void)? = nil
    ) {
        self.renderModel = renderModel
        self.maxHeight = maxHeight
        self.reduceMotion = reduceMotion
        self.usesLyricsScrollEdgeFade = usesLyricsScrollEdgeFade
        self.lyricsTextSize = lyricsTextSize
        self.onSeek = onSeek
    }

    var body: some View {
        ImmersiveLyricsScrollCore(
            activeID: renderModel.activeID,
            reduceMotion: reduceMotion,
            usesLyricsScrollEdgeFade: usesLyricsScrollEdgeFade
        ) { engageAutoCenter in
            LazyVStack(alignment: .leading, spacing: lyricsTextSize.timedLineSpacing) {
                ForEach(renderModel.lines) { line in
                    TappableLyricLine(
                        isActive: line.isActive,
                        reduceMotion: reduceMotion,
                        onTap: onSeek.flatMap { seek in
                            line.seekPositionMs.map { seekPositionMs in
                                {
                                    seek(seekPositionMs)
                                    engageAutoCenter()
                                }
                            }
                        }
                    ) {
                        ImmersiveLyricsLineText(
                            line.text,
                            distance: line.distance,
                            size: lyricsTextSize,
                            reduceMotion: reduceMotion
                        )
                    }
                    .id(line.id)
                }
            }
            .scrollTargetLayout()
            .animation(reduceMotion ? nil : LyricsMotion.lineSpring, value: renderModel.activeID)
            .animation(reduceMotion ? nil : LyricsMotion.sizeSpring, value: lyricsTextSize)
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .leading)
    }
}

// MARK: - Plain (unsynced) lyrics

struct ImmersiveLyricsPlainLyricsScrollView: View {
    let renderModel: LyricsScrollRenderModel
    let maxHeight: CGFloat
    let reduceMotion: Bool
    let usesLyricsScrollEdgeFade: Bool
    let lyricsTextSize: LyricsTextMetrics

    init(
        renderModel: LyricsScrollRenderModel,
        maxHeight: CGFloat,
        reduceMotion: Bool,
        usesLyricsScrollEdgeFade: Bool,
        lyricsTextSize: LyricsTextMetrics
    ) {
        self.renderModel = renderModel
        self.maxHeight = maxHeight
        self.reduceMotion = reduceMotion
        self.usesLyricsScrollEdgeFade = usesLyricsScrollEdgeFade
        self.lyricsTextSize = lyricsTextSize
    }

    var body: some View {
        ImmersiveLyricsScrollCore(
            activeID: renderModel.activeID,
            reduceMotion: reduceMotion,
            usesLyricsScrollEdgeFade: usesLyricsScrollEdgeFade
        ) { _ in
            // Plain unsynced lyrics have no per-line timestamp to seek to, so
            // they're not tappable and don't need the engageAutoCenter hook.
            LazyVStack(alignment: .leading, spacing: lyricsTextSize.plainLineSpacing) {
                ForEach(renderModel.lines) { line in
                    ImmersiveLyricsLineText(
                        line.text,
                        distance: line.distance,
                        size: lyricsTextSize,
                        reduceMotion: reduceMotion
                    )
                    .id(line.id)
                }
            }
            .scrollTargetLayout()
            .animation(reduceMotion ? nil : LyricsMotion.lineSpring, value: renderModel.activeID)
            .animation(reduceMotion ? nil : LyricsMotion.sizeSpring, value: lyricsTextSize)
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .leading)
    }
}

// MARK: - Line text

/// A lyric line styled by its `distance` (in lines) from the currently active line.
///
/// `distance == 0` is the active line: full white, bold, slight glow, scale 1.0.
/// As `|distance|` grows, the line fades, blurs, and shrinks subtly — Apple-Music-style.
struct ImmersiveLyricsLineText: View {
    let text: String
    let distance: Int
    let size: LyricsTextMetrics
    let reduceMotion: Bool

    init(_ text: String, distance: Int, size: LyricsTextMetrics, reduceMotion: Bool = false) {
        self.text = text
        self.distance = distance
        self.size = size
        self.reduceMotion = reduceMotion
    }

    private var isActive: Bool { distance == 0 }

    /// Continuous distance, capped so very-far lines don't visually disappear entirely.
    private var clampedDistance: CGFloat {
        min(CGFloat(abs(distance)), 6)
    }

    private var opacity: Double {
        // 0 -> 1.0, 1 -> 0.62, 2 -> 0.45, 3 -> 0.34, 4 -> 0.28, 5 -> 0.24, 6 -> 0.22
        let d = clampedDistance
        if d == 0 { return 1.0 }
        return max(0.22, 0.78 * pow(0.72, Double(d - 1)) + 0.22)
    }

    private var scale: CGFloat {
        // 0 -> 1.0, 1 -> 0.985, 2 -> 0.97, 3 -> 0.955, capped at ~0.93
        max(0.93, 1.0 - clampedDistance * 0.015)
    }

    private var blurRadius: CGFloat {
        // Active is crisp; lines fall off softly.
        min(clampedDistance * 0.45, 2.0)
    }

    private var fontSize: CGFloat {
        isActive ? size.activeFontSize : size.inactiveFontSize
    }

    private var font: Font {
        .system(size: fontSize, weight: isActive ? .semibold : .regular, design: .default)
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.white.opacity(opacity))
            .blur(radius: blurRadius)
            .scaleEffect(scale, anchor: .leading)
            // Soft white halo around the active line — disappears smoothly for non-active lines.
            .shadow(
                color: .white.opacity(isActive ? 0.18 : 0),
                radius: isActive ? size.activeGlowRadius : 0,
                x: 0,
                y: 0
            )
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentTransition(reduceMotion ? .identity : .interpolate)
            .animation(
                LyricsMotion.animation(LyricsMotion.lineSpring, reduceMotion: reduceMotion),
                value: distance
            )
            .animation(
                LyricsMotion.animation(LyricsMotion.lineSpring, reduceMotion: reduceMotion),
                value: isActive
            )
            .animation(
                LyricsMotion.animation(LyricsMotion.sizeSpring, reduceMotion: reduceMotion),
                value: size
            )
    }
}

// MARK: - Tappable line wrapper for click-to-seek

/// Wraps a lyric line in an interactive button when an `onTap` action is
/// provided. Press = scale only (no glow), release springs back with a
/// subtle overshoot, hover lifts brightness on non-active lines and shows
/// the link cursor.
///
/// When `onTap` is nil (e.g., unsynced plain lyrics with no per-line
/// timestamp), the content is rendered without any button wrapper so
/// there's zero interaction overhead.
struct TappableLyricLine<Content: View>: View {
    let isActive: Bool
    let reduceMotion: Bool
    let onTap: (() -> Void)?
    @ViewBuilder var content: () -> Content

    @State private var isHovered = false

    var body: some View {
        if let onTap = onTap {
            Button(action: onTap) {
                content()
                    // Subtle brightness lift on hover so the line feels
                    // reachable. Active line is already at peak luminance so
                    // no extra lift — just the cursor cue.
                    .brightness(isHovered && !isActive ? 0.08 : 0)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.12),
                        value: isHovered
                    )
            }
            .buttonStyle(TappableLyricButtonStyle(reduceMotion: reduceMotion))
            .pointerStyle(.link)
            .onHover { isHovered = $0 }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text(SpotiglassL10n.string("lyrics.jumpToLineHint")))
        } else {
            content()
        }
    }
}

/// Press-driven animation for tappable lyric lines. The spring's low damping
/// fraction (0.62) is what produces the ~1.02 release overshoot the design
/// calls for, without needing an explicit two-stage withAnimation chain.
private struct TappableLyricButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0, anchor: .leading)
            .animation(
                reduceMotion
                    ? nil
                    : .spring(response: 0.32, dampingFraction: 0.62),
                value: configuration.isPressed
            )
    }
}

// MARK: - "Return to current line" pill

struct LyricsReturnToCurrentLinePill: View {
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var iconPulse = false

    var body: some View {
        Button(action: action) {
            if LyricsMotion.shouldAnimate(reduceMotion: reduceMotion) {
                Label(SpotiglassL10n.string("lyrics.returnToLine"), systemImage: "scope")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.semibold))
                    .symbolEffect(.pulse, options: .repeating, value: iconPulse)
                    .foregroundStyle(.white)
            } else {
                Label(SpotiglassL10n.string("lyrics.returnToLine"), systemImage: "scope")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(SpotiglassPillStyle(
            variant: .glass,
            horizontalPadding: ImmersiveLyricsLayout.resumePillHorizontalPadding,
            verticalPadding: ImmersiveLyricsLayout.resumePillVerticalPadding
        ))
        .onAppear {
            if LyricsMotion.shouldAnimate(reduceMotion: reduceMotion) {
                iconPulse.toggle()
            }
        }
        .accessibilityLabel(SpotiglassL10n.string("lyrics.returnToLine"))
    }
}
