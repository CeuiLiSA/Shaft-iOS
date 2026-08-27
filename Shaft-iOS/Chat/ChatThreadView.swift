import SwiftUI
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Metrics / palette
//
// Everything in this section is a literal transcription of the upstream Android
// resources so the two apps render the same screen:
//
//   * `res/layout/chat_bubble_sent.xml`     — right-aligned gradient bubble
//   * `res/layout/chat_bubble_received.xml` — left-aligned surface bubble
//   * `res/layout/chat_fragment_demo_list.xml` — input bar / new-message pill
//   * `res/drawable/bg_chat_bubble_received.xml` / `bg_chat_time_chip.xml`
//   * `ui/ChatMessageAdapter.kt`            — the runtime-computed bits
//
// dp and pt are 1:1 for our purposes (both are "points at 1× density"), so the
// numbers carry over unchanged.
// ─────────────────────────────────────────────────────────────────────────────

/// Layout constants shared by the bubble row and the composer.
private enum ChatMetrics {
    /// `chat_bubble_*.xml` root `paddingHorizontal`.
    static let rowPaddingH: CGFloat = 12
    static let avatarSize: CGFloat = 40
    static let avatarGap: CGFloat = 8
    static let bubblePadH: CGFloat = 14
    static let bubblePadV: CGFloat = 9
    static let bubbleRadius: CGFloat = 18
    /// The "tail" corner — top-trailing on sent, top-leading on received.
    static let bubbleTailRadius: CGFloat = 6
    static let textSize: CGFloat = 15
    /// `ChatMessageAdapter.JUMBO_TEXT_SP` — 1–3 bare emoji render bubble-less.
    static let jumboTextSize: CGFloat = 40
    /// `android:lineSpacingExtra="3dp"`.
    static let lineSpacing: CGFloat = 3
    static let timeSize: CGFloat = 11
    static let nameSize: CGFloat = 12
    static let monogramSize: CGFloat = 16
    static let stateIconSize: CGFloat = 14

    /// `layout_marginStart="56dp"` on the sent bubble column (and the mirrored
    /// `layout_marginEnd` on the received one).
    static let minGutter: CGFloat = 56
    /// `ChatMessageAdapter.BUBBLE_WIDTH_RATIO`.
    static let contentWidthRatio: CGFloat = 0.70

    /// `ChatMessageAdapter.TIME_GROUP_GAP_MS`.
    static let timeGroupGapMs: Int64 = 5 * 60 * 1000

    /// `ChatListViewModel(pageSize = 30)`.
    static let pageSize = 30
    /// doc §3.1 / §12 — cap client-side, never wait for `bad_text_length`.
    static let maxTextLength = 2048
    /// `ChatListViewModel.TYPING_REFRESH_INTERVAL_MS`.
    static let typingRefreshIntervalMs: Double = 4_000
    /// `ChatListViewModel.PEER_TYPING_TIMEOUT_MS`.
    static let peerTypingTimeout: Duration = .seconds(5)
    /// `BottomPanelCoordinator(fallbackHeightDp = 270)`.
    static let emojiPanelFallbackHeight: CGFloat = 270

    /// Width of the flexible gutter opposite the bubble.
    ///
    /// Android enforces the bubble's max width **twice**: a fixed 56dp margin in
    /// the layout, and `tvContent.maxWidth = 0.70 × screenWidth` at bind time —
    /// whichever binds tighter wins. SwiftUI has no "shrink-to-fit but cap at N"
    /// frame modifier (`.frame(maxWidth:)` *expands*), so we express both limits
    /// as one flexible `Spacer(minLength:)` and let the layout do the clamping:
    ///
    /// ```
    /// bubbleColumnSpace = W − 2·12 (row padding) − 40 (avatar) − 8 (gap) = W − 72
    /// androidCap        = min(W − 72 − 56,  0.70·W + 2·14 (bubble padding))
    /// ⇒ gutter          = max(56, (W − 72) − (0.70·W + 28)) = max(56, 0.30·W − 100)
    /// ```
    ///
    /// On a 390pt phone that resolves to the 56pt margin (same as Android); on a
    /// 1024pt iPad the 70 % rule takes over (also same as Android).
    static func gutter(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return minGutter }
        return max(minGutter, (1 - contentWidthRatio) * width - 100)
    }
}

