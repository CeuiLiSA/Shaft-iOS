import SwiftUI

// MARK: - Web user detail (best-effort, unauthenticated `/ajax/user/{id}?full=1`)
//
// Upstream UserActivityV3 supplements the app API with pixiv's web ajax API
// (bio HTML, social links, official badge, mutual-follow badges). Android rides
// the WebView cookie jar; we have no web session, so this is a cookieless
// best-effort fetch — public fields (social / commentHtml / official) resolve,
// login-gated ones (followedBack / isMypixiv) stay nil and their badges hide.

struct WebUserDetail: Sendable {
    var official: Bool?
    var followedBack: Bool?
    var isMypixiv: Bool?
    var canSendMessage: Bool?
    var commentHtml: String?
    var webpage: String?
    /// platform key → url. Insertion order of pixiv's own object is lost in a
    /// dictionary, so the info tab sorts by key for a stable row order.
    var social: [String: String] = [:]
}

enum WebUserDetailAPI {
    static func fetch(userId: Int64) async -> WebUserDetail? {
        guard let url = URL(string: "https://www.pixiv.net/ajax/user/\(userId)?full=1&lang=en")
        else { return nil }
        var req = URLRequest(url: url)
        req.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("https://www.pixiv.net/users/\(userId)", forHTTPHeaderField: "Referer")
        guard let (data, resp) = try? await DirectConnection.data(
                  for: req, using: DirectConnection.shared, directConnect: DirectConnection.isEnabledAtLaunch),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["error"] as? Bool) != true,
              let body = root["body"] as? [String: Any]
        else { return nil }

        var d = WebUserDetail()
        d.official = body["official"] as? Bool
        d.followedBack = body["followedBack"] as? Bool
        d.isMypixiv = body["isMypixiv"] as? Bool
        d.canSendMessage = body["canSendMessage"] as? Bool
        d.commentHtml = body["commentHtml"] as? String
        d.webpage = body["webpage"] as? String
        // pixiv quirk: `social` is `[]` when empty, an object map otherwise.
        if let social = body["social"] as? [String: Any] {
            for (platform, value) in social {
                if let link = value as? [String: Any], let u = link["url"] as? String {
                    d.social[platform] = u
                }
            }
        }
        return d
    }
}

// MARK: - Tabs

/// Upstream `UserActivityV3.TabKind`, same order:
/// 插画 · [漫画] · [漫画系列] · [小说] · [小说系列] · 收藏 · [约稿中] · 资料.
enum UserV3Tab: Hashable {
    case illust, manga, mangaSeries, novel, novelSeries, collection, request, info
}

// MARK: - View model

@MainActor
@Observable
final class UserProfileViewModel {
    let userId: Int64
    var user: PixivUser?
    var profile: UserProfile?
    var workspace: PixivWorkspace?
    var webDetail: WebUserDetail?
    var isLoading = false
    var errorMessage: String?

    /// Tab list, built once the detail lands — never "3 tabs first, conditional
    /// ones inserted later" (that flickers upstream too). Refreshes only ever
    /// *insert* (`ensureConditionalTab`), so the current tab is never yanked.
    var tabs: [UserV3Tab] = []
    /// Counts appended to the tab labels (`updateTabCount`); a zero drops out
    /// so a refresh can't leave a stale number arguing with the stats strip.
    var tabCounts: [UserV3Tab: Int] = [:]

    /// Novel-cover fallback banner for novelists with no profile background.
    var novelBannerNovel: Novel?
    @ObservationIgnored private var novelBannerFetched = false
    @ObservationIgnored private var novelBannerLoading = false

    // Feeds are created up front (they don't fetch until their tab asks) so the
    // view never has to mutate the model while building its body.
    let illustFeed: UserWorksFeed
    let mangaFeed: UserWorksFeed
    let novelFeed: UserWorksFeed
    let bookmarkIllustFeed: UserWorksFeed
    let bookmarkNovelFeed: UserWorksFeed
    let mangaSeriesFeed: UserIllustSeriesFeed
    let novelSeriesFeed: UserNovelSeriesFeed
    let requestFeed: UserRequestPlanFeed

    /// Follow state resolved through the app-wide `InteractionStore` so the
    /// header pill always agrees with the artist card on detail pages.
    var isFollowed: Bool {
        InteractionStore.shared.isFollowed(id: userId, fallback: user?.isFollowed)
    }
    var isFollowBusy: Bool { InteractionStore.shared.followBusy.contains(userId) }
    /// `followedLabelRes`: 「悄悄关注中」 when the follow is private.
    var isPrivateFollow: Bool { InteractionStore.shared.isPrivateFollow(id: userId) }

    @ObservationIgnored private let api: PixivAPI

    init(userId: Int64) {
        self.userId = userId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
        illustFeed = UserWorksFeed(userId: userId, kind: .illust)
        mangaFeed = UserWorksFeed(userId: userId, kind: .manga)
        novelFeed = UserWorksFeed(userId: userId, kind: .novel)
        bookmarkIllustFeed = UserWorksFeed(userId: userId, kind: .bookmarkIllust)
        bookmarkNovelFeed = UserWorksFeed(userId: userId, kind: .bookmarkNovel)
        mangaSeriesFeed = UserIllustSeriesFeed(userId: userId)
        novelSeriesFeed = UserNovelSeriesFeed(userId: userId)
        requestFeed = UserRequestPlanFeed(userId: userId)
    }

    func loadIfNeeded() async {
        if user == nil { await load() }
    }

