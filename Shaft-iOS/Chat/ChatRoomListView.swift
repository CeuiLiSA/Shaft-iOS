import SwiftUI

// MARK: - Error projection

/// Swift stand-in for Android `ceui.pixiv.chat.core.AppError` + its
/// `toUserMessage(Context)` extension, collapsed into one value type.
///
/// Only the parts this screen can actually produce are modelled: the
/// conversation list talks to exactly one endpoint (`/chat/conversations`), so
/// the full 15-case sealed hierarchy would be dead code here. What *is* kept
/// 1:1 is the triple the UI reads — `httpCode` (drives the big status number in
/// `chat_view_state_error.xml`), `isRetryable` (hides the retry button on auth
/// errors, `StateLayout.showError`), and the localized message.
struct ChatUiError: Equatable {
    /// HTTP status for HTTP-originated failures; `nil` for network/decode.
    let httpCode: Int?
    /// Auth errors (401/403) need a re-login, not a retry — `AppError.isRetryable`.
    let isRetryable: Bool
    let messageKey: LocalizedKey

    /// `OnboardingStore` is main-actor isolated, so this resolver is too — every
    /// caller is a `View` body anyway.
    @MainActor
    func message(_ l10n: OnboardingStore) -> String { l10n.t(messageKey) }

    /// Mirrors Android's `Throwable.toAppError()` mapping table.
    static func from(_ error: Error) -> ChatUiError {
        if let apiError = error as? ChatAPIError {
            switch apiError {
            case .http(let code, _):
                return fromHTTP(code)
            case .decode:
                return ChatUiError(httpCode: nil, isRetryable: false, messageKey: .chatErrorSerialization)
            case .notLoggedIn:
                return ChatUiError(httpCode: 401, isRetryable: false, messageKey: .chatErrorUnauthorized)
            case .hmacDisabled, .badURL:
                return ChatUiError(httpCode: nil, isRetryable: false, messageKey: .chatErrorUnknown)
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return ChatUiError(httpCode: nil, isRetryable: true, messageKey: .chatErrorRequestTimeout)
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .clientCertificateRejected:
                return ChatUiError(httpCode: nil, isRetryable: false, messageKey: .chatErrorSecurity)
            default:
                return ChatUiError(httpCode: nil, isRetryable: true, messageKey: .chatErrorNetworkUnavailable)
            }
        }
        return ChatUiError(httpCode: nil, isRetryable: false, messageKey: .chatErrorUnknown)
    }

    private static func fromHTTP(_ code: Int) -> ChatUiError {
        switch code {
        case 401: return ChatUiError(httpCode: 401, isRetryable: false, messageKey: .chatErrorUnauthorized)
        case 403: return ChatUiError(httpCode: 403, isRetryable: false, messageKey: .chatErrorForbidden)
        case 404: return ChatUiError(httpCode: 404, isRetryable: false, messageKey: .chatErrorNotFound)
        case 410: return ChatUiError(httpCode: 410, isRetryable: false, messageKey: .chatErrorGone)
        // Retry-After isn't surfaced by ShaftChatAPI, so the "in %@s" variant
        // (`chatErrorRateLimitedWithDelay`) can't be filled in truthfully here.
        case 429: return ChatUiError(httpCode: 429, isRetryable: true, messageKey: .chatErrorRateLimited)
        case 503: return ChatUiError(httpCode: 503, isRetryable: true, messageKey: .chatErrorServiceUnavailable)
        case 500...599: return ChatUiError(httpCode: code, isRetryable: true, messageKey: .chatErrorServiceUnavailable)
        default: return ChatUiError(httpCode: code, isRetryable: false, messageKey: .chatErrorUnknown)
        }
    }
}

// MARK: - View model

