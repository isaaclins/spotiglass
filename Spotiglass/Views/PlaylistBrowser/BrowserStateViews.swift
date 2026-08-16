import AppKit
import SwiftUI

struct EmptyStateView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: SpotiglassDesign.spacingM) {
            Text(title)
                .font(.title3.weight(.semibold))

            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(SpotiglassDesign.spacingL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

struct ErrorStateView: View {
    let error: BrowsingDisplayError
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

            // The details are a request line, a status, a header dump and a raw
            // JSON body. That is for a bug report, not for someone who wanted a
            // playlist, so it waits behind a button instead of opening itself
            // over the window (#148).
            if let diagnosticDetails = error.diagnosticDetails {
                Button(SpotiglassL10n.string("browser.showDetails")) {
                    isShowingDiagnosticAlert = true
                }
                .buttonStyle(.link)
                .help(SpotiglassL10n.string("browser.showDetails.hint"))
                .alert(error.title, isPresented: $isShowingDiagnosticAlert) {
                    Button(SpotiglassL10n.string("browser.copyError")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnosticDetails, forType: .string)
                    }
                    Button(SpotiglassL10n.string("browser.ok"), role: .cancel) {}
                } message: {
                    Text(SpotiglassL10n.string("browser.diagnostics.message"))
                }
            }
        }
        .padding(SpotiglassDesign.spacingL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

struct StaleCacheBanner: View {
    let error: BrowsingDisplayError?

    var body: some View {
        Text(error?.message ?? SpotiglassL10n.string("browser.cachedFallback"))
            .font(.caption)
            .padding(SpotiglassDesign.spacingS)
            .background(.background, in: Capsule())
            .padding(SpotiglassDesign.spacingM)
    }
}
