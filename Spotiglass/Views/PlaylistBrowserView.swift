import AppKit
import SwiftUI

struct PlaylistBrowserView: View {
    @StateObject private var viewModel: PlaylistBrowserViewModel
    @StateObject private var playbackViewModel: PlaybackSessionViewModel
    private let commander: WebPlaybackViewCommander
    private let playbackCoordinator: SpotifyPlaybackWebViewCoordinator
    let signOut: () -> Void

    init(
        viewModel: PlaylistBrowserViewModel,
        playbackTokenProvider: PlaybackAccessTokenProviding,
        signOut: @escaping () -> Void
    ) {
        let commander = WebPlaybackViewCommander()
        let playbackViewModel = PlaybackSessionViewModel(
            playbackAPI: SpotifyPlaybackAPI(tokenProvider: playbackTokenProvider),
            webCommander: commander
        )
        let playbackCoordinator = SpotifyPlaybackWebViewCoordinator(
            tokenBridge: PlaybackTokenBridge(provider: playbackTokenProvider)
        )
        playbackCoordinator.onEvent = { [weak playbackViewModel] event in
            playbackViewModel?.handle(event)
        }

        _viewModel = StateObject(wrappedValue: viewModel)
        _playbackViewModel = StateObject(wrappedValue: playbackViewModel)
        self.commander = commander
        self.playbackCoordinator = playbackCoordinator
        self.signOut = signOut
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                playlistSidebar
                    .background(.background)
                    .navigationSplitViewColumnWidth(min: 280, ideal: SpotiglassDesign.sidebarWidth)
            } detail: {
                playlistDetail
                    .background(.background)
            }

