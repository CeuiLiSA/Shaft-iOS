import Foundation

/// Server → client WS frames per `docs/ws-chat-integration.md` §3.2 (1:1 with
/// Android `ceui.pixiv.chat.api.ChatFrame`).
///
/// Six real kinds plus an ``unknown`` fallback for "valid envelope, unrecognised
/// kind" so the decoder never silently drops a frame or kills the stream.
///
/// **Identity model**: uid (pixiv user id) is the only identity — the legacy
/// 64-hex `client_id` is gone, the server routes by uid.
enum ChatFrame: Sendable, Equatable {

    /// `{"kind":"hello","uid","display_name","server_ts","global_send_enabled"?}`
    /// — always the first frame after a successful handshake. `onOpen` is *not*
    /// "connected"; this frame is. `globalSendEnabled` is `nil` only on older
    /// servers that omit the flag (treat as enabled).
    case hello(uid: Int64, displayName: String?, serverTs: Int64, globalSendEnabled: Bool?)

    /// `{"kind":"msg","room","uid","display_name","client_msg_id","text","illust_id"?,"ts"}`
    ///
    /// `room` is server-assigned: `"global"` for public broadcasts, or the
    /// `pairRoomId` decimal string for 1v1. `clientMsgId` is the dedup anchor
    /// (doc §4) — broadcasts are NOT idempotent even though the DB write is, so
    /// every store write must be an upsert keyed by it.
    case msg(ChatMsgFrame)

    /// `{"kind":"err","code","client_msg_id"?,"message"?}` — protocol /
    /// rate-limit / validation / policy error. **The connection stays open.**
    ///
    /// `clientMsgId` is echoed whenever the offending inbound frame carried one,
    /// so the failure can be anchored to that exact optimistic row. Frame-level
    /// errors that happen before per-msg parsing (`bad_json`, `bad_envelope`,
    /// `frame_too_large`) leave it `nil` — callers fall back to a "most recent
    /// Sending" heuristic. `message` is an optional server-supplied, directly
    /// displayable string; prefer it over the local code→text map so the server
    /// can reword without a client release. Never show the raw code.
    case err(code: String, clientMsgId: String?, message: String?)

    /// `{"kind":"pong","server_ts"}` — reply to a client app-level `ping`.
    case pong(serverTs: Int64)

    /// `{"kind":"typing","room","uid","display_name","state","ts"}` — DM-only
    /// (global is rejected server-side as `typing_forbidden_for_global`).
    /// Fire-and-forget: no id, no persistence, and the sender does NOT get an
    /// echo of its own typing. `state` is `"start"` (default) or `"stop"`; the
    /// ~5s expiry on `"start"` is a *client* convention — the server never sends
    /// an "expired" frame.
    case typing(room: String, uid: Int64, displayName: String?, state: String, ts: Int64)

    /// `{"kind":"global_send_state","enabled","server_ts"}` — pushed to every
    /// connection when an admin toggles the public-room send switch, so a client
    /// already sitting in the global room updates live instead of waiting for
    /// the next handshake's ``hello``.
    case globalSendState(enabled: Bool)

    /// Valid JSON but an unknown / malformed envelope. Logged, dead-lettered,
    /// stream stays alive.
    case unknown(raw: String)
}

/// Payload of a ``ChatFrame/msg(_:)``. A struct rather than a tuple so the
/// message list can hold it, diff it, and pass it around by value.
struct ChatMsgFrame: Sendable, Equatable {
    let room: String
    let uid: Int64
    let displayName: String?
    let clientMsgId: String?
    let text: String?
    let illustId: Int64?
    let ts: Int64
    var stickerId: String? = nil
}

// MARK: - Decoding

enum ChatFrameDecoder {

    /// Never throws: any decode-time problem (malformed JSON, wrong types, a
    /// missing required field) is downgraded to ``ChatFrame/unknown(raw:)`` and
    /// logged, per doc §9.1 "解析失败 → dead-letter, 不挂掉流".
    static func decode(_ raw: String) -> ChatFrame {
        guard let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            ChatLog.warn("frame decode failed, dead-lettered: \(raw.prefix(120))")
            return .unknown(raw: raw)
        }
        guard let kind = obj.chatString("kind"), !kind.isEmpty else {
            ChatLog.warn("envelope missing 'kind': \(raw.prefix(120))")
            return .unknown(raw: raw)
        }

