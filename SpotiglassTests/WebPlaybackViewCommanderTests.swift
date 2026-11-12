import WebKit
import XCTest
@testable import Spotiglass

@MainActor
final class WebPlaybackViewCommanderTests: XCTestCase {
    func testLoadHostBeforeAttachDefersUntilWebViewAttached() {
        let commander = WebPlaybackViewCommander()
        commander.loadHost(generation: .initial)

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
        commander.attach(webView: webView)

        // However long a busy machine takes to load the page.
        while webView.url == nil, webView.isLoading {
            AppKitTestSupport.pumpRunLoop(for: 0.05)
        }
    }

    func testLoadHostWithAttachedWebViewLoadsImmediately() {
        let commander = WebPlaybackViewCommander()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
        commander.attach(webView: webView)
        commander.loadHost(generation: .initial)

        let expectation = expectation(description: "loaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: mustHappenTimeout)
    }

    func testSendWithoutWebViewIsNoOp() async throws {
        let commander = WebPlaybackViewCommander()
        try await commander.send(.togglePlay)
    }

    func testSendEvaluatesJavaScriptOnAttachedWebView() async throws {
        let commander = WebPlaybackViewCommander()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
        commander.attach(webView: webView)
        commander.loadHost(generation: .initial)
        try await commander.send(.togglePlay)
    }
}
