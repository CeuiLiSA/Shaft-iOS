import Foundation
import CryptoKit

struct PkcePair: Sendable, Equatable {
    let verifier: String
    let challenge: String
}

enum PkceUtil {
    private static let verifierByteLength = 32

    static func generate() -> PkcePair {
        let verifier = generateVerifier()
        let challenge = computeChallenge(verifier: verifier)
        return PkcePair(verifier: verifier, challenge: challenge)
    }

    private static func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: verifierByteLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes).urlSafeBase64NoPadding()
    }

    private static func computeChallenge(verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).urlSafeBase64NoPadding()
    }
}

extension Data {
    func urlSafeBase64NoPadding() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
