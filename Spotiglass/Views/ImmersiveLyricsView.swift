import AppKit
import SwiftUI

struct ImmersiveLyricsView: View {
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    @ObservedObject var queueViewModel: QueueViewModel
    @ObservedObject var lyricsModel: ImmersiveLyricsViewModel
    let navigateToArtist: (ArtistTapTarget) -> Void
    let navigateToAlbum: (AlbumTapTarget, String, URL?) -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
                .ignoresSafeArea()

            backgroundLayer
                .ignoresSafeArea()

            VStack(spacing: 0) {
                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: currentTrack?.uri) {
            guard let track = currentTrack else {
                onDismiss()
                return
            }
            async let lyricsLoad: Void = lyricsModel.load(track: track)
            async let queuePrefetch: Void = queueViewModel.prefetchQueueForLyricsOverlay()
            await lyricsLoad
            await queuePrefetch
        }
        .onExitCommand(perform: onDismiss)
    }

    @ViewBuilder
    private var mainContent: some View {
        GeometryReader { geo in
            let bottomPadding = max(SpotiglassDesign.spacingM, geo.safeAreaInsets.bottom)
            // Main layout relies on the host `VStack` safe area (below title bar). Do not add
            // `.padding(.top, safeAreaInsets.top)` here — it duplicates that inset and creates a large gap.
            let usableHeight = max(0, geo.size.height - bottomPadding)
            let leadingGutter = max(SpotiglassDesign.spacingL, geo.safeAreaInsets.leading)
            let trailingGutter = max(SpotiglassDesign.spacingL, geo.safeAreaInsets.trailing)
            let wide = geo.size.width > 720
            Group {
                if wide {
                    HStack(alignment: .top, spacing: SpotiglassDesign.spacingL) {
                        leftColumn
                            .frame(width: min(320, geo.size.width * 0.36), alignment: .leading)
                        lyricsScrollColumn(maxHeight: usableHeight)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: SpotiglassDesign.spacingM) {
                        leftColumn
                        lyricsScrollColumn(maxHeight: max(200, usableHeight * 0.5))
                    }
                }
            }
            .padding(.leading, leadingGutter)
            .padding(.trailing, trailingGutter)
            .padding(.bottom, bottomPadding)
        }
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            if let track = currentTrack {
                ArtworkView(url: track.albumArtURL, size: 220)
                    .shadow(color: .black.opacity(0.45), radius: 28, y: 14)

                HStack(alignment: .firstTextBaseline, spacing: SpotiglassDesign.spacingS) {
                    Text(track.name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        Task { await playbackViewModel.cycleRepeat() }
                    } label: {
                        Image(systemName: lyricsRepeatButtonIcon)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(lyricsRepeatUsesAccent ? SpotiglassDesign.controlAccent : .white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasPlaybackDeviceForTransportControls)
                    .accessibilityLabel(lyricsRepeatAccessibilityLabel)
                    .accessibilityHint("Cycles repeat: off, repeat playlist, repeat one track.")
                }

                lyricsArtistLine(track: track)

                if let album = track.albumName, !album.isEmpty {
                    Button {
                        navigateToAlbum(
                            AlbumTapTarget(id: track.albumID, name: album),
                            track.artistText,
                            track.albumArtURL
                        )
                    } label: {
                        Text(album)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open album \(album)")
                }

                nextInQueueSection
            }
        }
    }

    @ViewBuilder
    private func lyricsArtistLine(track: PlaybackNowPlaying) -> some View {
        if track.artistTapTargets.isEmpty {
            Text(track.artistText)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(track.artistTapTargets.enumerated()), id: \.element.stableID) { index, target in
                    if index > 0 {
                        Text(", ")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    Button {
                        navigateToArtist(target)
                    } label: {
                        Text(target.name)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open artist \(target.name)")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func queueUpcomingRow(item: QueueItem) -> some View {
        HStack(alignment: .center, spacing: SpotiglassDesign.spacingS) {
            ArtworkView(url: item.albumArtURL, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                queueUpcomingSubtitle(item: item)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func queueUpcomingSubtitle(item: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if item.artistTapTargets.isEmpty {
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(item.artistTapTargets.enumerated()), id: \.element.stableID) { index, target in
                        if index > 0 {
                            Text(", ")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        Button {
                            navigateToArtist(target)
                        } label: {
                            Text(target.name)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open artist \(target.name)")
                    }
                    Spacer(minLength: 0)
                }
            }

            if let albumName = item.albumName, !albumName.isEmpty {
                Button {
                    navigateToAlbum(
                        AlbumTapTarget(id: item.albumID, name: albumName),
                        item.subtitle,
                        item.albumArtURL
                    )
                } label: {
                    Text(albumName)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open album \(albumName)")
            }
        }
    }

    @ViewBuilder
    private var nextInQueueSection: some View {
        let upcoming = Array(queueViewModel.upcomingItems.prefix(3))
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            Text("NEXT IN QUEUE:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, SpotiglassDesign.spacingS)

            if upcoming.isEmpty {
                Text(nextInQueueEmptyMessage)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
                    ForEach(upcoming) { item in
                        queueUpcomingRow(item: item)
                    }
                }
            }
        }
    }

    private var nextInQueueEmptyMessage: String {
        if playbackViewModel.repeatMode == .track {
            return "This song repeats. Turn repeat off to see what plays next."
        }
        return "No upcoming tracks."
    }

    private var lyricsRepeatButtonIcon: String {
        switch playbackViewModel.repeatMode {
        case .off, .context:
            "infinity.circle"
        case .track:
            "infinity.circle.fill"
        }
    }

    private var lyricsRepeatUsesAccent: Bool {
        playbackViewModel.repeatMode != .off
    }

    private var lyricsRepeatAccessibilityLabel: String {
        switch playbackViewModel.repeatMode {
        case .off:
            "Repeat off"
        case .context:
            "Repeat playlist"
        case .track:
            "Repeat one"
        }
    }

    /// Matches ``PlaybackControlsView`` transport availability for prev/next/repeat.
    private var hasPlaybackDeviceForTransportControls: Bool {
        switch playbackViewModel.connectionState {
        case .ready, .transferring, .playing, .paused:
            true
        case .disconnected, .connecting, .unavailable, .error:
            false
        }
    }

    private func lyricsScrollColumn(maxHeight: CGFloat) -> some View {
        Group {
            switch lyricsModel.phase {
            case .idle:
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 160)
            case .loading:
                ProgressView("Loading lyrics…")
                    .controlSize(.large)
                    .tint(.white)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            case let .failed(message):
                VStack(alignment: .leading, spacing: 12) {
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.9))
                    if let track = currentTrack {
                        Button("Try again") {
                            Task { await lyricsModel.load(track: track) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case let .ready(lyrics):
                lyricsBody(lyrics: lyrics, maxHeight: maxHeight)
            }
        }
    }

    @ViewBuilder
    private func lyricsBody(lyrics: FetchedLyrics, maxHeight: CGFloat) -> some View {
        switch lyrics {
        case .instrumental:
            Text("This track is instrumental.")
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        case let .synced(lines):
            timedLyricsList(lines: lines, maxHeight: maxHeight)
        case let .unsyncedPlain(lines):
            plainLyricsList(lines: lines, maxHeight: maxHeight)
        }
    }

    private func timedLyricsList(lines: [SyncedLyricLine], maxHeight: CGFloat) -> some View {
        let activeIndex = LrcLineParser.activeTimedLineIndex(positionMs: positionMs, lines: lines)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(lines) { line in
                        lyricLineText(line.words, isActive: line.id == activeIndex)
                            .id(line.id)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
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

    private func plainLyricsList(lines: [String], maxHeight: CGFloat) -> some View {
        let duration = max(currentTrack?.durationMilliseconds ?? 1, 1)
        let active = LrcLineParser.activePlainLineIndex(
            positionMs: positionMs,
            durationMs: duration,
            lineCount: lines.count
        )
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, text in
                        lyricLineText(text, isActive: index == active)
                            .id(index)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
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

    private func lyricLineText(_ text: String, isActive: Bool) -> some View {
        Text(text)
            .font(isActive ? .title2.weight(.semibold) : .title3)
            .foregroundStyle(.white.opacity(isActive ? 1 : 0.38))
            .blur(radius: isActive ? 0 : 0.35)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.smooth(duration: 0.22), value: isActive)
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

    private var backgroundLayer: some View {
        Group {
            if reduceTransparency {
                Color.black
            } else {
                ZStack {
                    if let url = currentTrack?.albumArtURL {
                        ImmersiveBlurredArtwork(url: url)
                    } else {
                        Color.black
                    }

                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.5),
                            Color.black.opacity(0.78),
                            Color.black.opacity(0.88)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
        }
    }

    private var currentTrack: PlaybackNowPlaying? {
        switch playbackViewModel.connectionState {
        case let .playing(np):
            return np
        case let .paused(opt):
            return opt
        default:
            return nil
        }
    }

    private var positionMs: Int {
        switch playbackViewModel.connectionState {
        case let .playing(np):
            return np.positionMilliseconds
        case let .paused(opt):
            return opt?.positionMilliseconds ?? 0
        default:
            return 0
        }
    }
}

// MARK: - Blurred album backdrop (bounded cost)

/// Full-bleed blurred artwork: small source bitmap + moderate blur radius, then scale to fill.
/// Cheaper than blurring a 1600pt tile at r≈36 (previous approach).
private struct ImmersiveBlurredArtwork: View {
    let url: URL

    /// After optional downscale, this is the raster size SwiftUI blurs (not window size).
    private let blurredTileSize: CGFloat = 1_024
    private let blurRadius: CGFloat = 24
    /// One-time shrink before `blur` so the filter runs on fewer pixels.
    private let downscaleMaxEdge: CGFloat = 576

    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                        .frame(width: blurredTileSize, height: blurredTileSize)
                        .compositingGroup()
                        .blur(radius: blurRadius)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                } else {
                    Color.black
                }
            }
        }
        .task(id: url.absoluteString) {
            guard let full = await ArtworkImageStore.shared.image(for: url) else {
                image = nil
                return
            }
            image = Self.downscaledForBlur(full, maxEdge: downscaleMaxEdge)
        }
    }

    private static func downscaledForBlur(_ image: NSImage, maxEdge: CGFloat) -> NSImage {
        let s = image.size
        let w = s.width
        let h = s.height
        guard w > 0, h > 0 else { return image }
        let maxSide = max(w, h)
        guard maxSide > maxEdge else { return image }
        let scale = maxEdge / maxSide
        let nw = max(1, floor(w * scale))
        let nh = max(1, floor(h * scale))
        let out = NSImage(size: NSSize(width: nw, height: nh))
        out.lockFocus()
        if let ctx = NSGraphicsContext.current {
            ctx.imageInterpolation = .medium
        }
        image.draw(
            in: NSRect(x: 0, y: 0, width: nw, height: nh),
            from: NSRect(x: 0, y: 0, width: w, height: h),
            operation: .copy,
            fraction: 1
        )
        out.unlockFocus()
        return out
    }
}


