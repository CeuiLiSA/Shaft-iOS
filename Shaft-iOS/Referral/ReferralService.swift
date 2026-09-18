import Foundation
import CryptoKit
import Security
import Observation

/// Auth V2 bootstrap uses the existing app signature. Pixiv credentials never leave
/// the Pixiv client. Rotating refresh tokens and retry IDs live together in Keychain.
actor ReferralSession {
    static let shared = ReferralSession()
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
        send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await ReferralSession.session.data(for: $0) },
        currentUID: @escaping @Sendable () -> Int64 = { KeychainTokenStore.shared.load()?.user?.id ?? 0 },
        readCredentials: @escaping @Sendable (Int64) -> Data? = { ReferralSession.read($0) },
        writeCredentials: @escaping @Sendable (Data, Int64) throws -> Void = { try ReferralSession.write($0, uid: $1) }
    ) {
        self.send = send; self.currentUID = currentUID
        self.readCredentials = readCredentials; self.writeCredentials = writeCredentials
    }
    private var deviceID: String {
        let key = "pixshaft_auth_device_id"
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    func token(uid: Int64, rejected: String? = nil) async throws -> String {
        guard uid > 0, currentUID() == uid else {
            throw ReferralFailure(code: "login_required")
        }
        if let flight = flights[uid] { return try await flight.value }
        let flight = Task { try await self.obtain(uid: uid, rejected: rejected) }
        flights[uid] = flight
        defer { flights[uid] = nil }
        return try await flight.value
    }

    private func obtain(uid: Int64, rejected: String?) async throws -> String {
        var stored = memory[uid] ?? readCredentials(uid).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        if let value = stored, value.tokens.access_expires_at > referralNow() + 60_000,
           value.tokens.access_token != rejected, value.refreshAttempt == nil {
            return value.tokens.access_token
        }
        if var value = stored {
            value.refreshAttempt = value.refreshAttempt ?? UUID().uuidString
            try save(value, uid: uid) // Persist before rotating, so interrupted retries reuse this ID.
            do {
                let tokens = try await exchange("token", body: [
                    "grant_type": "refresh_token", "refresh_token": value.tokens.refresh_token,
                    "device_id": deviceID,
                ], attempt: value.refreshAttempt)
                guard tokens.uid == uid else { throw ReferralFailure(code: "uid_forbidden") }
                stored = Stored(tokens: tokens)
            } catch let failure as ReferralFailure where failure.code == "unauthorized" {
                stored = nil
            }
        }
        if stored == nil {
            let tokens = try await exchange("session", body: [
                "grant_type": "app_hmac", "uid": uid, "device_id": deviceID,
            ])
            guard tokens.uid == uid else { throw ReferralFailure(code: "uid_forbidden") }
            stored = Stored(tokens: tokens)
        }
        guard let stored, currentUID() == uid else {
            throw ReferralFailure(code: "login_required")
        }
        try save(stored, uid: uid)
        return stored.tokens.access_token
    }

    private func exchange(_ path: String, body: [String: Any], attempt: String? = nil) async throws -> Tokens {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var request = URLRequest(url: URL(string: "https://pixshaft.com/v1/auth/\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let attempt { request.setValue(attempt, forHTTPHeaderField: "Idempotency-Key") }
        if path == "session" {
            guard !ShaftEventsConfig.hmacSecret.isEmpty else { throw ReferralFailure(code: "unauthorized") }
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
            let detail = try? JSONDecoder().decode(ReferralActionResponse.self, from: response)
            if path == "token", status == 400,
               ["invalid_grant", "token_reuse_detected"].contains(detail?.error ?? "") {
                throw ReferralFailure(code: "unauthorized")
            }
            throw ReferralFailure(code: status == 401 ? "unauthorized" : status == 429 ? "rate_limited" : "auth_unavailable")
        }
        return try JSONDecoder().decode(Tokens.self, from: response)
    }

    private nonisolated static func query(_ uid: Int64) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.shaft.ShaftiOS.referral-session", kSecAttrAccount: String(uid)]
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
        guard status == errSecSuccess else { throw ReferralFailure(code: "unauthorized") }
    }
}

struct ReferralMutation: Sendable {
    var operation: String
    var task: String?
    var id: Int64?
    var code: String?
    var url: String?
    var description: String?
}

protocol ReferralServing: Sendable {
    func load(uid: Int64, campaign: String?) async throws -> ReferralSnapshot
    func mutate(_ mutation: ReferralMutation, uid: Int64, campaign: String?) async throws -> ReferralSnapshot
}

struct ReferralAPI: ReferralServing {
    private static let session = URLSession(configuration: .ephemeral)
    func load(uid: Int64, campaign: String?) async throws -> ReferralSnapshot {
        let data = try await request("state", uid: uid, campaign: campaign)
        return try JSONDecoder().decode(ReferralSnapshot.self, from: data)
    }
    func mutate(_ mutation: ReferralMutation, uid: Int64, campaign: String?) async throws -> ReferralSnapshot {
        var body: [String: Any] = ["uid": uid]
        body["campaign"] = campaign
        body["task"] = mutation.task
        body["id"] = mutation.id
        body["code"] = mutation.code
        body["url"] = mutation.url
        body["description"] = mutation.description
        let data = try await request(mutation.operation, uid: uid, body: body)
        let response = try JSONDecoder().decode(ReferralActionResponse.self, from: data)
        guard let state = response.state else { throw ReferralFailure(code: "invalid_state", stale: true) }
        return state
    }
    func activity(uid: Int64, bookmarked: Bool) async throws {
        _ = try await request("activity", uid: uid, body: ["uid": uid, "bookmarked": bookmarked])
    }
    private func request(_ path: String, uid: Int64, campaign: String? = nil, body: [String: Any]? = nil) async throws -> Data {
        var components = URLComponents(string: "https://pixshaft.com/v1/referral/\(path)")!
        if let campaign { components.queryItems = [URLQueryItem(name: "campaign", value: campaign)] }
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("ios", forHTTPHeaderField: "X-Shaft-Flavor")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        var token = try await ReferralSession.shared.token(uid: uid)
        for attempt in 0...1 {
            try Task.checkCancellation()
            guard KeychainTokenStore.shared.load()?.user?.id == uid else { throw ReferralFailure(code: "login_required") }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await Self.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 {
                token = try await ReferralSession.shared.token(uid: uid, rejected: token)
                continue
            }
            guard (200..<300).contains(status) else {
                let detail = try? JSONDecoder().decode(ReferralActionResponse.self, from: data)
                throw ReferralFailure(code: status == 401 ? "unauthorized" : status == 429 ? "rate_limited" : detail?.error ?? "generic", stale: status == 409)
            }
            return data
        }
        throw ReferralFailure(code: "unauthorized")
    }
}

@MainActor @Observable
final class ReferralModel {
    private(set) var snapshot = ReferralSnapshot()
    private(set) var loading = true
    private(set) var busy = false
    private(set) var error: ReferralFailure?
    private(set) var campaign: String?
    private let service: any ReferralServing
    private let currentUID: () -> Int64
    private var ownerUID: Int64 = 0
    private var generation = 0
    private var refreshPending = false

    init(service: any ReferralServing = ReferralAPI(), currentUID: @escaping () -> Int64 = { KeychainTokenStore.shared.load()?.user?.id ?? 0 }) {
        self.service = service
        self.currentUID = currentUID
    }
    func refresh() async {
        let uid = currentUID()
        if ownerUID != uid {
            generation += 1; ownerUID = uid; campaign = nil
            snapshot = ReferralSnapshot(); error = nil; loading = true
        }
        guard uid > 0 else { loading = false; error = ReferralFailure(code: "login_required"); return }
        guard !busy else { refreshPending = true; return }
        _ = await perform { try await self.service.load(uid: uid, campaign: self.campaign) }
    }
    func chooseCampaign(_ value: String) async {
        guard value != campaign else { return }
        generation += 1; campaign = value; snapshot = ReferralSnapshot(); loading = true; error = nil
        await refresh()
    }
    func mutate(_ mutation: ReferralMutation) async -> ReferralFailure? {
        guard !busy, ownerUID > 0, ownerUID == currentUID() else { return ReferralFailure(code: "unauthorized") }
        let uid = ownerUID, campaign = snapshot.campaign
        return await perform { try await self.service.mutate(mutation, uid: uid, campaign: campaign) }
    }
    private func perform(_ operation: () async throws -> ReferralSnapshot) async -> ReferralFailure? {
        busy = true
        let uid = ownerUID, revision = generation
        defer {
            busy = false; loading = false
            if refreshPending { refreshPending = false; Task { await self.refresh() } }
        }
        do {
            let response = try await operation()
            try Task.checkCancellation()
            guard uid == currentUID(), uid == ownerUID else {
                snapshot = ReferralSnapshot(); refreshPending = true
                return ReferralFailure(code: "login_required")
            }
            guard response.uid == nil || response.uid == uid else { throw ReferralFailure(code: "uid_forbidden") }
            guard revision == generation else { refreshPending = true; return ReferralFailure(code: "not_ready") }
            guard campaign == nil || response.campaign == campaign else { throw ReferralFailure(code: "invalid_state") }
            snapshot = response; error = nil
            return nil
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                refreshPending = true
                return ReferralFailure(code: "network")
            }
            let failure = error as? ReferralFailure ?? ReferralFailure(code: error is URLError ? "network" : "generic")
            if revision == generation && uid == currentUID() { self.error = failure }
            if failure.stale { refreshPending = true }
            return failure
        }
    }
}