/// Conversation-list state holder — 1:1 port of Android
/// `ceui.pixiv.chat.vm.ChatRoomListViewModel`.
///
/// Same responsibilities, same invariants:
///   - `items`       — rows visible right now (global pinned first, DMs by recency)
///   - `nextCursor`  — server pagination cursor; `nil` once exhausted
///   - `loadingMore` — guards re-entrant pagination
///   - `hasUnknownRoomSinceLastRefresh` — a WS msg landed in a room we don't
///     hold locally; the next refresh pulls the authoritative row (the server
///     owns `last_message.id` + `peer_display_name`, which we'd have to invent)
///
/// Avatar resolution keeps Android's three-state cache:
///   absent → never fetched · present-with-nil → fetched, no avatar (don't
///   hammer until the next refresh) · present-with-url → bind on the row.
///
/// **Divergences from Android, all deliberate:**
/// 1. Android's VM has *no* loading/error state at all — the fragment doesn't
///    use `StateLayout` (see `chat_fragment_room_list.xml`'s header comment: it
///    would drag in a Material3 theme dependency) and `refresh()` merely logs on
///    failure. iOS has no such constraint, so `loadState` drives the four-state
///    surface the rest of the chat stack (`PageState` / `chat_view_state_*.xml`)
///    already specifies. A failed refresh with rows on screen still keeps the
///    rows, exactly like Android.
/// 2. `refresh()` / `loadMore()` are `async` instead of launching into a
///    `viewModelScope`: SwiftUI's `.task` already owns the "cancel when the
///    screen goes away" half of `viewModelScope`, and `refreshing` /
///    `loadingMore` cover the re-entrancy half that Android got from
///    `loadJob?.cancel()`.
/// 3. `onRoomTapped` also fires `/read`; see its doc for why.
@MainActor
@Observable
final class ChatRoomListVM {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(ChatUiError)
    }

    /// What the content area should render. Rows always win: a background
    /// refresh that fails must not blank a populated list.
    enum Phase: Equatable {
        case loading
        case content
        case empty
        case error(ChatUiError)
    }

    private(set) var items: [ChatRoomEntry] = []
    private(set) var nextCursor: String?
    private(set) var loadingMore = false
    /// Pagination failure — renders the `chat_item_list_error.xml` footer.
    private(set) var footerError: ChatUiError?
    private(set) var loadState: LoadState = .idle
    private(set) var hasUnknownRoomSinceLastRefresh = false

    /// Signed-in pixiv uid — Android's `SessionManager.loggedInUid`. Read from
    /// the keychain rather than `AuthViewModel` because this route is pushed
    /// without that environment object.
    ///
    /// Cached at init: `KeychainTokenStore.load()` is a `SecItemCopyMatching`
    /// plus a full token decode, and this is read once per row per render pass
    /// (`previewText`) and once per inbound broadcast (`onWsMsg`). A recomputed
    /// property turned a busy global room into a keychain hammer. The uid can't
    /// change without the whole screen being torn down — logging out pops the
    /// navigation stack.
    let selfUid: Int64 = KeychainTokenStore.shared.load()?.user?.id ?? 0

    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var avatarCache: [Int64: String?] = [:]
    @ObservationIgnored private var pendingAvatarFetches: Set<Int64> = []
    @ObservationIgnored private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)

    var phase: Phase {
        if !items.isEmpty { return .content }
        switch loadState {
        case .idle, .loading: return .loading
        case .failed(let error): return .error(error)
        case .loaded: return .empty
        }
    }

    // MARK: Loading

    /// Pull page 1 — the authoritative refresh, run on every appearance
    /// (Android: `onResume`). Picks up unread changes from `/read` calls made on
    /// another device, new DMs, and rows that expired server-side.
    func refresh() async {
        let uid = selfUid
        guard uid > 0 else {
            ChatLog.warn("refresh: not logged in (uid=\(uid)) — skip")
            items = []
            nextCursor = nil
            footerError = nil
            loadState = .loaded          // Android: `_state.update { UiState() }`
            return
        }
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        // Only the very first paint gets a spinner; a refresh behind existing
        // rows is silent, matching Android (which has no loading state at all).
        if items.isEmpty { loadState = .loading }
        do {
            let page = try await ShaftChatAPI.shared.listConversations(uid: uid, cursor: nil, limit: 50)
            try Task.checkCancellation()
            let entries = page.items.map(ShaftChatAPI.entry(from:)).map(applyCachedAvatar)
            items = entries
            nextCursor = page.next_cursor
            loadingMore = false
            footerError = nil
            hasUnknownRoomSinceLastRefresh = false
            loadState = .loaded
            ensureAvatars(entries)
        } catch is CancellationError {
            // Screen went away mid-flight — leave the state untouched.
        } catch {
            ChatLog.warn("refresh failed: \(error)")
            loadState = .failed(ChatUiError.from(error))
        }
    }

    /// Append the next page when a cursor is available and nothing is in flight.
    func loadMore() async {
        guard !loadingMore, footerError == nil, let cursor = nextCursor else { return }
        let uid = selfUid
        guard uid > 0 else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await ShaftChatAPI.shared.listConversations(uid: uid, cursor: cursor, limit: 50)
            try Task.checkCancellation()
            let newItems = page.items.map(ShaftChatAPI.entry(from:)).map(applyCachedAvatar)
            // Server contract: page 2+ never repeats `global`. Plain append —
            // but dedup by room anyway, which is what Android's DiffUtil
            // `keySelector = { it.room }` bought it for free.
            let known = Set(items.map(\.room))
            items.append(contentsOf: newItems.filter { !known.contains($0.room) })
            nextCursor = page.next_cursor
            ensureAvatars(newItems)
        } catch is CancellationError {
        } catch {
            ChatLog.warn("loadMore failed: \(error)")
            footerError = ChatUiError.from(error)
        }
    }

    /// Footer "加载失败,点击重试" tap — `PagingFooterAdapter.onRetry`.
    func retryLoadMore() async {
        footerError = nil
        await loadMore()
    }

    // MARK: WS optimistic updates

    /// Apply optimistic UI changes when a WS msg lands — line-for-line with
    /// Android `onWsMsg`:
    ///  - known room → bump preview / unread / move to top
    ///  - unknown room → flag for the next refresh
    func onWsMsg(_ frame: ChatMsgFrame) {
        guard let idx = items.firstIndex(where: { $0.room == frame.room }) else {
            hasUnknownRoomSinceLastRefresh = true
            return
        }
        var updated = items[idx]
        // Global has no server-tracked unread count, and our own echo must never
        // bump one.
        let bumpUnread = updated.kind == .oneOnOne && frame.uid != selfUid
        updated.previewText = frame.text ?? ""
        updated.previewSenderUid = frame.uid
        updated.previewSenderDisplayName = frame.displayName
        updated.lastTs = frame.ts
        if bumpUnread { updated.unreadCount += 1 }

        // Move the bumped row to the top — after global, which is index 0 when present.
        var rest = items
        rest.remove(at: idx)
        let insertAt = (rest.first?.kind == .global) ? 1 : 0
        rest.insert(updated, at: min(insertAt, rest.count))
        items = rest
    }

    // MARK: Interaction

    /// The user tapped a row. Clears the local unread badge so it doesn't linger
    /// while the thread opens (Android `onRoomTapped`).
    ///
    /// **Divergence:** Android leaves the `/read` POST to the chat fragment
    /// (`DemoChatListFragment.observeMarkRead`). Here the list fires it too, as
    /// a best-effort, because the optimistic zeroing would otherwise be undone
    /// by the very next `refresh()` if the thread screen hadn't gotten around to
    /// its own call yet. It's safe to double-send: the server recomputes the
    /// count from `chat_messages` rather than trusting the client, and the call
    /// no-ops for global.
    func onRoomTapped(_ entry: ChatRoomEntry) {
        guard let idx = items.firstIndex(where: { $0.room == entry.room }) else { return }
        let row = items[idx]
        guard row.unreadCount > 0 else { return }
        items[idx].unreadCount = 0

        let uid = selfUid
        guard row.kind == .oneOnOne, let lastMessageId = row.lastMessageId, uid > 0 else { return }
        Task {
            do {
                _ = try await ShaftChatAPI.shared.markRead(
                    uid: uid, room: row.room, lastReadMessageId: lastMessageId
                )
            } catch {
                ChatLog.warn("markRead failed for room=\(row.room): \(error)")
            }
        }
    }

    // MARK: Avatar resolution

    private func applyCachedAvatar(_ entry: ChatRoomEntry) -> ChatRoomEntry {
        guard let peer = entry.peerUid, let cached = avatarCache[peer] else { return entry }
        var copy = entry
        copy.avatarUrl = cached
        return copy
    }

    /// Lazily fill `avatarUrl` from pixiv's user detail — Android
    /// `ensureAvatars`. Deduped by `pendingAvatarFetches` + `avatarCache` so a
    /// refresh (or a second page carrying the same peer) never re-queries a uid
    /// already resolved, including one resolved to "no avatar".
    private func ensureAvatars(_ entries: [ChatRoomEntry]) {
        let toFetch = Set(entries.compactMap(\.peerUid))
            .filter { avatarCache.index(forKey: $0) == nil && !pendingAvatarFetches.contains($0) }
        guard !toFetch.isEmpty else { return }
        for peer in toFetch {
            pendingAvatarFetches.insert(peer)
            Task { [weak self] in
                guard let self else { return }
                var url: String?
                do {
                    url = try await self.api.userDetail(peer).user.profileImageUrls?.chatMaxSizeUrl
                } catch {
                    ChatLog.debug("avatar fetch failed for uid=\(peer): \(error)")
                }
                self.pendingAvatarFetches.remove(peer)
                self.avatarCache[peer] = url
                guard let url else { return }
                for idx in self.items.indices
                where self.items[idx].peerUid == peer && self.items[idx].avatarUrl == nil {
                    self.items[idx].avatarUrl = url
                }
            }
        }
    }
}

