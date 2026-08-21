import Foundation
import CryptoKit

// MARK: - Config & anonymous identity

/// Configuration + anonymous identity for the self-hosted **shaft-api-v2**
/// backend (当前最热 / 站长推荐·本月收藏 / 操作记录 + anonymous event reporting).
/// 1:1 with Android `BuildConfig.SHAFT_EVENTS_BASE_URL` / `SHAFT_EVENTS_HMAC`
/// and `EventReporter`'s anonymous `client_id`.
///
/// This backend is NOT pixiv — its own base URL, no pixiv token, no direct-conn.
enum ShaftEventsConfig {
    /// shaft-api-v2 base. Upstream default is a plaintext-HTTP IP; the matching
    /// ATS exception lives in `Info.plist`. Read endpoints need no auth.
    static let baseURL = URL(string: "http://36.138.103.18:30009")!

    /// HMAC-SHA256 secret for the WRITE path (events/batch, uid-bindings) — the
    /// same value as the server's `/etc/shaft-api-v2/events-hmac-secret` and the
    /// Android build's `SHAFT_EVENTS_HMAC`. The key is the secret's ASCII bytes
    /// verbatim (NOT hex-decoded), matching Node's `crypto.createHmac('sha256', secret)`.
    /// Empty here would disable reporting (fork-build behavior). Kept in-source
    /// because this is a PRIVATE repo; move to a gitignored xcconfig if it ever
    /// goes public.
    static let hmacSecret = "f193c37033335db2c05dc03e10d38f6fe780b8f70391b6114181e46770f1dfc4"

    static var hmacEnabled: Bool { !hmacSecret.isEmpty }

    static let platform = "ios"
    static let channel = "github"
    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    private static let clientIdKey = "shaft_events_client_id_v1"
    /// Guards the check-generate-store sequence below: the reporter actor and the
    /// main-thread `EventHistoryVM`/`bindUid` can first-access `clientId`
    /// concurrently, and without this lock they could each mint a different id and
    /// clobber each other — the reporter would then write under one fingerprint
    /// while 操作记录 queries another, showing an empty history forever.
    private static let clientIdLock = NSLock()

    /// sha256(randomUUID | randomUUID) — a stable 64-hex anonymous fingerprint,
    /// generated once and reused forever. Never the pixiv uid (that link lives
    /// only server-side in the uid-bindings table). Matches upstream `EventReporter`.
    static var clientId: String {
        clientIdLock.lock()
        defer { clientIdLock.unlock() }
        if let existing = UserDefaults.standard.string(forKey: clientIdKey),
           existing.count == 64 {
            return existing
        }
        let seed = UUID().uuidString + "|" + UUID().uuidString
        let hex = SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: clientIdKey)
        return hex
    }
}

enum ShaftApiError: Error { case http(Int), badURL, decode }

// MARK: - Read client (no auth)