    /// `UserActivityV3.initData()`: user detail (v2) + follow detail + the web
    /// supplement, all at once. Work tabs stay lazy — the ViewPager only builds
    /// a tab's fragment when it is actually swiped to.
    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in await self?.loadDetail() }
            group.addTask { @MainActor [weak self] in await self?.loadFollowDetail() }
            group.addTask { @MainActor [weak self] in await self?.loadWebDetail() }
        }
    }

    /// Pull-to-refresh parity with `refreshUserDetail()`: only the user-detail
    /// API is re-requested; follow detail, web supplement and every work tab
    /// stay put. The novel-cover banner choice is cleared so a newer cover can
    /// win, exactly like upstream.
    func refreshDetail() async {
        novelBannerFetched = false
        novelBannerNovel = nil
        await loadDetail()
    }

    private func loadDetail() async {
        do {
            let r = try await api.userDetail(userId)
            user = r.user
            profile = r.profile
            workspace = r.workspace
            // Fresh single-item truth — sync the app-wide follow state.
            InteractionStore.shared.ingest(user: r.user)
            // (Upstream also writes a fresh *self* profile back into the
            // session so the drawer avatar updates; our session record is only
            // ever read for identity, so there is nothing to refresh.)
            applyTabs()
            await loadNovelBannerIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
            // Upstream error path: fall back to the three permanent tabs rather
            // than leaving the page blank.
            if tabs.isEmpty { tabs = [.illust, .collection, .info] }
        }
    }

    /// `/v1/user/follow/detail` → public vs private, so the pill can say
    /// 「悄悄关注中」. Failure is ignored: the label falls back to 「已关注」.
    private func loadFollowDetail() async {
        guard let d = try? await api.userFollowDetail(userId) else { return }
        InteractionStore.shared.ingestRemoteFollowRestrict(d.restrict, id: userId)
    }

    private func loadWebDetail() async {
        webDetail = await WebUserDetailAPI.fetch(userId: userId)
    }

    // MARK: Tabs

    private func applyTabs() {
        guard let p = profile else { return }
        setCount(.illust, p.totalIllusts ?? 0)
        setCount(.manga, p.totalManga ?? 0)
        setCount(.mangaSeries, p.totalIllustSeries ?? 0)
        setCount(.novel, p.totalNovels ?? 0)
        setCount(.novelSeries, p.totalNovelSeries ?? 0)
        // 收藏 tab reuses the header's public-bookmark count; the novel bookmark
        // count isn't exposed by the API and upstream refuses to fake one.
        setCount(.collection, p.totalIllustBookmarksPublic ?? 0)

        // Novelist-only (0 illusts + 0 manga + >0 novels): hide the empty
        // 插画作品 tab as well (漫画 is already conditional).
        let novelistOnly = (p.totalIllusts ?? 0) == 0 && (p.totalManga ?? 0) == 0
            && (p.totalNovels ?? 0) > 0
        let acceptRequest = user?.isAcceptRequest == true

        if tabs.isEmpty {
            var t: [UserV3Tab] = []
            if !novelistOnly { t.append(.illust) }
            if (p.totalManga ?? 0) > 0 { t.append(.manga) }
            if (p.totalIllustSeries ?? 0) > 0 { t.append(.mangaSeries) }   // right after 漫画
            if (p.totalNovels ?? 0) > 0 { t.append(.novel) }
            if (p.totalNovelSeries ?? 0) > 0 { t.append(.novelSeries) }    // right after 小说
            t.append(.collection)
            if acceptRequest { t.append(.request) }                        // hugs 资料's left
            t.append(.info)
            tabs = t
        } else {
            // Refresh path: only insert what is newly non-empty, keeping the
            // reader on the tab they were looking at.
            if (p.totalManga ?? 0) > 0 { insert(.manga, at: 1) }
            if (p.totalIllustSeries ?? 0) > 0 {
                let mangaIndex = tabs.firstIndex(of: .manga)
                insert(.mangaSeries, at: mangaIndex.map { $0 + 1 } ?? indexOfCollection)
            }
            if (p.totalNovels ?? 0) > 0 { insert(.novel, at: indexOfCollection) }
            if (p.totalNovelSeries ?? 0) > 0 { insert(.novelSeries, at: indexOfCollection) }
            if acceptRequest, let infoIndex = tabs.firstIndex(of: .info) {
                insert(.request, at: infoIndex)
            }
        }
    }

    private var indexOfCollection: Int { tabs.firstIndex(of: .collection) ?? tabs.count }

    private func insert(_ tab: UserV3Tab, at index: Int) {
        guard !tabs.contains(tab), index >= 0, index <= tabs.count else { return }
        tabs.insert(tab, at: index)
    }

    private func setCount(_ tab: UserV3Tab, _ count: Int) {
        if count > 0 { tabCounts[tab] = count } else { tabCounts.removeValue(forKey: tab) }
    }

    // MARK: Novel-cover banner fallback

    /// Novelists usually have no `background_image_url`: page one of their
    /// novels supplies the newest cover that isn't pixiv's grey placeholder.
    /// The pick lives on the model so a re-render doesn't re-request it.
    private func loadNovelBannerIfNeeded() async {
        guard let p = profile else { return }
        guard (p.backgroundImageUrl ?? "").isEmpty else { return }
        let novelistOnly = (p.totalIllusts ?? 0) == 0 && (p.totalManga ?? 0) == 0
            && (p.totalNovels ?? 0) > 0
        guard novelistOnly, novelBannerNovel == nil, !novelBannerFetched, !novelBannerLoading
        else { return }
        novelBannerLoading = true
        defer { novelBannerLoading = false }
        // Failure stays silent and does NOT set `fetched`, so the next detail
        // load can try again (the gradient placeholder shows meanwhile).
        guard let r = try? await api.userNovels(userId) else { return }
        novelBannerFetched = true
        novelBannerNovel = r.novels.first { $0.realCoverURL != nil }
    }

    // MARK: Follow

    /// Follow with restrict (plain tap honours the setting, long-press forces
    /// "private" — the upstream `ProgressTextButton` pair).
    func follow(restrict: String? = nil) async {
        guard !isFollowed else { return }
        do {
            try await InteractionStore.shared.setFollowed(true, id: userId, restrict: restrict, user: user)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unfollow() async {
        guard isFollowed else { return }
        do {
            try await InteractionStore.shared.setFollowed(false, id: userId, user: user)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// `/v1/user/follow/detail` — upstream `UserFollowDetail` + `followRestrictOf`.
struct UserFollowDetailResponse: Codable, Sendable {
    struct Detail: Codable, Sendable {
        let isFollowed: Bool?
        /// "public" / "private"; absent (or null) while not following.
        let restrict: String?

        enum CodingKeys: String, CodingKey {
            case isFollowed = "is_followed"
            case restrict
        }
    }
    let followDetail: Detail?

    enum CodingKeys: String, CodingKey {
        case followDetail = "follow_detail"
    }

    /// nil when not followed at all — `follow_detail` itself can be missing and
    /// `restrict` can be null, so neither is dereferenced blind.
    var restrict: String? {
        guard let d = followDetail, d.isFollowed == true else { return nil }
        return d.restrict == "private" ? "private" : "public"
    }
}

extension Novel {
    /// `NovelExt.realCoverUrl`: large → medium → square_medium, minus pixiv's
    /// "no cover" placeholder (using it as a banner just paints grey).
    var realCoverURL: URL? {
        let raw = imageUrls?.large ?? imageUrls?.medium ?? imageUrls?.squareMedium
        guard let raw, !raw.contains("/common/images/novel_thumb/") else { return nil }
        return URL(string: raw)
    }
}

// MARK: - Scroll bookkeeping

private struct V3ProfileScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct V3ProfileTabBarYKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

private struct V3ProfileHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - User profile (UserActivityV3 parity)

/// V3 user page: a 190pt banner with the avatar / follow pill hanging 42pt over
/// its bottom edge, the name / handle / badges / inline stats strip below it,
/// then a pinned scrollable tab strip over the paged content
/// (插画 · 漫画 · 漫画系列 · 小说 · 小说系列 · 收藏 · 约稿中 · 资料).
struct UserProfileView: View {
    let userId: Int64
    @State private var vm: UserProfileViewModel
    @State private var tab: UserV3Tab = .illust
    @State private var scrollOffset: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var tabBarGlobalY: CGFloat = .greatestFiniteMagnitude
    @State private var viewerItem: ViewerItem?
    @State private var viewerIndex = 0
    @State private var jumpSheet: UserJumpRequest?
    @State private var jumpTarget: UserJumpTarget?
    @State private var bulkFetch: UserBulkFetchRequest?
    @State private var mute = MuteStore.shared
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    private struct ViewerItem: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private static let navBarHeight: CGFloat = 44

    init(userId: Int64) {
        self.userId = userId
        _vm = State(wrappedValue: UserProfileViewModel(userId: userId))
    }

    private var pixivURL: URL {
        URL(string: "https://www.pixiv.net/users/\(userId)")!
    }

    private var isSelf: Bool {
        KeychainTokenStore.shared.load()?.user?.id == userId
    }

    /// `AppBarLayout` offset listener: the profile text block fades out (and the
    /// toolbar title fades in) over `collapsingHeight - toolbar`, with the same
    /// 15pt snap zones at either end.
    private func collapseProgress(barInset: CGFloat) -> CGFloat {
        let range = max(1, headerHeight - barInset)
        let scrolled = -scrollOffset
        if scrolled < 15 { return 0 }
        if range - scrolled < 15 { return 1 }
        return min(1, max(0, scrolled / range))
    }

    var body: some View {
        GeometryReader { outer in
            let topInset = outer.safeAreaInsets.top
            // The system nav bar is hidden (its iOS 26 Liquid Glass scroll-edge
            // material can't be cleared), so `profileTopBar` — a floating button
            // row — stands in for it. `barInset` = status bar + that row, i.e.
            // exactly what the safe-area top used to be with the inline bar.
            let barInset = topInset + Self.navBarHeight
            let tabPinned = tabBarGlobalY <= barInset + 0.5
            // Pinned strip implies fully collapsed — floor the progress so the
            // bar can never sit transparent over scrolled content.
            let progress = tabPinned ? 1 : collapseProgress(barInset: barInset)

            ZStack(alignment: .top) {
                ScrollView {
                    // Plain VStack on purpose: a lazy outer stack would recycle
                    // the inline tab bar off-screen and reset its pin
                    // preference mid-scroll. Cell laziness still comes from
                    // WaterfallGrid's internal LazyVStack columns.
                    VStack(alignment: .leading, spacing: 0) {
                        V3ProfileHeader(
                            vm: vm,
                            isSelf: isSelf,
                            headerAlpha: 1 - progress,
                            onShowImage: { url in
                                viewerIndex = 0
                                viewerItem = ViewerItem(url: url)
                            }
                        )
                        .background(GeometryReader { p in
                            Color.clear.preference(
                                key: V3ProfileHeaderHeightKey.self, value: p.size.height
                            )
                        })

                        tabStrip(frosted: false)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(
                                    key: V3ProfileTabBarYKey.self,
                                    value: proxy.frame(in: .global).minY
                                )
                            })

                        // Nothing is paged until the detail says which tabs
                        // exist — a novelist has no 插画 tab, so rendering the
                        // default one early would fire a pointless request.
                        if vm.tabs.contains(tab) {
                            tabContent
                        } else {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 60)
                        }

                        Color.clear.frame(height: 32)
                    }
                    .background(GeometryReader { proxy in
                        // .global, not a named scroll space: the content top
                        // sits at the screen top (the scroll view ignores the
                        // top safe area), so global minY is the scroll offset.
                        Color.clear.preference(
                            key: V3ProfileScrollOffsetKey.self,
                            value: proxy.frame(in: .global).minY
                        )
                    })
                }
                .onPreferenceChange(V3ProfileScrollOffsetKey.self) { scrollOffset = $0 }
                .onPreferenceChange(V3ProfileTabBarYKey.self) { tabBarGlobalY = $0 }
                .onPreferenceChange(V3ProfileHeaderHeightKey.self) { headerHeight = $0 }
                .refreshable { await vm.refreshDetail() }
                .ignoresSafeArea(.container, edges: .top)

                // Toolbar scrim — the `contentScrim` stand-in: a frosted bar
                // fades in behind the floating controls as the header leaves.
                Rectangle()
                    .fill(Theme.v3Bg)              // app:contentScrim="@color/v3_bg"
                    .frame(height: barInset)
                    .offset(y: -topInset)
                    .opacity(progress)
                    .allowsHitTesting(false)

                // Pinned copy of the tab strip once the inline one reaches the
                // floating bar (TabLayout pinned below the collapsing header).
                if tabPinned {
                    tabStrip(frosted: true)
                        .offset(y: Self.navBarHeight)
                }

                profileTopBar(titleAlpha: progress)
            }
        }
        .background(Theme.v3Bg)
        // iOS 26 Liquid Glass paints an unclearable scroll-edge material on the
        // nav bar; it's hidden and replaced by profileTopBar (see body).
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await vm.loadIfNeeded()
            if let u = vm.user { HistoryStore.shared.record(user: u) }
        }
        .onChange(of: vm.tabs) { _, newTabs in
            // The default tab is whatever comes first (a novelist has no 插画).
            if !newTabs.contains(tab), let first = newTabs.first { tab = first }
        }
        .fullScreenCover(item: $viewerItem) { item in
            ImageViewerView(pages: [IllustPageURLs(large: nil, original: item.url)],
                            index: $viewerIndex)
        }
        .sheet(item: $jumpSheet) { req in
            UserJumpSheet(request: req) { jumpTarget = $0 }
        }
        .navigationDestination(item: $jumpTarget) { target in
            UserWorksJumpListView(
                userId: target.userId, type: target.type,
                offset: target.offset, targetDate: target.targetDate
            )
        }
        .sheet(item: $bulkFetch) { req in
            UserBulkFetchSheet(request: req)
        }
    }

    // MARK: Top bar + overflow menu

    /// Floating top bar replacing the hidden navigation bar: back and overflow
    /// controls as glass capsules over the edge-to-edge banner, with the user
    /// name fading in (centered) as the header collapses.
    private func profileTopBar(titleAlpha: CGFloat) -> some View {
        ZStack {
            Text(vm.user?.name ?? "")
                .font(.montserratBold(18))
                .foregroundStyle(Theme.v3Text1)
                .lineLimit(1)
                .padding(.horizontal, 56)
                .opacity(Double(titleAlpha))
            HStack {
                Button { dismiss() } label: {
                    DetailGlassCircle(system: "chevron.backward")
                }
                .buttonStyle(.plain)
                Spacer()
                if vm.user != nil { moreMenu }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.navBarHeight)
        .padding(.horizontal, 12)
    }

    /// `showMoreMenu()` — same items, same order, same visibility conditions.
    ///
    /// Two upstream entries can't exist here and are left out rather than shown
    /// dead: 「添加到桌面」 (iOS has no launcher-shortcut pinning) and
    /// 「拉黑此画师…」 (pixiv's block endpoint is web-only and needs the
    /// PHPSESSID cookie jar the Android WebView shares with OkHttp). The share /
    /// copy / open-in-browser block below them is the iOS-side affordance for
    /// the profile URL — upstream exposes that as the tappable "Pixiv URL" chip
    /// in the 资料 tab, which we also have.
    private var moreMenu: some View {
        Menu {
            if (vm.profile?.totalIllusts ?? 0) > 0 {
                Button {
                    jumpSheet = UserJumpRequest(
                        userId: userId, type: "illust",
                        total: vm.profile?.totalIllusts ?? 0
                    )
                } label: {
                    Label(l10n.t(.userV3MenuJumpIllust), systemImage: "arrow.down.to.line")
                }
            }
            if (vm.profile?.totalManga ?? 0) > 0 {
                Button {
                    jumpSheet = UserJumpRequest(
                        userId: userId, type: "manga",
                        total: vm.profile?.totalManga ?? 0
                    )
                } label: {
                    Label(l10n.t(.userV3MenuJumpManga), systemImage: "arrow.down.to.line")
                }
            }
            NavigationLink(value: AppRoute.userRelated(userId: userId)) {
                Label(l10n.t(.navRelatedUsers), systemImage: "person.2")
            }
            if (vm.profile?.totalIllusts ?? 0) > 0 {
                Button {
                    bulkFetch = UserBulkFetchRequest(userId: userId, type: "illust")
                } label: {
                    Label(l10n.t(.userV3MenuDownloadAllIllust), systemImage: "arrow.down.circle")
                }
            }
            if (vm.profile?.totalManga ?? 0) > 0 {
                Button {
                    bulkFetch = UserBulkFetchRequest(userId: userId, type: "manga")
                } label: {
                    Label(l10n.t(.userV3MenuDownloadAllManga), systemImage: "arrow.down.circle")
                }
            }
            NavigationLink(value: AppRoute.downloads) {
                Label(l10n.t(.userV3MenuOpenDownloadManager), systemImage: "tray.and.arrow.down")
            }
            if !isSelf {
                let muted = mute.isUserMuted(userId)
                Button(role: muted ? nil : .destructive) {
                    mute.toggleUser(userId)
                } label: {
                    Label(muted ? l10n.t(.userV3UnblockUserWorks) : l10n.t(.v3BlockUserWorks),
                          systemImage: "speaker.slash")
                }
            }
            Divider()
            ShareLink(item: pixivURL) {
                Label(l10n.t(.actionShare), systemImage: "square.and.arrow.up")
            }
            Button {
                UIPasteboard.general.string = pixivURL.absoluteString
            } label: {
                Label(l10n.t(.actionCopyLink), systemImage: "doc.on.doc")
            }
            Button {
                openURL(pixivURL)
            } label: {
                Label(l10n.t(.actionOpenInBrowser), systemImage: "safari")
            }
        } label: {
            DetailGlassCircle(system: "ellipsis")
        }
    }

    // MARK: Tab strip + paged content

    private func tabTitle(for t: UserV3Tab) -> String {
        let base: String
        switch t {
        case .illust: base = l10n.t(.navIllustWorks)
        case .manga: base = l10n.t(.navMangaWorks)
        case .mangaSeries: base = l10n.t(.navIllustSeries)
        case .novel: base = l10n.t(.navNovelWorks)
        case .novelSeries: base = l10n.t(.navNovelSeries)
        case .collection: base = l10n.t(.userV3TabBookmarks)
        case .request: base = l10n.t(.userV3TabRequest)
        case .info: base = l10n.t(.v3LabelProfileDetails)
        }
        guard let count = vm.tabCounts[t] else { return base }
        return "\(base) \(count.formatted())"
    }

    private func tabStrip(frosted: Bool) -> some View {
        V3ProfileTabBar(
            tabs: vm.tabs.map { ($0, tabTitle(for: $0)) },
            selection: $tab,
            frosted: frosted
        )
    }

    /// One tab is built at a time and each one loads itself on first appear —
    /// the upstream ViewPager2 keeps its default offscreen limit, so opening the
    /// page never fans out into every tab's API.
    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .illust:
            UserV3WorkTab(userId: userId, feed: vm.illustFeed, category: "illusts")
        case .manga:
            UserV3WorkTab(userId: userId, feed: vm.mangaFeed, category: "manga")
        case .novel:
            UserV3WorkTab(userId: userId, feed: vm.novelFeed, category: "novels")
        case .mangaSeries:
            UserV3IllustSeriesTab(feed: vm.mangaSeriesFeed)
        case .novelSeries:
            UserV3NovelSeriesTab(feed: vm.novelSeriesFeed)
        case .collection:
            UserV3CollectionTab(
                illustFeed: vm.bookmarkIllustFeed,
                novelFeed: vm.bookmarkNovelFeed
            )
        case .request:
            UserV3RequestTab(feed: vm.requestFeed)
        case .info:
            V3ProfileInfoPage(vm: vm, isSelf: isSelf)
        }
    }
}

