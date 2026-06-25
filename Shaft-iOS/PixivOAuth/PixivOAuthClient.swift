import Foundation
import CryptoKit
import AuthenticationServices

protocol VerifierStore: Sendable {
    func save(_ verifier: String)
    func load() -> String?
    func clear()
}

final class InMemoryVerifierStore: VerifierStore, @unchecked Sendable {
    private let lock = NSLock()
    private var verifier: String?
    func save(_ v: String) { lock.lock(); verifier = v; lock.unlock() }
    func load() -> String? { lock.lock(); defer { lock.unlock() }; return verifier }
    func clear() { lock.lock(); verifier = nil; lock.unlock() }
}

final class PixivOAuthClient {
    let config: PixivOAuthConfig
    private let session: URLSession
    private let verifierStore: VerifierStore
    private let addDefaultHeaders: Bool
    /// Direct-connect for the token endpoint (refresh + code exchange). The
    /// interactive login web page loads in ASWebAuthenticationSession (system
    /// Safari) and can't be routed through this — see `DirectConnection`.
    private let directConnect: Bool

    init(
        config: PixivOAuthConfig,
        session: URLSession? = nil,
        addDefaultHeaders: Bool = true,
        verifierStore: VerifierStore = InMemoryVerifierStore()
    ) {
        self.config = config
        self.addDefaultHeaders = addDefaultHeaders
        self.verifierStore = verifierStore
        self.directConnect = (session == nil) && DirectConnection.isEnabled
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 15
            cfg.timeoutIntervalForResource = 30
            self.session = directConnect ? DirectConnection.makeSession(cfg)
                                         : URLSession(configuration: cfg)
        }
    }

    // MARK: High-level API

    func startLogin() -> URL {
        let pkce = PkceUtil.generate()
        verifierStore.save(pkce.verifier)
        return buildLoginUrl(challenge: pkce.challenge)
    }

    func startProvisionalAccount() -> URL {
        let pkce = PkceUtil.generate()
        verifierStore.save(pkce.verifier)
        return buildProvisionalAccountUrl(challenge: pkce.challenge)
    }

    func isOAuthCallback(_ url: URL) -> Bool {
        url.scheme == config.callbackScheme
    }

    func handleCallback(_ url: URL) async -> PixivOAuthResult {
        guard let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else {
            return .failure(.missingCode(message: "No 'code' in callback URI: \(url)"))
        }
        guard let verifier = verifierStore.load() else {
            return .failure(.missingVerifier(message: "No pending PKCE verifier — call startLogin() first."))
        }
        let result = await exchangeCode(code: code, codeVerifier: verifier)
        if result.isSuccess { verifierStore.clear() }
        return result
    }

    // MARK: Low-level API

    func buildLoginUrl(challenge: String) -> URL {
        var c = URLComponents(string: config.loginUrl)!
        c.queryItems = [
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "client", value: config.clientParam),
        ]
        return c.url!
    }

    func buildProvisionalAccountUrl(challenge: String) -> URL {
        var c = URLComponents(string: config.provisionalAccountUrl)!
        c.queryItems = [
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "client", value: config.clientParam),
        ]
        return c.url!
    }

    func exchangeCode(code: String, codeVerifier: String) async -> PixivOAuthResult {
        await tokenRequest(fields: [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": codeVerifier,
            "redirect_uri": config.redirectUri,
        ])
    }

    func refreshToken(_ refreshToken: String) async -> PixivOAuthResult {
        await tokenRequest(fields: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
    }

    // MARK: Internals

    private func tokenRequest(fields: [String: String]) async -> PixivOAuthResult {
        var allFields = fields
        allFields["client_id"] = config.clientId
        allFields["client_secret"] = config.clientSecret
        allFields["include_policy"] = "true"
        allFields["get_secure_url"] = "true"

        let url = URL(string: config.tokenEndpointPath, relativeTo: URL(string: config.oauthBaseUrl))!
            .absoluteURL
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode(allFields).data(using: .utf8)

        if addDefaultHeaders {
            applyDefaultHeaders(to: &req)
        }

        let issuedAt = Date()
        do {
            let (data, response) = try await DirectConnection.data(for: req, using: session, directConnect: directConnect)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.networkError(message: "Non-HTTP response", underlying: nil))
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.serverRejected(httpCode: http.statusCode, message: body))
            }
            do {
                let raw = try JSONDecoder().decode(RawTokenResponse.self, from: data)
                return .success(response: raw.toPublic(issuedAt: issuedAt), rawBody: body)
            } catch {
                return .failure(.serverRejected(
                    httpCode: http.statusCode,
                    message: "Failed to parse response: \(error.localizedDescription)"
                ))
            }
        } catch is CancellationError {
            return .failure(.networkError(message: "Cancelled", underlying: nil))
        } catch {
            return .failure(.networkError(message: error.localizedDescription, underlying: error))
        }
    }

    private func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return fields
            .map { k, v in
                let key = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
                let val = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
                return "\(key)=\(val)"
            }
            .joined(separator: "&")
    }

    private func applyDefaultHeaders(to req: inout URLRequest) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let clientTime = formatter.string(from: Date())
        let hashSecret = "28c1fdd170a5204386cb1313c7077b34f83e4aaf4aa829ce78c231e05b0bae2c"
        let hash = md5Hex(clientTime + hashSecret)

        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue(PixivClientIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        }
        if req.value(forHTTPHeaderField: "App-OS") == nil {
            req.setValue("ios", forHTTPHeaderField: "App-OS")
        }
        if req.value(forHTTPHeaderField: "App-OS-Version") == nil {
            req.setValue(UIDeviceOSVersionString, forHTTPHeaderField: "App-OS-Version")
        }
        if req.value(forHTTPHeaderField: "X-Client-Time") == nil {
            req.setValue(clientTime, forHTTPHeaderField: "X-Client-Time")
        }
        if req.value(forHTTPHeaderField: "X-Client-Hash") == nil {
            req.setValue(hash, forHTTPHeaderField: "X-Client-Hash")
        }
    }

    private func md5Hex(_ s: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

#if canImport(UIKit)
import UIKit
private var UIDeviceOSVersionString: String { UIDevice.current.systemVersion }
#else
private var UIDeviceOSVersionString: String { "17.0" }
#endif

// MARK: - Wire-format types (private to this file)

private struct RawTokenResponse: Codable {
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