        switch kind {
        case "hello":
            guard let uid = obj.chatInt64("uid") else {
                ChatLog.warn("hello frame missing uid: \(raw.prefix(120))")
                return .unknown(raw: raw)
            }
            return .hello(
                uid: uid,
                displayName: obj.chatString("display_name"),
                serverTs: obj.chatInt64("server_ts") ?? 0,
                globalSendEnabled: obj.chatBool("global_send_enabled")
            )

        case "msg":
            // Required: ts, uid, room. Missing any → can't dedup / route → dead letter.
            guard let ts = obj.chatInt64("ts"),
                  let uid = obj.chatInt64("uid"),
                  let room = obj.chatString("room") else {
                ChatLog.warn("msg frame missing ts/uid/room: \(raw.prefix(120))")
                return .unknown(raw: raw)
            }
            return .msg(ChatMsgFrame(
                room: room,
                uid: uid,
                displayName: obj.chatString("display_name"),
                clientMsgId: obj.chatString("client_msg_id"),
                text: obj.chatString("text"),
                illustId: obj.chatInt64("illust_id"),
                ts: ts,
                stickerId: obj.chatString("sticker_id")
            ))

        case "err":
            return .err(
                code: obj.chatString("code") ?? "unknown",
                clientMsgId: obj.chatString("client_msg_id"),
                message: obj.chatString("message")
            )

        case "pong":
            return .pong(serverTs: obj.chatInt64("server_ts") ?? 0)

        case "typing":
            // `ts` is informational (the receiver times out on its own wall
            // clock) and `state` defaults to "start", mirroring the server.
            guard let uid = obj.chatInt64("uid"), let room = obj.chatString("room") else {
                ChatLog.warn("typing frame missing uid/room: \(raw.prefix(120))")
                return .unknown(raw: raw)
            }
            return .typing(
                room: room,
                uid: uid,
                displayName: obj.chatString("display_name"),
                state: obj.chatString("state") ?? "start",
                ts: obj.chatInt64("ts") ?? 0
            )

        case "global_send_state":
            guard let enabled = obj.chatBool("enabled") else {
                ChatLog.warn("global_send_state missing 'enabled': \(raw.prefix(120))")
                return .unknown(raw: raw)
            }
            return .globalSendState(enabled: enabled)

        default:
            ChatLog.debug("unknown kind=\(kind) — ignored")
            return .unknown(raw: raw)
        }
    }
}

/// Lenient scalar readers matching Kotlin's `asStringOrNull` / `asLongOrNull` /
/// `asBooleanOrNull` — the server is consistent today, but a number arriving as
/// a string (or vice versa) must not dead-letter an otherwise good frame.
private extension [String: Any] {
    func chatString(_ key: String) -> String? {
        switch self[key] {
        case let s as String: return s
        case let n as NSNumber:
            // NSNumber covers JSON bools too; render them the JSON way.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        default: return nil
        }
    }

    func chatInt64(_ key: String) -> Int64? {
        switch self[key] {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.int64Value
        case let s as String: return Int64(s)
        default: return nil
        }
    }

    func chatBool(_ key: String) -> Bool? {
        switch self[key] {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            return n.intValue != 0
        case let s as String:
            if s == "true" { return true }
            if s == "false" { return false }
            return nil
        default: return nil
        }
    }
}

// MARK: - Client → server encoding

enum ChatFrameEncoder {

    /// `{"kind":"msg","room":"global","client_msg_id":…,"text":…,"illust_id":…?}`
    static func msgGlobal(clientMsgId: String, text: String, illustId: Int64? = nil, stickerId: String? = nil) -> String {
        var body: [String: Any] = ["kind": "msg", "room": "global",
                                   "client_msg_id": clientMsgId, "text": text]
        if let illustId { body["illust_id"] = illustId }
        if let stickerId { body["sticker_id"] = stickerId }
        return encode(body)
    }

    /// `{"kind":"msg","to_uid":<long>,"client_msg_id":…,"text":…,"illust_id":…?}`
    ///
    /// Doc §5: never send a numeric `room` from the client — the server derives
    /// it from `(authed_self_uid, to_uid)`, which is what makes the 1v1 ACL hold.
    /// A raw numeric `room` comes back as `err.room_forbidden`.
    ///
    /// `to_uid` goes out as a JSON number literal (never a quoted or
    /// space-padded string) — the server does no coercion and answers
    /// `bad_to_uid` for anything else.
    static func msg1v1(toUid: Int64, clientMsgId: String, text: String, illustId: Int64? = nil, stickerId: String? = nil) -> String {
        var body: [String: Any] = ["kind": "msg", "to_uid": toUid,
                                   "client_msg_id": clientMsgId, "text": text]
        if let illustId { body["illust_id"] = illustId }
        if let stickerId { body["sticker_id"] = stickerId }
        return encode(body)
    }

    /// `{"kind":"typing","to_uid":<long>,"state":"start"|"stop"}` — DM-only.
    /// Pass `state: nil` to let the server default to `"start"`. Any other
    /// value is a programmer error and is dropped to `"start"` rather than put
    /// on the wire to bounce back as `bad_state`.
    static func typing1v1(toUid: Int64, state: String? = nil) -> String {
        var body: [String: Any] = ["kind": "typing", "to_uid": toUid]
        if let state {
            assert(state == "start" || state == "stop", "typing state must be \"start\" / \"stop\", got: \(state)")
            body["state"] = (state == "stop") ? "stop" : "start"
        }
        return encode(body)
    }

    private static func encode(_ body: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
