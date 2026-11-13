import WebKit
import XCTest
@testable import Spotiglass

/// What the commander hands the hidden player page: which host page it loads, when, and which
/// scripts it runs. A recording web view stands in, so each test checks the exact calls.
@MainActor
final class WebPlaybackViewCommanderTests: XCTestCase {
    func testLoadHostBeforeAttachDefersUntilWebViewAttached() {
        let commander = WebPlaybackViewCommander()
        let generation = PlaybackHostGeneration.initial.advanced()
        commander.loadHost(generation: generation)

        let webView = RecordingWebView()
        XCTAssertTrue(webView.loadedPages.isEmpty)
        commander.attach(webView: webView)

        XCTAssertEqual(webView.loadedPages.count, 1, "the load asked before the web view existed must run once it is attached")
        XCTAssertEqual(webView.loadedPages.first?.html, SpotifyPlaybackHost.html(forHostGeneration: generation))
        XCTAssertEqual(webView.loadedPages.first?.baseURL, URL(string: "https://spotiglass.local"))

        commander.attach(webView: webView)
        XCTAssertEqual(webView.loadedPages.count, 1, "attaching again must not load the page a second time")
    }

    func testLoadHostWithAttachedWebViewLoadsImmediately() {
        let commander = WebPlaybackViewCommander()
        let webView = RecordingWebView()
        commander.attach(webView: webView)
        XCTAssertTrue(webView.loadedPages.isEmpty, "nothing to load before a host was asked for")

        commander.loadHost(generation: .initial)

        XCTAssertEqual(webView.loadedPages.map(\.html), [SpotifyPlaybackHost.html(forHostGeneration: .initial)])
        XCTAssertEqual(webView.loadedPages.first?.baseURL, URL(string: "https://spotiglass.local"))
    }

    func testSendWithoutWebViewIsNoOp() async throws {
        let commander = WebPlaybackViewCommander()
        let webView = RecordingWebView()
        commander.attach(webView: webView)
        commander.attach(webView: nil)

        try await commander.send(.togglePlay)

        XCTAssertTrue(webView.evaluatedScripts.isEmpty, "a detached web view must not run commands")
    }

    func testSendEvaluatesJavaScriptOnAttachedWebView() async throws {
        let commander = WebPlaybackViewCommander()
        let webView = RecordingWebView()
        commander.attach(webView: webView)
        commander.loadHost(generation: .initial)

        try await commander.send(.togglePlay, payload: ["id": NSNumber(value: 7)])
        try await commander.send(.seek, payload: ["milliseconds": 42_000])

        XCTAssertEqual(webView.evaluatedScripts, [
            "window.spotiglassPlayback && window.spotiglassPlayback.togglePlay(7);",
            "window.spotiglassPlayback && window.spotiglassPlayback.seek(42000);"
        ])
    }

    /// A command meant for an older host page is dropped once a newer page was loaded.
    func testSendForAnOlderHostGenerationIsDropped() async throws {
        let commander = WebPlaybackViewCommander()
        let webView = RecordingWebView()
        commander.attach(webView: webView)
        let newer = PlaybackHostGeneration.initial.advanced()
        commander.loadHost(generation: newer)

        try await commander.send(.pause, payload: [:], generation: .initial)
        XCTAssertTrue(webView.evaluatedScripts.isEmpty, "a command for the replaced page reached the new one")

        try await commander.send(.pause, payload: [:], generation: newer)
        XCTAssertEqual(webView.evaluatedScripts, ["window.spotiglassPlayback && window.spotiglassPlayback.pause();"])
    }
}

/// Records what is loaded and evaluated instead of running it.
private final class RecordingWebView: WKWebView {
    private(set) var loadedPages: [(html: String, baseURL: URL?)] = []
    private(set) var evaluatedScripts: [String] = []

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 4, height: 4), configuration: WKWebViewConfiguration())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        loadedPages.append((string, baseURL))
        return nil
    }

    override func evaluateJavaScript(
        _ javaScriptString: String,
        completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil
    ) {
        evaluatedScripts.append(javaScriptString)
        completionHandler?("ok", nil)
    }
}
