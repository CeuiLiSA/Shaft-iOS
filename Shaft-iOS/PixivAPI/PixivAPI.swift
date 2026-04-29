import Foundation
import CryptoKit

protocol PixivTokenProvider: Sendable {
    func currentAccessToken() async -> String?
    func refreshAccessToken() async -> String?
}

actor PixivAPI {
    static let baseURL = URL(string: "https://app-api.pixiv.net")!
    private static let hashSecret = "28c1fdd170a5204386cb1313c7077b34f83e4aaf4aa829ce78c231e05b0bae2c"
    private static let appVersion = "7.13.4"

    private let session: URLSession
    private let tokenProvider: any PixivTokenProvider

    init(tokenProvider: any PixivTokenProvider, session: URLSession? = nil) {
        self.tokenProvider = tokenProvider
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 10
            cfg.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: cfg)
        }
    }

    enum APIError: Error, LocalizedError {
        case noToken
        case http(code: Int, body: String)
        case nonHTTP
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .noToken: return "Not signed in"
            case .http(let c, let b): return "HTTP \(c): \(b)"
            case .nonHTTP: return "Non-HTTP response"
            case .decoding(let m): return "Decoding failed: \(m)"
            }
        }
    }

    // MARK: Endpoints

    func recommendedIllusts(type: String = "illust") async throws -> HomeIllustResponse {
        try await get(path: "/v1/\(type)/recommended", query: [
            "include_ranking_illusts": "false",
            "include_privacy_policy": "true",
            "filter": "for_ios",
        ])
    }

    func trendingTags(type: String = "illust") async throws -> TrendingTagsResponse {
        try await get(path: "/v1/trending-tags/\(type)", query: ["filter": "for_ios"])
    }

    func nextPage<T: Decodable>(_ url: String) async throws -> T {
        guard let u = URL(string: url) else { throw APIError.http(code: 0, body: "bad next_url") }
        return try await perform(request: URLRequest(url: u))
    }

    // MARK: Internals

    private func get<T: Decodable>(path: String, query: [String: String] = [:]) async throws -> T {
        var comps = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return try await perform(request: URLRequest(url: comps.url!))
    }

    private func perform<T: Decodable>(request original: URLRequest) async throws -> T {
        guard let token = await tokenProvider.currentAccessToken() else { throw APIError.noToken }

        var req = original
        applyHeaders(&req, accessToken: token)

        var (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse,
           http.statusCode == 400, isTokenError(data: data) {
            if let newToken = await tokenProvider.refreshAccessToken() {
                var retried = original
                applyHeaders(&retried, accessToken: newToken)
                (data, response) = try await session.data(for: retried)
            }
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.nonHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(code: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    private func applyHeaders(_ req: inout URLRequest, accessToken: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let clientTime = formatter.string(from: Date())
        let hash = Insecure.MD5.hash(data: Data((clientTime + Self.hashSecret).utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        req.setValue("ios", forHTTPHeaderField: "app-os")
        req.setValue("17.0", forHTTPHeaderField: "app-os-version")
        req.setValue(Self.appVersion, forHTTPHeaderField: "app-version")
        req.setValue(clientTime, forHTTPHeaderField: "x-client-time")
        req.setValue(hash, forHTTPHeaderField: "x-client-hash")
        req.setValue("PixivIOSApp/\(Self.appVersion) (iOS 17.0; iPhone)", forHTTPHeaderField: "user-agent")
        req.setValue(Self.acceptLanguage(), forHTTPHeaderField: "accept-language")
    }

    private func isTokenError(data: Data) -> Bool {
        guard let s = String(data: data, encoding: .utf8) else { return false }
        return s.contains("Error occurred at the OAuth process")
            || s.contains("Invalid refresh token")
    }

    private static func acceptLanguage() -> String {
        let pref = Locale.preferredLanguages.first ?? "en"
        let lang = Locale(identifier: pref).language.languageCode?.identifier ?? "en"
        let region = Locale(identifier: pref).region?.identifier ?? "US"
        return "\(lang)-\(region.lowercased()),\(lang);q=0.9,en-us;q=0.8,en;q=0.7"
    }
}
