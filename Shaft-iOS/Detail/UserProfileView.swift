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
    var commentHtml: String?
    var webpage: String?
    /// platform key → url
    var social: [String: String] = [:]
}

private enum WebUserDetailAPI {
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

// MARK: - View model

@MainActor
@Observable
final class UserProfileViewModel {
    let userId: Int64
    var user: PixivUser?
    var profile: UserProfile?
    var workspace: PixivWorkspace?
    var webDetail: WebUserDetail?
    var illusts: [Illust] = []
    var manga: [Illust] = []
    var illustNext: String?
    var mangaNext: String?
    /// Top tags aggregated from the first page of the author's illusts
    /// (issue #569 parity) — `(display, rawName)`, frequency-sorted, max 20.
    var illustTagChips: [(display: String, name: String)] = []
    var isLoading = false
    var isRefreshing = false
    var isLoadingIllusts = false
    var isLoadingManga = false
    var errorMessage: String?

    /// Follow state resolved through the app-wide `InteractionStore` so the
    /// header pill always agrees with the artist card on detail pages (and
    /// anywhere else the author appears).
    var isFollowed: Bool {
        InteractionStore.shared.isFollowed(id: userId, fallback: user?.isFollowed)
    }
    var isFollowBusy: Bool {
        InteractionStore.shared.followBusy.contains(userId)
    }

    @ObservationIgnored private var didLoadIllusts = false
    @ObservationIgnored private var didLoadManga = false

    private static let maxIllustTagChips = 20

    @ObservationIgnored private let api: PixivAPI

