import SwiftUI
import AppKit

struct AccountSettingsView: View {
    @ObservedObject var viewModel: AuthViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent(SpotiglassL10n.string("settings.account.status")) {
                    Text(viewModel.state.title)
                }
                if let session = activeSession {
                    LabeledContent(SpotiglassL10n.string("settings.account.accessToken")) {
                        Text(
                            String(
                                format: SpotiglassL10n.string("settings.account.validUntil"),
                                session.expiresAt.formatted(
                                    .dateTime.year().month().day().hour().minute().timeZone()
                                )
                            )
                        )
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent(SpotiglassL10n.string("settings.account.details")) {
                        Text(viewModel.state.message)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text(SpotiglassL10n.string("settings.account.connection"))
            }

            Section {
                SpotifyClientIDAndActionsView(viewModel: viewModel, layout: .settings)
            } header: {
                Text(SpotiglassL10n.string("settings.account.developerApp"))
            } footer: {
                Text(SpotiglassL10n.string("settings.account.developerApp.hint"))
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(SpotiglassL10n.string("settings.account.diagnostics.logFileLabel")) {
                    if let url = SpotiglassLog.logFileURL {
                        HStack(spacing: SpotiglassDesign.spacingS) {
                            // Truncate the front, not the middle, so the file name stays
                            // readable; the full path is available via tooltip and Copy.
                            Text(url.path)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .textSelection(.enabled)
                                .help(url.path)
                            Button(SpotiglassL10n.string("settings.account.diagnostics.copyPath")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.path, forType: .string)
                            }
                            Button(SpotiglassL10n.string("settings.account.diagnostics.revealInFinder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                    } else {
                        Text(SpotiglassL10n.string("settings.account.diagnostics.logFileUnavailable"))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(SpotiglassL10n.string("settings.account.diagnostics.header"))
            } footer: {
                Text(SpotiglassL10n.string("settings.account.diagnostics.footer"))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
