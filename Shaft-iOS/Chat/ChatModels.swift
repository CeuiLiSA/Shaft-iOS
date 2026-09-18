import Foundation
import os

/// One log handle for the whole chat stack. Android splits this across Timber
/// tags (`Chat-Gateway` / `Chat-Frame` / `Chat-Raw` / `Chat-Heartbeat`); on iOS
/// one subsystem with a `category` per call site is the equivalent, and it keeps
/// the frame decoder free of a logger dependency.
enum ChatLog {
    private static let log = Logger(subsystem: "com.shaft.ShaftiOS", category: "chat")
    static func debug(_ m: @autoclosure () -> String) { let s = m(); log.debug("\(s, privacy: .public)") }
    static func info(_ m: @autoclosure () -> String) { let s = m(); log.info("\(s, privacy: .public)") }
    static func warn(_ m: @autoclosure () -> String) { let s = m(); log.warning("\(s, privacy: .public)") }
}

// MARK: - Local message model

/// Delivery state of a locally-known message. 1:1 with Android
/// `ceui.pixiv.chat.data.SendState`.
enum ChatSendState: String, Codable, Sendable {
    /// Optimistically written on send; waiting for the WS broadcast echo.
    case sending
    /// Confirmed — either the echo came back, or the row came from `/history`.
    case delivered
    /// The WS refused the frame, or the server answered `err` for this cmid.
    case failed
}

/// A chat message as the UI sees it — 1:1 with Android `ChatMessageEntity`.
///
/// ``localKey`` is the primary key and the whole dedup story (doc §4 / §9.2):
/// `client_msg_id` when present, else `"server:<id>"` for rows the server
/// inserted directly before the column existed. **Every** write — optimistic
/// send, WS echo, `/history` backfill — is an upsert on this key, because the
/// server's broadcast fan-out is NOT idempotent even though its DB write is.
struct ChatMessage: Identifiable, Hashable, Codable, Sendable {
    /// `client_msg_id` ?? `"server:<serverId>"`.
    let localKey: String
    /// Server autoincrement id — present on `/history` rows, absent on WS
    /// broadcasts (the id isn't assigned until the async batch insert).
    var serverId: Int64?
    var clientMsgId: String?
    var uid: Int64
    var room: String
    var displayName: String?
    var text: String
    var illustId: Int64?
    var ts: Int64
    var state: ChatSendState
    var stickerId: String? = nil

    var id: String { localKey }

    /// Sent by the signed-in user → right-aligned bubble.
    func isMine(selfUid: Int64) -> Bool { uid == selfUid }

    /// Display name with the server's own fallback shape for an unnamed uid.
    var resolvedDisplayName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return "匿名_\(uid)"
    }

    static func fromHistory(_ item: ChatHistoryItem, room: String) -> ChatMessage {
        ChatMessage(
            localKey: item.client_msg_id ?? "server:\(item.id)",
            serverId: item.id,
            clientMsgId: item.client_msg_id,
            uid: item.uid,
            room: room,
            displayName: item.display_name,
            text: item.text ?? "",
            illustId: item.illust_id,
            ts: item.ts,
            state: .delivered,
            stickerId: item.sticker_id
        )
    }

    /// A WS broadcast. Returns `nil` when the frame carries neither a
    /// `client_msg_id` nor anything else to key on — such a row can't be
    /// deduped, so storing it would risk endless duplicates.
    static func fromBroadcast(_ frame: ChatMsgFrame) -> ChatMessage? {
        guard let cmid = frame.clientMsgId, !cmid.isEmpty else {
            ChatLog.warn("broadcast without client_msg_id — dropped (room=\(frame.room) uid=\(frame.uid))")
            return nil
        }
        return ChatMessage(
            localKey: cmid,
            serverId: nil,          // broadcasts don't carry the DB id
            clientMsgId: cmid,
            uid: frame.uid,
            room: frame.room,
            displayName: frame.displayName,
            text: frame.text ?? "",
            illustId: frame.illustId,
            ts: frame.ts,
            state: .delivered,
            stickerId: frame.stickerId
        )
    }
}

// MARK: - Conversation-list row

/// Display-ready conversation row — 1:1 with Android `ChatRoomEntry`.
/// Source-agnostic: filled either from the API `ConversationItem` projection
/// (production) or from local previews (offline fallback).
struct ChatRoomEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case global, oneOnOne }

    let room: String
    let kind: Kind
    var title: String
    var previewText: String
    /// Last message's sender uid — `nil` when the room has no message yet.
    var previewSenderUid: Int64?
    /// Last message's server-resolved `display_name`, for the "X: 内容" prefix.
    var previewSenderDisplayName: String?
    /// Server autoincrement id of the last message. Needed to POST `/read`.
    var lastMessageId: Int64?
    var lastTs: Int64
    /// 1v1 rooms only — `nil` for global. Used to open the thread with the right peer.
    var peerUid: Int64?
    /// Server-authoritative unread count for DMs; 0 for global (the server
    /// returns null there and we coerce).
    var unreadCount: Int = 0
    /// Peer's pixiv profile-image URL, resolved lazily after a `userDetail`
    /// lookup; always `nil` for the global row (no single peer).
    var avatarUrl: String?

    var id: String { room }
}

// MARK: - Local store

