import CryptoKit
import Foundation
import os

private let cacheLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Shaft-iOS",
    category: "BorrowedSearch"
)

/// A search page the borrowed-search cache can hold: `{ illusts|novels, next_url }`.
protocol BorrowedSearchPage: Codable, Sendable {
    var nextUrl: String? { get }
}

extension IllustResponse: BorrowedSearchPage {}
extension NovelResponse: BorrowedSearchPage {}

/// The client half of the borrowed-search cache (server: pixshaft-api
/// `src/search-cache.js`), ported from Android `Nana7miSearchCache`.
///
/// A borrowed search spends the requester's quota, usually a token renew, and a
/// Premium-only request from yet another IP against a pooled account. So ask
/// pixshaft **before** borrowing: a hit is rendered as is; a miss borrows as
/// before and then posts the page back, so the next caller sending the same
/// request — whoever they are — hits. Pagination works the same way: every
/// page's `next_url` is the next page's key.
///
/// The server does not understand Pixiv parameters. The key is a sha256 of the
/// exact request about to be sent, so any differing parameter is a different
/// key. iOS derives it from the complete query it sends, which includes
/// `filter=for_ios`: iOS pages never mix with Android's `for_android` pages,
/// whose models serialize differently.
///
/// This path must never fail a search: any lookup error is a miss, and a fill
/// is fire-and-forget.
enum BorrowedSearchCache {
    enum Kind: String, Sendable { case illust, novel }
    /// The server bills a hit by it: first = one search, next = one page turn.
    enum Page: String, Sendable { case first, next }

    /// Canonical-string version prefix: bump it when the spelling changes so old
    /// keys simply stop matching instead of serving the wrong page.
    static let keyVersion = "v1"

    static let hourMS: Int64 = 3_600_000
    static let dayMS: Int64 = 24 * hourMS

    /// Searches whose results move at any moment (a window that holds today or
    /// yesterday, or a date sort): only merge practically simultaneous searches.
    static let maxAgeFreshMS: Int64 = 30 * 60_000

    /// Same as the server's `SEARCH_CACHE_SERVE_MAX_AGE_MS`; it clamps anything longer.
    static let maxAgeStableMS: Int64 = 7 * dayMS

    /// How old a cached page this search accepts. `startDate`/`endDate` are the
    /// `yyyy-MM-dd` values actually sent (relative buckets already resolved
    /// against today); nil means the parameter is not sent.
    ///
    /// Popularity sorts: how fast a ranking moves depends on how new the works in
    /// the window are — fresh uploads climb within hours, year-old works barely
    /// move in a week. So tier by how far back the window reaches: no period (the
    /// default a tag tap opens) or a window that ended over a month ago → 7 days;
    /// the last year → 1 day; the last month → 12 hours; the last week → 2 hours;
    /// the last 24 hours → 30 minutes. A window ending today carries its dates in
    /// the key, so the key rotates daily by itself; this only governs one day.
    ///
    /// Date sorts (non-Premium users borrow for them only with a bookmark filter):
    /// the head of the list is the newest work, so any window reaching into the
    /// last week gets 30 minutes; only a window that ended over a week ago relaxes
    /// to 1 day (no new uploads enter, only the rare work crossing the threshold).
    ///
    /// A date that does not parse takes the strictest tier: fewer hits rather
    /// than a logically wrong result.
    static func maxAgeMS(sort: String?, startDate: String?, endDate: String?, today: Date) -> Int64 {
        let daysSinceEnd: Int
        if let endDate {
            guard let days = daysBefore(endDate, today: today) else { return maxAgeFreshMS }
            daysSinceEnd = days
        } else {
            daysSinceEnd = 0
        }
        let popular = sort == SortType.popularDesc
            || sort == SortType.popularMaleDesc
            || sort == SortType.popularFemaleDesc
        if !popular {
            return endDate != nil && daysSinceEnd > 7 ? dayMS : maxAgeFreshMS
        }
        guard let startDate, daysSinceEnd < 30 else { return maxAgeStableMS }
        guard let daysSinceStart = daysBefore(startDate, today: today) else { return maxAgeFreshMS }
        switch daysSinceStart {
        case ...2: return maxAgeFreshMS
        case ...8: return 2 * hourMS
        case ...32: return 12 * hourMS
        case ...366: return dayMS
        default: return maxAgeStableMS
        }
    }

