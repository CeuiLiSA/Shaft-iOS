import CryptoKit
import Foundation
import Observation
import os
import WebKit

private let borrowedLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Shaft-iOS",
    category: "BorrowedSearch"
)

// MARK: - pixshaft.com wire model

struct BorrowedAccountUser: Codable, Sendable, Equatable {
    var id: Int64
    var name: String?
    var account: String?
    var isPremium: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, account
        case isPremium = "is_premium"
    }
}

struct BorrowedAccount: Codable, Sendable, Equatable {
    var accessToken: String?
    var expiresIn: Int?
    var refreshToken: String?
    var scope: String?
    var tokenType: String?
    var user: BorrowedAccountUser?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case tokenType = "token_type"
        case user
    }
}

struct BorrowedAccountPayload: Sendable, Equatable {
    var uid: Int64
    var account: BorrowedAccount
    var updatedAt: Int64
    var expiresAt: Int64
    var expired: Bool
}

enum BorrowedFetchResult: Sendable {
    case success(BorrowedAccountPayload)
    case noAccount
    case notPremium(Int64, BorrowedAccount)
    case rateLimited(retryAfter: Int64?, scope: String?, resetsAt: Int64?, serverTime: Int64?)
    case httpFailure(Int)
    case invalidRequest
    case invalidResponse
    case networkFailure(String)

    var reason: String {
        switch self {
        case .success(let value): return value.expired ? "expired" : "success"
        case .noAccount: return "no_account"
        case .notPremium: return "not_premium"
        case .rateLimited: return "rate_limited"
        case .httpFailure(let status): return "http_\(status)"
        case .invalidRequest: return "invalid_request"
        case .invalidResponse: return "invalid_response"
        case .networkFailure: return "network_failure"
        }
    }
}

struct BorrowedQuotaNotice: Equatable, Sendable, Identifiable {
    let scope: String
    let resetInMS: Int64
    let bucket: String
    var id: String { bucket }
}

/// One-shot UI channel for quota exhaustion. Minute-level rate limiting remains
/// silent; only the two durable uid buckets are user-visible, exactly as in
/// Nana7miQuotaNotice.
@MainActor
@Observable
final class BorrowedQuotaNoticeStore {
    static let shared = BorrowedQuotaNoticeStore()

    private(set) var notice: BorrowedQuotaNotice?
    @ObservationIgnored private var announcedBucket: String?

    func report(_ result: BorrowedFetchResult) {
        guard case let .rateLimited(retryAfter, scopeValue, resetsAt, serverTime) = result,
              let scope = scopeValue,
              scope == "uid_5h" || scope == "uid_weekly" else { return }
        let bucket = "\(scope):\(resetsAt ?? 0)"
        guard bucket != announcedBucket else { return }
        let resetInMS: Int64
        if let resetsAt, let serverTime { resetInMS = resetsAt - serverTime }
        else if let retryAfter { resetInMS = retryAfter * 1_000 }
        else { return }
        guard resetInMS > 0 else { return }
        announcedBucket = bucket
        notice = .init(scope: scope, resetInMS: resetInMS, bucket: bucket)
    }

    func consume(id: String) {
        if notice?.id == id { notice = nil }
    }
}

private struct Nana7miResponse: Codable {
    let uid: Int64?
    let account: BorrowedAccount?
    let updatedAt: Int64?
    let expiresAt: Int64?
    let expired: Bool?
}

private struct RateLimitResponse: Codable {
    let scope: String?
    let retryAfterSeconds: Int64?
    let serverTime: Int64?
    let quotas: [QuotaWindow]?
    struct QuotaWindow: Codable {
        let scope: String?
        let resetsAt: Int64?
    }
}

private struct RemoteConfigResponse: Codable {
    let nana7miSearchEnabled: Bool?
}

private struct OnlineAck: Codable { let ok: Bool; let uid: Int64? }
private struct InvalidAck: Codable { let ok: Bool; let uid: Int64? }

// MARK: - Signed pixshaft client