// MARK: - Header (banner + avatar + name + stats strip)

/// The whole collapsing block: a 190pt banner with a 42pt overhang carrying the
/// avatar and the follow pill (232pt total, so the overhanging controls stay
/// inside their own hit area — upstream had the same negative-margin bug), then
/// the profile text block.
private struct V3ProfileHeader: View {
    @Bindable var vm: UserProfileViewModel
    let isSelf: Bool
    let headerAlpha: CGFloat
    var onShowImage: (URL) -> Void

    @Environment(OnboardingStore.self) private var l10n

    private static let bannerVisualHeight: CGFloat = 190
    private static let overhang: CGFloat = 42
    private static var bannerBlockHeight: CGFloat { bannerVisualHeight + overhang }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bannerBlock
            profileText
                .padding(.leading, 20)
                .padding(.trailing, 20)
                .padding(.top, 10)
                .padding(.bottom, 18)
                // Only the text block fades (upstream fades `profileHeader`
                // alone; the banner simply scrolls away behind the toolbar).
                .opacity(Double(headerAlpha))
        }
    }

    // MARK: Banner

    private var bannerBlock: some View {
        GeometryReader { proxy in
            // Global frame: the banner sits at the very top of the scroll
            // content, which starts at the screen top, so global minY > 0
            // means overscroll (stretch).
            let minY = proxy.frame(in: .global).minY
            let stretch = max(0, minY)

            ZStack(alignment: .top) {
                bannerLayers
                    .frame(width: proxy.size.width,
                           height: Self.bannerVisualHeight + stretch)
                    .clipped()
                    .offset(y: -stretch)

                // Avatar / actions sit on the 232pt baseline (bottom of the
                // block), i.e. 42pt below the banner artwork.
                HStack(alignment: .bottom) {
                    avatar
                    Spacer(minLength: 0)
                    if !isSelf, vm.user != nil { followButtons }
                }
                .padding(.horizontal, 20)
                .frame(width: proxy.size.width,
                       height: Self.bannerBlockHeight, alignment: .bottom)
            }
            .frame(width: proxy.size.width, height: Self.bannerBlockHeight, alignment: .top)
        }
        .frame(height: Self.bannerBlockHeight)
    }

    @ViewBuilder
    private var bannerLayers: some View {
        ZStack(alignment: .bottom) {
            // `V3Palette.bannerPlaceholder()` resolved from the brand
            // (#7C6CFF): desaturate ×0.85, then L=0.85/0.88/0.83 (light) or
            // 0.15/0.12/0.17 (dark) with ±25°/−15° hue shifts, BL→TR.
            LinearGradient(
                colors: [
                    Color(light: 0xBFB8F9, dark: 0x0D0647),
                    Color(light: 0xE2C6FA, dark: 0x200539),
                    Color(light: 0xAFB9F9, dark: 0x071150),
                ],
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            )

            if let banner = bannerURL {
                GeometryReader { p in
                    let image = PixivAsyncImage(url: banner)
                        .frame(width: p.size.width, height: p.size.height)
                        .clipped()
                        // 40% black on the image pixels (the PorterDuff
                        // SRC_ATOP color filter, not a separate scrim view).
                        .overlay(Color.black.opacity(0.4))
                        .contentShape(.rect)
                    // A novel-cover banner opens that novel; a real profile
                    // banner opens the image viewer (upstream 图片详情).
                    if let novel = novelBannerNovel {
                        NavigationLink(value: AppRoute.novelDetail(novel.id)) { image }
                            .buttonStyle(.plain)
                    } else {
                        image.onTapGesture { onShowImage(banner) }
                    }
                }
            }

            // bg_v3_banner_gradient: bottom 120pt fade into the page bg.
            LinearGradient(
                colors: [Theme.v3Bg, Theme.v3Bg.opacity(0)],
                startPoint: .bottom, endPoint: .top
            )
            .frame(height: 120)
            .allowsHitTesting(false)
        }
    }

    /// Profile background, else a novelist's newest real novel cover.
    private var bannerURL: URL? {
        if let raw = vm.profile?.backgroundImageUrl, !raw.isEmpty {
            return URL(string: raw)
        }
        return vm.novelBannerNovel?.realCoverURL
    }

    /// Non-nil only while the banner is standing in with a novel cover.
    private var novelBannerNovel: Novel? {
        guard (vm.profile?.backgroundImageUrl ?? "").isEmpty else { return nil }
        return vm.novelBannerNovel
    }

    // MARK: Avatar

    private var avatarURL: URL? {
        (vm.user?.profileImageUrls?.medium ?? vm.user?.profileImageUrls?.px170x170)
            .flatMap(URL.init(string:))
    }

    /// Upstream reads `user.is_premium`, which `/v2/user/detail` only fills in
    /// on `profile` — reading the profile flag is the same intent with data
    /// that actually arrives.
    private var isPremium: Bool {
        vm.user?.isPremium == true || vm.profile?.isPremium == true
    }

    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                if isPremium {
                    Circle()
                        .strokeBorder(Theme.v3GoldRing, lineWidth: 3)
                        .frame(width: 94, height: 94)
                }
                PixivAsyncImage(url: avatarURL)
                    .frame(width: 88, height: 88)
                    .clipShape(.circle)
                    // CircleImageView civ_border: 1.5dp ?attr/colorPrimary.
                    .overlay(Circle().strokeBorder(Theme.brand, lineWidth: 1.5))
                    .contentShape(.circle)
                    .onTapGesture {
                        if let url = avatarURL { onShowImage(url) }
                    }
            }
            if isPremium {
                Text("★")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0x1A1A2E))
                    .frame(width: 24, height: 24)
                    .background(Theme.v3Gold, in: .circle)
                    .overlay(Circle().strokeBorder(Theme.v3Bg, lineWidth: 2.5))
            }
        }
        .frame(width: 94, height: 94, alignment: .center)
    }

    // MARK: Follow pill

    @ViewBuilder
    private var followButtons: some View {
        // The 私信 button upstream draws left of this pill opens shaft-api-v2's
        // 1v1 chat room, which this app doesn't ship — omitted rather than
        // stubbed. Everything else in the row is identical.
        if vm.isFollowed {
            pill(
                title: vm.isPrivateFollow
                    ? l10n.t(.userV3FollowingPrivate) : l10n.t(.profileFollowing),
                foreground: Theme.v3TextSecondary,
                background: AnyShapeStyle(Theme.brand.opacity(0.20)),
                stroked: true
            )
            .contentShape(.capsule)
            .onTapGesture { Task { await vm.unfollow() } }
            // Upstream consumes the long-press on 已关注 (returns true) so it
            // can't fall through to anything else.
            .onLongPressGesture { }
        } else {
            pill(
                // Android keeps the label `v3_text_1` on the brand pill.
                title: l10n.t(.profileFollow),
                foreground: Theme.v3Text1,
                background: AnyShapeStyle(Theme.brand),
                stroked: false
            )
            .contentShape(.capsule)
            .onTapGesture { Task { await vm.follow() } }
            .onLongPressGesture { Task { await vm.follow(restrict: "private") } }
        }
    }

    private func pill(
        title: String, foreground: Color, background: AnyShapeStyle, stroked: Bool
    ) -> some View {
        ZStack {
            // ProgressTextButton swaps its label for a spinner while the call
            // is in flight.
            if vm.isFollowBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(foreground)
            } else {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(foreground)
            }
        }
        .padding(.horizontal, 30)
        .frame(height: 42)
        .background(background, in: .capsule)
        .overlay {
            if stroked {
                Capsule().strokeBorder(Theme.brand.opacity(0.30), lineWidth: 1)
            }
        }
    }

    // MARK: Name / handle / badges / stats

    @ViewBuilder
    private var profileText: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                // Upstream caps the name at 280dp and lets it wrap; a hard
                // SwiftUI max-width frame would also *expand* short names and
                // shove the badge away, so the HStack does the capping.
                Text(vm.user?.name ?? "")
                    .font(.montserratSemiBold(25))
                    .foregroundStyle(Theme.v3Text1)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { UIPasteboard.general.string = String(vm.userId) }
                    .onLongPressGesture { UIPasteboard.general.string = vm.user?.name ?? "" }
                if vm.webDetail?.official == true {
                    Text(l10n.t(.v3Official).uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Theme.v3Gold, in: .capsule)
                }
            }

            Text("@\(vm.user?.account ?? "")")
                .font(.montserratMedium(13))
                .foregroundStyle(Theme.v3Text3)
                .padding(.top, 3)

            // Web-only relationship badges (need a pixiv web session; without
            // one the flags stay nil and the row hides, like a logged-out web).
            let followsYou = !isSelf && vm.webDetail?.followedBack == true
            let myPixiv = vm.webDetail?.isMypixiv == true
            if followsYou || myPixiv {
                HStack(spacing: 8) {
                    if followsYou { V3RelationBadge(text: l10n.t(.v3FollowsYou)) }
                    if myPixiv { V3RelationBadge(text: l10n.t(.v3MyPixivBadge)) }
                }
                .padding(.top, 10)
            }

            statsStrip
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline 关注 · 好P友 strip. The numbers (18pt Montserrat) and labels
    /// (12pt) are baseline-aligned — centering them reads as misaligned.
    private var statsStrip: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            statSegment(
                value: vm.profile?.totalFollowUsers ?? 0,
                label: l10n.t(.v3LabelFollowing),
                color: Color(light: 0x6366F1, dark: 0xA5B4FC),
                route: .userFollowing(userId: vm.userId)
            )
            Text("·")
                .font(.system(size: 16))
                .foregroundStyle(Theme.v3Text3)
                .opacity(0.5)
                .padding(.horizontal, 12)
            statSegment(
                value: vm.profile?.totalMypixivUsers ?? 0,
                label: l10n.t(.v3LabelMyPixiv),
                color: Color(light: 0x0EA574, dark: 0x2DD4A8),
                route: .userMyPixiv(userId: vm.userId)
            )
        }
    }

    private func statSegment(
        value: Int, label: String, color: Color, route: AppRoute
    ) -> some View {
        NavigationLink(value: route) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value.formatted())
                    .font(.montserratBold(18))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.v3Text3)
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// 互相关注 / 好P友 pill: 4% white fill + a 20% brand hairline (`makeBadgeBg`).
private struct V3RelationBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Theme.v3Text2)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.white.opacity(10 / 255), in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.brand.opacity(0.20), lineWidth: 1))
    }
}