    /// How many days `date` lies before `today` (negative for a future date);
    /// nil unless it is a real `yyyy-MM-dd` date.
    static func daysBefore(_ date: String, today: Date) -> Int? {
        let parts = date.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let parsed = utc.date(from: DateComponents(year: year, month: month, day: day)),
              utc.dateComponents([.year, .month, .day], from: parsed)
                == DateComponents(year: year, month: month, day: day) else { return nil }
        // Today is the local calendar day, the same one SearchFilter.ymd sends.
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let now = local.dateComponents([.year, .month, .day], from: today)
        guard let todayUTC = utc.date(from: DateComponents(year: now.year, month: now.month, day: now.day)) else { return nil }
        return utc.dateComponents([.day], from: parsed, to: todayUTC).day
    }

    /// First-page key. `params` are the query items about to be sent, in a fixed
    /// order; a nil value is a parameter that is not sent — "absent" and "empty
    /// string" are two different Pixiv requests.
    static func firstPageKey(kind: Kind, params: [(String, String?)]) -> String {
        var canonical = "\(keyVersion)|\(kind.rawValue)|first"
        for (name, value) in params {
            guard let value else { continue }
            canonical += "|\(name)=\(formEncode(value))"
        }
        return sha256Hex(canonical)
    }

    /// Every query item of an app-api search, in name order.
    static func params(of query: [String: String]) -> [(String, String?)] {
        query.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Page-turn key: `next_url` already carries every parameter plus the offset,
    /// and is not bound to an account.
    static func nextPageKey(kind: Kind, nextURL: String) -> String {
        sha256Hex("\(keyVersion)|\(kind.rawValue)|next|\(nextURL)")
    }

    /// One id per page operation; the lookup and a possible dispatch share it.
    static func newRequestID() -> String { UUID().uuidString.lowercased() }

    /// A hit's page, or nil for anything that is not a clean hit.
    static func decode<T: BorrowedSearchPage>(_ data: Data, as type: T.Type) -> T? {
        guard let envelope = try? JSONDecoder().decode(HitEnvelope<T>.self, from: data),
              envelope.hit == true, let page = envelope.page else { return nil }
        guard isSafePixivNextURL(page.nextUrl) else {
            cacheLog.warning("cache page carried an unsafe next_url")
            return nil
        }
        return page
    }

    /// A cached cursor is followed with the borrowed account's Authorization.
    static func isSafePixivNextURL(_ raw: String?) -> Bool {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        guard let url = URLComponents(string: raw) else { return false }
        return url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "app-api.pixiv.net"
            && url.user == nil && url.password == nil && url.fragment == nil
            && (url.port == nil || url.port == 443)
    }

    /// `java.net.URLEncoder.encode(value, "UTF-8")`, so the canonical string
    /// spells a value exactly as Android's does.
    static func formEncode(_ value: String) -> String {
        var out = ""
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "*"), UInt8(ascii: "_"):
                out.append(Character(UnicodeScalar(byte)))
            case UInt8(ascii: " "):
                out.append("+")
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    private static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct HitEnvelope<Page: Decodable>: Decodable {
    let hit: Bool?
    let page: Page?
}

private struct LookupEnvelope: Decodable {
    let hit: Bool?
    let ageMs: Int64?
    /// A miss's short-lived one-time fill receipt; older servers send none.
    let storeToken: String?
}

/// A refusal is a 200 too: nothing is worth retrying, `reason` is for the log.
private struct StoreAck: Decodable {
    let stored: Bool?
    let reason: String?
}

/// Network half: lookup before a borrow, fill after it. Holds the one-time
/// store receipts a miss hands out.
actor BorrowedSearchCacheClient {
    static let shared = BorrowedSearchCacheClient()

    private struct FillKey: Hashable { let uid: Int64; let kind: BorrowedSearchCache.Kind; let key: String }
    private var fillTokens: [FillKey: String] = [:]
    private static let maxPendingFills = 64

    /// The page on a hit, nil for everything else. A hit is already billed by the
    /// server per `page`; a full quota answers 429 there, which is a miss here —
    /// the following borrow is refused the same way and takes the existing
    /// notice + preview fallback.
    func lookup<T: BorrowedSearchPage>(
        _ type: T.Type,
        kind: BorrowedSearchCache.Kind,
        key: String,
        page: BorrowedSearchCache.Page,
        requestID: String?,
        maxAgeMS: Int64,
        requesterUID: Int64,
        stage: String
    ) async -> T? {
        guard requesterUID > 0 else { return nil }
        let fillKey = FillKey(uid: requesterUID, kind: kind, key: key)
        // A new lookup supersedes any receipt left by an abandoned older flow.
        fillTokens[fillKey] = nil
        let data: Data
        do {
            let (body, status) = try await PixshaftAccountClient.shared.searchCacheLookup(
                .init(
                    uid: requesterUID, kind: kind.rawValue, key: key,
                    maxAgeMs: maxAgeMS, page: page.rawValue, requestId: requestID
                )
            )
            guard (200..<300).contains(status) else {
                cacheLog.warning("stage=\(stage, privacy: .public) cache=http_\(status, privacy: .public)")
                return nil
            }
            data = body
        } catch {
            cacheLog.warning("stage=\(stage, privacy: .public) cache=error error_type=\(String(describing: Swift.type(of: error)), privacy: .public)")
            return nil
        }
        let envelope = try? JSONDecoder().decode(LookupEnvelope.self, from: data)
        let decoded = BorrowedSearchCache.decode(data, as: type)
        if decoded == nil, envelope?.hit == false, requestID != nil,
           let token = envelope?.storeToken, !token.trimmingCharacters(in: .whitespaces).isEmpty {
            // An optimisation, never durable state: dropping receipts only lowers
            // the future hit rate, it cannot break the search that succeeded.
            if fillTokens.count >= Self.maxPendingFills { fillTokens.removeAll() }
            fillTokens[fillKey] = token
        }
        cacheLog.debug("stage=\(stage, privacy: .public) cache=\(decoded != nil ? "hit" : "miss", privacy: .public) key=\(key.prefix(12), privacy: .public) age_ms=\(envelope?.ageMs.map(String.init) ?? "-", privacy: .public) max_age_ms=\(maxAgeMS, privacy: .public)")
        return decoded
    }

    /// Fill one page with the receipt its miss received. Encoding happens here;
    /// the upload is detached and fire-and-forget: the page already reached the
    /// UI, and nothing about the cache may reach back into it.
    func store<T: BorrowedSearchPage>(
        _ page: T,
        kind: BorrowedSearchCache.Kind,
        key: String,
        requesterUID: Int64,
        stage: String
    ) {
        guard requesterUID > 0,
              let storeToken = fillTokens.removeValue(
                forKey: FillKey(uid: requesterUID, kind: kind, key: key)
              ) else { return }
        let body: Data
        do {
            let encoded = try JSONEncoder().encode(page)
            let pageObject = try JSONSerialization.jsonObject(with: encoded)
            body = try JSONSerialization.data(withJSONObject: [
                "uid": requesterUID,
                "kind": kind.rawValue,
                "key": key,
                "page": pageObject,
                "storeToken": storeToken,
            ] as [String: Any])
        } catch {
            cacheLog.warning("stage=\(stage, privacy: .public) cache_store=serialize_failed")
            return
        }
        Task.detached(priority: .utility) {
            do {
                let (data, status) = try await PixshaftAccountClient.shared.searchCacheStore(body: body)
                let ack = try? JSONDecoder().decode(StoreAck.self, from: data)
                let outcome = (200..<300).contains(status) && ack?.stored == true ? "stored" : "refused"
                cacheLog.debug("stage=\(stage, privacy: .public) cache_store=\(outcome, privacy: .public) key=\(key.prefix(12), privacy: .public) reason=\(ack?.reason ?? String(status), privacy: .public)")
            } catch {
                cacheLog.warning("stage=\(stage, privacy: .public) cache_store=error error_type=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }
}