actor PixshaftAccountClient {
    static let shared = PixshaftAccountClient()

    private let baseURL = URL(string: "https://pixshaft.com")!
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func remoteConfig(uid: Int64) async throws -> Bool? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/v1/config"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "uid", value: String(uid))]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 8
        if !ShaftEventsConfig.hmacSecret.isEmpty {
            request.setValue(
                Self.sign(Data(String(uid).utf8)),
                forHTTPHeaderField: "X-Shaft-Sign"
            )
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw PixshaftError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(RemoteConfigResponse.self, from: data).nana7miSearchEnabled
    }

    func fetchNana7mi(uid: Int64) async -> BorrowedFetchResult {
        guard uid > 0 else { return .invalidRequest }
        do {
            let body = try JSONEncoder().encode(["uid": uid])
            let (data, http) = try await send(path: "/v1/account/nana7mi", body: body)
            switch http.statusCode {
            case 404:
                return .noAccount
            case 429:
                let retryHeader = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int64.init)
                let detail = try? JSONDecoder().decode(RateLimitResponse.self, from: data)
                let resetsAt = detail?.quotas?.first { $0.scope == detail?.scope }?.resetsAt
                return .rateLimited(
                    retryAfter: detail?.retryAfterSeconds ?? retryHeader,
                    scope: detail?.scope,
                    resetsAt: resetsAt,
                    serverTime: detail?.serverTime
                )
            default:
                guard (200..<300).contains(http.statusCode) else { return .httpFailure(http.statusCode) }
                guard let wire = try? JSONDecoder().decode(Nana7miResponse.self, from: data),
                      let uid = wire.uid, uid > 0,
                      let account = wire.account,
                      account.user?.id == uid,
                      account.accessToken?.isEmpty == false,
                      account.refreshToken?.isEmpty == false,
                      let updatedAt = wire.updatedAt, updatedAt > 0,
                      let expiresAt = wire.expiresAt, expiresAt >= updatedAt,
                      let expired = wire.expired else { return .invalidResponse }
                if account.user?.isPremium == false { return .notPremium(uid, account) }
                return .success(.init(
                    uid: uid, account: account, updatedAt: updatedAt,
                    expiresAt: expiresAt, expired: expired
                ))
            }
        } catch is CancellationError {
            return .networkFailure("cancelled")
        } catch {
            return .networkFailure(error.localizedDescription)
        }
    }

    func reportOnline(uid: Int64, account: BorrowedAccount, premiumAgeMS: Int64? = nil) async throws {
        struct Body: Codable {
            let uid: Int64
            let account: BorrowedAccount
            let premiumAgeMs: Int64?
        }
        let data = try JSONEncoder().encode(Body(uid: uid, account: account, premiumAgeMs: premiumAgeMS))
        let (responseData, http) = try await send(path: "/v1/account/online", body: data)
        guard (200..<300).contains(http.statusCode) else { throw PixshaftError.http(http.statusCode) }
        let ack = try JSONDecoder().decode(OnlineAck.self, from: responseData)
        guard ack.ok, ack.uid == uid else { throw PixshaftError.rejected }
    }

    func invalidate(uid: Int64, refreshTokenHash: String) async throws {
        struct Body: Codable { let uid: Int64; let refreshTokenHash: String }
        let data = try JSONEncoder().encode(Body(uid: uid, refreshTokenHash: refreshTokenHash))
        let (responseData, http) = try await send(path: "/v1/account/nana7mi/invalid", body: data)
        guard (200..<300).contains(http.statusCode) else { throw PixshaftError.http(http.statusCode) }
        let ack = try JSONDecoder().decode(InvalidAck.self, from: responseData)
        guard ack.ok, ack.uid == uid else { throw PixshaftError.rejected }
    }

    private func send(path: String, body: Data) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !ShaftEventsConfig.hmacSecret.isEmpty {
            request.setValue(Self.sign(body), forHTTPHeaderField: "X-Shaft-Sign")
        }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PixshaftError.nonHTTP }
        return (data, http)
    }

    private static func sign(_ data: Data) -> String {
        let key = SymmetricKey(data: Data(ShaftEventsConfig.hmacSecret.utf8))
        return HMAC<SHA256>.authenticationCode(for: data, using: key)
            .map { String(format: "%02x", $0) }.joined()
    }

    enum PixshaftError: Error { case http(Int), nonHTTP, rejected }
}

// MARK: - Per-account remote kill switch

actor BorrowedSearchRemoteConfig {
    static let shared = BorrowedSearchRemoteConfig()
    private var inFlight: [Int64: Task<Void, Never>] = [:]
    private var memory: [Int64: Bool] = [:]
    /// Mirrors Android's single `fetchedForUid`: switching A → B → A must
    /// refresh A again instead of treating any historical process read as fresh.
    private var fetchedForUID: Int64?
    private var failedAt: [Int64: TimeInterval] = [:]
    private let retryCooldown: TimeInterval = 60

    /// A read never waits for the network: use the last per-uid value now and
    /// refresh it in the background. First install defaults to disabled.
    func enabled(uid: Int64) -> Bool {
        guard uid > 0 else { return false }
        let cached = memory[uid]
            ?? (UserDefaults.standard.object(forKey: key(uid)) as? Bool ?? false)
        memory[uid] = cached
        if fetchedForUID == uid || inFlight[uid] != nil { return cached }
        if let failure = failedAt[uid],
           ProcessInfo.processInfo.systemUptime - failure < retryCooldown {
            return cached
        }
        let task = Task<Void, Never> {
            do {
                let value = try await PixshaftAccountClient.shared.remoteConfig(uid: uid) ?? cached
                self.finishRefresh(uid: uid, value: value, succeeded: true)
            } catch {
                self.finishRefresh(uid: uid, value: cached, succeeded: false)
            }
        }
        inFlight[uid] = task
        return cached
    }

    private func finishRefresh(uid: Int64, value: Bool, succeeded: Bool) {
        inFlight[uid] = nil
        memory[uid] = value
        if succeeded {
            fetchedForUID = uid
            failedAt[uid] = nil
            UserDefaults.standard.set(value, forKey: key(uid))
        } else {
            failedAt[uid] = ProcessInfo.processInfo.systemUptime
        }
    }

    private func key(_ uid: Int64) -> String { "nana7mi_search_enabled_\(uid)" }
}

