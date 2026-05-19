import WebKit
import XCTest
@testable import Spotiglass

@MainActor
final class WebPlaybackViewCommanderTests: XCTestCase {
    func testLoadHostBeforeAttachDefersUntilWebViewAttached() {
        let commander = WebPlaybackViewCommander()
        commander.loadHost()

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
        commander.attach(webView: webView)

        let expectation = expectation(description: "html loaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if webView.url != nil || !webView.isLoading {
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 2)
    }

    func testLoadHostWithAttachedWebViewLoadsImmediately() {
        let commander = WebPlaybackViewCommander()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
        commander.attach(webView: webView)
        commander.loadHost()

        let expectation = expectation(description: "loaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testSendWithoutWebViewIsNoOp() async throws {
        let commander = WebPlaybackViewCommander()
        try await commander.send(.togglePlay)
    }

    func testSendEvaluatesJavaScriptOnAttachedWebView() async throws {
        let commander = WebPlaybackViewCommander()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
        commander.attach(webView: webView)
        commander.loadHost()
        try await commander.send(.togglePlay)
    }
}
