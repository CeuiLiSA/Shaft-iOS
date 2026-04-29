import Foundation

struct PixivOAuthUser: Sendable, Equatable, Codable {
    let id: Int64
    let name: String
    let account: String
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

struct RawTokenResponse: Codable {
    let access_token: String
    let refresh_token: String
    let expires_in: Int?
    let token_type: String?
    let scope: String?
    let user: RawUser?

    struct RawUser: Codable {
        let id: StringOrInt
        let name: String?
        let account: String?
    }

    enum StringOrInt: Codable {
        case string(String), int(Int64)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int64.self) { self = .int(i); return }
            if let s = try? c.decode(String.self) { self = .string(s); return }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "id is neither Int nor String")
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .int(let i): try c.encode(i)
            }
        }

        var int64Value: Int64 {
            switch self {
            case .int(let i): return i
            case .string(let s): return Int64(s) ?? 0
            }
        }
    }

    func toPublic(issuedAt: Date) -> PixivOAuthResponse {
        PixivOAuthResponse(
            accessToken: access_token,
            refreshToken: refresh_token,
            expiresIn: expires_in ?? 3600,
            tokenType: token_type ?? "bearer",
            scope: scope ?? "",
            user: user.map {
                PixivOAuthUser(id: $0.id.int64Value, name: $0.name ?? "", account: $0.account ?? "")
            },
            issuedAt: issuedAt
        )
    }
}