// MARK: - Durable refreshed-token handoff

/// Monotonic age of a membership value that was actually read from Pixiv in
/// this process. A borrowed account never records here, so it cannot vouch for
/// somebody else's Premium status through our device.
actor PremiumObservationClock {
    static let shared = PremiumObservationClock()
    private var observedAt: [Int64: TimeInterval] = [:]

    func record(uid: Int64) {
        guard uid > 0 else { return }
        observedAt[uid] = ProcessInfo.processInfo.systemUptime
    }

    func ageMS(uid: Int64) -> Int64? {
        guard let start = observedAt[uid] else { return nil }
        return Int64(max(0, ProcessInfo.processInfo.systemUptime - start) * 1_000)
    }
}

actor BorrowedAccountReportOutbox {
    static let shared = BorrowedAccountReportOutbox()
    private let onlinePrefix = "nana7mi_outbox_online_"
    private let invalidPrefix = "nana7mi_outbox_invalid_"
    private var delivering = false
    private var deliveryWaiters: [CheckedContinuation<Void, Never>] = []

    func persistAndAttemptOnline(uid: Int64, account: BorrowedAccount) async -> Bool {
        guard uid > 0, account.user?.id == uid,
              account.accessToken?.isEmpty == false,
              account.refreshToken?.isEmpty == false,
              let data = try? JSONEncoder().encode(account) else { return false }
        UserDefaults.standard.set(data, forKey: onlinePrefix + String(uid))
        UserDefaults.standard.removeObject(forKey: invalidPrefix + String(uid))
        guard UserDefaults.standard.synchronize() else { return false }
        await attemptOnline(uid: uid)
        return true
    }

    func persistAndAttemptInvalid(uid: Int64, refreshToken: String) async {
        let hash = SHA256.hash(data: Data(refreshToken.utf8))
            .map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hash, forKey: invalidPrefix + String(uid))
        _ = UserDefaults.standard.synchronize()
        await attemptInvalid(uid: uid)
    }

    func flush() async {
        let keys = UserDefaults.standard.dictionaryRepresentation().keys
        for key in keys where key.hasPrefix(onlinePrefix) {
            if let uid = Int64(key.dropFirst(onlinePrefix.count)) { await attemptOnline(uid: uid) }
        }
        for key in keys where key.hasPrefix(invalidPrefix) {
            if let uid = Int64(key.dropFirst(invalidPrefix.count)) { await attemptInvalid(uid: uid) }
        }
    }

    private func attemptOnline(uid: Int64) async {
        await acquireDelivery()
        defer { releaseDelivery() }
        let key = onlinePrefix + String(uid)
        guard let data = UserDefaults.standard.data(forKey: key),
              let account = try? JSONDecoder().decode(BorrowedAccount.self, from: data) else { return }
        do {
            let age = await PremiumObservationClock.shared.ageMS(uid: uid)
            try await PixshaftAccountClient.shared.reportOnline(
                uid: uid, account: account, premiumAgeMS: age
            )
            // A refresh may replace this row while the request is in flight.
            // Never let the older completion erase that newer rotated token.
            if UserDefaults.standard.data(forKey: key) == data {
                UserDefaults.standard.removeObject(forKey: key)
            }
        } catch {
            borrowedLog.warning("online report queued uid=\(uid, privacy: .public)")
        }
    }

    private func attemptInvalid(uid: Int64) async {
        await acquireDelivery()
        defer { releaseDelivery() }
        let key = invalidPrefix + String(uid)
        guard let hash = UserDefaults.standard.string(forKey: key) else { return }
        do {
            try await PixshaftAccountClient.shared.invalidate(uid: uid, refreshTokenHash: hash)
            if UserDefaults.standard.string(forKey: key) == hash {
                UserDefaults.standard.removeObject(forKey: key)
            }
        } catch {
            borrowedLog.warning("invalid-token report queued uid=\(uid, privacy: .public)")
        }
    }

    private func acquireDelivery() async {
        if !delivering { delivering = true; return }
        await withCheckedContinuation { deliveryWaiters.append($0) }
    }

    private func releaseDelivery() {
        if deliveryWaiters.isEmpty { delivering = false }
        else { deliveryWaiters.removeFirst().resume() }
    }
}