/// Foreground use records an active day. A successful own-account bookmark also
/// records the separate bookmark condition; neither signal may suppress the other.
actor ReferralActivityReporter {
    static let shared = ReferralActivityReporter()
    private struct Activity: Hashable {
        var uid: Int64
        var day: Int
        var bookmarked: Bool
    }
    private var inFlight = Set<Activity>()
    private var reported = Set<Activity>()
    private var campaignFlags: [Int64: (enabled: Bool, until: Date)] = [:]
    private let currentUID: @Sendable () -> Int64
    private let now: @Sendable () -> Date
    private let enabled: @Sendable (Int64) async throws -> Bool
    private let send: @Sendable (Int64, Bool) async throws -> Void

    init(
        currentUID: @escaping @Sendable () -> Int64 = { KeychainTokenStore.shared.load()?.user?.id ?? 0 },
        now: @escaping @Sendable () -> Date = { Date() },
        enabled: @escaping @Sendable (Int64) async throws -> Bool = { try await ReferralActivityReporter.fetchEnabled(uid: $0) },
        send: @escaping @Sendable (Int64, Bool) async throws -> Void = { try await ReferralAPI().activity(uid: $0, bookmarked: $1) }
    ) {
        self.currentUID = currentUID; self.now = now; self.enabled = enabled; self.send = send
    }
    func active(uid: Int64) async { await report(uid: uid, bookmarked: false) }
    func bookmark(uid: Int64) async { await report(uid: uid, bookmarked: true) }

    private func report(uid: Int64, bookmarked: Bool) async {
        guard uid > 0, currentUID() == uid else { return }
        let date = now(), day = Int((date.timeIntervalSince1970 + 8 * 3600) / 86400)
        reported = reported.filter { $0.day == day }
        let key = Activity(uid: uid, day: day, bookmarked: bookmarked)
        guard !reported.contains(key), inFlight.insert(key).inserted else { return }
        defer { inFlight.remove(key) }
        do {
            // Config is read-only and prevents activity traffic when the campaign is closed.
            if (campaignFlags[uid]?.until ?? .distantPast) <= date {
                let flag = try await enabled(uid)
                campaignFlags[uid] = (flag, now().addingTimeInterval(300))
            }
            try Task.checkCancellation()
            guard campaignFlags[uid]?.enabled == true, currentUID() == uid else { return }
            try await send(uid, bookmarked)
            reported.insert(key)
            if bookmarked { reported.insert(Activity(uid: uid, day: day, bookmarked: false)) }
        } catch { /* The next foreground use or successful bookmark retries. */ }
    }
    private static func fetchEnabled(uid: Int64) async throws -> Bool {
        let url = URL(string: "https://pixshaft.com/v1/config?uid=\(uid)")!
        var request = URLRequest(url: url, timeoutInterval: 10)
        let sign = HMAC<SHA256>.authenticationCode(for: Data(String(uid).utf8), using: SymmetricKey(data: Data(ShaftEventsConfig.hmacSecret.utf8)))
            .map { String(format: "%02x", $0) }.joined()
        request.setValue(sign, forHTTPHeaderField: "X-Shaft-Sign")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw ReferralFailure(code: "network")
        }
        struct Config: Decodable { var referralEnabled: Bool? }
        return try JSONDecoder().decode(Config.self, from: data).referralEnabled == true
    }
}

/// An explicit invite survives the login/onboarding flow; binding still needs confirmation.
@MainActor @Observable
final class ReferralLinkStore {
    static let shared = ReferralLinkStore()
    private static let key = "referral_pending_invite"
    var pendingCode: String? = UserDefaults.standard.string(forKey: key)
    func receive(_ url: URL) {
        guard url.scheme?.lowercased() == "shaftintent", url.host?.lowercased() == "referral",
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value,
              let code = parseReferralCode(raw) else { return }
        UserDefaults.standard.set(code, forKey: Self.key)
        pendingCode = code
    }
    func consume() -> String? {
        guard let code = pendingCode else { return nil }
        pendingCode = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
        return parseReferralCode(code)
    }
}