            PlaybackControlsView(viewModel: playbackViewModel)
        }
        .background(.background)
        .background {
            HiddenPlaybackWebView(commander: commander, coordinator: playbackCoordinator)
                .frame(width: 1, height: 1)
                .opacity(0.01)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await viewModel.refreshPlaylists() }
                } label: {
                    Label("Refresh Playlists", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityHint("Reloads playlists from Spotify and updates cached data.")

                Button {
                    signOut()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
                .accessibilityHint("Disconnects Spotify and returns to the sign-in screen.")
            }
        }
        .task {
            await viewModel.loadIfNeeded()
        }
        .task {
            playbackViewModel.start()
        }
    }

    private var playlistSidebar: some View {
        VStack(spacing: 0) {
            header(title: "Playlists", state: viewModel.playlistState)

            switch viewModel.playlistState {
            case .loading:
                ProgressView("Loading playlists...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .loaded(playlists), let .refreshing(playlists), let .staleCache(playlists, _):
                playlistList(playlists)
            case let .empty(message):
                EmptyStateView(title: "No playlists", message: message) {
                    Task { await viewModel.refreshPlaylists() }
                }
            case let .error(error):
                ErrorStateView(error: error) {
                    Task { await viewModel.refreshPlaylists() }
                }
            }
        }
    }

    private func playlistList(_ playlists: [PlaylistRowViewModel]) -> some View {
        List(selection: $viewModel.selectedPlaylistID) {
            ForEach(playlists) { playlist in
                PlaylistListRow(playlist: playlist)
                    .tag(playlist.id)
            }
        }
        .onChange(of: viewModel.selectedPlaylistID) { _, newValue in
            Task { await viewModel.selectPlaylist(id: newValue) }
        }
        .overlay(alignment: .bottom) {
            if case let .staleCache(_, error) = viewModel.playlistState {
                StaleCacheBanner(error: error)
            } else if case .refreshing = viewModel.playlistState {
                ProgressView("Refreshing playlists...")
                    .controlSize(.small)
                    .padding(SpotiglassDesign.spacingS)
                    .background(.background, in: Capsule())
                    .padding(SpotiglassDesign.spacingM)
            }
        }
        .listStyle(.sidebar)
    }

    private var playlistDetail: some View {
        VStack(spacing: 0) {
            switch viewModel.detailState {
            case .loading:
                ProgressView("Loading tracks...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .loaded(detail), let .refreshing(detail), let .staleCache(detail, _):
                PlaylistDetailContent(
                    detail: detail,
                    refresh: {
                        Task { await viewModel.refreshSelectedPlaylist() }
                    },
                    playURI: { uri in
                        Task { await playbackViewModel.play(uri: uri) }
                    },
                    currentPlaybackURI: currentPlaybackURI
                )
                .overlay(alignment: .bottom) {
                    if case let .staleCache(_, error) = viewModel.detailState {
                        StaleCacheBanner(error: error)
                    } else if case .refreshing = viewModel.detailState {
                        ProgressView("Refreshing tracks...")
                            .controlSize(.small)
                            .padding(SpotiglassDesign.spacingS)
                            .background(.background, in: Capsule())
                            .padding(SpotiglassDesign.spacingM)
                    }
                }
            case let .empty(message):
                EmptyStateView(title: "No tracks", message: message) {
                    Task { await viewModel.refreshSelectedPlaylist() }
                }
            case let .error(error):
                ErrorStateView(error: error) {
                    Task { await viewModel.refreshSelectedPlaylist() }
                }
            }
        }
    }

    private func header<Value: Equatable>(title: String, state: BrowsingLoadState<Value>) -> some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            Text(title)
                .font(.title2.weight(.semibold))

            switch state {
            case .staleCache:
                Text("Showing cached data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .refreshing:
                Text("Refreshing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SpotiglassDesign.spacingM)
    }

    private var currentPlaybackURI: String? {
        switch playbackViewModel.connectionState {
        case let .playing(nowPlaying):
            nowPlaying.uri
        case let .paused(nowPlaying):
            nowPlaying?.uri
        case .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            nil
        }
    }
}

private struct PlaylistListRow: View {
    let playlist: PlaylistRowViewModel

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            ArtworkView(url: playlist.artworkURL, size: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title)
                    .font(.headline)
                    .lineLimit(1)

                Text("\(playlist.owner) • \(playlist.trackCountText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, SpotiglassDesign.spacingXS)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(playlist.title), by \(playlist.owner), \(playlist.trackCountText)")
    }
}

private struct PlaylistDetailContent: View {
    let detail: PlaylistDetailViewModel
    let refresh: () -> Void
    let playURI: (String) -> Void
    let currentPlaybackURI: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: SpotiglassDesign.spacingL) {
                ArtworkView(url: detail.playlist.artworkURL, size: 104)

                VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
                    Text(detail.playlist.title)
                        .font(.largeTitle.weight(.semibold))
                        .lineLimit(2)

                    Text("\(detail.playlist.owner) • \(detail.playlist.trackCountText)")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: refresh) {
                    Label("Refresh Tracks", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("t", modifiers: .command)
                .accessibilityHint("Reloads tracks for the selected playlist.")
            }
            .padding(SpotiglassDesign.spacingL)

            Divider()

            if detail.tracks.isEmpty {
                EmptyStateView(title: "No tracks", message: "This playlist is empty.", retry: refresh)
            } else {
                List(detail.tracks) { track in
                    TrackListRow(
                        track: track,
                        playURI: playURI,
                        isCurrent: track.playableURI != nil && track.playableURI == currentPlaybackURI
                    )
                }
            }
        }
    }
}

private struct TrackListRow: View {
    let track: TrackRowViewModel
    let playURI: (String) -> Void
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            ArtworkView(url: track.artworkURL, size: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(track.title)
                        .font(.headline)
                        .foregroundStyle(track.isUnavailable ? .secondary : .primary)
                        .lineLimit(1)

                    if let badgeText = track.badgeText {
                        Text(badgeText)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15), in: Capsule())
                    }
                }

                Text(track.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(track.durationText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if let playableURI = track.playableURI {
                Button {
                    playURI(playableURI)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("Play in Spotiglass")
                .accessibilityLabel("Play \(track.title)")
                .accessibilityHint("Starts playback in the hidden Spotify Web Playback device.")
            }
        }
        .padding(.vertical, SpotiglassDesign.spacingXS)
        .padding(.horizontal, SpotiglassDesign.spacingXS)
        .background(
            RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                .fill(isCurrent ? Color.accentColor.opacity(0.14) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard let playableURI = track.playableURI else { return }
            playURI(playableURI)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.title), \(track.subtitle), \(track.durationText)\(isCurrent ? ", currently playing" : "")")
    }
}

private struct ArtworkView: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
            .fill(.secondary.opacity(0.16))
            .overlay {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
            }
    }
}

