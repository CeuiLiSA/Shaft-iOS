import Foundation
import CryptoKit

// MARK: - Wire DTOs (1:1 with the server, see docs/ws-chat-integration.md §8)

struct ChatHistoryResponse: Decodable, Sendable {
    let room: String
    let limit: Int
    let items: [ChatHistoryItem]
}

/// One `/chat/history` row. `id` is the server autoincrement (history rows have
/// it, WS broadcasts don't). `client_msg_id` is the dedup anchor; server-direct
/// inserts predating the column carry `null`, in which case the local key falls
/// back to `"server:<id>"`.
struct ChatHistoryItem: Decodable, Sendable {
    let id: Int64
    let uid: Int64
    let client_msg_id: String?
    let display_name: String?
    let text: String?
    let illust_id: Int64?
    let sticker_id: String?
    let ts: Int64
}

struct ChatProfileResponse: Decodable, Sendable {
    let uid: Int64
    let display_name: String?
}

struct SetProfileResponse: Decodable, Sendable {
    let ok: Bool
    let display_name: String?
}

struct ChatStatsResponse: Decodable, Sendable {
    let room: String
    let online: Int
    let total_connections: Int?
    let total_messages: Int64
}

struct ConversationListResponse: Decodable, Sendable {
    let uid: Int64
    let limit: Int
    let items: [ConversationItem]
    let next_cursor: String?
}

/// One conversation. Nullability follows the server contract:
/// * `peer_uid` / `peer_display_name` — dm-only, and also null when the server's
///   `peerFromRoomId` couldn't reverse-derive the uid (row kept, UI falls back
///   to the room id).
/// * `unread_count` / `last_read_message_id` — dm-only; null for global, which
///   the server doesn't authoritatively track.
/// * `last_message` — null only when the room has literally no messages yet.
struct ConversationItem: Decodable, Sendable {
    let room_id: String
    /// `"global"` | `"dm"` — a future `"group"` renders as a 1v1 placeholder.
    let kind: String
    let peer_uid: Int64?
    let peer_display_name: String?
    let last_message: ConversationLastMessage?
    let unread_count: Int?
    let last_read_message_id: Int64?
    let muted: Bool?
    let pinned: Bool?
}

/// Last-message snapshot. `text` is **server-truncated to ~100 chars** for list
/// rendering — the full text comes from `/history` when the thread is opened.
struct ConversationLastMessage: Decodable, Sendable {
    let id: Int64
    let uid: Int64?
    let display_name: String?
    let text: String?
    let ts: Int64
}

struct MarkReadResponse: Decodable, Sendable {
    let ok: Bool
    let room: String
    let last_read_message_id: Int64
}

// MARK: - Client

enum ChatAPIError: Error {
    case notLoggedIn
    case hmacDisabled
    case http(Int, String?)
    case badURL
    case decode
}