enum CurrentAccountOnlineReporter {
    static func report(uid: Int64, isPremium: Bool) async {
        guard let token = KeychainTokenStore.shared.load(), token.user?.id == uid else { return }
        let account = BorrowedAccount(
            accessToken: token.accessToken,
            expiresIn: token.expiresIn,
            refreshToken: token.refreshToken,
            scope: token.scope,
            tokenType: token.tokenType,
            user: .init(
                id: uid, name: token.user?.name, account: token.user?.account,
                isPremium: isPremium
            )
        )
        _ = await BorrowedAccountReportOutbox.shared.persistAndAttemptOnline(uid: uid, account: account)
    }
}

// MARK: - Borrow lifecycle

enum BorrowedSessionError: Error {
    case unavailable(String)
}

actor BorrowedAccountSession {
    private(set) var payload: BorrowedAccountPayload?
    private(set) var borrowedAccountLost = false
    private let oauth = PixivOAuthClient(config: .pixivAndroid)
    private static let validMS: Int64 = 55 * 60 * 1_000

    func fetchReady(requesterUID: Int64) async -> BorrowedFetchResult {
        await BorrowedAccountReportOutbox.shared.flush()
        if Task.isCancelled { return .networkFailure("cancelled") }
        let fetched = await PixshaftAccountClient.shared.fetchNana7mi(uid: requesterUID)
        if Task.isCancelled { return .networkFailure("cancelled") }
        if case .rateLimited = fetched {
            await BorrowedQuotaNoticeStore.shared.report(fetched)
        }
        if case .notPremium(let uid, let account) = fetched {
            _ = await BorrowedAccountReportOutbox.shared.persistAndAttemptOnline(uid: uid, account: account)
        }

        let ready: BorrowedFetchResult
        if case .success(let value) = fetched, value.expired {
            ready = await renew(value, reason: "server_expired")
        } else {
            ready = fetched
        }
        if case .success(let value) = ready { payload = value }
        else { payload = nil }
        return ready
    }

    func request<T: Sendable>(
        _ operation: @Sendable (String) async throws -> T
    ) async throws -> T {
        guard var current = payload else { throw BorrowedSessionError.unavailable("missing_payload") }
        var refreshed = false

        if current.expiresAt <= Self.nowMS {
            let result = await renew(current, reason: "client_55m_expired")
            try Task.checkCancellation()
            guard case .success(let value) = result else {
                payload = nil; borrowedAccountLost = true
                throw BorrowedSessionError.unavailable(result.reason)
            }
            current = value; refreshed = true
        }

        do {
            return try await operation(current.account.accessToken!)
        } catch {
            guard !refreshed, Self.isOAuthExpired(error) else { throw error }
            let result = await renew(current, reason: "pixiv_oauth_400")
            try Task.checkCancellation()
            guard case .success(let value) = result else {
                payload = nil; borrowedAccountLost = true
                throw BorrowedSessionError.unavailable(result.reason)
            }
            return try await operation(value.account.accessToken!)
        }
    }

    private func renew(_ stale: BorrowedAccountPayload, reason: String) async -> BorrowedFetchResult {
        guard let refreshToken = stale.account.refreshToken, !refreshToken.isEmpty,
              stale.account.user?.id == stale.uid else { return .invalidResponse }

        let result = await oauth.refreshToken(refreshToken)
        let response: PixivOAuthResponse
        switch result {
        case .success(let value, _):
            response = value
        case .failure(let failure):
            if case .serverRejected(let status, let message) = failure,
               status == 400,
               message.contains("Invalid refresh token") {
                await BorrowedAccountReportOutbox.shared.persistAndAttemptInvalid(
                    uid: stale.uid, refreshToken: refreshToken
                )
            }
            return .invalidResponse
        }

        let freshPremium: Bool? = response.user?.id == stale.uid ? response.user?.isPremium : nil
        var account = stale.account
        account.accessToken = response.accessToken
        account.refreshToken = response.refreshToken
        account.expiresIn = response.expiresIn
        if let freshPremium, var user = account.user {
            user.isPremium = freshPremium
            account.user = user
        }
        let updatedAt = Self.nowMS
        let renewed = BorrowedAccountPayload(
            uid: stale.uid, account: account, updatedAt: updatedAt,
            expiresAt: updatedAt + Self.validMS, expired: false
        )

        // A rotated refresh token is safe to use only after a durable owner exists.
        guard await BorrowedAccountReportOutbox.shared.persistAndAttemptOnline(
            uid: stale.uid, account: account
        ) else { return .invalidResponse }

        if freshPremium == false { return .notPremium(stale.uid, account) }
        payload = renewed
        borrowedLog.info("renewed uid=\(stale.uid, privacy: .public) reason=\(reason, privacy: .public)")
        return .success(renewed)
    }

    private static var nowMS: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
    private static func isOAuthExpired(_ error: Error) -> Bool {
        guard case PixivAPI.APIError.http(let code, let body) = error, code == 400 else { return false }
        return body.contains("Error occurred at the OAuth process") || body.contains("Invalid refresh token")
    }
}