    init(userId: Int64) {
        self.userId = userId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async {
        if user == nil { await load() }
    }

    /// Initial load — what UserActivityV3.initData() fires immediately: the
    /// user detail, the web supplement, and the first page of illusts (it is
    /// both the default tab's content and the tag-chip source; upstream issues
    /// the same request from setupIllustTags). Manga waits for its tab — the
    /// upstream fragment is created lazily by the ViewPager too.
    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in await self?.loadDetail() }
            group.addTask { @MainActor [weak self] in await self?.loadIllustsIfNeeded() }
            group.addTask { @MainActor [weak self] in await self?.loadWebDetail() }
        }
    }

    /// Pull-to-refresh parity with UserActivityV3.refreshUserDetail(): only the
    /// user-detail API is re-requested; works tabs and web supplement stay put.
    func refreshDetail() async {
        isRefreshing = true
        defer { isRefreshing = false }
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadIllustsIfNeeded() async {
        guard !didLoadIllusts, !isLoadingIllusts else { return }
        isLoadingIllusts = true
        defer { isLoadingIllusts = false }
        let r = try? await api.userIllusts(userId, type: "illust")
        illusts = r?.illusts ?? []
        illustNext = r?.nextUrl
        aggregateIllustTags(from: illusts)
        didLoadIllusts = r != nil  // failed fetch retries next trigger
    }

    func loadMangaIfNeeded() async {
        guard !didLoadManga, !isLoadingManga else { return }
        isLoadingManga = true
        defer { isLoadingManga = false }
        let r = try? await api.userIllusts(userId, type: "manga")
        manga = r?.illusts ?? []
        mangaNext = r?.nextUrl
        didLoadManga = r != nil
    }

    private func loadWebDetail() async {
        webDetail = await WebUserDetailAPI.fetch(userId: userId)
    }

    private func aggregateIllustTags(from illusts: [Illust]) {
        // Muted works drop out before aggregation, so muted tags never surface
        // as chips (parity with the upstream Mapper pass).
        let visible = MuteStore.shared.filter(illusts)
        var freq: [String: (display: String, count: Int)] = [:]
        var order: [String] = []
        for illust in visible {
            for tag in illust.tags ?? [] {
                guard let name = tag.name, !name.isEmpty else { continue }
                let display = tag.translatedName?.isEmpty == false ? tag.translatedName! : name
                if let prev = freq[name] {
                    freq[name] = (prev.display, prev.count + 1)
                } else {
                    freq[name] = (display, 1)
                    order.append(name)
                }
            }
        }
        illustTagChips = order
            .sorted { (freq[$0]?.count ?? 0) > (freq[$1]?.count ?? 0) }
            .prefix(Self.maxIllustTagChips)
            .map { (freq[$0]?.display ?? $0, $0) }
    }

    func loadMoreIllusts() async {
        guard let url = illustNext else { return }
        if let r: IllustResponse = try? await api.nextPage(url) {
            illusts.append(contentsOf: r.illusts)
            illustNext = r.nextUrl
        }
    }

    func loadMoreManga() async {
        guard let url = mangaNext else { return }
        if let r: IllustResponse = try? await api.nextPage(url) {
            manga.append(contentsOf: r.illusts)
            mangaNext = r.nextUrl
        }
    }

    /// Follow with restrict ("public" tap / "private" long-press, parity with
    /// the upstream ProgressTextButton long-press behavior). Goes through the
    /// app-wide store (optimistic, store reverts on failure).
    func follow(restrict: String) async {
        guard !isFollowed else { return }
        do {
            try await InteractionStore.shared.setFollowed(true, id: userId, restrict: restrict)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unfollow() async {
        guard isFollowed else { return }
        do {
            try await InteractionStore.shared.setFollowed(false, id: userId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Scroll bookkeeping

private struct V3ProfileScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct V3ProfileTabBarYKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

// MARK: - User profile (UActivityV3 pixel parity)

/// V3 user page: 300pt banner with the profile header overlaid on its bottom
/// edge, stats card (following / mypixiv), quick-navigation pill chips, top
/// illust-tag chips, then a pinned tab strip switching between the illust
/// waterfall, manga waterfall and the profile-details page.
struct UserProfileView: View {
    let userId: Int64
    @State private var vm: UserProfileViewModel
    @State private var tab: ProfileTab = .illusts
    @State private var illustTagsExpanded = false
    @State private var scrollOffset: CGFloat = 0
    @State private var tabBarGlobalY: CGFloat = .greatestFiniteMagnitude
    @State private var viewerItem: ViewerItem?
    @State private var viewerIndex = 0
    @State private var mute = MuteStore.shared
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    enum ProfileTab: Hashable { case illusts, manga, info }

    private struct ViewerItem: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private static let bannerHeight: CGFloat = 300
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

    private var tabs: [ProfileTab] {
        // Manga tab joins the strip only once the detail reports manga works —
        // same deferred insertion as ensureMangaTab().
        var t: [ProfileTab] = [.illusts]
        if (vm.profile?.totalManga ?? 0) > 0 { t.append(.manga) }
        t.append(.info)
        return t
    }

    /// Header/title cross-fade matching the AppBar offset listener: profile
    /// header fully visible near the top, faded out (title faded in) once the
    /// banner has scrolled behind the toolbar.
    private func collapseProgress(topInset: CGFloat) -> CGFloat {
        // topInset spans status bar + inline nav bar — the banner is fully
        // collapsed once its bottom edge reaches the nav bar's bottom.
        let range = Self.bannerHeight - topInset
        let scrolled = -scrollOffset
        if scrolled < 15 { return 0 }
        if range - scrolled < 15 { return 1 }
        return min(1, max(0, scrolled / range))
    }

    var body: some View {
        GeometryReader { outer in
            // The safe-area top already includes the inline navigation bar,
            // so the strip pins (and the scrim ends) at the bar's bottom edge.
            let topInset = outer.safeAreaInsets.top
            // The system nav bar is hidden (its iOS 26 Liquid Glass scroll-edge
            // material can't be cleared), so `profileTopBar` — a floating button
            // row — stands in for it. `barInset` = status bar + that row, i.e.
            // exactly what the safe-area top used to be with the inline nav bar,
            // so every collapse threshold below is unchanged.
            let barInset = topInset + Self.navBarHeight
            let pinY = barInset
            let tabPinned = tabBarGlobalY <= pinY + 0.5
            // Pinned strip implies fully collapsed — floor the progress so the
            // bar can never sit transparent over scrolled content.
            let progress = tabPinned ? 1 : collapseProgress(topInset: barInset)

            ZStack(alignment: .top) {
                ScrollView {
                    // Plain VStack on purpose: a lazy outer stack would recycle
                    // the inline tab bar off-screen and reset its pin
                    // preference mid-scroll. Cell laziness still comes from
                    // WaterfallGrid's internal LazyVStack columns.
                    VStack(alignment: .leading, spacing: 0) {
                        V3ProfileBanner(
                            vm: vm,
                            isSelf: isSelf,
                            headerAlpha: 1 - progress,
                            onShowImage: { url in
                                viewerIndex = 0
                                viewerItem = ViewerItem(url: url)
                            }
                        )

                        statsAndNav

                        inlineTabBar
                            .background(GeometryReader { proxy in
                                Color.clear.preference(
                                    key: V3ProfileTabBarYKey.self,
                                    value: proxy.frame(in: .global).minY
                                )
                            })

                        tabContent

                        Color.clear.frame(height: 32)
                    }
                    .background(GeometryReader { proxy in
                        // .global, not a named scroll space: the content top
                        // sits at the screen top (the scroll view ignores the
                        // top safe area), so global minY is the scroll offset.
                        // Named-space frames come back stuck at 0 on iOS 26,
                        // which left the toolbar permanently transparent.
                        Color.clear.preference(
                            key: V3ProfileScrollOffsetKey.self,
                            value: proxy.frame(in: .global).minY
                        )
                    })
                }
                .onPreferenceChange(V3ProfileScrollOffsetKey.self) { scrollOffset = $0 }
                .onPreferenceChange(V3ProfileTabBarYKey.self) { tabBarGlobalY = $0 }
                .refreshable { await vm.refreshDetail() }
                .ignoresSafeArea(.container, edges: .top)

                // Toolbar scrim — the contentScrim stand-in: a frosted bar fades
                // in behind the floating controls as the header leaves, so
                // scrolled content blurs under them instead of showing through.
                Rectangle()
                    .fill(.bar)
                    .frame(height: pinY)
                    .offset(y: -topInset)
                    .opacity(progress)
                    .allowsHitTesting(false)

                // Pinned copy of the tab strip once the inline one reaches the
                // floating bar (TabLayout pinned below the collapsing header).
                // Dropped by the floating row's height so it sits below it.
                if tabPinned {
                    tabBar(frosted: true)
                        .offset(y: Self.navBarHeight)
                }

                // Floating nav controls replacing the hidden bar.
                profileTopBar
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
        .onChange(of: tab) { _, newTab in
            // Manga loads on first tab visit — the ViewPager-lazy fragment.
            if newTab == .manga {
                Task { await vm.loadMangaIfNeeded() }
            }
        }
        .fullScreenCover(item: $viewerItem) { item in
            ImageViewerView(pages: [IllustPageURLs(large: nil, original: item.url)],
                            index: $viewerIndex)
        }
    }

    /// Title alpha needs the safe-area inset, but toolbar content builds outside
    /// the GeometryReader — approximate with the standard 59pt status bar inset;
    /// the snap thresholds make the difference invisible.
    private var collapseTitleAlpha: CGFloat {
        // Same floor as the scrim: a pinned tab strip means fully collapsed.
        if tabBarGlobalY <= 59 + Self.navBarHeight + 0.5 { return 1 }
        let range = Self.bannerHeight - 59 - Self.navBarHeight
        let scrolled = -scrollOffset
        if scrolled < 15 { return 0 }
        if range - scrolled < 15 { return 1 }
        return min(1, max(0, scrolled / range))
    }

    private var moreMenu: some View {
        Menu {
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
            if !isSelf {
                Divider()
                Button(role: .destructive) {
                    MuteStore.shared.toggleUser(userId)
                } label: {
                    let muted = MuteStore.shared.isUserMuted(userId)
                    Label(muted ? l10n.t(.actionUnmuteUser) : l10n.t(.actionMuteUser),
                          systemImage: "speaker.slash")
                }
            }
        } label: {
            DetailGlassCircle(system: "ellipsis")
        }
    }

    /// Floating top bar that replaces the hidden navigation bar (see body): back
    /// and overflow controls as glass capsules over the edge-to-edge banner, with
    /// the user name fading in (centered) as the banner collapses.
    private var profileTopBar: some View {
        ZStack {
            Text(vm.user?.name ?? "")
                .font(.montserratBold(18))
                .foregroundStyle(Theme.v3Text1)
                .lineLimit(1)
                .padding(.horizontal, 56)
                .opacity(Double(collapseTitleAlpha))
            HStack {
                Button { dismiss() } label: {
                    DetailGlassCircle(system: "chevron.backward")
                }
                .buttonStyle(.plain)
                Spacer()
                moreMenu
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.navBarHeight)
        .padding(.horizontal, 12)
    }

    // MARK: Stats + quick navigation (between banner and tab strip)

    @ViewBuilder
    private var statsAndNav: some View {
        VStack(alignment: .leading, spacing: 0) {
            statsRow

            if vm.profile != nil {
                V3SectionHeading(text: l10n.t(.v3LabelNavigate))
                    .padding(.top, 20)
                navChipsFlow
                    .padding(.top, 12)
            }

            if !vm.illustTagChips.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        illustTagsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        V3SectionHeading(text: l10n.t(.v3LabelIllustTags))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.v3Text3)
                            .rotationEffect(.degrees(illustTagsExpanded ? 180 : 0))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.top, 20)

                if illustTagsExpanded {
                    illustTagFlow
                        .padding(.top, 12)
                        // Spring height-growth unfolds the section; the chips fade
                        // in over it. No .move — that would overlap the heading on
                        // insert.
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            statColumn(
                value: vm.profile?.totalFollowUsers ?? 0,
                label: l10n.t(.v3LabelFollowing),
                color: Color(light: 0x6366F1, dark: 0xA5B4FC),
                route: .userFollowing(userId: userId)
            )
            statColumn(
                value: vm.profile?.totalMypixivUsers ?? 0,
                label: l10n.t(.v3LabelMyPixiv),
                color: Color(light: 0x0EA574, dark: 0x2DD4A8),
                route: .userMyPixiv(userId: userId)
            )
        }
        .padding(.vertical, 16)
        .v3Glass(corner: 20)
        .overlay {
            if vm.user == nil, vm.isLoading {
                ProgressView()
            }
        }
    }

    private func statColumn(value: Int, label: String, color: Color, route: AppRoute) -> some View {
        NavigationLink(value: route) {
            VStack(spacing: 2) {
                Text(value.formatted())
                    .font(.montserratBold(20))
                    .foregroundStyle(color)
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.9)
                    .foregroundStyle(Theme.v3Text3)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Quick-navigation chips — same set, order and visibility conditions as
    /// setupNavTags().
    private var navChips: [(label: String, count: Int, route: AppRoute)] {
        guard let p = vm.profile else { return [] }
        var chips: [(String, Int, AppRoute)] = []
        if (p.totalIllusts ?? 0) > 0 {
            chips.append((l10n.t(.navIllustWorks), p.totalIllusts ?? 0,
                          .userIllusts(userId: userId, type: "illust")))
        }
        if (p.totalManga ?? 0) > 0 {
            chips.append((l10n.t(.navMangaWorks), p.totalManga ?? 0,
                          .userIllusts(userId: userId, type: "manga")))
        }
        if (p.totalIllustSeries ?? 0) > 0 {
            chips.append((l10n.t(.navIllustSeries), p.totalIllustSeries ?? 0,
                          .userIllustSeriesList(userId: userId)))
        }
        if (p.totalNovels ?? 0) > 0 {
            chips.append((l10n.t(.navNovelWorks), p.totalNovels ?? 0,
                          .userNovels(userId: userId)))
        }
        if (p.totalNovelSeries ?? 0) > 0 {
            chips.append((l10n.t(.navNovelSeries), p.totalNovelSeries ?? 0,
                          .userNovelSeriesList(userId: userId)))
        }
        if (p.totalIllustBookmarksPublic ?? 0) > 0 || isSelf {
            chips.append((l10n.t(.navIllustBookmarks), p.totalIllustBookmarksPublic ?? 0,
                          .userBookmarks(userId: userId)))
        }
        chips.append((l10n.t(.navNovelBookmarks), 0, .userNovelBookmarks(userId: userId)))
        chips.append((l10n.t(.navRelatedUsers), 0, .userRelated(userId: userId)))
        return chips
    }

    private var navChipsFlow: some View {
        FlowLayout(spacing: 8) {
            ForEach(Array(navChips.enumerated()), id: \.offset) { _, chip in
                NavigationLink(value: chip.route) {
                    V3NavChip(label: chip.label, count: chip.count)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var illustTagFlow: some View {
        FlowLayout(spacing: 8) {
            ForEach(vm.illustTagChips, id: \.name) { chip in
                NavigationLink(value: AppRoute.userIllustTag(userId: userId, tag: chip.name)) {
                    V3NavChip(label: chip.display, count: 0)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Tab strip + paged content

    private var inlineTabBar: some View {
        tabBar(frosted: false)
    }

    private func tabBar(frosted: Bool) -> V3ProfileTabBar {
        V3ProfileTabBar(
            tabs: tabs.map { ($0, tabTitle(for: $0)) },
            selection: $tab,
            frosted: frosted
        )
    }

    private func tabTitle(for t: ProfileTab) -> String {
        switch t {
        case .illusts: return l10n.t(.navIllustWorks)
        case .manga:   return l10n.t(.navMangaWorks)
        case .info:    return l10n.t(.v3LabelProfileDetails)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .illusts:
            illustGrid(vm.illusts, isLoading: vm.isLoadingIllusts,
                       hasMore: vm.illustNext != nil) {
                await vm.loadMoreIllusts()
            }
        case .manga:
            illustGrid(vm.manga, isLoading: vm.isLoadingManga,
                       hasMore: vm.mangaNext != nil) {
                await vm.loadMoreManga()
            }
        case .info:
            V3ProfileInfoPage(vm: vm, isSelf: isSelf)
        }
    }

    @ViewBuilder
    private func illustGrid(
        _ illusts: [Illust], isLoading: Bool, hasMore: Bool,
        loadMore: @escaping () async -> Void
    ) -> some View {
        let visible = mute.filter(illusts)
        if visible.isEmpty {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
            } else {
                Text(l10n.t(.nothingHere))
                    .font(.footnote)
                    .foregroundStyle(Theme.v3Text3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
            }
        } else {
            WaterfallGrid(
                items: visible,
                columns: mute.waterfallColumns,
                spacing: 8,
                estimatedRelativeHeight: { $0.waterfallImageHeightRatio }
            ) { illust in
                NavigationLink(value: illust) {
                    IllustWaterfallCell(illust: illust)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    IllustCellContextMenuItems(illust: illust)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            if hasMore {
                Color.clear
                    .frame(height: 40)
                    .onAppear { Task { await loadMore() } }
            }
        }
    }
}

// MARK: - Banner + profile header overlay

/// 300pt banner: themed placeholder gradient → banner image (40% black overlay)
/// → bottom fade into the page background, with the avatar / follow / name /
/// badges header glued to its bottom edge. The image stretches on overscroll
/// (the iOS counterpart of the fixed CollapsingToolbar banner).
private struct V3ProfileBanner: View {
    @Bindable var vm: UserProfileViewModel
    let isSelf: Bool
    let headerAlpha: CGFloat
    var onShowImage: (URL) -> Void

    @Environment(OnboardingStore.self) private var l10n

    private static let baseHeight: CGFloat = 300

    var body: some View {
        GeometryReader { proxy in
            // Global frame: the banner sits at the very top of the scroll
            // content, which starts at the screen top, so global minY > 0
            // means overscroll (stretch).
            let minY = proxy.frame(in: .global).minY
            let stretch = max(0, minY)

            ZStack(alignment: .bottom) {
                bannerLayers
                    .frame(width: proxy.size.width, height: Self.baseHeight + stretch)
                    .clipped()

                profileHeader
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .opacity(Double(headerAlpha))
            }
            .frame(width: proxy.size.width, height: Self.baseHeight + stretch)
            .offset(y: -stretch)
        }
        .frame(height: Self.baseHeight)
    }

    @ViewBuilder
    private var bannerLayers: some View {
        ZStack(alignment: .bottom) {
            // bg_v3_banner_placeholder: 135° tri-stop gradient
            LinearGradient(
                colors: [
                    Color(light: 0xE8E0F0, dark: 0x1E1840),
                    Color(light: 0xDED8EE, dark: 0x2A1440),
                    Color(light: 0xE0E4F0, dark: 0x161A38),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let banner = bannerURL {
                GeometryReader { p in
                    PixivAsyncImage(url: banner)
                        .frame(width: p.size.width, height: p.size.height)
                        .clipped()
                        // 40% black overlay on the image pixels (the
                        // PorterDuff SRC_ATOP color filter).
                        .overlay(Color.black.opacity(0.4))
                        .contentShape(.rect)
                        .onTapGesture { onShowImage(banner) }
                }
            }

            // bg_v3_banner_gradient: bottom 160pt fade into the page bg
            LinearGradient(
                colors: [Theme.v3Bg, Theme.v3Bg.opacity(0)],
                startPoint: .bottom, endPoint: .top
            )
            .frame(height: 160)
            .allowsHitTesting(false)
        }
    }

    private var bannerURL: URL? {
        vm.profile?.backgroundImageUrl.flatMap(URL.init(string:))
    }

    private var avatarURL: URL? {
        (vm.user?.profileImageUrls?.medium ?? vm.user?.profileImageUrls?.px170x170)
            .flatMap(URL.init(string:))
    }

    private var isPremium: Bool { vm.profile?.isPremium == true }

    @ViewBuilder
    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Avatar row — avatar left, follow actions bottom-right
            HStack(alignment: .bottom, spacing: 0) {
                avatar
                Spacer(minLength: 0)
                if !isSelf, vm.user != nil {
                    followButtons
                        .padding(.bottom, 8)
                }
            }

            // Name + official badge
            HStack(spacing: 8) {
                Text(vm.user?.name ?? "")
                    .font(.montserratBold(24))
                    .foregroundStyle(Theme.v3Text1)
                    .lineLimit(1)
                    .onTapGesture {
                        UIPasteboard.general.string = String(vm.userId)
                    }
                    .onLongPressGesture {
                        UIPasteboard.general.string = vm.user?.name ?? ""
                    }
                if vm.webDetail?.official == true {
                    Text(l10n.t(.v3Official).uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Theme.v3Gold, in: .capsule)
                }
            }
            .padding(.top, 14)

            // Handle
            Text("@\(vm.user?.account ?? "")")
                .font(.montserratMedium(13))
                .foregroundStyle(Theme.v3Text3)
                .padding(.top, 2)

            // Web-only relationship badges
            let followsYou = !isSelf && vm.webDetail?.followedBack == true
            let myPixiv = vm.webDetail?.isMypixiv == true
            if followsYou || myPixiv {
                HStack(spacing: 8) {
                    if followsYou { V3RelationBadge(text: l10n.t(.v3FollowsYou)) }
                    if myPixiv { V3RelationBadge(text: l10n.t(.v3MyPixivBadge)) }
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .overlay(Circle().strokeBorder(Theme.v3Bg, lineWidth: 3))
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

    @ViewBuilder
    private var followButtons: some View {
        let followed = vm.isFollowed
        if followed {
            // palette.textSecondary: brand lightened (dark) / darkened (light) @90%
            Text(l10n.t(.profileFollowing))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(
                    Color(light: 0x4636B3, dark: 0xB7ADFF,
                          lightAlpha: 0.9, darkAlpha: 0.9)
                )
                .padding(.horizontal, 28)
                .frame(height: 42)
                .background(Theme.brand.opacity(0.20), in: .capsule)
                .overlay(Capsule().strokeBorder(Theme.brand.opacity(0.30), lineWidth: 1))
                .contentShape(.capsule)
                .onTapGesture { Task { await vm.unfollow() } }
        } else {
            // Android keeps the label `v3_text_1` on the brand pill in both modes.
            Text(l10n.t(.profileFollow))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.v3Text1)
                .padding(.horizontal, 28)
                .frame(height: 42)
                .background(Theme.brand, in: .capsule)
                .contentShape(.capsule)
                .onTapGesture { Task { await vm.follow(restrict: "public") } }
                .onLongPressGesture { Task { await vm.follow(restrict: "private") } }
        }
    }
}

private struct V3RelationBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Theme.v3Text2)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.04), in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.brand.opacity(0.20), lineWidth: 1))
    }
}

// MARK: - Section heading (NAVIGATE / ILLUST TAGS / card titles)

private struct V3SectionHeading: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold))
            .kerning(1.4)
            .foregroundStyle(Theme.v3Text3)
    }
}

// MARK: - Navigation pill chip (item_v3_nav_tag)

private struct V3NavChip: View {
    let label: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.v3Text2)
            if count > 0 {
                Text(count.formatted())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.brand)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Theme.brand.opacity(0.10), in: .capsule)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03), in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.brand.opacity(0.20), lineWidth: 1))
        .contentShape(.capsule)
    }
}

// MARK: - V3 tab strip (fixed tabs, text-width indicator)

private struct V3ProfileTabBar: View {
    let tabs: [(value: UserProfileView.ProfileTab, title: String)]
    @Binding var selection: UserProfileView.ProfileTab
    var frosted = false

    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.value) { item in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        selection = item.value
                    }
                } label: {
                    VStack(spacing: 7) {
                        Text(item.title)
                            .font(.system(size: 14, weight: selection == item.value ? .semibold : .regular))
                            .foregroundStyle(selection == item.value ? Theme.v3Text1 : Theme.v3Text3)
                            .padding(.top, 12)
                        ZStack {
                            Capsule().fill(.clear).frame(height: 3)
                            if selection == item.value {
                                Capsule()
                                    .fill(Theme.v3Text1)
                                    .frame(width: 32, height: 3)
                                    .matchedGeometryEffect(id: "v3TabIndicator", in: indicator)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
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

// MARK: - Info page (UserV3InfoFragment)

/// 资料 tab — profile-details card, social links card, bio, collapsible
/// workspace card, and the mute strip (non-self only).
private struct V3ProfileInfoPage: View {
    @Bindable var vm: UserProfileViewModel
    let isSelf: Bool

    @State private var workspaceExpanded = true
    @State private var mute = MuteStore.shared
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            profileCard

            if !socialRows.isEmpty {
                socialCard
                    .padding(.top, 16)
            }

            if let bio = bioText, !bio.isEmpty {
                Text(bio)
                    .font(.system(size: 14))
                    .lineSpacing(6)
                    .foregroundStyle(Theme.v3Text1.opacity(0.78))
                    .textSelection(.enabled)
                    .padding(.top, 16)
            }

            if !workspaceItems.isEmpty {
                workspaceCard
                    .padding(.top, 16)
            }

            if !isSelf {
                muteStrip
                    .padding(.top, 20)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 32)
    }

    // ── Profile details card ────────────────────────────────────────

    private struct ChipData: Identifiable {
        let label: String
        let value: String
        var isWide = false
        var isPremium = false
        var url: URL?
        var id: String { label }
    }

    private var profileChips: [ChipData] {
        guard let user = vm.user else { return [] }
        let p = vm.profile
        var chips: [ChipData] = [
            ChipData(label: l10n.t(.chipUserId), value: String(user.id)),
            ChipData(label: l10n.t(.chipAccount), value: user.account ?? ""),
        ]
        if let gender = p?.gender, !gender.isEmpty {
            let text: String
            switch gender {
            case "male": text = l10n.t(.genderMale)
            case "female": text = l10n.t(.genderFemale)
            default: text = gender
            }
            chips.append(ChipData(label: l10n.t(.chipGender), value: text))
        }
        if let region = p?.region, !region.isEmpty {
            chips.append(ChipData(label: l10n.t(.chipRegion), value: region))
        }
        if let birthday = p?.birthDay, !birthday.isEmpty {
            chips.append(ChipData(label: l10n.t(.chipBirthday), value: birthday))
        }
        if let job = p?.job, !job.isEmpty {
            chips.append(ChipData(label: l10n.t(.chipJob), value: job))
        }
        chips.append(ChipData(
            label: l10n.t(.chipPremium),
            value: p?.isPremium == true ? l10n.t(.chipPremiumUser) : l10n.t(.chipStandard),
            isPremium: p?.isPremium == true
        ))
        chips.append(ChipData(
            label: l10n.t(.chipPixivUrl),
            value: "https://www.pixiv.net/users/\(user.id)",
            isWide: true,
            url: URL(string: "https://www.pixiv.net/users/\(user.id)")
        ))
        return chips
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            V3SectionHeading(text: l10n.t(.v3LabelProfileDetails))
            chipGrid(profileChips)
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .v3Glass(corner: 28)
    }

    /// Two-up chip rows; wide chips (and a trailing odd one) take a full row —
    /// the same packing as setupProfileCard().
    @ViewBuilder
    private func chipGrid(_ chips: [ChipData]) -> some View {
        let rows = packChips(chips)
        VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ForEach(row) { chip in
                        V3ProfileChip(
                            label: chip.label, value: chip.value,
                            isPremium: chip.isPremium, url: chip.url
                        )
                    }
                }
            }
        }
    }

    private func packChips(_ chips: [ChipData]) -> [[ChipData]] {
        var rows: [[ChipData]] = []
        var i = 0
        while i < chips.count {
            let chip = chips[i]
            if chip.isWide || i + 1 >= chips.count {
                rows.append([chip])
                i += 1
            } else if chips[i + 1].isWide {
                rows.append([chip])
                i += 1
            } else {
                rows.append([chip, chips[i + 1]])
                i += 2
            }
        }
        return rows
    }

    // ── Social links card ───────────────────────────────────────────

    private struct SocialRow: Identifiable {
        let platform: String
        let label: String
        let url: String
        var id: String { "\(platform.lowercased()):\(url)" }
    }

    private var socialRows: [SocialRow] {
        var rows: [SocialRow] = []
        var seen = Set<String>()
        func add(_ platform: String, _ label: String, _ url: String?) {
            guard let url, !url.isEmpty else { return }
            let row = SocialRow(platform: platform, label: label, url: url)
            guard seen.insert(row.id).inserted else { return }
            rows.append(row)
        }
        if let p = vm.profile {
            let twitterLabel = (p.twitterAccount?.isEmpty == false)
                ? "@\(p.twitterAccount!)" : "X (Twitter)"
            add("twitter", twitterLabel, p.twitterUrl)
            add("webpage", "Website", p.webpage)
            add("pawoo", "Pawoo", p.pawooUrl)
        }
        if let web = vm.webDetail {
            for (platform, url) in web.social.sorted(by: { $0.key < $1.key }) {
                add(platform, prettySocialLabel(platform), url)
            }
            add("webpage", "Website", web.webpage)
        }
        return rows
    }

    private func prettySocialLabel(_ platform: String) -> String {
        switch platform.lowercased() {
        case "twitter", "x": return "X (Twitter)"
        case "youtube": return "YouTube"
        case "tiktok": return "TikTok"
        case "linkedin": return "LinkedIn"
        case "github": return "GitHub"
        case "webpage": return "Website"
        default: return platform.prefix(1).uppercased() + platform.dropFirst()
        }
    }

    private func socialStyle(_ platform: String) -> (icon: String, badge: Color) {
        switch platform.lowercased() {
        case "instagram": return ("camera", Color(hex: 0xFFE7FC))
        case "facebook": return ("person.2", Color(hex: 0xDBF2FE))
        case "twitter", "x": return ("at", Color(hex: 0xDFDFDF))
        case "youtube": return ("play.rectangle", Color(hex: 0xFFD6CD))
        case "tiktok": return ("music.note", Color(hex: 0xDFDFDF))
        case "linkedin": return ("briefcase", Color(hex: 0xE0EFFF))
        case "spotify": return ("music.note.list", Color(hex: 0xD5EDC2))
        default: return ("link", Color(hex: 0xE8DCCD))
        }
    }

    private var socialCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            V3SectionHeading(text: l10n.t(.v3LabelSocial))
                .padding(.bottom, 6)
            ForEach(Array(socialRows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.v3Border)
                        .frame(height: 0.5)
                }
                socialRowView(row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 6)
        .v3Glass(corner: 28)
    }

    private func socialRowView(_ row: SocialRow) -> some View {
        let style = socialStyle(row.platform)
        return Button {
            if let url = URL(string: row.url) { openURL(url) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: style.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x1A1A2E))
                    .frame(width: 36, height: 36)
                    .background(style.badge, in: .rect(cornerRadius: 10))
                Text(row.label)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.v3Text1)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.v3Text3)
            }
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // ── Bio ─────────────────────────────────────────────────────────

    private var bioText: String? {
        // Web commentHtml carries richer markup than the app-api comment —
        // prefer it when present (rendered as text, tags stripped).
        if let html = vm.webDetail?.commentHtml, !html.isEmpty {
            return V3Caption.plain(html)
        }
        if let comment = vm.user?.comment, !comment.isEmpty {
            return V3Caption.plain(comment)
        }
        return nil
    }

    // ── Workspace card ──────────────────────────────────────────────

    private var workspaceItems: [ChipData] {
        guard let w = vm.workspace else { return [] }
        // Upstream hardcodes English workspace labels; keep them for parity.
        let pairs: [(String, String?)] = [
            ("PC", w.pc), ("Monitor", w.monitor), ("Tool", w.tool),
            ("Tablet", w.tablet), ("Scanner", w.scanner), ("Mouse", w.mouse),
            ("Printer", w.printer), ("Desktop", w.desktop), ("Music", w.music),
            ("Desk", w.desk), ("Chair", w.chair), ("Comment", w.comment),
        ]
        return pairs.compactMap { label, value in
            guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return ChipData(label: label, value: value)
        }
    }

    private var workspaceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { workspaceExpanded.toggle() }
            } label: {
                HStack {
                    V3SectionHeading(text: l10n.t(.v3LabelWorkspace))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.v3Text3)
                        .rotationEffect(.degrees(workspaceExpanded ? 0 : -90))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if workspaceExpanded {
                chipGrid(workspaceItems)
                    .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .v3Glass(corner: 28)
    }

    // ── Mute strip ──────────────────────────────────────────────────

    private var muteStrip: some View {
        HStack {
            Text(l10n.t(.v3BlockUserWorks))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.v3Text2)
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { mute.isUserMuted(vm.userId) },
                set: { _ in mute.toggleUser(vm.userId) }
            ))
            .labelsHidden()
        }
        .padding(14)
        .background(Color(hex: 0xFF2D78).opacity(0.15), in: .rect(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color(hex: 0xFF2D78).opacity(0.25), lineWidth: 0.5)
        )
    }
}

