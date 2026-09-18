import Foundation
import CryptoKit
import Security
import Observation

/// Tokyo Auth V2, independent of the main API session. Based on the in-progress
/// ReferralSession implementation; deliberately does not mutate that module. Pixiv credentials never leave
/// the Pixiv client. Rotating refresh tokens and retry IDs live together in Keychain.
actor PlazaSession {
    private struct AuthErrorBody: Decodable { var error: String? }
    static let shared = PlazaSession()
    private struct Tokens: Codable {
        var uid: Int64
        var access_token: String
        var refresh_token: String
        var access_expires_at: Double
    }
    private struct Stored: Codable {
        var tokens: Tokens
        var refreshAttempt: String?
    }
    private static let session = URLSession(configuration: .ephemeral)
    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let currentUID: @Sendable () -> Int64
    private let readCredentials: @Sendable (Int64) -> Data?
    private let writeCredentials: @Sendable (Data, Int64) throws -> Void
    private var flights: [Int64: Task<String, Error>] = [:]
    private var memory: [Int64: Stored] = [:]
    init(
        send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await PlazaSession.session.data(for: $0) },
        currentUID: @escaping @Sendable () -> Int64 = { KeychainTokenStore.shared.load()?.user?.id ?? 0 },
        readCredentials: @escaping @Sendable (Int64) -> Data? = { PlazaSession.read($0) },
        writeCredentials: @escaping @Sendable (Data, Int64) throws -> Void = { try PlazaSession.write($0, uid: $1) }
    ) {
        self.send = send; self.currentUID = currentUID
        self.readCredentials = readCredentials; self.writeCredentials = writeCredentials
    }
    private var deviceID: String {
        let key = "pixshaft_tokyo_device_id"
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    func token(uid: Int64, rejected: String? = nil) async throws -> String {
        guard uid > 0, currentUID() == uid else {
            throw PlazaFailure(key: "account_changed")
        }
        if let flight = flights[uid] { return try await flight.value }
        let stored = memory[uid] ?? readCredentials(uid).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        // Cached reads cannot be shared flights: a concurrent 401 must not join
        // a task returning the exact access token that it just rejected.
        if let value = stored, value.tokens.access_expires_at > plazaNow() + 60_000,
           value.tokens.access_token != rejected, value.refreshAttempt == nil {
            return value.tokens.access_token
        }
        let flight = Task { try await self.obtain(uid: uid, stored: stored) }
        flights[uid] = flight
        defer { flights[uid] = nil }
        return try await flight.value
    }

    private func obtain(uid: Int64, stored initial: Stored?) async throws -> String {
        var stored = initial
        if var value = stored {
            value.refreshAttempt = value.refreshAttempt ?? UUID().uuidString
            try save(value, uid: uid) // Persist before rotating, so interrupted retries reuse this ID.
            do {
                let tokens = try await exchange("token", body: [
                    "grant_type": "refresh_token", "refresh_token": value.tokens.refresh_token,
                    "device_id": deviceID,
                ], attempt: value.refreshAttempt)
                guard tokens.uid == uid else { throw PlazaFailure(key: "auth_error") }
                stored = Stored(tokens: tokens)
            } catch let failure as PlazaFailure where failure.code == "invalid_session" {
                stored = nil
            }
        }
        if stored == nil {
            let tokens = try await exchange("session", body: [
                "grant_type": "app_hmac", "uid": uid, "device_id": deviceID,
            ])
            guard tokens.uid == uid else { throw PlazaFailure(key: "auth_error") }
            stored = Stored(tokens: tokens)
        }
        guard let stored, currentUID() == uid else {
            throw PlazaFailure(key: "account_changed")
        }
        try save(stored, uid: uid)
        return stored.tokens.access_token
    }

    private func exchange(_ path: String, body: [String: Any], attempt: String? = nil) async throws -> Tokens {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var request = URLRequest(url: URL(string: "https://api.pixshaft.com/v1/auth/\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let attempt { request.setValue(attempt, forHTTPHeaderField: "Idempotency-Key") }
        if path == "session" {
            guard !ShaftEventsConfig.hmacSecret.isEmpty else { throw PlazaFailure(key: "auth_error") }
            let key = SymmetricKey(data: Data(ShaftEventsConfig.hmacSecret.utf8))
            let signature = HMAC<SHA256>.authenticationCode(for: data, using: key)
                .map { String(format: "%02x", $0) }.joined()
            request.setValue(signature, forHTTPHeaderField: "X-Shaft-Sign")
        }
        let (response, http) = try await send(request)
        let status = (http as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // Expired/revoked refresh credentials are OAuth 400s, not 401s.
            // Only definitive invalidation permits bootstrap; transport/5xx
            // failures must retain the persisted rotation ID for a safe retry.
            let detail = try? JSONDecoder().decode(AuthErrorBody.self, from: response)
            if path == "token", status == 400,
               ["invalid_grant", "token_reuse_detected"].contains(detail?.error ?? "") {
                throw PlazaFailure(key: "auth_error", code: "invalid_session")
            }
            throw PlazaFailure(key: status == 401 ? "auth_error" : status == 429 ? "rate_error" : "auth_error")
        }
        return try JSONDecoder().decode(Tokens.self, from: response)
    }

    private nonisolated static func query(_ uid: Int64) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.shaft.ShaftiOS.tokyo-session", kSecAttrAccount: String(uid)]
    }
    private nonisolated static func read(_ uid: Int64) -> Data? {
        var query = query(uid)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return data
    }
    private func save(_ value: Stored, uid: Int64) throws {
        let data = try JSONEncoder().encode(value)
        try writeCredentials(data, uid)
        memory[uid] = value
    }
    private nonisolated static func write(_ data: Data, uid: Int64) throws {
        var status = SecItemUpdate(query(uid) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = query(uid)
            query[kSecValueData] = data
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PlazaFailure(key: "auth_error") }
    }
}