/// A fair, process-wide permit across illustration/novel first pages and
/// pagination. This prevents a quick tab switch from spending two borrow slots.
actor BorrowedSearchSerial {
    static let shared = BorrowedSearchSerial()
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            try Task.checkCancellation()
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        if !occupied { occupied = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().resume() }
    }
}

// MARK: - Search route selection

actor SearchRequestCoordinator {
    private let api: PixivAPI
    private var illustBorrow = BorrowedAccountSession()
    private var novelBorrow = BorrowedAccountSession()

    init(api: PixivAPI) { self.api = api }

    func startGeneration() {
        illustBorrow = BorrowedAccountSession()
        novelBorrow = BorrowedAccountSession()
    }

    func startIllustGeneration() { illustBorrow = BorrowedAccountSession() }
    func startNovelGeneration() { novelBorrow = BorrowedAccountSession() }

    func firstIllust(
        word: String, filter: SearchFilter, requesterUID: Int64, isPremium: Bool
    ) async throws -> IllustResponse {
        // Freeze the repository-generation session before the first suspension.
        // A newer search may replace the coordinator property while remote
        // config is loading; the old request must never adopt that new session.
        let session = illustBorrow
        let selectedPreview = filter.sort == SortType.popularPreview
        let wantsSort = !isPremium && SortType.isPremiumOnly(filter.sort, isNovel: false)
        let hasBookmarkBound = (filter.bookmarkRange?.min ?? 0) > 0
            || (filter.bookmarkRange?.max ?? 0) > 0
        let wantsBookmark = !isPremium && hasBookmarkBound
        let enabled = await BorrowedSearchRemoteConfig.shared.enabled(uid: requesterUID)

        if selectedPreview || (wantsSort && !enabled) {
            return try await api.searchPopularPreviewIllust(word: word, filter: filter)
        }
        guard enabled, !selectedPreview, wantsSort || wantsBookmark else {
            return try await api.searchIllust(word: word, filter: filter)
        }

        do {
            let borrowed = try await BorrowedSearchSerial.shared.run { [api, session] in
                let result = await session.fetchReady(requesterUID: requesterUID)
                try Task.checkCancellation()
                guard case .success = result else {
                    throw BorrowedSessionError.unavailable(result.reason)
                }
                return try await session.request { token in
                    try await api.searchIllust(word: word, filter: filter, accessToken: token)
                }
            }
            return await Self.withViewerBookmarkState(borrowed)
        } catch is BorrowedSessionError {
            return wantsSort
                ? try await api.searchPopularPreviewIllust(word: word, filter: filter)
                : try await api.searchIllust(word: word, filter: filter)
        }
    }

    func firstNovel(
        word: String, filter: SearchFilter, requesterUID: Int64, isPremium: Bool
    ) async throws -> NovelResponse {
        let session = novelBorrow
        let safeFilter = withNovelSafeSort(filter)
        let selectedPreview = safeFilter.sort == SortType.popularPreview
        let wantsSort = !isPremium && SortType.isPremiumOnly(safeFilter.sort, isNovel: true)
        let hasBookmarkBound = (safeFilter.bookmarkRange?.min ?? 0) > 0
            || (safeFilter.bookmarkRange?.max ?? 0) > 0
        let wantsBookmark = !isPremium && hasBookmarkBound
        let enabled = await BorrowedSearchRemoteConfig.shared.enabled(uid: requesterUID)

        func own(_ preview: Bool) async throws -> NovelResponse {
            let first: NovelResponse
            if preview {
                first = try await api.searchPopularPreviewNovel(word: word, filter: safeFilter)
            } else {
                first = try await api.searchNovel(word: word, filter: safeFilter)
            }
            guard safeFilter.target == .partialTags, first.novels.isEmpty else { return first }
            if preview {
                return try await api.searchPopularPreviewNovel(
                    word: word, filter: safeFilter, omitDefaultTarget: true
                )
            }
            return try await api.searchNovel(
                word: word, filter: safeFilter, omitDefaultTarget: true
            )
        }

        if selectedPreview || (wantsSort && !enabled) { return try await own(true) }
        guard enabled, !selectedPreview, wantsSort || wantsBookmark else { return try await own(false) }

        do {
            let borrowed = try await BorrowedSearchSerial.shared.run { [api, session] in
                let result = await session.fetchReady(requesterUID: requesterUID)
                try Task.checkCancellation()
                guard case .success = result else {
                    throw BorrowedSessionError.unavailable(result.reason)
                }
                return try await session.request { token in
                    let first = try await api.searchNovel(
                        word: word, filter: safeFilter, accessToken: token
                    )
                    guard safeFilter.target == .partialTags, first.novels.isEmpty else { return first }
                    return try await api.searchNovel(
                        word: word, filter: safeFilter, accessToken: token,
                        omitDefaultTarget: true
                    )
                }
            }
            return await Self.withViewerBookmarkState(borrowed)
        } catch is BorrowedSessionError {
            return try await own(wantsSort)
        }
    }

    func nextIllust(_ url: String) async throws -> IllustResponse {
        let session = illustBorrow
        if await session.borrowedAccountLost { return .init(illusts: [], nextUrl: nil) }
        guard await session.payload != nil else { return try await api.nextPage(url) }
        do {
            let borrowed: IllustResponse = try await BorrowedSearchSerial.shared.run { [api, session] in
                try await session.request { token in
                    try await api.nextPage(url, accessToken: token)
                }
            }
            return await Self.withViewerBookmarkState(borrowed)
        } catch is BorrowedSessionError {
            return .init(illusts: [], nextUrl: nil)
        }
    }

    func nextNovel(_ url: String) async throws -> NovelResponse {
        let session = novelBorrow
        if await session.borrowedAccountLost { return .init(novels: [], nextUrl: nil) }
        guard await session.payload != nil else { return try await api.nextPage(url) }
        do {
            let borrowed: NovelResponse = try await BorrowedSearchSerial.shared.run { [api, session] in
                try await session.request { token in
                    try await api.nextPage(url, accessToken: token)
                }
            }
            return await Self.withViewerBookmarkState(borrowed)
        } catch is BorrowedSessionError {
            return .init(novels: [], nextUrl: nil)
        }
    }

    // MARK: Viewer bookmark state (#1063)

    /// A borrowed token answers `is_bookmarked` for the **borrowed** account. Pixiv
    /// has no batch "did I bookmark these" endpoint, so keep only what is certainly
    /// right for the viewer: works in the viewer's local bookmark mirror are
    /// bookmarked; everything else becomes "unknown" (nil — rendered as not
    /// bookmarked; in-app toggles still win through `InteractionStore`). "Not in
    /// the mirror" never means "not bookmarked": the mirror may still be filling.
    private static func withViewerBookmarkState(_ response: IllustResponse) async -> IllustResponse {
        let mirrored = await BookmarkMirrorService.shared.bookmarkedAmong(contentType: .illust, targetIds: response.illusts.map(\.id))
        let illusts = response.illusts.map { BookmarkMirrorMapper.withBookmarkedState($0, mirrored.contains($0.id) ? true : nil) }
        return IllustResponse(illusts: illusts, nextUrl: response.nextUrl)
    }

    private static func withViewerBookmarkState(_ response: NovelResponse) async -> NovelResponse {
        let mirrored = await BookmarkMirrorService.shared.bookmarkedAmong(contentType: .novel, targetIds: response.novels.map(\.id))
        let novels = response.novels.map { BookmarkMirrorMapper.withBookmarkedState($0, mirrored.contains($0.id) ? true : nil) }
        return NovelResponse(novels: novels, nextUrl: response.nextUrl)
    }

    private func withNovelSafeSort(_ filter: SearchFilter) -> SearchFilter {
        var value = filter
        value.sort = SortType.novelSafe(filter.sort)
        return value
    }
}

