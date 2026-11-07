import AppKit
import Foundation

/// Sends scripts to the Music app. It starts Music hidden when it isn't running, asks for the
/// Automation permission (macOS shows its prompt the first time, and again on the next edit
/// while it is unanswered), then runs the script.
struct AppleEventMusicAppScriptRunner: MusicAppScriptRunning {
    static let musicBundleIdentifier = "com.apple.Music"
    static let launchTimeout: Duration = .seconds(15)

    /// How long one Apple Event to Music may take before the edit gives up with
    /// `musicUnavailable`. Music answers lookups over a large library in a few seconds; a Music
    /// that is still loading or syncing can take much longer.
    static let eventTimeoutSeconds = 60

    /// Scripts run one at a time on their own queue: `NSAppleScript` waits for Music's answer,
    /// and on the main thread that froze every window until Music replied (#395).
    private static let scriptQueue = DispatchQueue(label: "com.isaaclins.spotiglass.music-scripts", qos: .userInitiated)

    /// Starts Music and checks the Automation permission; separate so tests run without Music.
    let prepare: @Sendable () async throws -> Void
    /// Runs the finished script and returns its result; called on `scriptQueue`.
    let execute: @Sendable (String) throws -> String?

    init(
        prepare: @escaping @Sendable () async throws -> Void = AppleEventMusicAppScriptRunner.prepareMusic,
        execute: @escaping @Sendable (String) throws -> String? = AppleEventMusicAppScriptRunner.executeAppleScript
    ) {
        self.prepare = prepare
        self.execute = execute
    }

    @discardableResult
    func run(_ source: String) async throws -> String? {
        try await prepare()
        let timed = MusicAppScripts.withTimeout(source, seconds: Self.eventTimeoutSeconds)
        let execute = execute
        return try await withCheckedThrowingContinuation { continuation in
            Self.scriptQueue.async {
                continuation.resume(with: Result { try execute(timed) })
            }
        }
    }

    @Sendable static func prepareMusic() async throws {
        try await ensureMusicIsRunning()
        try await ensurePermission()
    }

    @Sendable static func executeAppleScript(_ source: String) throws -> String? {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw AppleMusicLibraryEditError.requestFailed
        }
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            SpotiglassLog.error(.api, "Music script failed (\(number)): \(errorInfo[NSAppleScript.errorMessage] ?? "")")
            throw MusicAppScripts.editError(forScriptErrorNumber: number)
        }
        return result.stringValue
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