/// Read-only client for shaft-api-v2's public endpoints. Each response `item`
/// embeds the full IllustsBean/NovelBean/UserBean JSON (`bean`/`meta`), which we
/// decode with the existing `Illust`/`Novel`/`PixivUser` decoders — no second
/// Pixiv call. Decoding is done by hand (JSONSerialization) so we can clear the
/// reporter's stale `is_bookmarked` and lift the trending score onto the model.
actor ShaftApiV2Client {
    static let shared = ShaftApiV2Client()

    private let base = ShaftEventsConfig.baseURL
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    // 当前最热 — window nil = live recency feed; day/week/month = live 日/周/月榜.
    func recentWorks(type: String, window: String?, limit: Int = 60, offset: Int = 0) async throws -> WorksPage {
        var q = [URLQueryItem(name: "type", value: type),
                 URLQueryItem(name: "limit", value: String(limit)),
                 URLQueryItem(name: "offset", value: String(offset))]
        if let window { q.append(URLQueryItem(name: "window", value: window)) }
        let data = try await getData(path: "/api/v1/recent/works", query: q)
        return decodeWorks(data, type: type, scoreFromBookmark: true)
    }

    // 站长推荐 / 本月收藏 — upstream hard-codes window=week, sort=bookmark, include_meta=1.
    func trendingWorks(type: String, window: String = "week", sort: String = "bookmark",
                       limit: Int = 60, offset: Int = 0) async throws -> WorksPage {
        let q = [URLQueryItem(name: "type", value: type),
                 URLQueryItem(name: "window", value: window),
                 URLQueryItem(name: "limit", value: String(limit)),
                 URLQueryItem(name: "sort", value: sort),
                 URLQueryItem(name: "include_meta", value: "1"),
                 URLQueryItem(name: "offset", value: String(offset))]
        let data = try await getData(path: "/api/v1/trending/works", query: q)
        // trending uses the weighted `score`; recent uses raw bookmark_count.
        return decodeWorks(data, type: type, scoreFromBookmark: false)
    }

    /// 发现页首屏聚合 — one `/api/v1/discover` call fills both shaft-api-v2
    /// shelves (本月收藏 `site` / 当前最热 `recent`), 1:1 with upstream
    /// `DiscoverViewModel.loadDiscover`: `site` scores by weighted `score`,
    /// `recent` by raw `bookmark_count`; reporter bookmark state cleared;
    /// beans without a `user` dropped; each shelf truncated to `limit`.
    func discover(limit: Int = 12) async throws -> DiscoverShelves {
        // No query → build the URL directly (an empty queryItems array would leave a dangling "?").
        let data = try await getData(url: base.appendingPathComponent("/api/v1/discover"))
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ShaftApiError.decode
        }
        func shelf(_ key: String, scoreFromBookmark: Bool) -> [Illust] {
            let items = (obj[key] as? [String: Any])?["items"] as? [[String: Any]] ?? []
            return Array(decodeIllusts(items, scoreFromBookmark: scoreFromBookmark)
                .filter { $0.user != nil }
                .prefix(limit))
        }
        return DiscoverShelves(site: shelf("site", scoreFromBookmark: false),
                               recent: shelf("recent", scoreFromBookmark: true))
    }

    // 操作记录 — reads this client's own event log by client_id (public, no auth).
    func eventsHistory(clientId: String, limit: Int = 50, before: Int64? = nil) async throws -> EventHistoryPage {
        var q = [URLQueryItem(name: "client_id", value: clientId),
                 URLQueryItem(name: "limit", value: String(limit))]
        if let before { q.append(URLQueryItem(name: "before", value: String(before))) }
        let data = try await getData(path: "/api/v1/events/history", query: q)
        return decodeHistory(data)
    }

    /// Follow a server-supplied absolute `next_url` verbatim (trending/recent paging).
    func worksByUrl(_ url: String, type: String, scoreFromBookmark: Bool) async throws -> WorksPage {
        guard let u = URL(string: url) else { throw ShaftApiError.badURL }
        let data = try await getData(url: u)
        return decodeWorks(data, type: type, scoreFromBookmark: scoreFromBookmark)
    }

    // MARK: transport

    private func getData(path: String, query: [URLQueryItem]) async throws -> Data {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = query
        guard let url = comps.url else { throw ShaftApiError.badURL }
        return try await getData(url: url)
    }
    private func getData(url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ShaftApiError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    // MARK: decode

    /// JSON numbers usually arrive as `NSNumber`, but a backend may serialize a
    /// 64-bit id as a string to preserve precision — accept both so ids/scores
    /// are never silently dropped.
    private static func int64(_ v: Any?) -> Int64? {
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String { return Int64(s) }
        return nil
    }
    private static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// Illust-only variant of `decodeWorks` over an already-parsed `items` array
    /// (the `/discover` aggregate nests two of them).
    private func decodeIllusts(_ rawItems: [[String: Any]], scoreFromBookmark: Bool) -> [Illust] {
        let dec = JSONDecoder()
        var illusts: [Illust] = []
        for it in rawItems {
            guard var bean = it["bean"] as? [String: Any] else { continue }
            bean["is_bookmarked"] = false
            let score = scoreFromBookmark
                ? Double(Self.int64(it["bookmark_count"]) ?? 0)
                : (Self.double(it["score"]) ?? 0)
            guard let beanData = try? JSONSerialization.data(withJSONObject: bean),
                  var il = try? dec.decode(Illust.self, from: beanData) else { continue }
            il.trendingScore = score
            illusts.append(il)
        }
        return illusts
    }

    private func decodeWorks(_ data: Data, type: String, scoreFromBookmark: Bool) -> WorksPage {
        let dec = JSONDecoder()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return WorksPage(illusts: [], novels: [], nextUrl: nil)
        }
        let nextUrl = obj["next_url"] as? String
        let rawItems = obj["items"] as? [[String: Any]] ?? []
        var illusts: [Illust] = []
        var novels: [Novel] = []
        for it in rawItems {
            guard var bean = it["bean"] as? [String: Any] else { continue }
            // Clear the reporter's bookmark snapshot — the current user bookmarks
            // under their own name (display resolves via InteractionStore anyway).
            bean["is_bookmarked"] = false
            let score = scoreFromBookmark
                ? Double(Self.int64(it["bookmark_count"]) ?? 0)
                : (Self.double(it["score"]) ?? 0)
            guard let beanData = try? JSONSerialization.data(withJSONObject: bean) else { continue }
            if type == "novel" {
                if var n = try? dec.decode(Novel.self, from: beanData) {
                    n.trendingScore = score
                    novels.append(n)
                }
            } else {
                if var il = try? dec.decode(Illust.self, from: beanData) {
                    il.trendingScore = score
                    illusts.append(il)
                }
            }
        }
        return WorksPage(illusts: illusts, novels: novels, nextUrl: nextUrl)
    }

    private func decodeHistory(_ data: Data) -> EventHistoryPage {
        let dec = JSONDecoder()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return EventHistoryPage(entries: [], nextBefore: nil)
        }
        let nextBefore = Self.int64(obj["next_before"])
        let rawItems = obj["items"] as? [[String: Any]] ?? []
        var entries: [EventHistoryEntry] = []
        for it in rawItems {
            guard let id = Self.int64(it["id"]),
                  let eventType = it["event_type"] as? String,
                  let targetType = it["target_type"] as? String,
                  let targetId = Self.int64(it["target_id"]) else { continue }
            let ts = Self.int64(it["ts"]) ?? 0
            var illust: Illust?; var novel: Novel?; var user: PixivUser?
            if var meta = it["meta"] as? [String: Any] {
                meta["is_bookmarked"] = false
                if let metaData = try? JSONSerialization.data(withJSONObject: meta) {
                    switch targetType {
                    case "user": user = try? dec.decode(PixivUser.self, from: metaData)
                    case "novel": novel = try? dec.decode(Novel.self, from: metaData)
                    default: illust = try? dec.decode(Illust.self, from: metaData)
                    }
                }
            }
            entries.append(EventHistoryEntry(id: id, ts: ts, eventType: eventType,
                                             targetType: targetType, targetId: targetId,
                                             illust: illust, novel: novel, user: user))
        }
        return EventHistoryPage(entries: entries, nextBefore: nextBefore)
    }
}

