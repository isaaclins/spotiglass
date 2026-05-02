import SwiftUI

@MainActor
struct RootView: View {
    @EnvironmentObject private var viewModel: AuthViewModel
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
                if commandPaletteManager.viewModel.isPresented {
                    CommandPaletteView(viewModel: commandPaletteManager.viewModel)
                }
            }
            .background {
                CommandPaletteEventMonitor(manager: commandPaletteManager)
                    .frame(width: 0, height: 0)
            }
            .task {
                await viewModel.restoreSessionIfAvailable()
            }
            .onAppear {
                commandPaletteManager.signOut = viewModel.signOut
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
                signOut: viewModel.signOut
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
                VStack(spacing: SpotiglassDesign.spacingL) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 52, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary, .secondary)
                        .accessibilityHidden(true)

                    VStack(spacing: SpotiglassDesign.spacingS) {
                        Text(AppMetadata.displayName)
                            .font(.largeTitle.weight(.semibold))

                        StatusPill(text: viewModel.state.title, systemImage: statusIcon)

                        Text(viewModel.state.message)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }

                    SpotifyClientIDAndActionsView(viewModel: viewModel, layout: .welcome)
                }
                .padding(SpotiglassDesign.spacingXL)
            }
            .frame(maxWidth: 560)
            .padding(SpotiglassDesign.spacingL)
        }
    }

    private var statusIcon: String {
        switch viewModel.state {
        case .signedOut:
            "wifi.slash"
        case .signingIn:
            "arrow.triangle.2.circlepath"
        case .failed:
            "exclamationmark.triangle"
        case .signedIn, .refreshing:
            "checkmark.circle"
        }
    }
}

#Preview {
    RootView(commandPaletteManager: CommandPaletteManager())
        .environmentObject(AuthViewModel.preview())
}