private extension ImageUrls {
    /// `ceui.loxia.ImageUrls.findMaxSizeUrl()` — same priority order.
    var chatMaxSizeUrl: String? {
        url ?? original ?? large ?? medium ?? squareMedium ?? small ?? px170x170 ?? px50x50
    }
}

// MARK: - Screen

/// Conversation list (chat home) — port of `ChatRoomListFragment` +
/// `chat_fragment_room_list.xml`.
///
/// V3 chrome: a large-title header on `v3_bg` (back + 聊天室 + conversation
/// count) rather than a nav bar, and a divider-less list whose one public room
/// is a theme-gradient hero card.
///
/// The system navigation bar is hidden (as in `IllustDetailView` /
/// `UserProfileView`) so the 28pt large title can own the top of the screen the
/// way the Android header does; `RouteHost` already attaches `SwipeBackEnabler`
/// to every pushed route, so edge-swipe-back survives. The status-bar area is
/// handled by the safe area — the equivalent of Android's `head` spacer being
/// stretched to `BarUtils.getStatusBarHeight()`.
struct ChatRoomListView: View {
    @State private var vm = ChatRoomListVM()
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.v3Bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        // Android's authoritative `onResume` refresh. `.task` re-runs when the
        // page reappears after a push is popped, which is the same moment.
        .task { await vm.refresh() }
        // …and `onResume` also fires when the app returns from background, which
        // `.task` alone does not cover.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await vm.refresh() } }
        }
        // WS-driven optimistic updates while the list is visible — Android's
        // `repeatOnLifecycle(STARTED)` collect on `ShaftChatGateway.incoming`.
        // Decoding already happened in the gateway, so unlike Android we filter
        // rather than decode here.
        .task {
            for await frame in ShaftChatGateway.shared.frames() {
                if case .msg(let msg) = frame { vm.onWsMsg(msg) }
            }
        }
    }

    // MARK: Header

    /// `chat_fragment_room_list.xml`: a 48dp back-button bar (start padding 8,
    /// 44dp borderless button) over a 20dp-inset title block — 28sp bold title
    /// with -0.03em tracking, plus a 13sp `v3_text_3` subtitle that is GONE
    /// while the list is empty.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "arrow.backward")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Theme.v3Text1)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(l10n.t(.chatActionBack)))   // android:contentDescription
                Spacer(minLength: 0)
            }
            .frame(height: 48)
            .padding(.leading, 8)
            .padding(.trailing, 16)

            VStack(alignment: .leading, spacing: 0) {
                Text(l10n.t(.chatDrawerEntry))
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.84)                    // 28sp × -0.03em
                    .foregroundStyle(Theme.v3Text1)
                if !vm.items.isEmpty {
                    Text(l10n.t(.chatRoomCount, "\(vm.items.count)"))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.v3Text3)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch vm.phase {
        case .loading:
            ChatStateLoadingView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let error):
            ChatStateErrorView(error: error) { Task { await vm.refresh() } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ChatStateEmptyView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .content:
            list
        }
    }

    /// `RecyclerView` with `paddingTop=4dp` / `paddingBottom=8dp`; the
    /// navigation-bar inset Android applies by hand is the scroll view's own
    /// safe-area inset here.
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(vm.items.enumerated()), id: \.element.room) { index, entry in
                    row(for: entry)
                        // "~5 rows before the bottom" — Android's
                        // `last >= total - 5` scroll listener.
                        .onAppear {
                            if index >= vm.items.count - 5 {
                                Task { await vm.loadMore() }
                            }
                        }
                }
                if vm.loadingMore {
                    ChatPagingLoadingFooter()
                } else if let error = vm.footerError {
                    ChatPagingErrorFooter(error: error) { Task { await vm.retryLoadMore() } }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .refreshable { await vm.refresh() }
    }

    /// `getDataItemViewType`: `TYPE_HERO` for the one public room, `TYPE_ROW`
    /// for DMs.
    @ViewBuilder
    private func row(for entry: ChatRoomEntry) -> some View {
        let localized = localizedTitle(entry)
        if let route = route(for: entry) {
            NavigationLink(value: route) {
                cell(localized)
            }
            // NavigationLink has no action hook, and the unread badge must clear
            // on the same tap that pushes the thread. A simultaneous gesture is
            // the only way to observe it without hand-rolling the push (we don't
            // own the stack's `path` here).
            .simultaneousGesture(TapGesture().onEnded { vm.onRoomTapped(entry) })
            .buttonStyle(entry.kind == .global ? AnyButtonStyle(ChatHeroPressStyle())
                                               : AnyButtonStyle(ChatRowPressStyle()))
        } else {
            // A DM row whose `peer_uid` the server couldn't reverse-derive.
            // Android would launch the chat fragment with no peer extra (and a
            // dead composer); `AppRoute.chatThread(peerUid: nil, …)` means
            // *global* on iOS, so opening it would be actively wrong — the row
            // renders but doesn't navigate.
            cell(localized)
        }
    }

    @ViewBuilder
    private func cell(_ entry: ChatRoomEntry) -> some View {
        if entry.kind == .global {
            ChatRoomHeroCard(entry: entry, preview: previewText(entry))
        } else {
            ChatRoomRow(entry: entry, preview: previewText(entry))
        }
    }

    private func route(for entry: ChatRoomEntry) -> AppRoute? {
        switch entry.kind {
        case .global:
            return .chatThread(peerUid: nil, title: l10n.t(.chatRoomGlobalTitle))
        case .oneOnOne:
            guard let peer = entry.peerUid, peer > 0 else { return nil }
            return .chatThread(peerUid: peer, title: localizedTitle(entry).title)
        }
    }

    /// Swap the repository's `"__global__"` sentinel for the locale-aware title.
    /// Kept in the view for the same reason Android keeps it in the fragment:
    /// string lookup needs the localization context, and the VM shouldn't own one.
    private func localizedTitle(_ entry: ChatRoomEntry) -> ChatRoomEntry {
        guard entry.title == ShaftChatAPI.conventionGlobalTitle else { return entry }
        var copy = entry
        copy.title = l10n.t(.chatRoomGlobalTitle)
        return copy
    }

    /// `ChatRoomListAdapter.buildPreview` — "你: " for our own messages,
    /// "<sender>: <text>" on global rows from someone else, plain text for DMs
    /// (the row title already names the peer), and "—" for an empty room.
    private func previewText(_ entry: ChatRoomEntry) -> String {
        let body = entry.previewText
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "—" }
        if let sender = entry.previewSenderUid, sender == vm.selfUid {
            return "\(l10n.t(.chatPreviewYouPrefix)) \(body)"
        }
        if entry.kind == .global, let name = entry.previewSenderDisplayName, !name.isEmpty {
            return "\(name): \(body)"
        }
        return body
    }
}

