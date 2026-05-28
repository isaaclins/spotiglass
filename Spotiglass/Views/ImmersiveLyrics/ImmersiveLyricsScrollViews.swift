import SwiftUI

// MARK: - Motion design constants

private enum LyricsMotion {
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
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.85, anchor: .bottom)
                            .combined(with: .opacity)
                            .combined(with: .offset(y: 12)),
                        removal: .scale(scale: 0.9, anchor: .bottom)
                            .combined(with: .opacity)
                            .combined(with: .offset(y: 6))
                    )
                )
            }
        }
        .animation(LyricsMotion.engageSpring, value: controller.isAutoCentering)
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
    let lines: [SyncedLyricLine]
    let maxHeight: CGFloat
    let positionMs: Int
    let reduceMotion: Bool
    let usesLyricsScrollEdgeFade: Bool
    let lyricsTextSize: LyricsTextSize
    /// Called with `startTimeMs` of the tapped line. When non-nil, lines
    /// become tappable buttons that seek playback there.
    var onSeek: ((Int) -> Void)? = nil

    var body: some View {
        let activeIndex = LrcLineParser.activeTimedLineIndex(positionMs: positionMs, lines: lines)
        let activeID = lines.indices.contains(activeIndex) ? lines[activeIndex].id : (lines.first?.id ?? 0)

        ImmersiveLyricsScrollCore(
            activeID: activeID,
            reduceMotion: reduceMotion,
            usesLyricsScrollEdgeFade: usesLyricsScrollEdgeFade
        ) { engageAutoCenter in
            LazyVStack(alignment: .leading, spacing: lyricsTextSize.timedLineSpacing) {
                ForEach(lines) { line in
                    TappableLyricLine(
                        isActive: line.id == activeID,
                        reduceMotion: reduceMotion,
                        onTap: onSeek.map { seek in
                            {
                                seek(line.startTimeMs)
                                engageAutoCenter()
                            }
                        }
                    ) {
                        ImmersiveLyricsLineText(
                            line.words,
                            distance: line.id - activeID,
                            size: lyricsTextSize
                        )
                    }
                    .id(line.id)
                }
            }
            .scrollTargetLayout()
            .animation(reduceMotion ? nil : LyricsMotion.lineSpring, value: activeID)
            .animation(reduceMotion ? nil : LyricsMotion.sizeSpring, value: lyricsTextSize)
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .leading)
    }
}

// MARK: - Plain (unsynced) lyrics

struct ImmersiveLyricsPlainLyricsScrollView: View {
    let lines: [String]
    let maxHeight: CGFloat
    let positionMs: Int
    let trackDurationMs: Int?
    let reduceMotion: Bool
    let usesLyricsScrollEdgeFade: Bool
    let lyricsTextSize: LyricsTextSize

    var body: some View {
        let duration = max(trackDurationMs ?? 1, 1)
        let active = LrcLineParser.activePlainLineIndex(
            positionMs: positionMs,
            durationMs: duration,
            lineCount: lines.count
        )

        ImmersiveLyricsScrollCore(
            activeID: active,
            reduceMotion: reduceMotion,
            usesLyricsScrollEdgeFade: usesLyricsScrollEdgeFade
        ) { _ in
            // Plain unsynced lyrics have no per-line timestamp to seek to, so
            // they're not tappable and don't need the engageAutoCenter hook.
            LazyVStack(alignment: .leading, spacing: lyricsTextSize.plainLineSpacing) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, text in
                    ImmersiveLyricsLineText(
                        text,
                        distance: index - active,
                        size: lyricsTextSize
                    )
                    .id(index)
                }
            }
            .scrollTargetLayout()
            .animation(reduceMotion ? nil : LyricsMotion.lineSpring, value: active)
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
    let size: LyricsTextSize

    init(_ text: String, distance: Int, size: LyricsTextSize) {
        self.text = text
        self.distance = distance
        self.size = size
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
            .contentTransition(.interpolate)
            .animation(LyricsMotion.lineSpring, value: distance)
            .animation(LyricsMotion.lineSpring, value: isActive)
            .animation(LyricsMotion.sizeSpring, value: size)
    }
}

// MARK: - Tappable line wrapper for click-to-seek

/// Wraps a lyric line in an interactive button when an `onTap` action is
/// provided. Drives a premium press / release / hover animation:
/// - Press: scale 0.97, soft white glow swells behind the line.
/// - Release: spring back to 1.0 with a subtle overshoot (the low damping
///   factor in `TappableLyricButtonStyle` produces a ~1.02 peak naturally).
/// - Hover: pointer cursor + a slight brightness lift on non-active lines.
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
                    .animation(.easeOut(duration: 0.12), value: isHovered)
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
            .background(alignment: .leading) {
                // Always-rendered glow whose opacity animates between 0 and
                // 0.08 — cleaner spring continuity than appearing/disappearing
                // the view via a conditional.
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(configuration.isPressed ? 0.08 : 0))
                    .blur(radius: 14)
                    .padding(.vertical, -6)
                    .padding(.horizontal, -10)
                    .allowsHitTesting(false)
            }
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

    @State private var iconPulse = false

    var body: some View {
        Button(action: action) {
            Label(SpotiglassL10n.string("lyrics.returnToLine"), systemImage: "scope")
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.semibold))
                .symbolEffect(.pulse, options: .repeating, value: iconPulse)
                .foregroundStyle(.white)
        }
        .buttonStyle(SpotiglassPillStyle(
            variant: .glass,
            horizontalPadding: ImmersiveLyricsLayout.resumePillHorizontalPadding,
            verticalPadding: ImmersiveLyricsLayout.resumePillVerticalPadding
        ))
        .onAppear { iconPulse.toggle() }
        .accessibilityLabel(SpotiglassL10n.string("lyrics.returnToLine"))
    }
}
