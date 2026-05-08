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

struct StaleCacheBanner: View {
    let error: BrowsingDisplayError?

    var body: some View {
        Text(error?.message ?? "Showing cached data while Spotify refreshes.")
            .font(.caption)
            .padding(SpotiglassDesign.spacingS)
            .background(.background, in: Capsule())
            .padding(SpotiglassDesign.spacingM)
    }
}
