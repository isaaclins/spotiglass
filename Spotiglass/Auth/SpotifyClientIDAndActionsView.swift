import SwiftUI

/// Shared Spotify client ID field and Connect / Disconnect actions for the welcome screen and Settings.
struct SpotifyClientIDAndActionsView: View {
    enum Layout {
        /// Centered card width on the sign-in screen.
        case welcome
        /// Full-width fields inside a settings form.
        case settings
    }

    @ObservedObject var viewModel: AuthViewModel
    var layout: Layout = .welcome

    var body: some View {
        VStack(spacing: SpotiglassDesign.spacingM) {
            TextField("Spotify client ID", text: $viewModel.clientID)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: layout == .welcome ? 420 : .infinity)
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
                    Label("Connect Spotify", systemImage: "arrow.right.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSignIn)
                .accessibilityHint("Starts Spotify sign-in using the configured client ID.")

                Button {
                    viewModel.signOut()
                } label: {
                    Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.state.isConnectedOrRefreshing)
                .accessibilityHint("Clears the current Spotify sign-in state.")
            }
        }
    }

    private var canSignIn: Bool {
        !viewModel.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.state != .signingIn
    }
}
