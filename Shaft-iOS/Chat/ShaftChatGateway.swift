import Foundation
import Observation
import UIKit

/// Connection state — 1:1 with Android `WebSocketState`.
///
/// ⚠️ `.connected` means **the `hello` frame arrived**, not that the socket
/// opened. `didOpenWithProtocol` fires before the server has authenticated
/// anything useful to show; doc §1 makes `hello` the接通 signal.
enum ChatConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected(displayName: String?)
    case reconnecting(attempt: Int, delay: TimeInterval)
    case disconnected
}

/// App-scoped gateway for the shaft-api-v2 chat WebSocket — the iOS counterpart
/// of Android's `ShaftChatGateway` + `WebSocketManager` + `RobustWebSocketClient`
/// + `ShaftHmacAuthProvider`, collapsed into one type because
/// `URLSessionWebSocketTask` already owns the transport-level retry surface that
/// OkHttp made the Android stack split up.
///
/// ## Lifecycle
///
/// One socket per app process. ``start(uid:)`` is called once the pixiv uid is
/// known and again on login/logout changes; the connection then stays up for the
/// process lifetime, because doc §12 requires that a DM arriving while the user
/// is anywhere in the app still lands in the local store. `stop()` is only for
/// logout.
///
/// ## What arrives without asking
///
/// There is **no sub/unsub**: the server routes by uid, so a connected client
/// automatically receives every `room:"global"` broadcast (subject to the `&v=`
/// version gate) and every 1v1 message addressed to it, open thread or not.
///
/// ## Reconnect
///
/// Exponential backoff 1s → 30s with ±20 % jitter, reset on `hello`. Two cases
/// deliberately do **not** retry (doc §7.3):
/// * handshake `401` — `bad_sig` / `bad_ts` / `ts_skew` / `bad_uid` are all
///   unfixable by retrying the same credentials → ``fatalAuth``
/// * close `1008 "replaced"` — the same uid connected elsewhere and this was the
///   oldest of 5 connections. Retrying makes two devices kick each other
///   forever → ``replacedByOtherDevice``, and the user decides.
@MainActor
@Observable
final class ShaftChatGateway {
    static let shared = ShaftChatGateway()

    // MARK: Observable state

    private(set) var state: ChatConnectionState = .idle

    /// Display name the server greeted us with in `hello`. Note this is a
    /// snapshot from connect time: renaming takes effect immediately on the
    /// wire (the server resolves the name per message) but this field only
    /// refreshes on the next handshake.
    private(set) var selfDisplayName: String?

    /// Current public-room send switch — the single source of truth merged from
    /// `hello.global_send_enabled` (state at handshake) and live
    /// `global_send_state` pushes, in arrival order. Defaults to `true`, and an
    /// older server that omits the flag leaves it that way. The global room's
    /// composer reads this so a message that would be rejected is never
    /// optimistically appended in the first place. 1v1 ignores it.
    private(set) var globalSendEnabled = true

    /// Set once on a 401 handshake. The UI should say "check your clock / the
    /// key is misconfigured", not "network error".
    private(set) var fatalAuth = false

    /// Set on `onClose(1008, "replaced")` — another device took the connection.
    /// Cleared by ``reconnectNow()`` when the user asks to come back.
    private(set) var replacedByOtherDevice = false

    // MARK: Foreground-room bookkeeping

    /// The room the user is currently looking at (`"global"` or a 1v1 thread
    /// id), or `nil` when no chat screen is foreground. Maintained by the chat
    /// screens' own appear/disappear — the authoritative source, versus trying
    /// to reverse-engineer it from the navigation stack.
    private(set) var foregroundChatRoom: String?

    func enterChatRoom(_ room: String) { foregroundChatRoom = room }

    /// Guarded by `room` so an out-of-order appear/disappear across a room
    /// switch (the new screen's `onAppear` before the old one's `onDisappear`)
    /// can't wipe the new room.
    func exitChatRoom(_ room: String) {
        if foregroundChatRoom == room { foregroundChatRoom = nil }
    }

    // MARK: Frame fan-out

