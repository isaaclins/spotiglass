import Darwin
import Foundation

struct OAuthCallback: Equatable {
    let code: String
}

enum LoopbackOAuthCallbackError: Error, Equatable, LocalizedError {
    case invalidRequest
    case oauthError(String, String?)
    case missingState
    case stateMismatch
    case missingCode
    case socketSetupFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "Spotify’s redirect didn’t return a usable response. Close extra browser tabs and try Connect again."
        case let .oauthError(code, description):
            description ?? "Spotify authorization failed with error: \(code)."
        case .missingState:
            "Spotify’s callback was missing required data. Try Connect again."
        case .stateMismatch:
            "Spotify returned an invalid authorization state. Try Connect again."
        case .missingCode:
            "Spotify’s callback did not include an authorization code. Try Connect again."
        case let .socketSetupFailed(step):
            "Could not listen on the local port for Spotify’s redirect (\(step)). Another app may be using it, or macOS blocked the listener. Quit conflicting apps or restart Spotiglass, then try Connect again."
        case .timedOut:
            "Spotify sign-in timed out before the callback was received."
        }
    }
}

enum LoopbackOAuthCallbackValidator {
    static func validate(url: URL, expectedState: String) throws -> OAuthCallback {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []

        if let error = items.first(where: { $0.name == "error" })?.value {
            let description = items.first(where: { $0.name == "error_description" })?.value
            throw LoopbackOAuthCallbackError.oauthError(error, description)
        }

        guard let state = items.first(where: { $0.name == "state" })?.value else {
            throw LoopbackOAuthCallbackError.missingState
        }
        guard state == expectedState else {
            throw LoopbackOAuthCallbackError.stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw LoopbackOAuthCallbackError.missingCode
        }

        return OAuthCallback(code: code)
    }
}

final class ActiveLoopbackOAuthListener {
    let redirectURI: URL

    private let socketDescriptor: Int32
    private let expectedState: String
    private let timeout: TimeInterval
    private var didClose = false
    private let closeLock = NSLock()

    init(socketDescriptor: Int32, port: UInt16, expectedState: String, timeout: TimeInterval) {
        self.socketDescriptor = socketDescriptor
        self.redirectURI = SpotifyAuthConfiguration.loopbackRedirectURI(port: port)
        self.expectedState = expectedState
        self.timeout = timeout
    }

    deinit {
        close()
    }

    func waitForCallback() async throws -> OAuthCallback {
        try await withThrowingTaskGroup(of: OAuthCallback.self) { group in
            group.addTask {
                try await self.acceptSingleCallback()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                self.close()
                throw LoopbackOAuthCallbackError.timedOut
            }

            guard let result = try await group.next() else {
                throw LoopbackOAuthCallbackError.invalidRequest
            }
            group.cancelAll()
            close()
            return result
        }
    }

    private func acceptSingleCallback() async throws -> OAuthCallback {
        try await Task.detached(priority: .userInitiated) {
            var address = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let client = Darwin.accept(self.socketDescriptor, &address, &length)
            guard client >= 0 else {
                throw LoopbackOAuthCallbackError.invalidRequest
            }
            defer { Darwin.close(client) }

            var buffer = [UInt8](repeating: 0, count: 4096)
            let bufferCount = buffer.count
            let count = buffer.withUnsafeMutableBytes { pointer in
                Darwin.read(client, pointer.baseAddress, bufferCount)
            }
            guard count > 0,
                  let request = String(bytes: buffer.prefix(count), encoding: .utf8),
                  let requestLine = request.components(separatedBy: "\r\n").first else {
                self.writeResponse(to: client, status: "400 Bad Request", body: "Invalid Spotify callback.")
                throw LoopbackOAuthCallbackError.invalidRequest
            }

            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2,
                  parts[0] == "GET",
                  let callbackURL = URL(string: "http://127.0.0.1\(parts[1])") else {
                self.writeResponse(to: client, status: "400 Bad Request", body: "Invalid Spotify callback.")
                throw LoopbackOAuthCallbackError.invalidRequest
            }

            do {
                let callback = try LoopbackOAuthCallbackValidator.validate(url: callbackURL, expectedState: self.expectedState)
                self.writeResponse(to: client, status: "200 OK", body: "Spotify sign-in is complete. You can return to Spotiglass.")
                return callback
            } catch {
                self.writeResponse(to: client, status: "400 Bad Request", body: "Spotify sign-in could not be completed.")
                throw error
            }
        }.value
    }

    private func writeResponse(to client: Int32, status: String, body: String) {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        _ = response.withCString { pointer in
            Darwin.write(client, pointer, strlen(pointer))
        }
    }

    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }

        guard !didClose else { return }
        didClose = true
        Darwin.shutdown(socketDescriptor, SHUT_RDWR)
        Darwin.close(socketDescriptor)
    }
}

struct LoopbackOAuthListenerFactory {
    func start(
        expectedState: String,
        timeout: TimeInterval = 120,
        port: UInt16 = SpotifyAuthConfiguration.defaultLoopbackPort
    ) throws -> ActiveLoopbackOAuthListener {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else {
            throw LoopbackOAuthCallbackError.socketSetupFailed("socket")
        }

        var reuse: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(descriptor)
            throw LoopbackOAuthCallbackError.socketSetupFailed("setsockopt")
        }

        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: in_port_t(port).bigEndian,
            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(descriptor)
            throw LoopbackOAuthCallbackError.socketSetupFailed("bind")
        }

        guard Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw LoopbackOAuthCallbackError.socketSetupFailed("listen")
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.getsockname(descriptor, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(descriptor)
            throw LoopbackOAuthCallbackError.socketSetupFailed("getsockname")
        }

        return ActiveLoopbackOAuthListener(
            socketDescriptor: descriptor,
            port: UInt16(bigEndian: boundAddress.sin_port),
            expectedState: expectedState,
            timeout: timeout
        )
    }
}
