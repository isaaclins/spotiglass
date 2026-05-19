import SwiftUI

struct AccountSettingsView: View {
    @ObservedObject var viewModel: AuthViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "settings.account.status")) {
                    Text(viewModel.state.title)
                }
                if let session = activeSession {
                    LabeledContent(String(localized: "settings.account.accessToken")) {
                        Text(
                            String(
                                format: String(localized: "settings.account.validUntil"),
                                session.expiresAt.formatted(date: .omitted, time: .shortened)
                            )
                        )
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent(String(localized: "settings.account.details")) {
                        Text(viewModel.state.message)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("settings.account.connection", bundle: .main)
            }

            Section {
                SpotifyClientIDAndActionsView(viewModel: viewModel, layout: .settings)
            } header: {
                Text("settings.account.developerApp", bundle: .main)
            } footer: {
                Text("settings.account.developerApp.hint", bundle: .main)
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