private struct EmptyStateView: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: SpotiglassDesign.spacingM) {
            Text(title)
                .font(.title3.weight(.semibold))

            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            // Retry is intentionally not bound to a keyboard shortcut here:
            // both the sidebar and detail panes can be in their own empty/error
            // state at the same time, and binding ⌘R to multiple Retry buttons
            // makes the shortcut ambiguous. The toolbar's Refresh Playlists
            // (⌘R) and Refresh Tracks (⌘T) buttons remain authoritative.
            Button("Retry", action: retry)
        }
        .padding(SpotiglassDesign.spacingL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

private struct ErrorStateView: View {
    let error: BrowsingDisplayError
    let retry: () -> Void
    @State private var isShowingDiagnosticAlert = false

    var body: some View {
        VStack(spacing: SpotiglassDesign.spacingM) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(error.title)
                .font(.title3.weight(.semibold))

            Text(error.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if error.canRetry {
                Button("Retry", action: retry)
            }
        }
        .padding(SpotiglassDesign.spacingL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .onAppear {
            isShowingDiagnosticAlert = error.diagnosticDetails != nil
        }
        .onChange(of: error.id) { _, _ in
            isShowingDiagnosticAlert = error.diagnosticDetails != nil
        }
        .alert(error.title, isPresented: $isShowingDiagnosticAlert) {
            if let diagnosticDetails = error.diagnosticDetails {
                Button("Copy Error") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnosticDetails, forType: .string)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(error.diagnosticDetails ?? error.message)
        }
    }
}

private struct StaleCacheBanner: View {
    let error: BrowsingDisplayError?

    var body: some View {
        Text(error?.message ?? "Showing cached data while Spotify refreshes.")
            .font(.caption)
            .padding(SpotiglassDesign.spacingS)
            .background(.background, in: Capsule())
            .padding(SpotiglassDesign.spacingM)
    }
}

#Preview {
    PlaylistBrowserView(
        viewModel: PlaylistBrowserViewModel(
            api: PreviewBrowsingAPI(),
            cache: PreviewBrowsingCache()
        ),
        playbackTokenProvider: PreviewPlaybackTokenProvider(),
        signOut: {}
    )
}

private struct PreviewBrowsingAPI: SpotifyBrowsingAPI {
    func currentUserPlaylists(limit: Int) async throws -> [SpotifyPlaylistSummary] {
        [
            SpotifyPlaylistSummary(id: "playlist", name: "Preview Playlist", description: nil, ownerName: "Isaac", imageURL: nil, trackCount: 2, isPublic: nil, isCollaborative: false, snapshotID: "snapshot")
        ]
    }

    func playlistTracks(playlistID: String, limit: Int) async throws -> [SpotifyPlaylistTrackItem] {
        [
            SpotifyPlaylistTrackItem(id: "track", addedAt: nil, content: .track(SpotifyTrack(id: "track", name: "Preview Track", artists: ["Artist"], albumArtworkURL: nil, durationMilliseconds: 181_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:track")))
        ]
    }
}

private struct PreviewBrowsingCache: SpotifyBrowsingCache {
    func loadPlaylists(now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistSummary]? { nil }
    func savePlaylists(_ playlists: [SpotifyPlaylistSummary], cachedAt: Date) throws {}
    func loadTracks(playlistID: String, snapshotID: String, now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistTrackItem]? { nil }
    func saveTracks(_ tracks: [SpotifyPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws {}
    func invalidateTracks(playlistID: String) throws {}
}

@MainActor
private final class PreviewPlaybackTokenProvider: PlaybackAccessTokenProviding {
    func playbackAccessToken() async throws -> String { "preview-token" }
    func refreshedPlaybackAccessToken() async throws -> String { "preview-token" }
}