// MARK: - Hero cell (the public room)

/// `chat_item_room_hero.xml` — the single public room, rendered as a theme
/// gradient flagship card so it doesn't read as "just another row".
///
/// The gradient is `V3Palette.seriesIconBg`: `primary → hueShift(primary, 40°)`
/// on a `BL_TR` axis (bottom-leading → top-trailing), 24dp corners. Android
/// derives `primary` from `Shaft.getThemeColor()` because the app ships ten
/// theme presets plus a custom HEX; iOS has one brand color, so `Theme.brand`
/// stands in directly. Whites on the card are fixed in both light and dark —
/// the card底 is always the brand gradient.
private struct ChatRoomHeroCard: View {
    let entry: ChatRoomEntry
    let preview: String

    var body: some View {
        HStack(spacing: 0) {
            // Glass circle: 18 %-white (#2EFFFFFF) disc + white globe.
            ZStack {
                Circle().fill(Color.white.opacity(0x2E / 255.0))
                Image(systemName: "globe")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 27, height: 27)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(entry.title)
                        .font(.system(size: 17, weight: .bold))
                        .tracking(-0.17)                 // 17sp × -0.01em
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let time = ChatRelativeTime.format(entry.lastTs) {
                        Text(time)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0xB3 / 255.0))
                            .fixedSize()
                    }
                }
                Text(preview)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0xD9 / 255.0))
                    .lineLimit(1)
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 14)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0x80 / 255.0))
                .frame(width: 20, height: 20)
                .padding(.leading, 6)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Theme.brand, Theme.brand.hueShifted(40)],
                startPoint: .bottomLeading, endPoint: .topTrailing
            ),
            in: .rect(cornerRadius: 24)
        )
        // `android:elevation="3dp"` — the shadow follows the rounded outline.
        .shadow(color: Color.black.opacity(0.18), radius: 5, x: 0, y: 3)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