// MARK: - Section heading (card titles)

struct V3SectionHeading: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold))
            .kerning(1.4)
            .foregroundStyle(Theme.v3Text3)
    }
}

// MARK: - V3 tab strip (scrollable, indicator hugs the label)

private struct V3ProfileTabBar: View {
    let tabs: [(value: UserV3Tab, title: String)]
    @Binding var selection: UserV3Tab
    var frosted = false

    @Namespace private var indicator

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs, id: \.value) { item in
                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                selection = item.value
                            }
                        } label: {
                            VStack(spacing: 7) {
                                Text(item.title)
                                    // TextAppearance.Design.Tab is sans-serif-medium
                                    // in both states — only the color changes.
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(
                                        selection == item.value ? Theme.v3Text1 : Theme.v3Text3
                                    )
                                    .fixedSize()
                                    .padding(.top, 12)
                                ZStack {
                                    Capsule().fill(.clear).frame(height: 2)
                                    if selection == item.value {
                                        Capsule()
                                            .fill(Theme.v3Text1)
                                            .frame(height: 2)      // tabIndicatorHeight 2dp
                                            .matchedGeometryEffect(
                                                id: "v3TabIndicator", in: indicator
                                            )
                                    }
                                }
                            }
                            .padding(.horizontal, 12)          // tabPaddingStart/End 12dp
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .id(item.value)
                    }
                }
            }
            .onChange(of: selection) { _, new in
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
        }
        .background {
            if frosted {
                Rectangle().fill(.bar)
            } else {
                Theme.v3Bg
            }
        }
    }
}