// MARK: - Result types

struct WorksPage {
    var illusts: [Illust]
    var novels: [Novel]
    var nextUrl: String?
}

/// `/api/v1/discover` result — the two Discover-tab shelves.
struct DiscoverShelves {
    var site: [Illust]
    var recent: [Illust]
}

struct EventHistoryPage {
    var entries: [EventHistoryEntry]
    var nextBefore: Int64?
}

struct EventHistoryEntry: Identifiable {
    let id: Int64
    let ts: Int64
    let eventType: String
    let targetType: String
    let targetId: Int64
    let illust: Illust?
    let novel: Novel?
    let user: PixivUser?
}

// MARK: - Trending score pill format (upstream TrendingScoreFormat)

enum TrendingScore {
    /// "▲ N" with k/M compaction; nil (hidden) for score ≤ 0 / NaN.
    static func label(_ score: Double?) -> String? {
        // `s` arrives from the backend over plaintext HTTP — NEVER Int()-convert an
        // unbounded Double (that traps on out-of-range values like 1e300). Compare
        // in Double space; only the safe [1, 1000) range is narrowed to Int.
        guard let s = score, s.isFinite, s >= 1 else { return nil }
        if s >= 1_000_000 { return "▲ " + String(format: "%.1fM", s / 1_000_000) }
        if s >= 1_000 { return "▲ " + String(format: "%.1fk", s / 1_000) }
        return "▲ \(Int(s))"
    }
}
