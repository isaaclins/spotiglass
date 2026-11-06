import AppKit
import Foundation

/// Sends scripts to the Music app. It starts Music hidden when it isn't running, asks for the
/// Automation permission (macOS shows its prompt the first time, and again on the next edit
/// while it is unanswered), then runs the script.
struct AppleEventMusicAppScriptRunner: MusicAppScriptRunning {
    static let musicBundleIdentifier = "com.apple.Music"
    static let launchTimeout: Duration = .seconds(15)

    func run(_ source: String) async throws {
        try await Self.ensureMusicIsRunning()
        try await Self.ensurePermission()
        try await MainActor.run {
            var errorInfo: NSDictionary?
            guard let script = NSAppleScript(source: source) else {
                throw AppleMusicLibraryEditError.requestFailed
            }
            _ = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let number = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
                SpotiglassLog.error(.api, "Music script failed (\(number)): \(errorInfo[NSAppleScript.errorMessage] ?? "")")
                throw MusicAppScripts.editError(forScriptErrorNumber: number)
            }
        }
    }

    private static func isMusicRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleIdentifier)
            .contains { $0.isFinishedLaunching }
    }

    private static func ensureMusicIsRunning() async throws {
        if isMusicRunning() { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: musicBundleIdentifier) else {
            throw AppleMusicLibraryEditError.musicUnavailable
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            throw AppleMusicLibraryEditError.musicUnavailable
        }
        let deadline = ContinuousClock.now + launchTimeout
        while !isMusicRunning() {
            guard ContinuousClock.now < deadline else { throw AppleMusicLibraryEditError.musicUnavailable }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// `AEDeterminePermissionToAutomateTarget` blocks until the user answers the prompt, so it
    /// runs off the main thread.
    private static func ensurePermission() async throws {
        let status = await Task.detached(priority: .userInitiated) { () -> OSStatus in
            let target = NSAppleEventDescriptor(bundleIdentifier: musicBundleIdentifier)
            guard let address = target.aeDesc else { return OSStatus(procNotFound) }
            return AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, true)
        }.value
        guard status == noErr else {
            throw MusicAppScripts.editError(forScriptErrorNumber: Int(status))
        }
    }
}