// MARK: - Profile detail chip (item_v3_profile_chip)

private struct V3ProfileChip: View {
    let label: String
    let value: String
    var isPremium = false
    var url: URL?

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .kerning(0.7)
                .foregroundStyle(Theme.v3Text3.opacity(0.7))
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.v3Surface, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.v3Border, lineWidth: 0.5)
        )
        .contentShape(.rect)
        .onTapGesture {
            if let url { openURL(url) }
        }
    }

    private var valueColor: Color {
        if isPremium { return Theme.v3Gold }
        if url != nil { return Theme.brand }
        return Theme.v3Text1.opacity(0.82)
    }
}

// MARK: - Novel list (shared by ranking / search / series / user lists)

struct NovelList: View {
    let novels: [Novel]
    let onLoadMore: (() async -> Void)?
    let hasMore: Bool

    init(
        novels: [Novel],
        onLoadMore: (() async -> Void)? = nil,
        hasMore: Bool = false
    ) {
        self.novels = novels
        self.onLoadMore = onLoadMore
        self.hasMore = hasMore
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(novels) { novel in
                    NavigationLink(value: AppRoute.novelDetail(novel.id)) {
                        NovelRow(novel: novel)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
                if hasMore, !novels.isEmpty {
                    Color.clear
                        .frame(height: 40)
                        .onAppear { Task { await onLoadMore?() } }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

struct NovelRow: View {
    let novel: Novel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PixivAsyncImage(url: cover)
                .frame(width: 60, height: 80)
                .clipShape(.rect(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 4) {
                Text(novel.title ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let author = novel.user?.name {
                    Text(author).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if let v = novel.totalView { Label("\(v)", systemImage: "eye") }
                    if let b = novel.totalBookmarks { Label("\(b)", systemImage: "heart") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var cover: URL? {
        let s = novel.imageUrls?.medium ?? novel.imageUrls?.squareMedium
        return s.flatMap(URL.init(string:))
    }
}