// MARK: - Novel list (shared by ranking / search / series / user lists)

struct NovelList: View {
    let novels: [Novel]
    let isLoading: Bool
    let onLoadMore: (() async -> Void)?
    let hasMore: Bool

    init(
        novels: [Novel],
        isLoading: Bool = false,
        onLoadMore: (() async -> Void)? = nil,
        hasMore: Bool = false
    ) {
        self.novels = novels
        self.isLoading = isLoading
        self.onLoadMore = onLoadMore
        self.hasMore = hasMore
    }

    var body: some View {
        ScrollView {
            if novels.isEmpty, isLoading {
                NovelListSkeleton()
            } else {
                NovelListContent(
                    novels: novels, hasMore: hasMore, onLoadMore: onLoadMore
                )
            }
        }
    }
}

/// The rows without their own `ScrollView` — the V3 profile page embeds them in
/// its single outer scroll view (one collapsing header over every tab).
///
/// Edge-to-edge tiling (upstream #1038): no dividers, no outer gutter — each
/// `recy_novel` card carries its own 16/12dp padding.
struct NovelListContent: View {
    let novels: [Novel]
    let hasMore: Bool
    let onLoadMore: (() async -> Void)?

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(novels) { novel in
                NavigationLink(value: AppRoute.novelDetail(novel.id)) {
                    NovelRow(novel: novel)
                }
                .buttonStyle(.plain)
                .novelCardMenu(novel: novel) { novels }
            }
            if hasMore, !novels.isEmpty {
                Color.clear
                    .frame(height: 40)
                    .onAppear { Task { await onLoadMore?() } }
            }
        }
        .cardMenuHost()
    }
}