/// Chat-only colors that aren't in `Theme` yet, resolved from the same
/// `values/colors.xml` + `values-night/colors.xml` pairs the Android screen uses.
private enum ChatPalette {
    /// `chat_received_bubble` — pure white on light (it floats over `v3_bg`
    /// #FAFAFA on a hairline), a notch-lighter indigo on dark.
    static let receivedBubble = Color(light: 0xFFFFFF, dark: 0x23232F)
    /// `v3_surface_3` → witstudio `wit_surface_3` (#14000000 / #14FFFFFF) — the
    /// centred time-group chip's plate.
    static let surface3 = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 20 / 255, darkAlpha: 20 / 255)
    /// `v3_orange` → `wit_orange`; the one entry of the group-name palette that
    /// `Theme` doesn't already carry.
    static let orange = Color(light: 0xD45A30, dark: 0xFF6F3C)

    /// Sent bubble fill: `GradientDrawable(TL_BR, [palette.primary,
    /// palette.scrollProgressMid])`, and `scrollProgressMid == hueShift(primary,
    /// 40°)` (`V3Palette.kt:121`). `Theme.brand` is our `Shaft.getThemeColor()`.
    static let sentGradient = LinearGradient(
        colors: [Theme.brand, Theme.brand.hueShifted(40)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// `ChatMessageAdapter.nameColor` — curated per-uid palette that keeps
    /// public-room sender names legible against each other.
    static let nameColors: [Color] = [
        Theme.v3Blue, Theme.v3Pink, Theme.v3Green, Theme.v3Purple, orange, Theme.v3Gold,
    ]

    /// Kotlin's `((uid % n) + n) % n` — negative-safe modulo, kept verbatim so a
    /// hypothetical negative uid maps to the same slot on both platforms.
    static func nameColor(for uid: Int64) -> Color {
        let n = Int64(nameColors.count)
        return nameColors[Int(((uid % n) + n) % n)]
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Page / paging state
// ─────────────────────────────────────────────────────────────────────────────

/// Port of `chat/base/UiState.kt`'s `PageState<T>` narrowed to what this screen
/// needs (the generic payload was always `Unit` here).
private enum ChatPageState: Equatable {
    case loading
    case content
    case empty
    case error(String)
}

/// Port of `PagingState` (`chat/base/UiState.kt`), rendered by
/// `PagingFooterAdapter` on Android.
private enum ChatPagingState: Equatable {
    case idle
    case loadingMore
    case endReached
    case error(String)
}

/// Long-press menu entries — 1:1 with `MessageActionsSheet.ACTION_*`.
private enum ChatMessageAction {
    case copy, reply, forward, delete
}

/// One rendered row. Android computes `showTimeGroup` / `isGroupStart` inside
/// `onBindDataViewHolder` by peeking at the chronologically-older neighbour;
/// SwiftUI has no bind-time neighbour access, so we precompute the whole列表
/// once per messages change and hand each row its verdict.
private struct ChatRowModel: Identifiable, Equatable {
    let message: ChatMessage
    /// Gap > 5 min or a new calendar day since the previous message.
    let showTimeGroup: Bool
    /// First message of a same-sender run — drives avatar/name visibility and
    /// the vertical rhythm.
    let isGroupStart: Bool

    var id: String { message.localKey }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ViewModel
// ─────────────────────────────────────────────────────────────────────────────

/// Local-first chat thread ViewModel — port of
/// `ceui.pixiv.chat.vm.ChatListViewModel`.
///
/// ```
/// List ← observe ← messages ← AsyncStream ← ChatMessageStore
///                                  ↑ upsert (by localKey)
///                    ┌─────────────┤
///                    │             │
///            ShaftChatAPI    ShaftChatGateway.frames()
///             (/history)      (WS broadcast, room-filtered)
/// ```
///
/// The UI **only** reads ``messages``. Every write — optimistic send, WS echo,
/// history backfill — is an upsert keyed on `localKey`, which is what makes the
/// echo overwrite the optimistic row instead of double-rendering it (doc §4.3).
///
/// ⚠️ Unlike Android, this VM does **not** persist inbound broadcasts:
/// `ShaftChatGateway.installAlwaysOnPersister()` already upserts every `msg`
/// frame process-wide. We only grow the observation window so the new row stays
/// inside the LIMIT-bounded snapshot.
@MainActor
@Observable
private final class ChatThreadViewModel {

    // MARK: Identity

    let selfUid: Int64
    /// `nil` → the public broadcast room.
    let peerUid: Int64?
    /// Derived once per doc §3.2 and used as the filter for every subscription.
    let room: String
    var isGlobal: Bool { peerUid == nil }

    /// Set when `(selfUid, peerUid)` can't produce a room — self-chat, or no
    /// signed-in uid. The screen then renders a permanent error state instead of
    /// silently subscribing to `""`. (Android threw here and crashed the
    /// fragment; a dead-end state is strictly better.)
    private(set) var roomError: String?

    // MARK: Observable UI state

    /// Ascending by `ts` (oldest → newest), windowed to the newest `windowSize`.
    private(set) var messages: [ChatRowModel] = []
    /// `localKey` of the newest row — the view watches this to decide between
    /// "scroll to bottom" and "raise the N-new-messages pill".
    private(set) var newestKey: String?
    private(set) var pageState: ChatPageState = .loading
    private(set) var pagingState: ChatPagingState = .idle

    /// Peer typing indicator (DM only). `displayName` comes from the frame when
    /// the server resolved one, else the anonymous copy is used.
    private(set) var peerTypingName: String?
    private(set) var isPeerTyping = false

    /// `err.rate_limited` → send disabled for 1s (doc §12).
    private(set) var rateLimitCoolDown = false

    private(set) var peerDisplayName: String?
    private(set) var peerAvatarURL: URL?
    private(set) var selfAvatarURL: URL?

    /// Transient bottom toast — the stand-in for Android's `Toaster`.
    private(set) var toast: String?

    // MARK: Internals

    @ObservationIgnored private var windowSize = ChatMetrics.pageSize
    /// `before=` cursor for the next older page — the previous page's
    /// `items[0].id`. `nil` after a page came back empty ⇒ top reached.
    @ObservationIgnored private var nextBeforeId: Int64?
    @ObservationIgnored private var firstPageLoaded = false
    @ObservationIgnored private var didInitialLoad = false
    @ObservationIgnored private var lastSentReadId: Int64 = 0
    @ObservationIgnored private var lastTypingStartSentMs: Double = 0

    @ObservationIgnored private var observeTask: Task<Void, Never>?
    @ObservationIgnored private var frameTask: Task<Void, Never>?
    @ObservationIgnored private var pagingTask: Task<Void, Never>?
    @ObservationIgnored private var rateLimitTask: Task<Void, Never>?
    @ObservationIgnored private var peerTypingTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Guards against a stale window snapshot landing after a newer
    /// re-subscription (window size changes on every send / inbound message).
    @ObservationIgnored private var observeGeneration = 0

    @ObservationIgnored private var l10n: (LocalizedKey) -> String = { $0.rawValue }
    @ObservationIgnored private var isChinese = false
    @ObservationIgnored private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)

    init(peerUid: Int64?) {
        let uid = KeychainTokenStore.shared.load()?.user?.id ?? 0
        self.selfUid = uid
        self.peerUid = peerUid
        if let peerUid {
            if let derived = ChatThreadId.oneOnOneThreadId(uid, peerUid), uid > 0 {
                self.room = derived
            } else {
                self.room = ""
                // Mirrors the server's `self_chat_not_allowed`; also covers the
                // signed-out case, where no room can exist at all.
                self.roomError = uid == peerUid ? "self" : "auth"
            }
        } else {
            self.room = ChatThreadId.roomGlobal
        }
    }

    /// Injected from the view so VM-side strings follow the in-app language
    /// picker — same seam as `ComicReaderViewModel.configureL10n`.
    func configureL10n(_ t: @escaping (LocalizedKey) -> String, languageTag: String) {
        l10n = t
        isChinese = languageTag.hasPrefix("zh")
    }

    // MARK: Lifecycle

    /// Called from `.task` — safe to re-enter when the screen re-appears.
    /// Streaming subscriptions restart; the one-shot loads don't.
    func start() async {
        guard roomError == nil else {
            pageState = .error(roomErrorMessage)
            return
        }
        restartObserving()
        startFrameObserver()
        guard !didInitialLoad else { return }
        didInitialLoad = true
        loadAvatars()
        await initialLoad()
    }

    /// Called from `.onDisappear` — matches the Android fragment's view-lifecycle
    /// scoped collectors. The in-flight pagination task deliberately survives
    /// (Android's lives on `viewModelScope`, not the view's).
    func stop() {
        notifyTypingStop()
        observeTask?.cancel(); observeTask = nil
        frameTask?.cancel(); frameTask = nil
        peerTypingTask?.cancel(); peerTypingTask = nil
        isPeerTyping = false
        peerTypingName = nil
    }

    // MARK: Store window

    /// Re-subscribe the room's newest-`windowSize` window. Equivalent to the
    /// Android `windowSize.flatMapLatest { store.observe(room, it) }` chain: the
    /// store's `observe` takes its limit at subscription time, so growing the
    /// window means a new subscription.
    private func restartObserving() {
        observeTask?.cancel()
        observeGeneration += 1
        let generation = observeGeneration
        let room = self.room
        let limit = windowSize
        observeTask = Task { [weak self] in
            for await rows in await ChatMessageStore.shared.observe(room: room, limit: limit) {
                guard !Task.isCancelled, let self, self.observeGeneration == generation else { return }
                self.apply(rows)
            }
        }
    }

    private func apply(_ rows: [ChatMessage]) {
        messages = Self.buildRows(rows)
        newestKey = rows.last?.localKey
        maybeMarkRead(rows)
    }

    /// Time-group + sender-run boundaries, computed once per list change.
    /// Equivalent to `ChatMessageAdapter.onBindDataViewHolder`'s `older` peek
    /// (which, under `reverseLayout`, is `position + 1`).
    private static func buildRows(_ rows: [ChatMessage]) -> [ChatRowModel] {
        var out: [ChatRowModel] = []
        out.reserveCapacity(rows.count)
        var older: ChatMessage?
        for m in rows {
            let showTimeGroup = older.map { isNewTimeGroup(olderTs: $0.ts, ts: m.ts) } ?? true
            let isGroupStart = showTimeGroup || older == nil || older!.uid != m.uid
            out.append(ChatRowModel(message: m, showTimeGroup: showTimeGroup, isGroupStart: isGroupStart))
            older = m
        }
        return out
    }

    private static func isNewTimeGroup(olderTs: Int64, ts: Int64) -> Bool {
        ts - olderTs > ChatMetrics.timeGroupGapMs || !ChatTime.sameDay(olderTs, ts)
    }

    /// DM-only `/read` cursor. Strict-monotonic so a list re-emit that didn't
    /// actually advance the max server id (pagination, an optimistic row
    /// flipping state) doesn't spam the endpoint. WS-only rows carry no `id`,
    /// so they're marked read once `/history` backfills them — same as Android.
    private func maybeMarkRead(_ rows: [ChatMessage]) {
        guard peerUid != nil, selfUid > 0 else { return }
        let maxServerId = rows.compactMap(\.serverId).max() ?? 0
        guard maxServerId > lastSentReadId else { return }
        lastSentReadId = maxServerId
        let room = self.room
        let uid = self.selfUid
        Task {
            // Network errors / 404 not_a_member must not break the chat UI.
            _ = try? await ShaftChatAPI.shared.markRead(uid: uid, room: room, lastReadMessageId: maxServerId)
        }
    }

    // MARK: History

    private func initialLoad() async {
        let cached = await ChatMessageStore.shared.count(room: room)
        if cached > 0 {
            // Local-first: show what we have, then silently reconcile.
            pageState = .content
            await backgroundRefresh()
        } else {
            pageState = .loading
            await fetchNewest()
        }
    }

    func retry() {
        Task {
            pageState = .loading
            await fetchNewest()
        }
    }

    private func fetchNewest() async {
        do {
            let resp = try await ShaftChatAPI.shared.history(room: room, limit: ChatMetrics.pageSize, before: nil)
            let rows = resp.items.map { ChatMessage.fromHistory($0, room: room) }
            if !rows.isEmpty { await ChatMessageStore.shared.upsert(rows) }
            // `items` is ts-ascending, so `items[0].id` is the oldest — the
            // cursor for the *next* (older) page. Empty page ⇒ nothing above.
            nextBeforeId = resp.items.first?.id
            firstPageLoaded = true
            pageState = (rows.isEmpty && messages.isEmpty) ? .empty : .content
        } catch {
            // A failed refresh over a warm cache is not an error state.
            pageState = messages.isEmpty ? .error(errorText(error)) : .content
        }
    }

    private func backgroundRefresh() async {
        guard let resp = try? await ShaftChatAPI.shared.history(room: room, limit: ChatMetrics.pageSize, before: nil) else { return }
        let rows = resp.items.map { ChatMessage.fromHistory($0, room: room) }
        if !rows.isEmpty { await ChatMessageStore.shared.upsert(rows) }
        nextBeforeId = resp.items.first?.id
        firstPageLoaded = true
    }

    /// Load one page of older history (doc §8.1). Idempotent under the burst of
    /// `onAppear` calls a lazy stack fires while the top sentinel settles.
    func loadOlder() {
        // `pageState == .loading` means `fetchNewest()` is already in flight for
        // the same first page. Android can't hit this (its paginate check only
        // runs off scroll events), but a lazy stack materialises the top
        // sentinel during the very first layout, so the guard is needed here.
        guard roomError == nil, pagingState == .idle, pageState != .loading else { return }
        if nextBeforeId == nil, !messages.isEmpty {
            // Don't declare "top reached" off a cache-only list — the first
            // network page hasn't set the cursor yet.
            guard firstPageLoaded else { return }
            pagingState = .endReached
            return
        }
        // Claim the slot *synchronously*. Setting it inside the task left the
        // guard above useless: `retryPaging()` (which sets `.idle` then calls
        // straight through) and the sentinel's `onChange`-on-`.idle` observer
        // both reach here in the same run-loop turn, before the task body runs —
        // so both saw `.idle`, both fetched the same page, and `windowSize` grew
        // by two pages instead of one.
        pagingState = .loadingMore
        pagingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resp = try await ShaftChatAPI.shared.history(
                    room: self.room, limit: ChatMetrics.pageSize, before: self.nextBeforeId
                )
                let rows = resp.items.map { ChatMessage.fromHistory($0, room: self.room) }
                if !rows.isEmpty {
                    await ChatMessageStore.shared.upsert(rows)
                    // Grow the window by exactly the page size so the older rows
                    // fit inside the LIMIT-bounded snapshot.
                    self.windowSize += rows.count
                    self.restartObserving()
                }
                self.nextBeforeId = resp.items.first?.id
                self.pagingState = self.nextBeforeId == nil ? .endReached : .idle
            } catch {
                self.pagingState = .error(self.errorText(error))
            }
        }
    }

    func retryPaging() {
        pagingState = .idle
        loadOlder()
    }

    /// Shrink the window back to one page once the user returns to the bottom,
    /// so a long backwards scroll doesn't keep hundreds of rows laid out.
    /// The store still holds every row, so scrolling up re-reveals them
    /// contiguously as the window grows again.
    func trimWindow() {
        guard windowSize > ChatMetrics.pageSize else { return }
        windowSize = ChatMetrics.pageSize
        restartObserving()
    }

    // MARK: Send (doc §3.1 + §4.3)

    /// 1. fresh UUIDv4 `client_msg_id`
    /// 2. optimistic upsert `state = .sending`
    /// 3. dispatch; a refused dispatch flips the row to `.failed`
    /// 4. the WS broadcast echo upserts the *same* `localKey` as `.delivered`
    ///
    /// The return value is "the frame entered the outgoing buffer", **not** an
    /// end-to-end ACK — the echo is the ACK.
    @discardableResult
    func sendText(_ text: String, illustId: Int64? = nil) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, roomError == nil else { return false }
        // doc §12: cap client-side rather than round-tripping a
        // `bad_text_length`. UTF-16 units, matching Kotlin's `String.length`.
        guard trimmed.utf16.count <= ChatMetrics.maxTextLength else {
            showToast(zhEn("消息过长", "Message is too long"))
            return false
        }

        // Kotlin's `UUID.randomUUID().toString()` is lowercase; Foundation's is
        // upper. Lowercase it so both clients put the same shape on the wire.
        let clientMsgId = UUID().uuidString.lowercased()
        let optimistic = ChatMessage(
            localKey: clientMsgId,
            serverId: nil,
            clientMsgId: clientMsgId,
            uid: selfUid,
            room: room,
            displayName: nil,          // server fills it on the echo
            text: trimmed,
            illustId: illustId,
            ts: Int64(Date().timeIntervalSince1970 * 1000),
            state: .sending
        )

        windowSize += 1
        restartObserving()
        await ChatMessageStore.shared.upsert([optimistic])
        if pageState == .empty { pageState = .content }

        let accepted = ShaftChatGateway.shared.send(
            toUid: peerUid, clientMsgId: clientMsgId, text: trimmed, illustId: illustId
        )
        if !accepted {
            await ChatMessageStore.shared.markState(room: room, localKey: clientMsgId, state: .failed)
        }
        return accepted
    }

    // MARK: Inbound frames

    /// One subscription for the three frame kinds this screen reacts to. Android
    /// splits them across `chatStream` / `errorFrames` / `typingFrames`; the iOS
    /// gateway exposes a single fan-out, so we demux here.
    private func startFrameObserver() {
        frameTask?.cancel()
        frameTask = Task { [weak self] in
            for await frame in ShaftChatGateway.shared.frames() {
                guard !Task.isCancelled, let self else { return }
                switch frame {
                case .msg(let m) where m.room == self.room:
                    self.onInboundMessage()
                case .err(let code, let cmid, let message):
                    self.handleServerError(code: code, clientMsgId: cmid, message: message)
                case .typing(let r, let uid, let name, let state, _)
                    where r == self.room && uid != self.selfUid:
                    self.handlePeerTyping(state: state, displayName: name)
                default:
                    break
                }
            }
        }
    }

    /// The row itself is persisted by the gateway's always-on persister; all we
    /// owe it is window headroom and an Empty → Content flip.
    private func onInboundMessage() {
        windowSize += 1
        restartObserving()
        if pageState == .empty { pageState = .content }
    }

    /// doc §3.2 / §12. `client_msg_id` anchors the failure to one exact row; a
    /// frame-level error (`bad_json`, `bad_envelope`, an unparseable oversized
    /// frame) carries none, so we fall back to "the most recent still-sending
    /// row", which is overwhelmingly the user's last action.
    private func handleServerError(code: String, clientMsgId: String?, message: String?) {
        Task { [weak self] in
            guard let self else { return }
            // `??` can't host the actor hop (its right side is an autoclosure),
            // so the fallback is spelled out.
            let resolved: String?
            if let clientMsgId {
                resolved = clientMsgId
            } else {
                resolved = await ChatMessageStore.shared.latestSendingKey(room: self.room)
            }
            guard let target = resolved else {
                ChatLog.warn("err \(code): no in-flight sending row to anchor")
                return
            }
            if code == "global_send_disabled" {
                // Non-retryable policy rejection: the message was never accepted,
                // so leaving even a Failed row is noise. Deleting by key is safe
                // unconditionally — the server answers `err` XOR broadcasts the
                // echo for a cmid, never both, and the cmid is a fresh UUID.
                await ChatMessageStore.shared.delete(room: self.room, localKey: target)
                if self.windowSize > ChatMetrics.pageSize { self.windowSize -= 1 }
            } else {
                await ChatMessageStore.shared.markState(room: self.room, localKey: target, state: .failed)
            }
        }

        if code == "rate_limited" {
            // `collectLatest` equivalent: a back-to-back rate_limited restarts
            // the cool-down instead of stacking two overlapping timers.
            rateLimitTask?.cancel()
            rateLimitCoolDown = true
            showToast(zhEn("发送太频繁,请稍候", "Sending too fast — please wait"))
            rateLimitTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.rateLimitCoolDown = false
            }
        } else {
            showToast(friendlyChatErrorMessage(code: code, message: message))
        }
    }

    /// Never show the raw machine code. Priority: server-supplied `message`
    /// (policy errors carry one, so the wording can change without a release) →
    /// local code map → generic copy.
    private func friendlyChatErrorMessage(code: String, message: String?) -> String {
        if let message, !message.isEmpty { return message }
        switch code {
        case "global_send_disabled":  return l10n(.chatGlobalClosedHint)
        case "room_forbidden":        return zhEn("无法发送到该聊天", "Can't send to this chat")
        case "self_chat_not_allowed": return zhEn("不能给自己发消息", "You can't message yourself")
        case "bad_text_length":       return zhEn("消息为空或过长", "Message is empty or too long")
        case "bad_text":              return zhEn("消息内容无效", "Invalid message content")
        case "bad_illust_id":         return zhEn("插画 ID 无效", "Invalid illustration id")
        case "bad_client_msg_id":     return zhEn("消息标识无效", "Invalid message id")
        case "frame_too_large":       return zhEn("消息过大", "Message is too large")
        default:                      return sendFailedText
        }
    }

    var sendFailedText: String {
        zhEn("发送失败,请稍后重试", "Failed to send — please try again")
    }

    // MARK: Typing (DM only)

    /// Peer's indicator. Each fresh frame restarts the 5s auto-clear, which is
    /// the `collectLatest { … delay(5s) }` shape upstream: the server never
    /// sends an "expired" frame, so expiry is purely a client convention.
    private func handlePeerTyping(state: String, displayName: String?) {
        peerTypingTask?.cancel()
        if state == "stop" {
            isPeerTyping = false
            peerTypingName = nil
            return
        }
        isPeerTyping = true
        peerTypingName = displayName?.isEmpty == false ? displayName : nil
        peerTypingTask = Task { [weak self] in
            try? await Task.sleep(for: ChatMetrics.peerTypingTimeout)
            guard !Task.isCancelled else { return }
            self?.isPeerTyping = false
            self?.peerTypingName = nil
        }
    }

    /// Safe to call on every keystroke — the ~4s debounce lives here so call
    /// sites don't duplicate it, and the server's bucket (10 frames / 10s) stays
    /// untouched. `state: nil` lets the server default to `"start"`.
    ///
    /// The debounce clock only advances when the frame actually made it into the
    /// buffer; otherwise a blip would silently eat the next 4 s of typing.
    func notifyTyping() {
        guard let peerUid else { return }
        let now = Date().timeIntervalSince1970 * 1000
        guard now - lastTypingStartSentMs >= ChatMetrics.typingRefreshIntervalMs else { return }
        if ShaftChatGateway.shared.sendTyping(toUid: peerUid, state: nil) {
            lastTypingStartSentMs = now
        }
    }

    /// Explicit stop so the peer's indicator clears immediately instead of
    /// waiting out their 5s timeout. No-op on an input that never typed.
    func notifyTypingStop() {
        guard let peerUid, lastTypingStartSentMs != 0 else { return }
        lastTypingStartSentMs = 0
        _ = ShaftChatGateway.shared.sendTyping(toUid: peerUid, state: "stop")
    }

    // MARK: Message actions

    func message(forKey key: String) -> ChatMessage? {
        messages.first { $0.message.localKey == key }?.message
    }

    func copyToPasteboard(_ message: ChatMessage) {
        UIPasteboard.general.string = message.text
        showToast(l10n(.nrMsgCopied))
    }

    func delete(_ message: ChatMessage) {
        Task { [weak self] in
            guard let self else { return }
            await ChatMessageStore.shared.delete(room: self.room, localKey: message.localKey)
            self.showToast(self.zhEn("已删除", "Deleted"))
        }
    }

    // MARK: Avatars / peer profile

    /// Android reads the self avatar straight off the cached `SessionManager`
    /// user and only fetches the peer. iOS's keychain token carries no avatar
    /// URL, so both sides go through `userDetail` — one extra cached request,
    /// and the失败 path just leaves the placeholder in place.
    private func loadAvatars() {
        if selfUid > 0 {
            Task { [weak self] in
                guard let self,
                      let user = try? await self.api.userDetail(self.selfUid).user else { return }
                self.selfAvatarURL = Self.avatarURL(user)
            }
        }
        guard let peerUid else { return }
        Task { [weak self] in
            guard let self,
                  let user = try? await self.api.userDetail(peerUid).user else { return }
            if let name = user.name, !name.isEmpty { self.peerDisplayName = name }
            self.peerAvatarURL = Self.avatarURL(user)
        }
    }

    /// `profile_image_urls.findMaxSizeUrl()` — biggest square pixiv serves.
    private static func avatarURL(_ user: PixivUser) -> URL? {
        let raw = user.profileImageUrls?.original
            ?? user.profileImageUrls?.medium
            ?? user.profileImageUrls?.px170x170
            ?? user.profileImageUrls?.px50x50
        return raw.flatMap(URL.init(string:))
    }

    // MARK: Toast

    func showToast(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Copy helpers

    /// A handful of upstream strings have no `LocalizedKey` yet (the WS `err`
    /// code map, the delete-confirmation dialog, the connection banners). Adding
    /// keys means touching `Localization/`, which this port isn't allowed to do,
    /// so those few fall back to zh/en here. Everything that *does* have a key
    /// goes through `l10n` and picks up all seven languages.
    func zhEn(_ zh: String, _ en: String) -> String { isChinese ? zh : en }

    var roomErrorMessage: String {
        switch roomError {
        case "self": return zhEn("不能给自己发消息", "You can't message yourself")
        default:     return l10n(.chatErrorUnauthorized)
        }
    }

    /// Transport failures → the shared `chatError*` strings (the iOS counterpart
    /// of Android's `AppError.toUserMessage()`).
    private func errorText(_ error: Error) -> String {
        if let apiError = error as? ChatAPIError {
            switch apiError {
            case .notLoggedIn:  return l10n(.chatErrorUnauthorized)
            case .hmacDisabled: return l10n(.chatErrorSecurity)
            case .badURL:       return l10n(.chatErrorUnknown)
            case .decode:       return l10n(.chatErrorSerialization)
            case .http(let code, _):
                switch code {
                case 401: return l10n(.chatErrorUnauthorized)
                case 403: return l10n(.chatErrorForbidden)
                case 404: return l10n(.chatErrorNotFound)
                case 410: return l10n(.chatErrorGone)
                case 429: return l10n(.chatErrorRateLimited)
                case 503: return l10n(.chatErrorServiceUnavailable)
                default:  return l10n(.chatErrorUnknown)
                }
            }
        }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return l10n(.chatErrorUnknown) }
        switch ns.code {
        case NSURLErrorTimedOut:
            return l10n(.chatErrorRequestTimeout)
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return l10n(.chatErrorSecurity)
        default:
            return l10n(.chatErrorNetworkUnavailable)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Screen
// ─────────────────────────────────────────────────────────────────────────────

/// Chat thread (message list) — port of
/// `ceui.pixiv.chat.ui.DemoChatListFragment` + `chat_fragment_demo_list.xml`.
///
/// The WebSocket is app-scoped (`ShaftChatGateway.shared`); this screen just
/// opens a per-room view onto it:
///
/// * history — `ShaftChatAPI.history(room:limit:before:)`
/// * live    — `ShaftChatGateway.frames()` filtered to `room`
/// * send    — optimistic local write → `gateway.send` → the WS echo flips the
///   row `.sending` → `.delivered` (doc §4.3, never double-render)
///
/// ## Why the list is flipped
///
/// Android uses `LinearLayoutManager(reverseLayout = true, stackFromEnd = true)`:
/// index 0 is the newest row and it sits at the bottom, so appending a message
/// never disturbs the scroll offset and prepending a page of history can't make
/// the content jump. The iOS equivalent is the classic inverted-scroll-view
/// trick — flip the `ScrollView` and flip each row back. Both transforms cancel
/// for touches too, so the drag direction stays natural.
///
/// That's also why message actions use a long press + sheet rather than
/// `.contextMenu`: a context menu would snapshot the flipped row for its preview.
/// It happens to match upstream exactly, which presents a `MessageActionsSheet`.
struct ChatThreadView: View {
    let peerUid: Int64?
    let peerTitle: String?

    @State private var vm: ChatThreadViewModel
    @State private var draft = ""
    @State private var showEmojiPanel = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var listWidth: CGFloat = 0
    @State private var isAtBottom = true
    @State private var newMsgCount = 0
    @State private var scrollToBottomOnNextUpdate = false
    /// Bumped by the pill; watched inside the `ScrollViewReader`, which is the
    /// only place that owns a proxy.
    @State private var scrollToBottomRequest = 0
    /// Whether the top prefetch sentinel is currently materialised — lets a
    /// finished page immediately ask for the next one when the list is still
    /// shorter than the viewport (Android re-runs `paginateIfNeeded` after every
    /// list update; `onAppear` alone would only fire once).
    @State private var topSentinelVisible = false
    @State private var actionTarget: ChatMessage?
    @State private var pendingDelete: ChatMessage?

    @FocusState private var inputFocused: Bool
    @Environment(OnboardingStore.self) private var l10n

    init(peerUid: Int64?, peerTitle: String?) {
        self.peerUid = peerUid
        self.peerTitle = peerTitle
        _vm = State(wrappedValue: ChatThreadViewModel(peerUid: peerUid))
    }

    var body: some View {
        VStack(spacing: 0) {
            connectionBanner
            messageArea
            inputBar
            if showEmojiPanel {
                ChatEmojiPanel(height: panelHeight) { emoji in
                    draft.append(emoji)
                }
                .transition(.move(edge: .bottom))
            }
        }
        .background(Theme.v3Bg)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        // Opaque bar: the flipped list scrolls beneath it with the edge effect
        // off (see `messageScrollView`), so the bar must cover it itself.
        .toolbarBackground(Theme.v3Bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .overlay(alignment: .bottom) { toastOverlay }
        .task {
            vm.configureL10n({ l10n.t($0) }, languageTag: l10n.activeTag)
            await vm.start()
        }
        .onAppear {
            // Authoritatively tell the gateway which room is foreground so the
            // in-app banner for this room is suppressed (Android: onResume).
            ShaftChatGateway.shared.enterChatRoom(vm.room)
        }
        .onDisappear {
            ShaftChatGateway.shared.exitChatRoom(vm.room)
            vm.stop()
        }
        .onChange(of: draft) { _, newValue in
            // VM debounces internally, so per-keystroke calls are cheap. An
            // emptied input sends an explicit stop so the peer's indicator
            // clears at once instead of after their 5s timeout.
            if newValue.isEmpty { vm.notifyTypingStop() } else { vm.notifyTyping() }
        }
        .onChange(of: inputFocused) { _, focused in
            // Keyboard and panel are mutually exclusive (BottomPanelCoordinator).
            if focused, showEmojiPanel { withAnimation(.easeOut(duration: 0.2)) { showEmojiPanel = false } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            // Remember the real keyboard height so the emoji panel opens at
            // exactly the same size — the panel replaces the keyboard in place.
            keyboardHeight = max(0, frame.height - Self.bottomSafeAreaInset)
        }
        .sheet(item: $actionTarget) { message in
            ChatMessageActionsSheet(message: message) { action in
                actionTarget = nil
                handle(action, on: message)
            }
        }
        .alert(vm.zhEn("删除消息", "Delete message"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(l10n.t(.actionCancel), role: .cancel) { pendingDelete = nil }
            Button(l10n.t(.actionDelete), role: .destructive) {
                if let target = pendingDelete { vm.delete(target) }
                pendingDelete = nil
            }
        } message: {
            Text(vm.zhEn("确定要删除这条消息吗？", "Delete this message?"))
        }
    }

    // MARK: Title

    /// WeChat-style: while the peer types, the whole title is replaced, and it
    /// snaps back to the baseline the moment they stop. The baseline is the
    /// resolved peer name once `userDetail` lands, the list-supplied title
    /// before that, and the canonical drawer entry for the public room.
    private var navigationTitle: String {
        if vm.isPeerTyping {
            if let name = vm.peerTypingName ?? vm.peerDisplayName {
                return l10n.t(.chatPeerTyping, name)
            }
            return l10n.t(.chatPeerTypingAnon)
        }
        if let peerUid {
            return vm.peerDisplayName ?? peerTitle ?? "uid=\(peerUid)"
        }
        return l10n.t(.chatDrawerEntry)
    }

    // MARK: Connection banner

    /// Android surfaces these as toasts; a persistent strip is the better iOS
    /// shape because the two fatal cases don't clear on their own. The
    /// "replaced" case additionally offers an explicit way back — doc §7.3 bans
    /// auto-reconnect there (two devices would kick each other forever), so the
    /// user has to ask.
    @ViewBuilder
    private var connectionBanner: some View {
        let gateway = ShaftChatGateway.shared
        if gateway.fatalAuth {
            banner(
                text: vm.zhEn(
                    "聊天认证失败 — 请检查系统时间是否正确,或重新登录",
                    "Chat auth failed — check your device clock, or sign in again"
                ),
                tint: Theme.v3Danger
            )
        } else if gateway.replacedByOtherDevice {
            banner(
                text: vm.zhEn("账号在其它设备登录,聊天已断开", "Signed in on another device — chat disconnected"),
                tint: Theme.v3Danger,
                actionTitle: vm.zhEn("切换回来", "Reconnect"),
                action: { gateway.reconnectNow() }
            )
        } else if case .reconnecting = gateway.state {
            banner(text: vm.zhEn("正在重新连接…", "Reconnecting…"), tint: Theme.v3Text2)
        }
    }

    private func banner(
        text: String,
        tint: Color,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.v3MenuBg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.v3Border1).frame(height: 0.5) }
    }

    // MARK: Message list

    private var messageArea: some View {
        ZStack(alignment: .bottomTrailing) {
            messageList
                .opacity(vm.pageState == .content ? 1 : 0)
            stateOverlay
            if newMsgCount > 0 { newMessagesPill }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
    }

    private var messageList: some View {
        // The safe-area inset that would normally land on this scroll view's top
        // edge (the navigation bar) — zero whenever `connectionBanner` sits above.
        GeometryReader { geo in
            messageScrollView(topInset: geo.safeAreaInsets.top)
        }
    }

    private func messageScrollView(topInset: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // `chat_fragment_demo_list.xml`: recycler paddingTop/Bottom = 8dp.
                // Flipped, so the visual bottom padding is this stack's top one.
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 8)
                        .background(FlippedScrollEdgeEffectKiller())
                    ForEach(reversedRows) { row in
                        ChatBubbleRow(
                            row: row,
                            selfUid: vm.selfUid,
                            isGlobal: vm.isGlobal,
                            selfAvatarURL: vm.selfAvatarURL,
                            peerAvatarURL: vm.peerAvatarURL,
                            containerWidth: listWidth,
                            onLongPress: { message in
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                actionTarget = message
                            }
                        )
                        .id(row.id)
                        .scaleEffect(x: 1, y: -1, anchor: .center)
                    }
                    pagingFooter
                        .scaleEffect(x: 1, y: -1, anchor: .center)
                    // Prefetch sentinel — the lazy stack materialises it slightly
                    // before it scrolls in, which is the equivalent of Android's
                    // `PREFETCH_THRESHOLD = 5`.
                    Color.clear
                        .frame(height: 1)
                        .onAppear { topSentinelVisible = true; vm.loadOlder() }
                        .onDisappear { topSentinelVisible = false }
                }
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            // Flipped, so the automatic safe-area inset for the navigation bar
            // would surface at the *visual bottom* (a phantom gap under the newest
            // row) while the oldest visible row slid under the bar. Opt out and
            // re-add the same inset at the scroll-space bottom, which after the
            // flip is exactly the strip beneath the bar.
            .ignoresSafeArea(.container, edges: .top)
            .contentMargins(.bottom, topInset, for: .scrollContent)
            // iOS 26's Liquid Glass scroll-edge blur is computed in scroll space
            // too, so on a flipped list it blurred the whole viewport and left the
            // strip under the bar crisp. The bar gets an opaque background instead.
            .flippedListEdgeEffectDisabled()
            .scaleEffect(x: 1, y: -1, anchor: .center)
            .onScrollGeometryChange(for: CGFloat.self) {
                // Flipped space: offset 0 is the newest message.
                $0.contentOffset.y + $0.contentInsets.top
            } action: { _, distanceFromNewest in
                let atBottom = distanceFromNewest <= 24
                guard atBottom != isAtBottom else { return }
                isAtBottom = atBottom
                if atBottom {
                    resetNewMsgPill()
                    vm.trimWindow()
                }
            }
            .onChange(of: vm.newestKey) { oldKey, newKey in
                guard let newKey else { return }
                let isNewIncoming = oldKey != nil
                if isAtBottom || scrollToBottomOnNextUpdate {
                    scrollToBottomOnNextUpdate = false
                    resetNewMsgPill()
                    withAnimation(.easeOut(duration: 0.24)) {
                        proxy.scrollTo(newKey, anchor: .top)
                    }
                } else if isNewIncoming {
                    // Reading history — surface the pill instead of yanking the
                    // user down to the newest row.
                    newMsgCount += 1
                }
            }
            .onChange(of: scrollToBottomRequest) { _, _ in
                guard let newestKey = vm.newestKey else { return }
                withAnimation(.easeOut(duration: 0.24)) {
                    proxy.scrollTo(newestKey, anchor: .top)
                }
            }
            // Android's `paginateIfNeeded` runs again after every list update;
            // this is the equivalent for a list that never left the sentinel.
            .onChange(of: vm.pagingState) { _, state in
                guard state == .idle, topSentinelVisible else { return }
                vm.loadOlder()
            }
        }
    }

    /// Newest first — the flipped scroll view renders index 0 at the bottom.
    private var reversedRows: [ChatRowModel] {
        vm.messages.reversed()
    }

    // MARK: State layout (`chat_view_state_*.xml`)

    @ViewBuilder
    private var stateOverlay: some View {
        switch vm.pageState {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .frame(width: 40, height: 40)
                Text(l10n.t(.chatStateLoadingDefault))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.brand)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            VStack(spacing: 0) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 52))
                    .foregroundStyle(Theme.v3Text2)
                    .opacity(0.5)
                    .padding(.bottom, 16)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.v3Text1)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 24)
                Button(l10n.t(.chatStateRetry)) { vm.retry() }
                    .buttonStyle(.bordered)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.v3Text3)
                Text(l10n.t(.chatStateEmptyDefault))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.v3Text2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .content:
            EmptyView()
        }
    }

    // MARK: Paging footer (`chat_item_list_loading.xml` / `chat_item_list_error.xml`)

    @ViewBuilder
    private var pagingFooter: some View {
        switch vm.pagingState {
        case .loadingMore:
            VStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                Text(l10n.t(.chatListLoadingMore))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.v3Text2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(Theme.v3Surface1, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.v3Border1, lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        case .error(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.v3Danger)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.v3Text2)
                    .multilineTextAlignment(.center)
                Button(l10n.t(.chatStateRetry)) { vm.retryPaging() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(Theme.v3Surface1, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.v3Danger.opacity(0.35), lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        case .idle, .endReached:
            EmptyView()
        }
    }

    // MARK: "N 条新消息" pill

    private var newMessagesPill: some View {
        Button {
            resetNewMsgPill()
            scrollToBottomRequest += 1
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                Text(l10n.t(.chatNewMessages, "\(newMsgCount)"))
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(Theme.v3Text1)
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
            .background(ChatPalette.receivedBubble, in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.v3Border2, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 14)
        .padding(.bottom, 10)
        .transition(.opacity)
    }

    private func resetNewMsgPill() {
        newMsgCount = 0
    }

    // MARK: Input bar

    /// `chat_fragment_demo_list.xml`'s `input_bar`: emoji toggle (40dp) +
    /// 22dp-radius filled field + 40dp filled send button, on `v3_menu_bg`.
    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Button {
                toggleEmojiPanel()
            } label: {
                Image(systemName: showEmojiPanel ? "keyboard" : "face.smiling")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.v3Text2)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .disabled(isComposerLocked)

            TextField(inputHint, text: $draft, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(1...4)
                .focused($inputFocused)
                .disabled(isComposerLocked)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(ChatPalette.receivedBubble, in: .rect(cornerRadius: 22))
                .padding(.leading, 6)
                .padding(.trailing, 8)

            Button {
                send()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    // Disabled state mirrors `ColorUtils.setAlphaComponent(brand, 0x40)`.
                    .background(Theme.brand.opacity(isSendEnabled ? 1 : 0.25), in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(!isSendEnabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.v3MenuBg)
    }

    /// Admin closed the public room: lock the composer outright so a message the
    /// server would reject is never optimistically appended in the first place.
    /// 1v1 is never gated by this switch.
    private var isComposerLocked: Bool {
        (vm.isGlobal && !ShaftChatGateway.shared.globalSendEnabled) || vm.roomError != nil
    }

    private var inputHint: String {
        isComposerLocked && vm.roomError == nil
            ? l10n.t(.chatGlobalClosedHint)
            : l10n.t(.chatInputHint)
    }

    /// doc §12: connected + has text + not rate-limited + room open.
    private var isSendEnabled: Bool {
        guard !isComposerLocked, !vm.rateLimitCoolDown else { return false }
        guard case .connected = ShaftChatGateway.shared.state else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = draft
        Task {
            let accepted = await vm.sendText(text)
            guard accepted else {
                vm.showToast(vm.sendFailedText)
                return
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // Clearing the draft trips the `onChange(of: draft)` stop signal, so
            // no explicit `notifyTypingStop()` is needed here.
            draft = ""
            scrollToBottomOnNextUpdate = true
        }
    }

    // MARK: Emoji panel

    private func toggleEmojiPanel() {
        if showEmojiPanel {
            withAnimation(.easeOut(duration: 0.2)) { showEmojiPanel = false }
            inputFocused = true
        } else {
            inputFocused = false
            withAnimation(.easeOut(duration: 0.2)) { showEmojiPanel = true }
        }
    }

    /// Open the panel at exactly the height the keyboard just occupied, so the
    /// swap reads as a replacement rather than a resize. 270 is the upstream
    /// `BottomPanelCoordinator` fallback for "keyboard never shown yet".
    private var panelHeight: CGFloat {
        keyboardHeight > 0 ? keyboardHeight : ChatMetrics.emojiPanelFallbackHeight
    }

    /// The keyboard frame includes the home-indicator strip, which the composer
    /// already clears via the safe area — subtract it so the panel lines up.
    private static var bottomSafeAreaInset: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first(where: \.isKeyWindow)?.safeAreaInsets.bottom ?? 0
    }

    // MARK: Actions

    private func handle(_ action: ChatMessageAction, on message: ChatMessage) {
        switch action {
        case .copy:
            vm.copyToPasteboard(message)
        case .reply:
            // Upstream is a stub toast too (`DemoChatListFragment.handleMessageAction`).
            vm.showToast("\(l10n.t(.chatActionReply))（TODO）")
        case .forward:
            vm.showToast("\(l10n.t(.chatActionForward))（TODO）")
        case .delete:
            // Give the sheet a runloop turn to dismiss before the alert presents.
            Task { @MainActor in pendingDelete = message }
        }
    }

    // MARK: Toast

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = vm.toast {
            Text(toast)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.black.opacity(0.75), in: .capsule)
                .padding(.bottom, 90)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Bubble row
// ─────────────────────────────────────────────────────────────────────────────

/// One message row — port of `ChatMessageAdapter.BubbleHolder` plus both bubble
/// layouts. Two shapes dispatched on sender uid:
///
/// * **sent** (`msg.uid == selfUid`) — right-aligned brand-gradient bubble with
///   the tail on the top-trailing corner, self avatar on the right
/// * **received** — left-aligned surface bubble, tail top-leading, peer avatar
///   on the left, sender name above it in the public room only
///
/// Timestamps appear twice, exactly as upstream: a per-bubble `HH:mm` clock
/// under every message, and a centred time-group chip above the first message of
/// a new cluster (> 5 min gap or a new day).
private struct ChatBubbleRow: View {
    let row: ChatRowModel
    let selfUid: Int64
    let isGlobal: Bool
    let selfAvatarURL: URL?
    let peerAvatarURL: URL?
    let containerWidth: CGFloat
    let onLongPress: (ChatMessage) -> Void

    private var message: ChatMessage { row.message }
    private var isMine: Bool { message.isMine(selfUid: selfUid) }
    private var isJumbo: Bool { ChatEmoji.isJumbo(message.text) }
    private var gutter: CGFloat { ChatMetrics.gutter(forWidth: containerWidth) }
    /// Per-uid identity color; only meaningful for other people in the公屏.
    private var nameColor: Color { ChatPalette.nameColor(for: message.uid) }

    var body: some View {
        VStack(spacing: 0) {
            if row.showTimeGroup { timeGroupChip }
            if isMine { sentRow } else { receivedRow }
        }
        .padding(.horizontal, ChatMetrics.rowPaddingH)
        // Slack/Discord rhythm (`ChatMessageAdapter`): tight inside a same-sender
        // run, wider between runs, tightest right under a time chip.
        .padding(.top, row.showTimeGroup ? 4 : (row.isGroupStart ? 12 : 2))
        .padding(.bottom, 2)
        .contentShape(.rect)
        .onLongPressGesture(minimumDuration: 0.4) { onLongPress(message) }
    }

    // MARK: Time chip

    private var timeGroupChip: some View {
        Text(ChatTime.groupLabel(message.ts))
            .font(.system(size: ChatMetrics.timeSize))
            .foregroundStyle(Theme.v3Text3)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(ChatPalette.surface3, in: .rect(cornerRadius: 9))
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
    }

    // MARK: Sent

    private var sentRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: gutter)
            VStack(alignment: .trailing, spacing: 0) {
                bubble
                HStack(spacing: 3) {
                    if message.state == .failed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: ChatMetrics.stateIconSize))
                            .foregroundStyle(Theme.v3Danger)
                    }
                    Text(ChatTime.clock(message.ts))
                        .font(.system(size: ChatMetrics.timeSize))
                        .foregroundStyle(Theme.v3Text3)
                }
                .padding(.top, 3)
                .padding(.trailing, 4)
            }
            avatarSlot(url: selfAvatarURL, useMonogram: false)
                .padding(.leading, ChatMetrics.avatarGap)
        }
    }

    // MARK: Received

    private var receivedRow: some View {
        HStack(alignment: .top, spacing: 0) {
            avatarSlot(url: peerAvatarURL, useMonogram: isGlobal)
            VStack(alignment: .leading, spacing: 0) {
                // Sender name only in the public room — a 1v1 peer is already
                // named in the navigation bar — and only at a run's first message.
                if isGlobal, row.isGroupStart, let name = message.displayName, !name.isEmpty {
                    Text(name)
                        .font(.system(size: ChatMetrics.nameSize, weight: .bold))
                        .foregroundStyle(nameColor)
                        // `maxWidth="220dp"` upstream is a *cap*, not a fill;
                        // SwiftUI's `.frame(maxWidth:)` expands instead, which
                        // would stretch short bubbles, so the column's own
                        // gutter-derived limit does the clamping here.
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 4)
                        .padding(.bottom, 3)
                }
                bubble
                Text(ChatTime.clock(message.ts))
                    .font(.system(size: ChatMetrics.timeSize))
                    .foregroundStyle(Theme.v3Text3)
                    .padding(.leading, 4)
                    .padding(.top, 3)
            }
            .padding(.leading, ChatMetrics.avatarGap)
            Spacer(minLength: gutter)
        }
    }

    // MARK: Bubble

    @ViewBuilder
    private var bubble: some View {
        let content = Text(ChatEmoji.linkified(
            message.text,
            linkColor: isMine ? .white : Theme.brand
        ))
        .font(.system(size: isJumbo ? ChatMetrics.jumboTextSize : ChatMetrics.textSize))
        .lineSpacing(ChatMetrics.lineSpacing)
        .foregroundStyle(isMine ? Color.white : Theme.v3Text1)
        .textSelection(.disabled)

        Group {
            if isJumbo {
                // 1–3 bare emoji render jumbo & bubble-less (iMessage/Telegram).
                content
            } else if isMine {
                content
                    .padding(.horizontal, ChatMetrics.bubblePadH)
                    .padding(.vertical, ChatMetrics.bubblePadV)
                    .background(sentBubbleShape.fill(ChatPalette.sentGradient))
                    .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
            } else {
                content
                    .padding(.horizontal, ChatMetrics.bubblePadH)
                    .padding(.vertical, ChatMetrics.bubblePadV)
                    .background(receivedBubbleShape.fill(ChatPalette.receivedBubble))
                    .overlay(receivedBubbleShape.strokeBorder(Theme.v3Border2, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
            }
        }
        // Optimistic rows fade until the echo confirms them (doc §4.3).
        .opacity(isMine && message.state == .sending ? 0.6 : 1)
    }

    /// `cornerRadii = [18,18, 6,6, 18,18, 18,18]` — tail on the top-right.
    /// SwiftUI's leading/trailing naming mirrors correctly under RTL, which the
    /// Android absolute corners don't; that difference is an improvement, kept.
    private var sentBubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: ChatMetrics.bubbleRadius,
            bottomLeadingRadius: ChatMetrics.bubbleRadius,
            bottomTrailingRadius: ChatMetrics.bubbleRadius,
            topTrailingRadius: ChatMetrics.bubbleTailRadius
        )
    }

    /// `bg_chat_bubble_received.xml` — top-left collapses to 6dp (the tail next
    /// to the avatar), everything else 18dp, plus a 0.5dp hairline.
    private var receivedBubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: ChatMetrics.bubbleTailRadius,
            bottomLeadingRadius: ChatMetrics.bubbleRadius,
            bottomTrailingRadius: ChatMetrics.bubbleRadius,
            topTrailingRadius: ChatMetrics.bubbleRadius
        )
    }

    // MARK: Avatar

    /// Visible only at a run's first message; otherwise the slot stays as an
    /// invisible spacer so grouped bubbles keep their indent (Android uses
    /// `View.INVISIBLE` for exactly this).
    ///
    /// Tapping opens the sender's profile — upstream routes this through
    /// `UActivity`; here the registered `AppRoute.userProfile` link is the
    /// equivalent entry point.
    @ViewBuilder
    private func avatarSlot(url: URL?, useMonogram: Bool) -> some View {
        NavigationLink(value: AppRoute.userProfile(message.uid)) {
            avatarImage(url: url, useMonogram: useMonogram)
        }
        .buttonStyle(.plain)
        .opacity(row.isGroupStart ? 1 : 0)
        .allowsHitTesting(row.isGroupStart && message.uid > 0)
    }

    @ViewBuilder
    private func avatarImage(url: URL?, useMonogram: Bool) -> some View {
        Group {
            if let url {
                PixivAsyncImage(url: url, showsProgress: false, placeholder: Theme.v3Surface2)
                    .frame(width: ChatMetrics.avatarSize, height: ChatMetrics.avatarSize)
                    .clipShape(.circle)
            } else if useMonogram {
                // Anonymous public-room user: solid identity color + white
                // monogram instead of an empty grey circle.
                Circle()
                    .fill(nameColor)
                    .frame(width: ChatMetrics.avatarSize, height: ChatMetrics.avatarSize)
                    .overlay {
                        Text(ChatEmoji.monogram(message.displayName))
                            .font(.system(size: ChatMetrics.monogramSize, weight: .bold))
                            .foregroundStyle(.white)
                    }
            } else {
                Circle()
                    .fill(Theme.v3Surface2)
                    .frame(width: ChatMetrics.avatarSize, height: ChatMetrics.avatarSize)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Message actions sheet
// ─────────────────────────────────────────────────────────────────────────────

/// Port of `MessageActionsSheet` + `chat_sheet_message_actions.xml`: a 2-line
/// preview of the message, a hairline, then copy / reply / forward / delete rows
/// (`Chat.ActionRow` = 24pt horizontal, 14pt vertical, 24pt icon, 16pt gap).
private struct ChatMessageActionsSheet: View {
    let message: ChatMessage
    let onAction: (ChatMessageAction) -> Void

    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(message.text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.v3Text2)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Rectangle()
                .fill(Theme.v3Border1)
                .frame(height: 1)
                .padding(.horizontal, 16)

            actionRow(.copy, title: l10n.t(.chatActionCopy), icon: "doc.on.doc")
            actionRow(.reply, title: l10n.t(.chatActionReply), icon: "arrowshape.turn.up.left")
            actionRow(.forward, title: l10n.t(.chatActionForward), icon: "arrowshape.turn.up.right")
            actionRow(.delete, title: l10n.t(.chatActionDelete), icon: "trash", tint: Theme.v3Danger)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.v3MenuBg)
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.v3MenuBg)
    }

    private func actionRow(
        _ action: ChatMessageAction,
        title: String,
        icon: String,
        tint: Color = Theme.v3Text1
    ) -> some View {
        Button {
            onAction(action)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .frame(width: 24, height: 24)
                Text(title)
                    .font(.system(size: 16))
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Emoji panel
// ─────────────────────────────────────────────────────────────────────────────

/// Port of `EmojiPanelView`: an 8-column grid of 44pt cells at 26pt, 8pt inset,
/// sized to stand in for the soft keyboard.
private struct ChatEmojiPanel: View {
    let height: CGFloat
    let onPick: (String) -> Void

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: 0), count: 8
    )

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 0) {
                ForEach(Self.emojis, id: \.self) { emoji in
                    Button {
                        onPick(emoji)
                    } label: {
                        Text(emoji)
                            .font(.system(size: 26))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .frame(height: height)
        .background(Theme.v3MenuBg)
    }

    /// `EmojiPanelView.EMOJIS`, verbatim and in order.
    static let emojis: [String] = [
        "😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂",
        "🙂", "😊", "😇", "🥰", "😍", "🤩", "😘", "😗",
        "😋", "😛", "😜", "🤪", "😝", "🤑", "🤗", "🤭",
        "🤫", "🤔", "😐", "😑", "😶", "😏", "😒", "🙄",
        "😬", "😮‍💨", "🤥", "😌", "😔", "😪", "🤤", "😴",
        "😷", "🤒", "🤕", "🤢", "🤮", "🥵", "🥶", "🥴",
        "😵", "🤯", "🤠", "🥳", "🥺", "😢", "😭", "😤",
        "😠", "😡", "🤬", "💀", "💩", "🤡", "👹", "👻",
        "👍", "👎", "👏", "🙏", "🤝", "💪", "✌️", "🤞",
        "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍",
        "🔥", "⭐", "🌈", "☀️", "🌙", "🎉", "🎊", "✨",
    ]
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Text helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Text-shaping helpers lifted from `ChatMessageAdapter`'s companion object.
private enum ChatEmoji {

    /// True when the message is 1–3 emoji and nothing else — rendered jumbo and
    /// bubble-less. Modifiers (ZWJ, variation selectors, skin tones, keycaps,
    /// regional indicators) and whitespace are tolerated; any real text
    /// disqualifies it. Ranges copied from `isEmojiScalar` so both platforms
    /// agree on the exact same set.
    static func isJumbo(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.utf16.count <= 24 else { return false }
        var hasEmoji = false
        for scalar in s.unicodeScalars {
            let cp = scalar.value
            if isEmojiScalar(cp) || (0x1F1E6...0x1F1FF).contains(cp) {
                hasEmoji = true
            } else if cp == 0x200D || cp == 0xFE0F || cp == 0xFE0E || cp == 0x20E3 {
                continue                                    // joiners / selectors
            } else if (0x1F3FB...0x1F3FF).contains(cp) {
                continue                                    // skin-tone modifiers
            } else if scalar.properties.isWhitespace {
                continue
            } else {
                return false
            }
        }
        // `String.count` is the grapheme count — Kotlin needed a BreakIterator.
        return hasEmoji && (1...3).contains(s.count)
    }

    private static func isEmojiScalar(_ cp: UInt32) -> Bool {
        (0x1F300...0x1FAFF).contains(cp) ||
        (0x1F000...0x1F0FF).contains(cp) ||
        (0x2600...0x27BF).contains(cp) ||
        (0x2B00...0x2BFF).contains(cp) ||
        (0x231A...0x231B).contains(cp) ||
        (0x23E9...0x23FA).contains(cp) ||
        cp == 0x24C2 ||
        (0x25AA...0x25FF).contains(cp) ||
        (0x2934...0x2935).contains(cp)
    }

    /// First grapheme of a display name, for the anonymous-avatar monogram.
    static func monogram(_ name: String?) -> String {
        guard let name, let first = name.first else { return "?" }
        return String(first)
    }

    /// `LinkifyCompat.addLinks(tv, Linkify.WEB_URLS)` equivalent. Android's
    /// `URLSpan` underlines and takes the link color; `NSDataDetector` also
    /// catches `mailto:` targets, which is a small superset and harmless.
    static func linkified(_ text: String, linkColor: Color) -> AttributedString {
        var attributed = AttributedString(text)
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return attributed }
        let full = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: full) {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: text),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(stringRange.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].link = url
            attributed[lower..<upper].foregroundColor = linkColor
            attributed[lower..<upper].underlineStyle = .single
        }
        return attributed
    }
}

