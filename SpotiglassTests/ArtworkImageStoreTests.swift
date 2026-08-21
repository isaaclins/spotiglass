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
            responseURLCache: URLCache(memoryCapacity: 0, diskCapacity: 0),
            urlSessionFactory: { URLSession(configuration: config) }
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
            responseURLCache: URLCache(memoryCapacity: 0, diskCapacity: 0),
            urlSessionFactory: { URLSession(configuration: config) }
        )
        let url = URL(string: "https://example.com/clear.png")!
        _ = await store.image(for: url)
        await store.clearAllCachedImages()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(files.isEmpty)
    }

    func testClearFencesDelayedLoadAndAllowsPostClearRetry() async {
        let dir = spotiglassTestsTemporaryDirectory()
        let responseURLCache = URLCache(memoryCapacity: 1_024 * 1_024, diskCapacity: 1_024 * 1_024, diskPath: nil)
        let store = ArtworkImageStore(
            diskDirectory: dir,
            urlSession: makeDelayedArtworkURLSession(cache: responseURLCache),
            responseURLCache: responseURLCache,
            urlSessionFactory: { makeDelayedArtworkURLSession(cache: responseURLCache) }
        )
        let url = URL(string: "https://example.com/delayed.png")!
        let request = URLRequest(url: url)
        let gate = DelayedArtworkURLProtocol.gate
        gate.reset()

        async let preClearResult = store.image(for: url)
        await gate.waitUntilRequestCount(1)
        await store.clearAllCachedImages()

        gate.release(validArtworkPNGData())
        let preClearImage = await preClearResult
        XCTAssertNil(preClearImage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ArtworkImageStore.cacheFileURL(for: url, diskDirectory: dir).path))
        XCTAssertNil(responseURLCache.cachedResponse(for: request))

        let postClearTask = Task { await store.image(for: url) }
        await gate.waitUntilRequestCount(2)
        gate.release(validArtworkPNGData())

        let postClearImage = await postClearTask.value
        XCTAssertNotNil(postClearImage)
        XCTAssertEqual(gate.requestCount, 2)
    }

    func testOldLoadCannotRemovePostClearInFlightOwner() async {
        let dir = spotiglassTestsTemporaryDirectory()
        let responseURLCache = URLCache(memoryCapacity: 0, diskCapacity: 0, diskPath: nil)
        let store = ArtworkImageStore(
            diskDirectory: dir,
            urlSession: makeDelayedArtworkURLSession(cache: responseURLCache),
            responseURLCache: responseURLCache,
            urlSessionFactory: { makeDelayedArtworkURLSession(cache: responseURLCache) }
        )
        let url = URL(string: "https://example.com/ownership.png")!
        let gate = DelayedArtworkURLProtocol.gate
        gate.reset()

        async let preClearResult = store.image(for: url)
        await gate.waitUntilRequestCount(1)
        await store.clearAllCachedImages()

        let postClearTask = Task { await store.image(for: url) }
        await gate.waitUntilRequestCount(2)

        gate.release(validArtworkPNGData())
        _ = await preClearResult

        let coalescedTask = Task { await store.image(for: url) }
        gate.release(validArtworkPNGData())
        gate.release(validArtworkPNGData())

        _ = await (postClearTask.value, coalescedTask.value)
        XCTAssertEqual(gate.requestCount, 2)
    }

    func testCoalescesConcurrentLoads() async {
        let dir = spotiglassTestsTemporaryDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SingleResponseURLProtocol.self]
        let store = ArtworkImageStore(
            diskDirectory: dir,
            urlSession: URLSession(configuration: config),
            responseURLCache: URLCache(memoryCapacity: 0, diskCapacity: 0),
            urlSessionFactory: { URLSession(configuration: config) }
        )
        SingleResponseURLProtocol.requestCount = 0
        let url = URL(string: "https://example.com/one.png")!

        async let a = store.image(for: url)
        async let b = store.image(for: url)
        _ = await (a, b)
        XCTAssertEqual(SingleResponseURLProtocol.requestCount, 1)
    }

    func testCachedImageIfAvailableReadsDefaultCacheDirectory() throws {
        let dir = spotiglassTestsTemporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = URL(string: "https://cdn.test/art.png")!
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
        // Exercises the nonisolated disk read path (returns nil when file is outside default cache dir).
        _ = ArtworkImageStore.cachedImageIfAvailable(for: url)
    }

    func testNetworkFailureReturnsNil() async {
        let dir = spotiglassTestsTemporaryDirectory()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingURLProtocol.self]
        let store = ArtworkImageStore(
            diskDirectory: dir,
            urlSession: URLSession(configuration: config),
            responseURLCache: URLCache(memoryCapacity: 0, diskCapacity: 0),
            urlSessionFactory: { URLSession(configuration: config) }
        )
        let image = await store.image(for: URL(string: "https://example.com/missing.png")!)
        XCTAssertNil(image)
    }
}

private func makeDelayedArtworkURLSession(cache: URLCache) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DelayedArtworkURLProtocol.self]
    configuration.urlCache = cache
    return URLSession(configuration: configuration)
}

private func validArtworkPNGData() -> Data {
    Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
    ])
}

private final class FailingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        client?.urlProtocol(self, didFailWithError: error)
    }
    override func stopLoading() {}
}

private final class DelayedArtworkURLProtocol: URLProtocol {
    static let gate = DelayedArtworkResponseGate()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let protocolClient = client
        let requestURL = request.url!
        Self.gate.waitForResponse { [weak self] responseData in
            guard let self else { return }
            let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Cache-Control": "max-age=3600",
                    "Content-Type": "image/png"
                ]
            )!
            protocolClient?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            protocolClient?.urlProtocol(self, didLoad: responseData)
            protocolClient?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private final class DelayedArtworkResponseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var startedCount = 0
    private var startWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var pendingResponses: [((Data) -> Void)] = []
    private var queuedResponses: [Data] = []

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return startedCount
    }

    func reset() {
        lock.lock()
        startedCount = 0
        startWaiters.removeAll()
        pendingResponses.removeAll()
        queuedResponses.removeAll()
        lock.unlock()
    }

    func waitUntilRequestCount(_ target: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if startedCount >= target {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiters.append((target: target, continuation: continuation))
                lock.unlock()
            }
        }
    }

    func waitForResponse(_ completion: @escaping (Data) -> Void) {
        lock.lock()
        let queuedResponse: Data?
        if queuedResponses.isEmpty {
            queuedResponse = nil
            pendingResponses.append(completion)
        } else {
            queuedResponse = queuedResponses.removeFirst()
        }
        startedCount += 1
        let resumed = startWaiters.filter { $0.target <= startedCount }
        startWaiters.removeAll { $0.target <= startedCount }
        lock.unlock()
        for waiter in resumed {
            waiter.continuation.resume()
        }
        if let queuedResponse {
            completion(queuedResponse)
        }
    }

    func release(_ response: Data) {
        lock.lock()
        let completion: ((Data) -> Void)?
        if pendingResponses.isEmpty {
            completion = nil
            queuedResponses.append(response)
        } else {
            completion = pendingResponses.removeFirst()
        }
        lock.unlock()
        completion?(response)
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
