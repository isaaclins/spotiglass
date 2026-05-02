import SwiftUI

struct AccountSettingsView: View {
    @ObservedObject var viewModel: AuthViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Text(viewModel.state.title)
                }
                if let session = activeSession {
                    LabeledContent("Access token") {
                        Text("Valid until \(session.expiresAt.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent("Details") {
                        Text(viewModel.state.message)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Connection")
            }

            Section {
                SpotifyClientIDAndActionsView(viewModel: viewModel, layout: .settings)
            } header: {
                Text("Spotify developer app")
            } footer: {
                Text("Use the Client ID from your app in the Spotify Developer Dashboard. OAuth uses a fixed loopback redirect on 127.0.0.1.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(SpotiglassDesign.spacingL)
    }

    private var activeSession: AuthenticatedSession? {
        switch viewModel.state {
        case let .signedIn(session):
            session
        case let .refreshing(.some(session)):
            session
        case .signedOut, .signingIn, .failed, .refreshing(.none):
            nil
        }
    }
}
