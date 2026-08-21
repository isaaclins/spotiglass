import SwiftUI

@MainActor
struct RootView: View {
    @EnvironmentObject private var viewModel: AuthViewModel
    @EnvironmentObject private var pinnedStore: PinnedItemsStore
    @StateObject private var commandPaletteManager: CommandPaletteManager
    @Environment(\.openSettings) private var openSettingsAction

    init() {
        _commandPaletteManager = StateObject(wrappedValue: CommandPaletteManager())
    }

    init(commandPaletteManager: CommandPaletteManager) {
        _commandPaletteManager = StateObject(wrappedValue: commandPaletteManager)
    }

    var body: some View {
        content
            .overlay {
                LyricsOverlayLayer()
            }
            .overlay {
                ZStack {
                    if commandPaletteManager.viewModel.isPresented {
                        CommandPaletteView(viewModel: commandPaletteManager.viewModel)
                            .transition(
                                .asymmetric(
                                    insertion: .scale(scale: 0.96).combined(with: .opacity),
                                    removal: .scale(scale: 0.98).combined(with: .opacity)
                                )
                            )
                    }
                }
                .animation(
                    .spring(response: 0.32, dampingFraction: 0.86),
                    value: commandPaletteManager.viewModel.isPresented
                )
            }
            .background {
                CommandPaletteEventMonitor(manager: commandPaletteManager)
                    .frame(width: 0, height: 0)
            }
            .task {
                await viewModel.restoreSessionIfAvailable()
            }
            .onAppear {
                commandPaletteManager.signOut = { [viewModel] in
                    pinnedStore.clearForSignOut()
                    Task { await viewModel.signOut() }
                }
                commandPaletteManager.openSettings = {
                    openSettingsAction()
                }
            }
            .onChange(of: viewModel.state) { _, newState in
                switch newState {
                case .signedIn, .refreshing(.some):
                    commandPaletteManager.isSignedIn = true
                case .signedOut, .signingIn, .failed, .refreshing(.none):
                    commandPaletteManager.isSignedIn = false
                    pinnedStore.clearForSignOut()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .signedIn, .refreshing(.some):
            PlaylistBrowserView(
                viewModel: .live(tokenProvider: viewModel),
                playbackTokenProvider: viewModel,
                searchTokenProvider: viewModel,
                commandPaletteManager: commandPaletteManager,
                signOut: {
                    pinnedStore.clearForSignOut()
                    Task { await viewModel.signOut() }
                }
            )
        case .refreshing(.none):
            ZStack {
                ShellBackground()
                GlassPanel {
                    VStack(spacing: SpotiglassDesign.spacingM) {
                        ProgressView()
                            .controlSize(.large)
                        Text(viewModel.state.title)
                            .font(.title2.weight(.semibold))
                        Text(viewModel.state.message)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(SpotiglassDesign.spacingXL)
                }
                .padding(SpotiglassDesign.spacingL)
            }
        case .signedOut, .signingIn, .failed:
            authContent
        }
    }

    private var authContent: some View {
        ZStack {
            ShellBackground()

            GlassPanel {
                VStack(spacing: SpotiglassDesign.spacingM) {
                    Label {
                        Text(AppMetadata.displayName)
                    } icon: {
                        Image(systemName: "music.note")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .font(.title2.weight(.semibold))
                    .labelStyle(.titleAndIcon)

                    authStatusMessage

                    SpotifyClientIDAndActionsView(viewModel: viewModel, layout: .welcome)
                }
                .padding(SpotiglassDesign.spacingL)
            }
            .frame(maxWidth: 560)
            .padding(SpotiglassDesign.spacingL)
        }
    }

    @ViewBuilder
    private var authStatusMessage: some View {
        switch viewModel.state {
        case .signedOut:
            EmptyView()
        case .signingIn:
            VStack(alignment: .center, spacing: SpotiglassDesign.spacingXS) {
                Label(viewModel.state.title, systemImage: "safari")
                    .font(.subheadline.weight(.medium))
                    .symbolRenderingMode(.hierarchical)
                Text(viewModel.state.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        case .failed:
            VStack(alignment: .center, spacing: SpotiglassDesign.spacingXS) {
                Label(viewModel.state.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.medium))
                    .symbolRenderingMode(.hierarchical)
                Text(viewModel.state.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        case .signedIn, .refreshing:
            EmptyView()
        }
    }
}

/// Renders ``ImmersiveLyricsView`` above the whole window (not only the split-view detail column).
private struct LyricsOverlayLayer: View {
    @EnvironmentObject private var lyricsOverlay: LyricsOverlayController

    /// Avoid blocking the window when `isPresented` is true before browse VC has called `attach` (nil models).
    private var immersiveLyricsReady: Bool {
        lyricsOverlay.isPresented
            && lyricsOverlay.playbackViewModel != nil
            && lyricsOverlay.queueViewModel != nil
            && lyricsOverlay.lyricsModel != nil
            && lyricsOverlay.navigateToArtist != nil
            && lyricsOverlay.navigateToAlbum != nil
    }

    var body: some View {
        ZStack {
            if immersiveLyricsReady,
               let playback = lyricsOverlay.playbackViewModel,
               let queue = lyricsOverlay.queueViewModel,
               let lyrics = lyricsOverlay.lyricsModel,
               let navigateArtist = lyricsOverlay.navigateToArtist,
               let navigateAlbum = lyricsOverlay.navigateToAlbum {
                ImmersiveLyricsView(
                    playbackViewModel: playback,
                    queueViewModel: queue,
                    lyricsModel: lyrics,
                    navigateToArtist: navigateArtist,
                    navigateToAlbum: navigateAlbum,
                    onDismiss: { lyricsOverlay.dismiss() }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(200)
            }
        }
        .animation(.easeOut(duration: 0.22), value: lyricsOverlay.isPresented)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(immersiveLyricsReady)
    }
}

#Preview {
    let settingsURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("SpotiglassRootPreview-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("settings.json", isDirectory: false)
    return RootView(commandPaletteManager: CommandPaletteManager())
        .environmentObject(SpotiglassSettingsStore(fileURL: settingsURL))
        .environmentObject(AuthViewModel.preview())
        .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
        .environmentObject(LyricsOverlayController())
}
