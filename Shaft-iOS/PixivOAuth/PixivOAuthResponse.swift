import Foundation

struct PixivOAuthUser: Sendable, Equatable, Codable {
    let id: Int64
    let name: String
    let account: String
    let isPremium: Bool?
}

struct PixivOAuthResponse: Sendable, Equatable, Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let tokenType: String
    let scope: String
    let user: PixivOAuthUser?
    let issuedAt: Date

    var expiresAt: Date { issuedAt.addingTimeInterval(TimeInterval(expiresIn)) }

    func isExpired(margin: TimeInterval = 0, now: Date = Date()) -> Bool {
        now.addingTimeInterval(margin) >= expiresAt
    }
}

enum PixivOAuthResult: Sendable {
    case success(response: PixivOAuthResponse, rawBody: String)
    case failure(Failure)

    enum Failure: Error, Sendable {
        case missingCode(message: String)
        case missingVerifier(message: String)
        case serverRejected(httpCode: Int, message: String)
        case networkError(message: String, underlying: (any Error)?)
        case userCancelled

        var message: String {
            switch self {
            case .missingCode(let m), .missingVerifier(let m):
                return m
            case .serverRejected(let code, let m):
                return "HTTP \(code): \(m)"
            case .networkError(let m, _):
                return m
            case .userCancelled:
                return "User cancelled the login flow"
            }
        }
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
