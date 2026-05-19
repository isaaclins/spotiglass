import XCTest
@testable import Spotiglass

final class ArtworkImageStoreTests: XCTestCase {
    func testCacheFileURLIsStableSHA256Name() {
        let dir = spotiglassTestsTemporaryDirectory()
        let url = URL(string: "https://i.scdn.co/image/ab")!
        let file = ArtworkImageStore.cacheFileURL(for: url, diskDirectory: dir)
        XCTAssertEqual(file.deletingLastPathComponent(), dir)
        XCTAssertTrue(file.lastPathComponent.hasSuffix(".img"))
        XCTAssertEqual(
            file.lastPathComponent,
            ArtworkImageStore.cacheFileURL(for: url, diskDirectory: dir).lastPathComponent
        )
    }

    func testCachedImageIfAvailableReadsWrittenDiskFile() throws {
        let dir = spotiglassTestsTemporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = URL(string: "https://example.com/art.png")!
        let file = ArtworkImageStore.cacheFileURL(for: url, diskDirectory: dir)
        let png: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82,
        ]
        try Data(png).write(to: file)

        // Override default cache directory by writing where cachedImageIfAvailable looks — use direct disk read path via store init instead.
        let config = URLSessionConfiguration.ephemeral
        let store = ArtworkImageStore(
            diskDirectory: dir,
            urlSession: URLSession(configuration: config),
            responseURLCache: URLCache(memoryCapacity: 0, diskCapacity: 0)
        )

        let expectation = expectation(description: "load")
        Task {
            let image = await store.image(for: url)
            XCTAssertNotNil(image)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    func testClearAllCachedImages() async {
        let dir = spotiglassTestsTemporaryDirectory()
        let config = URLSessionConfiguration.ephemeral
        let store = ArtworkImageStore(
            diskDirectory: dir,
            urlSession: URLSession(configuration: config),
            responseURLCache: URLCache(memoryCapacity: 0, diskCapacity: 0)
        )
        let url = URL(string: "https://example.com/clear.png")!
        _ = await store.image(for: url)
        await store.clearAllCachedImages()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(files.isEmpty)
    }

    func testCoalescesConcurrentLoads() async {
        let dir = spotiglassTestsTemporaryDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SingleResponseURLProtocol.self]
        let store = ArtworkImageStore(
            diskDirectory: dir,
            urlSession: URLSession(configuration: config),
            responseURLCache: URLCache(memoryCapacity: 0, diskCapacity: 0)
        )
        SingleResponseURLProtocol.requestCount = 0
        let url = URL(string: "https://example.com/one.png")!

        async let a = store.image(for: url)
        async let b = store.image(for: url)
        _ = await (a, b)
        XCTAssertEqual(SingleResponseURLProtocol.requestCount, 1)
    }
}

private final class SingleResponseURLProtocol: URLProtocol {
    static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let png: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82,
        ]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(png))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