// MARK: - DM cell

/// `chat_item_room.xml` — divider-less DM row: 20dp start inset (aligned with
/// the header title), 10dp vertical breathing room, 54dp avatar.
///
/// Unread state is expressed three ways, exactly as upstream: the avatar ring
/// turns brand-colored (read rows keep a `v3_border_2` hairline), the preview
/// text reads at `v3_text_1` full strength instead of muted `v3_text_2`, and a
/// brand pill carries the count.
private struct ChatRoomRow: View {
    let entry: ChatRoomEntry
    let preview: String

    private var unread: Bool { entry.unreadCount > 0 }

    var body: some View {
        HStack(spacing: 0) {
            ChatAvatarView(url: entry.avatarUrl, ringColor: unread ? Theme.brand : Theme.v3Border2)
                .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(entry.title)
                        .font(.system(size: 15, weight: .bold))
                        .tracking(-0.15)                 // 15sp × -0.01em
                        .foregroundStyle(Theme.v3Text1)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let time = ChatRelativeTime.format(entry.lastTs) {
                        Text(time)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.v3Text3)
                            .fixedSize()
                    }
                }
                HStack(spacing: 10) {
                    Text(preview)
                        .font(.system(size: 13))
                        .foregroundStyle(unread ? Theme.v3Text1 : Theme.v3Text2)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if unread {
                        ChatUnreadPill(count: entry.unreadCount)
                    }
                }
                .padding(.top, 4)
            }
            .padding(.leading, 14)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contentShape(.rect)
    }
}