// MARK: - Novel series grouping (`www.pixiv.net`, gs=1)

/// `WKWebView` and `URLSession` keep separate cookie jars on iOS. Pixiv-Shaft's
/// web search explicitly uses its WebView session, so bridge the persistent
/// WebKit cookies into the grouped AJAX request instead of silently remaining
/// anonymous after the user has logged in on the web.
@MainActor
enum PixivWebCookieBridge {
    static func header(for url: URL) async -> String? {
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        let now = Date()
        let applicable = cookies.filter { cookie in
            let domain = cookie.domain
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            let domainMatches = host == domain || host.hasSuffix(".\(domain)")
            let pathMatches = path.hasPrefix(cookie.path.isEmpty ? "/" : cookie.path)
            let alive = cookie.expiresDate.map { $0 > now } ?? true
            return domainMatches && pathMatches && alive
        }.sorted { lhs, rhs in
            let lhsExact = lhs.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .caseInsensitiveCompare(host) == .orderedSame
            let rhsExact = rhs.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .caseInsensitiveCompare(host) == .orderedSame
            if lhsExact != rhsExact { return lhsExact }
            return lhs.path.count > rhs.path.count
        }

        // A stale duplicate PHPSESSID is particularly harmful because pixiv
        // accepts the first occurrence. Keep the most host/path-specific value.
        var names = Set<String>()
        let deduplicated = applicable.filter { names.insert($0.name).inserted }
        guard !deduplicated.isEmpty else { return nil }
        return deduplicated.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

struct SearchNovelItem: Identifiable, Sendable {
    let novel: Novel
    let destination: AppRoute
    let episodeCount: Int?
    let isConcluded: Bool?

    var id: String {
        switch destination {
        case .novelSeries(let id): return "series:\(id)"
        default: return "novel:\(novel.id)"
        }
    }

    static func novel(_ novel: Novel) -> SearchNovelItem {
        .init(novel: novel, destination: .novelDetail(novel.id), episodeCount: nil, isConcluded: nil)
    }
}

struct GroupedNovelPage: Sendable {
    let items: [SearchNovelItem]
    let nextPage: Int?
    let webAuthenticated: Bool
}

private struct WebResponse<Body: Decodable>: Decodable {
    let error: Bool?
    let message: String?
    let body: Body?
}

private struct WebNovelSearchBody: Decodable {
    let novel: Section?
    struct Section: Decodable {
        let data: [Collection]?
        let total: Int?
        let lastPage: Int?
    }
    struct Collection: Decodable {
        let id: String?
        let novelId: String?
        let title: String?
        let caption: String?
        let cover: Cover?
        let tags: [String]?
        let xRestrict: Int?
        let aiType: Int?
        let userId: Int64?
        let userName: String?
        let profileImageUrl: String?
        let bookmarkCount: Int?
        let isConcluded: Bool?
        let episodeCount: Int?
        let publishedEpisodeCount: Int?
        let textLength: Int?
        let publishedTextLength: Int?
        let createDateTime: String?
        let latestPublishDateTime: String?
        let publishedDateTime: String?
        /// Object when the active web-cookie session bookmarked this work;
        /// null/absent for anonymous or unbookmarked rows.
        let bookmarkData: JSONPresence?

        struct Cover: Decodable {
            let urls: URLs?
            struct URLs: Decodable {
                let width240: String?
                let width480: String?
                let original: String?
                enum CodingKeys: String, CodingKey {
                    case width240 = "240mw"
                    case width480 = "480mw"
                    case original
                }
            }
        }
    }
}

/// Decode-and-discard any non-null JSON value. Optional decoding still turns a
/// literal `null` into nil, which is all grouped search needs for bookmarkData.
private struct JSONPresence: Decodable {
    init(from decoder: Decoder) throws {}
}

actor GroupedNovelSearchClient {
    static let shared = GroupedNovelSearchClient()

    func search(word: String, filter: SearchFilter, page: Int) async throws -> GroupedNovelPage {
        // Android's grouped-web mapper treats zero as "unset" for bookmark
        // bounds before deciding whether the legacy users入り suffix is kept.
        let bookmarkMin = filter.bookmarkRange?.min.flatMap { $0 > 0 ? $0 : nil }
        let bookmarkMax = filter.bookmarkRange?.max.flatMap { $0 > 0 ? $0 : nil }
        let effectiveWord: String = {
            // Web grouped search treats bookmark and users入り as one narrowing
            // dimension, unlike app-api where both can coexist.
            guard bookmarkMin == nil, bookmarkMax == nil, filter.keywordUsers > 0 else { return word }
            return "\(word) \(filter.keywordUsers)users入り"
        }()

        var components = URLComponents(string: "https://www.pixiv.net")!
        var pathAllowed = CharacterSet.urlPathAllowed
        // This is one Retrofit @Path segment, not a pre-encoded path. Encode a
        // literal percent too; leaving it in percentEncodedPath can either form
        // an unintended escape or make URLComponents reject the URL.
        pathAllowed.remove(charactersIn: "/%?#")
        let escaped = effectiveWord.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? effectiveWord
        components.percentEncodedPath = "/ajax/search/novels/\(escaped)"

        var query: [URLQueryItem] = [
            .init(name: "word", value: effectiveWord),
            .init(name: "p", value: String(page)),
            .init(name: "gs", value: "1"),
            .init(name: "order", value: webOrder(filter.sort)),
            .init(name: "mode", value: webMode(filter.r18)),
            .init(name: "s_mode", value: webTarget(filter.target)),
            // Pixiv-Shaft's Retrofit declaration defaults this exact web-only
            // response-language parameter to zh.
            .init(name: "lang", value: "zh"),
        ]
        func add<T: CustomStringConvertible>(_ name: String, _ value: T?) {
            if let value { query.append(.init(name: name, value: value.description)) }
        }
        if let (start, end) = filter.resolvedDates() { add("scd", start); add("ecd", end) }
        add("blt", bookmarkMin)
        add("bgt", bookmarkMax)
        if let body = filter.bodyLength {
            switch body.unit {
            case .characters: add("tlt", body.min); add("tgt", body.max)
            case .words: add("wlt", body.min); add("wgt", body.max)
            case .readingTime: add("rlt", body.min); add("rgt", body.max)
            }
        }
        if filter.originalOnly { add("original_only", 1) }
        add("genre", filter.genre)
        add("work_lang", filter.language)
        if filter.replaceableOnly { add("replaceable_only", 1) }
        if filter.ai == .excludeAI { add("ai_type", 1) }
        components.queryItems = query

        guard let url = components.url else { throw WebSearchError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // The authoritative jar is WebKit's. Do not let Foundation append a
        // second stale PHPSESSID after the deduplicated explicit header.
        request.httpShouldHandleCookies = false
        request.setValue(PixivClientIdentity.acceptLanguage(), forHTTPHeaderField: "accept-language")
        request.setValue("https://www.pixiv.net/", forHTTPHeaderField: "referer")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
            forHTTPHeaderField: "user-agent"
        )
        let cookie = await PixivWebCookieBridge.header(for: url)
        if let cookie {
            request.setValue(cookie, forHTTPHeaderField: "cookie")
        }
        let (data, response) = try await DirectConnection.data(
            for: request, using: DirectConnection.shared,
            directConnect: DirectConnection.isEnabledAtLaunch
        )
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw WebSearchError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder().decode(WebResponse<WebNovelSearchBody>.self, from: data)
        if decoded.error == true { throw WebSearchError.business(decoded.message ?? "gs=1 failed") }
        let section = decoded.body?.novel
        let rows = section?.data ?? []
        let items = rows.compactMap { makeItem($0, filter: filter) }
        let lastPage = section?.lastPage ?? 0
        let next = rows.isEmpty || page >= lastPage ? nil : page + 1
        let authenticated = cookie?.split(separator: ";").contains { component in
            let pair = component.trimmingCharacters(in: .whitespaces)
            return pair.hasPrefix("PHPSESSID=") && pair != "PHPSESSID="
        } ?? false
        return .init(items: items, nextPage: next, webAuthenticated: authenticated)
    }

    private func makeItem(
        _ row: WebNovelSearchBody.Collection,
        filter: SearchFilter
    ) -> SearchNovelItem? {
        let novelID = row.novelId.flatMap(Int64.init)
        let seriesID = row.id.flatMap(Int64.init)
        guard novelID != nil || seriesID != nil else { return nil }
        let id = novelID ?? seriesID!
        let asSeries = novelID == nil
        let cover = row.cover?.urls.flatMap { $0.width480 ?? $0.width240 ?? $0.original }
        let imageURLs = cover.map {
            ImageUrls(
                url: nil, large: $0, medium: $0, original: $0, small: nil,
                squareMedium: $0, px170x170: nil, px50x50: nil
            )
        }
        let avatar = row.profileImageUrl.flatMap { value in
            value.isEmpty ? nil : ImageUrls(
                url: nil, large: nil, medium: value, original: nil, small: nil,
                squareMedium: nil, px170x170: value, px50x50: nil
            )
        }
        let user = PixivUser(
            id: row.userId ?? 0,
            name: row.userName ?? "",
            account: nil,
            profileImageUrls: avatar,
            isFollowed: nil
        )
        let novel = Novel(
            id: id,
            title: row.title ?? "",
            caption: row.caption,
            imageUrls: imageURLs,
            user: user,
            tags: (row.tags ?? []).map { Tag(name: $0, translatedName: nil) },
            pageCount: 1,
            // Android's WebNovelCollection.toNovel uses the published total
            // whenever present for both series and one-shot rows.
            textLength: (row.publishedTextLength ?? 0) > 0
                ? row.publishedTextLength
                : (row.textLength ?? 0),
            isBookmarked: row.bookmarkData != nil,
            totalBookmarks: row.bookmarkCount ?? 0,
            totalView: nil,
            createDate: asSeries
                ? (row.latestPublishDateTime ?? row.createDateTime)
                : (row.publishedDateTime ?? row.createDateTime),
            series: asSeries ? NovelSeries(id: id, title: row.title) : nil,
            xRestrict: row.xRestrict ?? 0,
            novelAIType: row.aiType ?? 0
        )
        guard filter.accepts(novel) else { return nil }
        if asSeries {
            return .init(
                novel: novel,
                destination: .novelSeries(seriesId: id),
                episodeCount: (row.publishedEpisodeCount ?? 0) > 0
                    ? row.publishedEpisodeCount
                    : (row.episodeCount ?? 0),
                isConcluded: row.isConcluded ?? false
            )
        }
        return .novel(novel)
    }

    private func webOrder(_ sort: String) -> String {
        switch sort {
        case SortType.dateAsc: return "date"
        case SortType.dateDesc: return "date_d"
        case SortType.popularMaleDesc: return "popular_male_d"
        case SortType.popularFemaleDesc: return "popular_female_d"
        default: return "popular_d"
        }
    }
    private func webMode(_ mode: R18Mode) -> String {
        switch mode { case .all: return "all"; case .safeOnly: return "safe"; case .r18Only: return "r18" }
    }
    private func webTarget(_ target: SearchTarget) -> String {
        switch target {
        case .exactTags: return "s_tag_full"
        case .novelText: return "s_tc"
        default: return "s_tag"
        }
    }
    enum WebSearchError: Error { case badURL, http(Int), business(String) }
}
