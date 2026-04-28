import CryptoKit
import Foundation
import Security

enum PKCE {
    private static let allowedVerifierCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func makeCodeVerifier(byteCount: Int = 64) throws -> String {
        precondition(byteCount > 0)

        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw PKCEError.randomGenerationFailed(status)
        }

        let verifier = Data(bytes).base64URLEncodedString()
        guard verifier.count >= 43, verifier.count <= 128, verifier.unicodeScalars.allSatisfy({ allowedVerifierCharacters.contains($0) }) else {
            throw PKCEError.invalidGeneratedVerifier
        }

        return verifier
    }

    static func makeCodeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

enum PKCEError: Error, Equatable {
    case randomGenerationFailed(OSStatus)
    case invalidGeneratedVerifier
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