/// 54dp circle avatar with `civ_border_width="2dp"`. The border is stroked
/// *inside* the bounds, like `CircleImageView` draws it.
///
/// `PixivAsyncImage` supplies the pximg referer/UA pair. When no URL has been
/// resolved yet we draw the plain disc ourselves rather than handing the image
/// view a nil URL — that path renders a "broken photo" glyph, whereas Android's
/// `chat_avatar_placeholder` is a flat oval.
private struct ChatAvatarView: View {
    let url: String?
    let ringColor: Color

    var body: some View {
        Group {
            if let url, let parsed = URL(string: url) {
                PixivAsyncImage(url: parsed, showsProgress: false, placeholder: Theme.lightBg)
            } else {
                Rectangle().fill(Theme.lightBg)
            }
        }
        .clipShape(.circle)
        .overlay(Circle().strokeBorder(ringColor, lineWidth: 2))
    }
}

/// The unread count pill: `V3Palette.pillPrimary(10dp)`, 20dp tall, 20dp min
/// width, 7dp horizontal padding, 11sp bold white. `>99` collapses to `99+`.
private struct ChatUnreadPill: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(minWidth: 20, minHeight: 20)
            .background(Theme.brand, in: .rect(cornerRadius: 10))
            .fixedSize()
    }
}

// MARK: - Paging footers