/// Timestamp formatting — port of `ChatMessageAdapter.clock` / `sameDay` /
/// `timeGroupLabel`.
private enum ChatTime {

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let sameYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    private static let otherYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/M/d HH:mm"
        return f
    }()

    /// Localized "Today" / "Yesterday". Android reads `R.string.timeline_today`
    /// / `timeline_yesterday`; there's no matching `LocalizedKey` on iOS and
    /// this file may not add one, so the system's own relative-date vocabulary
    /// stands in — which has the side benefit of covering all seven languages
    /// the app ships rather than just zh/en.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .named
        f.unitsStyle = .full
        return f
    }()

    static func date(_ ts: Int64) -> Date { Date(timeIntervalSince1970: Double(ts) / 1000) }

    static func clock(_ ts: Int64) -> String { clockFormatter.string(from: date(ts)) }

    static func sameDay(_ a: Int64, _ b: Int64) -> Bool {
        Calendar.current.isDate(date(a), inSameDayAs: date(b))
    }

    /// `今天 14:30` / `昨天 14:30` / `3/9 14:30` / `2024/3/9 14:30`.
    static func groupLabel(_ ts: Int64) -> String {
        let d = date(ts)
        let cal = Calendar.current
        let time = clock(ts)
        if cal.isDateInToday(d) {
            return "\(relative(days: 0)) \(time)"
        }
        if cal.isDateInYesterday(d) {
            return "\(relative(days: -1)) \(time)"
        }
        if cal.component(.year, from: d) == cal.component(.year, from: Date()) {
            return sameYearFormatter.string(from: d)
        }
        return otherYearFormatter.string(from: d)
    }

    private static func relative(days: Int) -> String {
        relativeFormatter.localizedString(from: DateComponents(day: days)).localizedCapitalized
    }
}

