import SwiftUI

@MainActor
struct RootView: View {
    @StateObject private var viewModel: AuthViewModel

    init() {
        _viewModel = StateObject(wrappedValue: AuthViewModel())
    }

    init(viewModel: AuthViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        content
            .task {
                await viewModel.restoreSessionIfAvailable()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .signedIn, .refreshing(.some):
            PlaylistBrowserView(
                viewModel: .live(tokenProvider: viewModel),
                playbackTokenProvider: viewModel,
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

                    VStack(spacing: SpotiglassDesign.spacingM) {
                        TextField("Spotify client ID", text: $viewModel.clientID)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 420)
                            .disabled(viewModel.state == .signingIn)
                            .accessibilityLabel("Spotify client ID")
                            .accessibilityHint("Paste the client ID from your Spotify Developer Dashboard app.")
                            .onSubmit {
                                guard canSignIn else { return }
                                Task { await viewModel.signIn() }
                            }

                        HStack(spacing: SpotiglassDesign.spacingS) {
                            Button {
                                Task { await viewModel.signIn() }
                            } label: {
                                Label("Connect Spotify", systemImage: "person.crop.circle.badge.plus")
                            }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canSignIn)
                            .accessibilityHint("Starts Spotify sign-in using the configured client ID.")

                            Button {
                                viewModel.signOut()
                            } label: {
                                Label("Disconnect", systemImage: "xmark.circle")
                            }
                            .disabled(!viewModel.state.isConnectedOrRefreshing)
                            .accessibilityHint("Clears the current Spotify sign-in state.")
                        }
                    }
                }
                .padding(SpotiglassDesign.spacingXL)
            }
            .frame(maxWidth: 560)
            .padding(SpotiglassDesign.spacingL)
        }
    }

    private var canSignIn: Bool {
        !viewModel.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.state != .signingIn
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

private extension AppConnectionState {
    var isConnectedOrRefreshing: Bool {
        switch self {
        case .signedIn, .refreshing:
            true
        case .signedOut, .signingIn, .failed:
            false
        }
    }
}

#Preview {
    RootView(viewModel: .preview())
}
