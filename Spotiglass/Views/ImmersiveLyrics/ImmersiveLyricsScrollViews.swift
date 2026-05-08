import SwiftUI

struct ImmersiveLyricsTimedLyricsScrollView: View {
    let lines: [SyncedLyricLine]
    let maxHeight: CGFloat
    let positionMs: Int
    let reduceMotion: Bool
    let usesLyricsScrollEdgeFade: Bool

    var body: some View {
        let activeIndex = LrcLineParser.activeTimedLineIndex(positionMs: positionMs, lines: lines)
        let syncedScroll = ImmersiveLyricsScrollCore {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(lines) { line in
                    ImmersiveLyricsLineText(line.words, isActive: line.id == activeIndex)
                        .id(line.id)
                }
            }
        }
        ScrollViewReader { proxy in
            Group {
                if usesLyricsScrollEdgeFade {
                    syncedScroll.mask { ImmersiveLyricsLayout.scrollEdgeFadeGradient }
                } else {
                    syncedScroll
                }
            }
            .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .leading)
            .onChange(of: activeIndex) { _, newValue in
                scrollLyricsIfNeeded(proxy: proxy, activeIndex: newValue, lines: lines)
            }
            .onAppear {
                guard !lines.isEmpty, lines.indices.contains(activeIndex) else { return }
                let scrollID = lines[activeIndex].id
                if reduceMotion {
                    proxy.scrollTo(scrollID, anchor: .center)
                } else {
                    withAnimation(.smooth(duration: 0.32)) {
                        proxy.scrollTo(scrollID, anchor: .center)
                    }
                }
            }
        }
    }

    private func scrollLyricsIfNeeded(proxy: ScrollViewProxy, activeIndex: Int, lines: [SyncedLyricLine]) {
        guard lines.indices.contains(activeIndex) else { return }
        let id = lines[activeIndex].id
        if reduceMotion {
            proxy.scrollTo(id, anchor: .center)
        } else {
            withAnimation(.smooth(duration: 0.35)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}

struct ImmersiveLyricsPlainLyricsScrollView: View {
    let lines: [String]
    let maxHeight: CGFloat
    let positionMs: Int
    let trackDurationMs: Int?
    let reduceMotion: Bool
    let usesLyricsScrollEdgeFade: Bool

    var body: some View {
        let duration = max(trackDurationMs ?? 1, 1)
        let active = LrcLineParser.activePlainLineIndex(
            positionMs: positionMs,
            durationMs: duration,
            lineCount: lines.count
        )
        let plainScroll = ImmersiveLyricsScrollCore {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, text in
                    ImmersiveLyricsLineText(text, isActive: index == active)
                        .id(index)
                }
            }
        }
        ScrollViewReader { proxy in
            Group {
                if usesLyricsScrollEdgeFade {
                    plainScroll.mask { ImmersiveLyricsLayout.scrollEdgeFadeGradient }
                } else {
                    plainScroll
                }
            }
            .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .leading)
            .onChange(of: active) { _, newValue in
                if reduceMotion {
                    proxy.scrollTo(newValue, anchor: .center)
                } else {
                    withAnimation(.smooth(duration: 0.28)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
            .onAppear {
                guard !lines.isEmpty, lines.indices.contains(active) else { return }
                if reduceMotion {
                    proxy.scrollTo(active, anchor: .center)
                } else {
                    withAnimation(.smooth(duration: 0.28)) {
                        proxy.scrollTo(active, anchor: .center)
                    }
                }
            }
        }
    }
}

struct ImmersiveLyricsScrollCore<Content: View>: View {
    @ViewBuilder private var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ScrollView {
            content()
                .padding(.top, ImmersiveLyricsLayout.lyricsInnerTopPadding)
                .padding(.bottom, ImmersiveLyricsLayout.lyricsInnerBottomPadding)
        }
    }
}

struct ImmersiveLyricsLineText: View {
    let text: String
    let isActive: Bool

    init(_ text: String, isActive: Bool) {
        self.text = text
        self.isActive = isActive
    }

    var body: some View {
        Text(text)
            .font(isActive ? .title2.weight(.semibold) : .title3)
            .foregroundStyle(.white.opacity(isActive ? 1 : 0.38))
            .blur(radius: isActive ? 0 : 0.35)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.smooth(duration: 0.22), value: isActive)
    }
}