    /// Live subscribers. Every decoded frame goes to all of them — the always-on
    /// persister, the conversation list, and whichever thread is open all fan
    /// out from this one socket, exactly like Android's shared `incoming` flow.
    private var subscribers: [UUID: (ChatFrame) -> Void] = [:]

    /// Subscribe to every decoded inbound frame. The stream ends when the
    /// consuming task is cancelled.
    func frames() -> AsyncStream<ChatFrame> {
        AsyncStream { continuation in
            let id = UUID()
            subscribers[id] = { continuation.yield($0) }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.subscribers.removeValue(forKey: id) }
            }
        }
    }

    /// Convenience: only `msg` frames for one room.
    func messages(inRoom room: String) -> AsyncStream<ChatMsgFrame> {
        let upstream = frames()
        return AsyncStream { continuation in
            let task = Task {
                for await frame in upstream {
                    if case .msg(let m) = frame, m.room == room { continuation.yield(m) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Connection internals

    private var uid: Int64 = 0
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let delegate = WSDelegate()
    private var receiveLoop: Task<Void, Never>?
    private var pingTimer: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var attempt = 0
    private var stopped = true
    private var observersInstalled = false

    private init() {
        // Every callback is tagged with the task it came from and dropped unless
        // it is still the live one — see `isCurrent(_:)`.
        delegate.onOpen = { [weak self] task in
            Task { @MainActor in self?.handleOpen(task) }
        }
        delegate.onClose = { [weak self] task, code, reason in
            Task { @MainActor in self?.handleClose(task, code: code, reason: reason) }
        }
        delegate.onError = { [weak self] task, status in
            Task { @MainActor in self?.handleError(task, httpStatus: status) }
        }
    }

    /// Is this delegate callback about the socket we currently care about?
    ///
    /// `connect()` tears the previous socket down (`cancel(with: .goingAway)` +
    /// `invalidateAndCancel`) and immediately builds a new one. Measured against
    /// the live server, that teardown reports back as
    /// `didCloseWith(code: 1001)` — indistinguishable, without this check, from
    /// the server hanging up on us. It arrives *after* `task` already points at
    /// the replacement, and the old code answered it with `scheduleReconnect()`:
    /// a reconnect fired against a perfectly healthy socket, which replaced it,
    /// which closed it with 1001 again — a self-sustaining teardown loop that
    /// also knocked `state` off `.connected` and greyed out the send button
    /// mid-conversation. `closeSocket()` nils `task` before cancelling, so every
    /// callback from a socket we walked away from fails this check.
    private func isCurrent(_ candidate: URLSessionTask) -> Bool {
        guard let task else { return false }
        return candidate === (task as URLSessionTask)
    }

    // MARK: Public API

    /// Connect (or reconnect with a new identity). Idempotent for the same uid.
    ///
    /// A `uid <= 0` (not signed in) or an empty HMAC secret (fork build) parks
    /// the gateway at `.idle` instead of burning handshakes the server will
    /// reject — Android does the same by pinning its activation flow to `false`.
    func start(uid: Int64) {
        guard ShaftEventsConfig.hmacEnabled else {
            ChatLog.info("HMAC secret not configured — chat WS disabled for this build (fork mode)")
            state = .idle
            return
        }
        guard uid > 0 else {
            ChatLog.info("start: uid not available yet (not signed in) — staying idle")
            stop()
            return
        }
        if self.uid == uid, !stopped { return }
        self.uid = uid
        stopped = false
        fatalAuth = false
        replacedByOtherDevice = false
        attempt = 0
        installAppScopedWiring()
        connect()
    }

    /// Tear the socket down for good (logout). No reconnect will follow.
    func stop() {
        stopped = true
        reconnectTask?.cancel(); reconnectTask = nil
        closeSocket(code: .goingAway)
        state = .idle
    }

    /// User-driven "bring me back" after ``replacedByOtherDevice``, or a manual
    /// retry from an error state. Clears the backoff so it connects immediately.
    func reconnectNow() {
        guard uid > 0, ShaftEventsConfig.hmacEnabled else { return }
        replacedByOtherDevice = false
        fatalAuth = false
        stopped = false
        attempt = 0
        reconnectTask?.cancel(); reconnectTask = nil
        connect()
    }

    /// Dispatch a `msg` frame. `toUid == nil` → public global frame; non-nil →
    /// 1v1 frame addressed by `to_uid` (never a numeric `room`, doc §5).
    ///
    /// Returns `true` when the frame entered the socket's outgoing buffer —
    /// **not** an end-to-end ACK. The broadcast echo is the real ACK (doc §4.3);
    /// the caller correlates by `clientMsgId` and flips `.sending` → `.delivered`.
    ///
    /// The caller owns the 2048-UTF-16-unit cap and generates a fresh
    /// `clientMsgId` per call; this method only rejects empty text.
    @discardableResult
    func send(toUid: Int64?, clientMsgId: String, text: String, illustId: Int64? = nil, stickerId: String? = nil) -> Bool {
        guard !text.isEmpty else { return false }
        let frame = toUid == nil
            ? ChatFrameEncoder.msgGlobal(clientMsgId: clientMsgId, text: text, illustId: illustId, stickerId: stickerId)
            : ChatFrameEncoder.msg1v1(toUid: toUid!, clientMsgId: clientMsgId, text: text, illustId: illustId, stickerId: stickerId)
        let ok = rawSend(frame)
        if ok {
            ChatLog.info("⇡ msg sent to=\(toUid.map(String.init) ?? "global") cmid=\(clientMsgId) text=\(text.prefix(80))")
        } else {
            ChatLog.warn("⇡ send rejected — no active session")
        }
        return ok
    }

    /// Dispatch a `typing` frame. DM-only: the server rejects global typing with
    /// `typing_forbidden_for_global`, so there's no global overload.
    ///
    /// Fire-and-forget — if the socket is mid-reconnect the frame is dropped and
    /// the peer's own ~5s timeout clears the stale "正在输入…" indicator. Callers
    /// debounce `start` (~4s) to stay under the server's 10-frames/10s bucket.
    @discardableResult
    func sendTyping(toUid: Int64, state: String? = nil) -> Bool {
        let ok = rawSend(ChatFrameEncoder.typing1v1(toUid: toUid, state: state))
        ChatLog.debug("⇡ typing to=\(toUid) state=\(state ?? "start") accepted=\(ok)")
        return ok
    }

    private func rawSend(_ text: String) -> Bool {
        guard let task, case .connected = state else { return false }
        task.send(.string(text)) { error in
            if let error { ChatLog.warn("send failed: \(error.localizedDescription)") }
        }
        return true
    }

    // MARK: Connect / receive

    private func connect() {
        guard !stopped, !fatalAuth, !replacedByOtherDevice else { return }
        closeSocket(code: .goingAway)

        guard let url = handshakeURL() else {
            ChatLog.warn("connect: could not build handshake URL")
            scheduleReconnect()
            return
        }

        let cfg = URLSessionConfiguration.default
        // A WebSocket is idle by design — a read timeout would kill healthy
        // connections. Liveness rides on ping/pong instead (doc §6.2).
        cfg.timeoutIntervalForRequest = 60
        cfg.waitsForConnectivity = true
        let s = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        session = s
        let t = s.webSocketTask(with: url)
        task = t
        state = .connecting
        ChatLog.info("→ WS connect uid=\(self.uid) attempt=\(self.attempt)")
        t.resume()
        startReceiveLoop(t)
    }

    /// `ws://host/api/v1/chat/ws?uid=&ts=&sig=&v=` (doc §2.1).
    ///
    /// Three traps, all previously stepped on: the HMAC key is the secret's
    /// **ASCII bytes** (not hex-decoded); `ts` is the canonical 13-digit decimal
    /// string used verbatim in both the payload and the query; and `v` is
    /// deliberately **outside** the signature — it's a server-side feature gate
    /// for `room:"global"` delivery, not a credential, and keeping it unsigned
    /// is what lets a new client ship before the server learns to read it.
    ///
    /// Authentication is **query-string only** — headers and cookies are ignored.
    private func handshakeURL() -> URL? {
        let ts = ShaftChatAPI.nowMillisString()
        guard let sig = try? ShaftChatAPI.sign(uid: uid, ts: ts) else { return nil }
        var s = ShaftEventsConfig.baseURL.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasPrefix("https://") { s = "wss://" + s.dropFirst("https://".count) }
        else if s.hasPrefix("http://") { s = "ws://" + s.dropFirst("http://".count) }
        return URL(string: "\(s)/api/v1/chat/ws?uid=\(uid)&ts=\(ts)&sig=\(sig)&v=\(Self.clientVersionCode)")
    }

    /// The `&v=` the server version-gates global delivery on. iOS has no
    /// Android `versionCode`, so `CFBundleVersion` plays the part; it must stay
    /// at or above the server's `GLOBAL_MIN_VERSION` or this client silently
    /// receives no public-room broadcasts. Android's current code is 42100, so
    /// the fallback matches rather than under-reporting.
    private static var clientVersionCode: Int {
        let raw = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return raw.flatMap(Int.init) ?? 42100
    }

    private func startReceiveLoop(_ t: URLSessionWebSocketTask) {
        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await t.receive()
                    guard let self else { return }
                    switch message {
                    case .string(let text):
                        self.handleInbound(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleInbound(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    // The delegate's didCompleteWithError / didCloseWith already
                    // drives the state machine; just end the loop here.
                    return
                }
            }
        }
    }

    private func handleInbound(_ text: String) {
        ChatLog.debug("⇣ raw: \(text.prefix(200))")
        let frame = ChatFrameDecoder.decode(text)

        switch frame {
        case .hello(_, let displayName, _, let globalSend):
            // ★ hello — not `didOpen` — is what "connected" means.
            attempt = 0
            selfDisplayName = displayName
            if let globalSend { globalSendEnabled = globalSend }
            state = .connected(displayName: displayName)
            ChatLog.info("← hello uid=\(self.uid) name=\(displayName ?? "-") globalSend=\(globalSend.map(String.init) ?? "(unset)")")

        case .globalSendState(let enabled):
            globalSendEnabled = enabled

        default:
            break
        }

        for (_, yield) in subscribers { yield(frame) }
    }

    // MARK: Delegate callbacks

    private func handleOpen(_ task: URLSessionTask) {
        guard isCurrent(task) else { return }
        ChatLog.debug("WS socket opened — waiting for hello")
        startPingTimer()
    }

    private func handleClose(_ task: URLSessionTask,
                             code: URLSessionWebSocketTask.CloseCode,
                             reason: String?) {
        guard isCurrent(task) else {
            ChatLog.debug("← WS close from a superseded socket — ignored (code=\(code.rawValue))")
            return
        }
        ChatLog.info("← WS closed code=\(code.rawValue) reason=\(reason ?? "")")
        stopPingTimer()
        // Doc §1.1 / §7.3: 1008 "replaced" means the same uid connected
        // elsewhere and evicted this, the oldest, connection. Reconnecting here
        // would make the two devices kick each other forever.
        if code.rawValue == 1008, reason == "replaced" {
            replacedByOtherDevice = true
            state = .disconnected
            return
        }
        if code == .normalClosure, stopped {
            state = .idle
            return
        }
        scheduleReconnect()
    }

    private func handleError(_ task: URLSessionTask, httpStatus: Int?) {
        guard isCurrent(task) else {
            ChatLog.debug("← WS failure from a superseded socket — ignored")
            return
        }
        stopPingTimer()
        // 401 covers bad_sig / bad_ts / ts_skew / bad_uid — the server doesn't
        // distinguish them from this side, and none is fixable by retrying with
        // the same credentials, so this is terminal.
        if httpStatus == 401 {
            ChatLog.warn("⚠ auth fatal — 401 on WS handshake (bad_sig / ts_skew / bad_uid)")
            fatalAuth = true
            state = .disconnected
            return
        }
        scheduleReconnect()
    }

    // MARK: Reconnect

    /// Doc §7.1: 1s / 2s / 4s / 8s / 16–30s, each ±20 % jitter. The counter
    /// resets on `hello`, not on socket-open.
    private func scheduleReconnect() {
        guard !stopped, !fatalAuth, !replacedByOtherDevice else { return }
        guard reconnectTask == nil else { return }
        attempt += 1
        let base = min(pow(2.0, Double(attempt - 1)), 30.0)
        let jitter = Double.random(in: 0.8...1.2)
        let delay = min(base * jitter, 30.0)
        state = .reconnecting(attempt: attempt, delay: delay)
        ChatLog.info("↻ reconnect #\(self.attempt) in \(String(format: "%.1f", delay))s")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.reconnectTask = nil
                self.connect()
            }
        }
    }

    private func closeSocket(code: URLSessionWebSocketTask.CloseCode) {
        receiveLoop?.cancel(); receiveLoop = nil
        stopPingTimer()
        task?.cancel(with: code, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: Heartbeat

    /// 30s to match the server's own interval (doc §6). Any inbound traffic —
    /// including the pong — resets the server's liveness timer, so an idle
    /// connection stays alive on ping/pong alone.
    private func startPingTimer() {
        stopPingTimer()
        pingTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                guard let t = await MainActor.run(body: { self?.task }) else { return }
                t.sendPing { error in
                    if let error { ChatLog.warn("ping failed: \(error.localizedDescription)") }
                }
            }
        }
    }

    private func stopPingTimer() { pingTimer?.cancel(); pingTimer = nil }

    // MARK: Always-on wiring

    /// Doc §0 ("自动接收…无论自己有没有打开那个聊天") requires the local store to
    /// mirror **every** message the socket receives, not just the ones that
    /// arrive while a chat screen happens to be open. This subscriber runs for
    /// the process lifetime, so a DM that lands while the user is on the home
    /// feed is already in the store when they later open the thread.
    /// Both of these are process-scoped and must be installed exactly once.
    ///
    /// `start(uid:)` runs again on every sign-in, including a sign-out →
    /// sign-in round trip with the *same* uid (which clears `stopped` and so
    /// gets past the early return). The notification observer used to be
    /// registered outside this guard, so each such round trip added another
    /// `didBecomeActive` handler — and every foreground after N cycles fired N
    /// `connect()` calls back to back, burning the server's 200-upgrades/min/IP
    /// budget and evicting the user's other devices via the 5-conns-per-uid cap.
    private func installAppScopedWiring() {
        guard !observersInstalled else { return }
        observersInstalled = true
        installAppLifecycleObservers()
        installAlwaysOnPersister()
    }

    private func installAlwaysOnPersister() {
        let stream = frames()
        Task {
            for await frame in stream {
                guard case .msg(let m) = frame, let row = ChatMessage.fromBroadcast(m) else { continue }
                await ChatMessageStore.shared.upsert([row])
                ChatLog.debug("⇣ persisted cmid=\(row.localKey) room=\(row.room) uid=\(row.uid)")
            }
        }
    }

    /// Doc §7.2: coming back to the foreground with a dead socket reconnects
    /// immediately rather than waiting out the backoff.
    private func installAppLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.stopped, !self.fatalAuth, !self.replacedByOtherDevice else { return }
                if case .connected = self.state { return }
                if case .connecting = self.state { return }
                self.attempt = 0
                self.reconnectTask?.cancel(); self.reconnectTask = nil
                self.connect()
            }
        }
    }
}

/// `URLSessionWebSocketTask` reports open / close / failure only through a
/// delegate, and the handshake's HTTP status (401 / 429 / 503 — doc §2.2) is
/// only reachable as `task.response` on failure. This thin shim forwards all
/// three to the gateway.
private final class WSDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onOpen: ((URLSessionTask) -> Void)?
    var onClose: ((URLSessionTask, URLSessionWebSocketTask.CloseCode, String?) -> Void)?
    var onError: ((URLSessionTask, Int?) -> Void)?

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        onOpen?(webSocketTask)
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        onClose?(webSocketTask, closeCode, reason.flatMap { String(data: $0, encoding: .utf8) })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A clean close arrives via didCloseWith, not here.
        guard error != nil else { return }
        onError?(task, (task.response as? HTTPURLResponse)?.statusCode)
    }
}