/// `chat_item_list_loading.xml`: 16dp side margins / 8dp vertical, 12dp corner,
/// 1dp hairline, 20dp inner padding, 32dp indicator, 12dp gap to the label.
private struct ChatPagingLoadingFooter: View {
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
                .tint(Theme.brand)
                .frame(width: 32, height: 32)
            Text(l10n.t(.chatListLoadingMore))
                .font(.system(size: 12))
                .foregroundStyle(Theme.v3Text2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.v3Border2, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// `chat_item_list_error.xml`: same card, error-tinted hairline, 28dp icon, and
/// a tonal retry button — shown only for a retryable error, mirroring
/// `PagingFooterAdapter.onBindViewHolder`'s `error.isRetryable` gate.
private struct ChatPagingErrorFooter: View {
    let error: ChatUiError
    let retry: () -> Void
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(Theme.v3Danger)
                .frame(width: 28, height: 28)
            Text(l10n.t(.chatListLoadError))
                .font(.system(size: 12))
                .foregroundStyle(Theme.v3Text2)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            if error.isRetryable {
                Button(l10n.t(.chatStateRetry), action: retry)
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.bordered)
                    .tint(Theme.brand)
                    .frame(height: 36)
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.v3Danger.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Full-screen states

/// `chat_view_state_loading.xml` — 40dp spinner over a 14sp bold accent label.
private struct ChatStateLoadingView: View {
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.brand)
                .frame(width: 40, height: 40)
            Text(l10n.t(.chatStateLoadingDefault))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.brand)
        }
    }
}

/// `chat_view_state_error.xml` via `StateLayout.showError`: a 64sp status number
/// for HTTP failures, a faded 64dp icon otherwise, the message, and a retry
/// button that hides for non-retryable errors (401/403 need a re-login).
private struct ChatStateErrorView: View {
    let error: ChatUiError
    let retry: () -> Void
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            if let code = error.httpCode {
                Text("\(code)")
                    .font(.system(size: 64, weight: .black))
                    .foregroundStyle(Theme.v3Danger)
                    .padding(.bottom, 8)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Theme.v3Text2)
                    .opacity(0.5)
                    .frame(width: 64, height: 64)
                    .padding(.bottom, 16)
            }
            Text(error.message(l10n))
                .font(.system(size: 14))
                .foregroundStyle(Theme.v3Text2)
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)
            if error.isRetryable {
                Button(l10n.t(.chatStateRetry), action: retry)
                    .buttonStyle(.bordered)
                    .tint(Theme.brand)
            }
        }
        .padding(24)
    }
}

/// `EmptyStateView` defaults: 64dp icon at 50 % opacity, 18sp title, 24dp padding.
/// The subtitle and action slots stay unused — this screen never sets them.
private struct ChatStateEmptyView: View {
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 52))
                .foregroundStyle(Theme.v3Text2)
                .opacity(0.5)
                .frame(width: 64, height: 64)
                .padding(.bottom, 16)
            Text(l10n.t(.chatStateEmptyDefault))
                .font(.system(size: 18))
                .foregroundStyle(Theme.v3Text1)
        }
        .padding(24)
    }
}

// MARK: - Relative time

enum ChatRelativeTime {
    /// `DateUtils.getRelativeTimeSpanString(ts, now, MINUTE_IN_MILLIS,
    /// FORMAT_ABBREV_RELATIVE)`.
    ///
    /// Returns `nil` for `ts == 0` (no message yet), where Android binds "".
    ///
    /// The `minResolution = MINUTE_IN_MILLIS` argument is the subtle part:
    /// Android *never* prints "刚刚" for a fresh message, it floors to one
    /// minute. `RelativeDateTimeFormatter` would say "now", so anything younger
    /// than a minute is clamped to exactly one minute old.
    static func format(_ tsMillis: Int64) -> String? {
        guard tsMillis > 0 else { return nil }
        let now = Date()
        let date = Date(timeIntervalSince1970: Double(tsMillis) / 1000)
        let clamped = min(date, now.addingTimeInterval(-60))
        return formatter.localizedString(for: clamped, relativeTo: now)
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated          // FORMAT_ABBREV_RELATIVE
        return f
    }()
}

// MARK: - Press feedback

/// `@animator/button_press_scale` on the hero card — 0.95 scale while pressed,
/// `config_shortAnimTime` (200 ms).
private struct ChatHeroPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
}

/// Stand-in for the DM row's `?attr/selectableItemBackground` ripple: a faint
/// surface wash under the pressed row. iOS has no ripple, and a plain-styled
/// link would otherwise give no touch feedback at all.
private struct ChatRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.v3Surface2 : Color.clear)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Type-eraser so the hero and row styles can be chosen inside one
/// `buttonStyle(_:)` call — `ButtonStyle` has no built-in `AnyButtonStyle`, and
/// branching on the view instead would fork the whole `NavigationLink`.
private struct AnyButtonStyle: ButtonStyle {
    private let makeBodyClosure: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        makeBodyClosure = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        makeBodyClosure(configuration)
    }
}