/// 1:1 port of upstream `recy_novel.xml` (the `NovelFeedFragment` card used by
/// every novel list): 80×119 rounded-12 cover with a bottom scrim carrying
/// ♥ bookmark count (12sp bold) over the word count (10sp), AI badge top-right,
/// trending pill top-left; right column = 3-line bold title with the heart
/// button on the first line, accent「系列：…」line, 22dp avatar + author + date;
/// then a compact tag flow (raw tag text only, folded to 6 + 「+N」).
struct NovelRow: View {
    let novel: Novel
    @State private var store = InteractionStore.shared
    @State private var mute = MuteStore.shared
    @Environment(OnboardingStore.self) private var l10n

    private static let maxTags = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                cover
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 4) {
                        Text(novel.title ?? "")
                            .font(.system(size: 15, weight: .bold))
                            .kerning(-0.3)
                            .lineLimit(3)
                            .foregroundStyle(Theme.v3Text1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        NovelRowBookmarkButton(novel: novel)
                    }
                    if let series = novel.series, let title = series.title, !title.isEmpty {
                        if let sid = series.id {
                            NavigationLink(value: AppRoute.novelSeries(seriesId: sid)) {
                                seriesLabel(title)
                            }
                            .buttonStyle(.plain)
                        } else {
                            seriesLabel(title)
                        }
                    }
                    HStack(spacing: 0) {
                        if let user = novel.user {
                            NavigationLink(value: AppRoute.userProfile(user.id)) {
                                HStack(spacing: 7) {
                                    PixivAsyncImage(
                                        url: user.profileImageUrls?.medium.flatMap(URL.init(string:)),
                                        showsProgress: false, placeholder: Theme.v3Surface2
                                    )
                                    .frame(width: 22, height: 22)
                                    .clipShape(.circle)
                                    .overlay(Circle().strokeBorder(Theme.v3Surface2, lineWidth: 1))
                                    Text(user.name ?? "")
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                        .foregroundStyle(Theme.v3Text2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 8)
                        Text(String((novel.createDate ?? "").prefix(10)))
                            .font(.system(size: 11))
                            .kerning(0.2)
                            .lineLimit(1)
                            .foregroundStyle(Theme.v3Text3)
                    }
                    .padding(.top, 8)
                }
            }
            tagFlow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(.rect)
        // "屏蔽此作品" (`NovelMuteStore`): the card stays in place under a blur;
        // a tap lifts the mute instead of opening the work (upstream `unmuteOr`).
        .overlay {
            if mute.isNovelMuted(novel.id) {
                CardSpoilerMask { mute.setNovelMuted(novel.id, false) }
            }
        }
    }

    private func seriesLabel(_ title: String) -> some View {
        Text(l10n.t(.novelSeriesFmt, title))
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(Theme.v3TextAccent)
            .padding(.top, 3)
    }

    private var cover: some View {
        PixivAsyncImage(url: coverURL, placeholder: Theme.v3Surface2)
            .frame(width: 80, height: 119)
            .overlay(alignment: .bottom) {
                // bg_v3_card_scrim, 52dp tall.
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.70), location: 0),
                        .init(color: .black.opacity(0.25), location: 0.5),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .bottom, endPoint: .top
                )
                .frame(height: 52)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 1) {
                    HStack(spacing: 3) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(red: 1, green: 0x44 / 255, blue: 0x5B / 255))
                        Text("\(novel.totalBookmarks ?? 0)")
                            .font(.system(size: 12, weight: .bold))
                            .kerning(0.1)
                            .foregroundStyle(.white)
                    }
                    Text(l10n.t(.novelWordCountFmt, "\(novel.textLength ?? 0)"))
                        .font(.system(size: 10, weight: .medium))
                        .kerning(0.2)
                        .foregroundStyle(.white.opacity(0.78))
                }
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.bottom, 6)
            }
            .overlay(alignment: .topLeading) {
                // shaft-api-v2 trending pill — only set on 当前最热 / 站长推荐 novel feeds.
                if let label = TrendingScore.label(novel.trendingScore) {
                    Text(label)
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: .capsule)
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                // v3_novel_ai_badge_bg: novel_ai_type == 2.
                if novel.novelAIType == 2 {
                    Text("AI")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color(red: 0x7C / 255, green: 0x5C / 255, blue: 0xC8 / 255).opacity(0.8),
                                    in: .rect(cornerRadius: 6))
                        .padding(5)
                }
            }
            .clipShape(.rect(cornerRadius: 12))
    }

    @ViewBuilder
    private var tagFlow: some View {
        let names = (novel.tags ?? []).compactMap { $0.name }.filter { !$0.isEmpty }
        if !names.isEmpty {
            let shown = Array(names.prefix(Self.maxTags))
            let rest = names.count - shown.count
            FlowLayout(spacing: 6) {
                ForEach(shown, id: \.self) { name in
                    NavigationLink(value: AppRoute.searchResults(word: name, section: "novel")) {
                        NovelRowTagChip(text: name)
                    }
                    .buttonStyle(.plain)
                }
                if rest > 0 {
                    NovelRowTagChip(text: "+\(rest)")
                }
            }
            .padding(.top, 10)
        }
    }

    private var coverURL: URL? {
        let s = novel.imageUrls?.medium ?? novel.imageUrls?.squareMedium
        return s.flatMap(URL.init(string:))
    }
}

/// Compact chip of `V3TagFlowView` (`compact = true`, no `#`, no translation).
private struct NovelRowTagChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(TagLegibility.shared.originalText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.v3Surface1, in: .capsule)
    }
}

/// The card's `like` button (`ic_like_illust_6`, 36dp): optimistic toggle through
/// `InteractionStore` so every list and the detail page agree.
private struct NovelRowBookmarkButton: View {
    let novel: Novel
    @State private var store = InteractionStore.shared

    var body: some View {
        let bookmarked = store.isBookmarked(novel)
        Button {
            BookmarkHaptics.commit(bookmarking: !bookmarked)
            Task {
                do { try await store.toggleBookmark(novel: novel) } catch { BookmarkHaptics.failed() }
            }
        } label: {
            Image(systemName: "heart.fill")
                .font(.system(size: 20))
                .foregroundStyle(bookmarked ? Theme.v3Bookmarked : Theme.v3Text3)
                .bookmarkBounce(bookmarked)
                .frame(width: 36, height: 36)
                .contentShape(.rect)
        }
        .buttonStyle(.bookmark)
        .disabled(store.novelBookmarkBusy.contains(novel.id))
    }
}