/// HTTP companion to the chat WebSocket — 1:1 with Android `ShaftChatApi` +
/// `ChatConversationsRepository`. Shares `ShaftEventsConfig.baseURL` and
/// `hmacSecret` with the events stack: the server hosts both under `/api/v1/`
/// on one port.
///
/// Two auth classes:
/// * **read** (`/history`, `/profile?uid=`, `/stats`) — no auth at all
/// * **write / owner-scoped** (`/profile` POST, `/conversations`,
///   `/conversations/{room}/read`) — `X-Shaft-Sign: HMAC_SHA256(secret_ascii,
///   "<uid>|<ts>")`, hex lowercase
///
/// ⚠️ `ts` canonicalisation trap (doc §2.1 #3): the **decimal string** goes into
/// both the HMAC payload and the request. Compute it once and reuse — a
/// `Int64 → "1.7e12"` drift in either spot is a silent 401 `bad_sig`.
actor ShaftChatAPI {
    static let shared = ShaftChatAPI()

    private let base = ShaftEventsConfig.baseURL
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    /// Sentinel the conversation list swaps for the localized "公屏闲聊" string —
    /// 1:1 with `ChatConversationsRepository.CONVENTION_GLOBAL_TITLE`.
    static let conventionGlobalTitle = "__global__"

    // MARK: Read endpoints (no auth)

    /// Pull history. `before` is the `id` of the **oldest** row of the previous
    /// page (= `items[0].id`); omit for the most recent page. Empty `items`
    /// means the top has been reached. `limit` caps server-side at 200.
    ///
    /// `room` is `"global"` or a decimal uint64 1v1 thread id from
    /// ``ChatThreadId/oneOnOneThreadId(_:_:)``.
    func history(room: String = ChatThreadId.roomGlobal,
                 limit: Int = 50,
                 before: Int64? = nil) async throws -> ChatHistoryResponse {
        var q = [URLQueryItem(name: "room", value: room),
                 URLQueryItem(name: "limit", value: String(limit))]
        if let before { q.append(URLQueryItem(name: "before", value: String(before))) }
        return try await get(path: "/api/v1/chat/history", query: q)
    }

    /// Public lookup of any uid's current display name — used to back-fill
    /// history rows whose uid the client has never seen.
    func profile(uid: Int64) async throws -> ChatProfileResponse {
        try await get(path: "/api/v1/chat/profile", query: [URLQueryItem(name: "uid", value: String(uid))])
    }

    /// Debug / observability — online count + total message count.
    func stats(room: String = ChatThreadId.roomGlobal) async throws -> ChatStatsResponse {
        try await get(path: "/api/v1/chat/stats", query: [URLQueryItem(name: "room", value: room)])
    }

    // MARK: Signed endpoints

    /// Rename self. `display_name` must be 1–32 UTF-16 units, ≤ 96 UTF-8 bytes,
    /// no ASCII control characters. The server trims leading/trailing whitespace
    /// before validating, so the client can afford to be permissive.
    ///
    /// Takes effect immediately — the server resolves `display_name` per message
    /// rather than caching it at handshake, so no reconnect is needed.
    @discardableResult
    func setProfile(uid: Int64, displayName: String) async throws -> SetProfileResponse {
        let ts = Self.nowMillisString()
        let sig = try Self.sign(uid: uid, ts: ts)
        // `ts` here is a JSON *number* (matching Android's `SetProfileRequest.ts: Long`)
        // while the signed payload uses its decimal string — same digits either way.
        let body: [String: Any] = ["uid": uid, "ts": Int64(ts) ?? 0, "display_name": displayName]
        return try await post(path: "/api/v1/chat/profile", sig: sig, body: body)
    }

    /// One page of conversations. Cursor pagination: `cursor == nil` asks for
    /// the first page (which always pins `global` first plus the first DM
    /// batch); pass the previous response's `next_cursor` for later pages (DMs
    /// only — global doesn't repeat). `next_cursor == nil` ⇔ end of list.
    func listConversations(uid: Int64, cursor: String?, limit: Int = 50) async throws -> ConversationListResponse {
        guard uid > 0 else { throw ChatAPIError.notLoggedIn }
        let ts = Self.nowMillisString()
        let sig = try Self.sign(uid: uid, ts: ts)
        var q = [URLQueryItem(name: "uid", value: String(uid)),
                 URLQueryItem(name: "ts", value: ts),
                 URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
        let t0 = Date()
        let resp: ConversationListResponse = try await get(
            path: "/api/v1/chat/conversations", query: q, sig: sig
        )
        ChatLog.info("← /chat/conversations \(resp.items.count) items in \(Int(Date().timeIntervalSince(t0) * 1000))ms next=\(resp.next_cursor ?? "(end)")")
        return resp
    }

    /// Mark `room` read up through `lastReadMessageId`. The server recomputes
    /// the unread count from `chat_messages` rather than trusting the client's
    /// view, so a stale client can't zero unreads it hasn't actually seen.
    ///
    /// Silently no-ops for `global` — the server answers 400
    /// `read_not_supported_for_global` there.
    @discardableResult
    func markRead(uid: Int64, room: String, lastReadMessageId: Int64) async throws -> MarkReadResponse? {
        guard room != ChatThreadId.roomGlobal else {
            ChatLog.debug("markRead: skipped for global room")
            return nil
        }
        guard uid > 0 else { throw ChatAPIError.notLoggedIn }
        let ts = Self.nowMillisString()
        let sig = try Self.sign(uid: uid, ts: ts)
        let body: [String: Any] = ["uid": uid, "ts": ts, "last_read_message_id": lastReadMessageId]
        // `room` is a uint64 decimal string — safe in a path segment as-is, but
        // percent-encode anyway so a future non-numeric room kind can't break the URL.
        let encoded = room.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? room
        return try await post(path: "/api/v1/chat/conversations/\(encoded)/read", sig: sig, body: body)
    }

    // MARK: Projection

    /// `ConversationItem` → ``ChatRoomEntry`` — 1:1 with Android
    /// `ChatConversationsRepository.toEntry()`, including the DM title fallback
    /// chain: server `peer_display_name` → `匿名_<peer_uid>` → raw room id.
    nonisolated static func entry(from item: ConversationItem) -> ChatRoomEntry {
        let kind: ChatRoomEntry.Kind = (item.kind == "global") ? .global : .oneOnOne
        let title: String
        switch kind {
        case .global:
            title = conventionGlobalTitle   // resolved to a localized string by the view
        case .oneOnOne:
            title = item.peer_display_name
                ?? item.peer_uid.map { "匿名_\($0)" }
                ?? item.room_id
        }
        return ChatRoomEntry(
            room: item.room_id,
            kind: kind,
            title: title,
            previewText: item.last_message?.text ?? "",
            previewSenderUid: item.last_message?.uid,
            previewSenderDisplayName: item.last_message?.display_name,
            lastMessageId: item.last_message?.id,
            lastTs: item.last_message?.ts ?? 0,
            peerUid: item.peer_uid,
            unreadCount: item.unread_count ?? 0,
            avatarUrl: nil
        )
    }

    // MARK: Transport

    private func get<T: Decodable>(path: String, query: [URLQueryItem], sig: String? = nil) async throws -> T {
        guard var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw ChatAPIError.badURL
        }
        comps.queryItems = query
        guard let url = comps.url else { throw ChatAPIError.badURL }
        var req = URLRequest(url: url)
        if let sig { req.setValue(sig, forHTTPHeaderField: "X-Shaft-Sign") }
        return try await send(req)
    }

    private func post<T: Decodable>(path: String, sig: String, body: [String: Any]) async throws -> T {
        guard let url = URL(string: path, relativeTo: base) else { throw ChatAPIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(sig, forHTTPHeaderField: "X-Shaft-Sign")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let body = String(data: data, encoding: .utf8)
            ChatLog.warn("HTTP \(code) \(req.url?.path ?? "?") — \(body?.prefix(200) ?? "")")
            throw ChatAPIError.http(code, body)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            ChatLog.warn("decode failed for \(req.url?.path ?? "?"): \(error)")
            throw ChatAPIError.decode
        }
    }

    // MARK: HMAC

    /// `HMAC_SHA256(secret_ascii, "<uid>|<ts>")`, hex lowercase — the same
    /// envelope the WS handshake signs. The key is the secret string's ASCII
    /// bytes verbatim, **not** hex-decoded, matching Node's
    /// `crypto.createHmac('sha256', secret)`.
    nonisolated static func sign(uid: Int64, ts: String) throws -> String {
        guard ShaftEventsConfig.hmacEnabled else { throw ChatAPIError.hmacDisabled }
        let key = SymmetricKey(data: Data(ShaftEventsConfig.hmacSecret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(uid)|\(ts)".utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Strictly 13 decimal digits — no `.0`, no scientific notation, no padding.
    /// The server HMACs the query string *verbatim*.
    nonisolated static func nowMillisString() -> String {
        String(Int64(Date().timeIntervalSince1970 * 1000))
    }
}