private extension View {
    /// Turns off the iOS 26 scroll-edge effect on every edge; a no-op on iOS 18.
    @ViewBuilder
    func flippedListEdgeEffectDisabled() -> some View {
        if #available(iOS 26, *) {
            scrollEdgeEffectStyle(nil, for: .all)
        } else {
            self
        }
    }
}

/// iOS 26 attaches a `UIScrollEdgeEffect` to the hosting `UIScrollView` for the
/// navigation bar. Its blur mask is computed in the scroll view's own
/// coordinate space, so on our flipped list it covers the whole viewport instead
/// of the strip under the bar. The SwiftUI `scrollEdgeEffectStyle(nil)` modifier
/// doesn't reach that UIKit object, so this probe walks up to the enclosing
/// scroll view and hides the effects directly. No-op on iOS 18.
private struct FlippedScrollEdgeEffectKiller: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.apply() }

    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }
        func apply() {
            guard #available(iOS 26, *) else { return }
            var v: UIView? = superview
            while let cur = v, !(cur is UIScrollView) { v = cur.superview }
            guard let scroll = v as? UIScrollView else { return }
            scroll.topEdgeEffect.isHidden = true
            scroll.bottomEdgeEffect.isHidden = true
            scroll.leftEdgeEffect.isHidden = true
            scroll.rightEdgeEffect.isHidden = true
        }
    }
}
