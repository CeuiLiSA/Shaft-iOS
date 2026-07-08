import Foundation
import CryptoKit

/// Anonymous event reporter for shaft-api-v2 (the WRITE path that feeds
/// 当前最热 / 站长推荐 aggregation and populates 操作记录). 1:1 with Android
/// `EventReporter`: fire-and-forget, never blocks the caller, never throws.
///
/// Reports bookmark/unbookmark (illust·manga·novel) and follow/unfollow (user),
/// each with the work/user JSON as payload. **No `ts`** — the server assigns it
/// (a client-supplied ts is a hard 400). Batched + HMAC-signed. When
/// `ShaftEventsConfig.hmacSecret` is empty (fork/OSS build) every method no-ops,
/// exactly like an Android fork build.
actor ShaftEventReporter {
    static let shared = ShaftEventReporter()

    private struct Pending {
        let type: String
        let targetType: String
        let targetId: Int64
        let payload: [String: Any]?
        var retries: Int = 0
    }

    private let FLUSH_THRESHOLD = 10
    private let FLUSH_INTERVAL: Duration = .seconds(30)
    private let MAX_BATCH = 50
    private let MAX_QUEUE = 500
    private let MAX_RETRIES = 3
    private let MAX_PAYLOAD_BYTES = 200_000

    private var queue: [Pending] = []
    private var flushing = false
    private var flushScheduled = false

    private let session: URLSession
    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    // MARK: Public report API

    /// `illust` optional — the payload seeds server-side meta, but even without it
    /// (id-only callers) the event is still recorded. target_type derives from the
    /// illust's type when available (manga vs illust), else "illust".
    func reportIllustBookmark(_ illust: Illust?, id: Int64, added: Bool) {
        let tt = (illust?.type == "manga") ? "manga" : "illust"
        enqueue(added ? "bookmark" : "unbookmark", tt, id, illust.flatMap { encode($0) })
    }
    func reportNovelBookmark(_ novel: Novel, added: Bool) {
        enqueue(added ? "bookmark" : "unbookmark", "novel", novel.id, encode(novel))
    }
    func reportFollow(_ user: PixivUser?, id: Int64, followed: Bool) {
        enqueue(followed ? "follow" : "unfollow", "user", id, user.flatMap { encode($0) })
    }

    /// Bind this anonymous client_id to a pixiv uid (silent, idempotent, cached).
    /// The events table stays anonymous — only the bindings table holds the link.
    func bindUid(_ uid: Int64) async {
        guard ShaftEventsConfig.hmacEnabled, uid > 0 else { return }
        let cid = ShaftEventsConfig.clientId
        let want = "\(uid):\(cid)"
        if UserDefaults.standard.string(forKey: Self.bindingCacheKey) == want { return }
        let bodyData = Data("{\"client_id\":\"\(cid)\",\"uid\":\(uid)}".utf8)
        do {
            try await post(path: "/api/v1/uid-bindings", body: bodyData)
            UserDefaults.standard.set(want, forKey: Self.bindingCacheKey)
        } catch {
            // leave uncached → retried on next launch/login
        }
    }

    // MARK: Queue

    private func enqueue(_ type: String, _ targetType: String, _ targetId: Int64, _ payload: [String: Any]?) {
        guard ShaftEventsConfig.hmacEnabled else { return }
        queue.append(Pending(type: type, targetType: targetType, targetId: targetId, payload: payload))
        if queue.count > MAX_QUEUE { queue.removeFirst(queue.count - MAX_QUEUE) }  // drop oldest
        if queue.count >= FLUSH_THRESHOLD {
            Task { await self.flush() }
        } else {
            scheduleFlush()
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task {
            try? await Task.sleep(for: FLUSH_INTERVAL)
            flushScheduled = false
            await self.flush()
        }
    }

    private func flush() async {
        guard ShaftEventsConfig.hmacEnabled, !flushing, !queue.isEmpty else { return }
        flushing = true
        defer { flushing = false }

        // Drain the batch BEFORE the network await. Actor reentrancy means an
        // enqueue (and its MAX_QUEUE front-eviction) can run while we're awaiting;
        // if the in-flight items were still in the queue, a `removeFirst(count)`
        // afterwards could delete the wrong elements. Taking them out now makes
        // the send atomic w.r.t. the queue — only a failure puts them back.
        let batch = Array(queue.prefix(MAX_BATCH))
        queue.removeFirst(batch.count)

        var events: [[String: Any]] = []
        for e in batch {
            var ev: [String: Any] = ["type": e.type, "target_type": e.targetType, "target_id": e.targetId]
            if let p = e.payload,
               let d = try? JSONSerialization.data(withJSONObject: p),
               d.count <= MAX_PAYLOAD_BYTES {
                ev["payload"] = p   // oversized payloads are dropped, event still sent
            }
            events.append(ev)
        }
        let body: [String: Any] = [
            "client_id": ShaftEventsConfig.clientId,
            "platform": ShaftEventsConfig.platform,
            "channel": ShaftEventsConfig.channel,
            "app_version": ShaftEventsConfig.appVersion,
            "events": events,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return   // unserializable — drop the drained batch, don't wedge the queue
        }

        do {
            try await post(path: "/api/v1/events/batch", body: bodyData)
        } catch {
            let retried = batch.compactMap { p -> Pending? in
                var q = p; q.retries += 1
                return q.retries <= MAX_RETRIES ? q : nil
            }
            queue.insert(contentsOf: retried, at: 0)   // requeue at head
        }
        if !queue.isEmpty { scheduleFlush() }
    }

    // MARK: transport / crypto

    private func post(path: String, body: Data) async throws {
        var req = URLRequest(url: ShaftEventsConfig.baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.signHex(body, secret: ShaftEventsConfig.hmacSecret), forHTTPHeaderField: "X-Shaft-Sign")
        req.httpBody = body
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ShaftApiError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    /// HMAC-SHA256 over the exact request-body bytes; key = secret's ASCII bytes
    /// verbatim (NOT hex-decoded). Lowercase hex. Matches Node crypto.createHmac.
    private static func signHex(_ data: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private func encode<T: Encodable>(_ v: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(v),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static let bindingCacheKey = "shaft_events_uid_binding_last"
}