/// Local-first message store — the iOS stand-in for Android's Room-backed
/// `RoomChatMessageStore`. Same contract, same invariants:
///
/// * primary key is ``ChatMessage/localKey``; **all** writes are upserts
/// * rows are kept per room, ordered by `ts` ascending (oldest → newest)
/// * an app-scoped persister (see ``ShaftChatGateway``) writes every inbound
///   broadcast whether or not a chat screen is open, so a DM that arrives while
///   the user is on the home feed is already there when they open the thread
///
/// Backing storage is a single JSON file in Application Support rather than
/// SQLite: the server prunes at 30 days, one device's history is small, and this
/// avoids adding a schema/migration surface for a feature whose source of truth
/// is `/history` anyway. Writes are coalesced (0.5 s) so a burst of broadcasts
/// costs one disk hit.
actor ChatMessageStore {
    static let shared = ChatMessageStore()

    /// room → localKey → message.
    private var rooms: [String: [String: ChatMessage]] = [:]
    private var saveTask: Task<Void, Never>?
    private var loaded = false

    /// Continuations of every live `observe(room:)` stream, so a write from any
    /// source (send / echo / history) pushes to every open screen.
    private var observers: [UUID: (room: String, limit: Int, yield: ([ChatMessage]) -> Void)] = [:]

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("shaft-chat-messages.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [String: ChatMessage]].self, from: data) else { return }
        rooms = decoded
        ChatLog.info("store loaded: \(decoded.count) room(s), \(decoded.values.reduce(0) { $0 + $1.count }) message(s)")
    }

    /// Upsert by `localKey`. Duplicate broadcasts collapse onto the existing
    /// row; a `.delivered` echo overwrites the optimistic `.sending` row.
    ///
    /// One exception to blind overwrite: a `serverId` we already know is never
    /// cleared by a later WS broadcast (which carries none), so the `/read`
    /// cursor the conversation list needs survives.
    func upsert(_ messages: [ChatMessage]) {
        guard !messages.isEmpty else { return }
        loadIfNeeded()
        for var m in messages {
            var bucket = rooms[m.room] ?? [:]
            if let existing = bucket[m.localKey], m.serverId == nil {
                m.serverId = existing.serverId
            }
            bucket[m.localKey] = m
            rooms[m.room] = bucket
        }
        let touched = Set(messages.map(\.room))
        for room in touched { notify(room) }
        scheduleSave()
    }

    /// Flip one row's state — used for "WS refused the frame" and for an `err`
    /// frame echoing a `client_msg_id`. No-op when the key is unknown.
    func markState(room: String, localKey: String, state: ChatSendState) {
        loadIfNeeded()
        guard var bucket = rooms[room], var row = bucket[localKey] else { return }
        row.state = state
        bucket[localKey] = row
        rooms[room] = bucket
        notify(room)
        scheduleSave()
    }

    /// Most recent `.sending` row in a room — the fallback anchor for a
    /// frame-level `err` that carries no `client_msg_id` (doc §12).
    func latestSendingKey(room: String) -> String? {
        loadIfNeeded()
        return rooms[room]?.values.filter { $0.state == .sending }
            .max(by: { $0.ts < $1.ts })?.localKey
    }

    func delete(room: String, localKey: String) {
        loadIfNeeded()
        rooms[room]?.removeValue(forKey: localKey)
        notify(room)
        scheduleSave()
    }

    /// Newest `limit` rows of a room, returned oldest → newest (list order).
    func snapshot(room: String, limit: Int) -> [ChatMessage] {
        loadIfNeeded()
        let all = (rooms[room] ?? [:]).values.sorted { $0.ts < $1.ts }
        return all.count <= limit ? all : Array(all.suffix(limit))
    }

    func count(room: String) -> Int {
        loadIfNeeded()
        return rooms[room]?.count ?? 0
    }

    /// Live window over one room. Emits immediately, then on every write.
    /// Mirrors Android's `store.observe(room, limit)` Room Flow.
    ///
    /// Registration is **synchronous**, inside the actor. The earlier version
    /// registered from a detached `Task`, which opened a window where a stream
    /// cancelled right after creation ran its `onTermination` (removing an id
    /// that wasn't there yet) *before* the registration landed — leaving a dead
    /// observer in the dictionary forever. The chat screen re-subscribes on
    /// every send and every inbound broadcast, so a burst of messages leaked one
    /// entry per race, and thereafter every write walked them all.
    func observe(room: String, limit: Int) -> AsyncStream<[ChatMessage]> {
        loadIfNeeded()
        let (stream, continuation) = AsyncStream<[ChatMessage]>.makeStream()
        let id = UUID()
        observers[id] = (room, limit, { continuation.yield($0) })
        continuation.yield(snapshotSync(room: room, limit: limit))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func snapshotSync(room: String, limit: Int) -> [ChatMessage] {
        let all = (rooms[room] ?? [:]).values.sorted { $0.ts < $1.ts }
        return all.count <= limit ? all : Array(all.suffix(limit))
    }

    private func notify(_ room: String) {
        for (_, o) in observers where o.room == room {
            o.yield(snapshotSync(room: room, limit: o.limit))
        }
    }

    /// Coalesce a burst of writes into one disk hit.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self.write()
        }
    }

    /// Reads `rooms` at write time (not at schedule time) so the coalesced
    /// write always persists the newest state, not the state that triggered it.
    private func write() {
        guard let data = try? JSONEncoder().encode(rooms) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
