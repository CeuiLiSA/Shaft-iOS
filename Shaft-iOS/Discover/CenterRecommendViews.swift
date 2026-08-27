import SwiftUI

// 1:1 ports of the two FragmentCenter「重点模块」destinations:
//
// - 推荐漫画 → `RecmdMangaFeedFragment` = `RecmdIllustFeedFragment(TYPE_MANGA)` in a
//   `fragment_toolbar_feed` shell: toolbar title「推荐 + 漫画」, then a heterogeneous
//   list = `recy_recmd_header` (crown「排行榜」+「查看更多」→ RankActivity(漫画) +
//   horizontal `recy_rank_illust_horizontal` hero strip +「为你推荐」row) followed by
//   the recommended waterfall. Data = `/v1/manga/recommended?include_ranking_illusts=true`.
// - 推荐小说 → `FragmentNewNovel` = `viewpager_with_tablayout`: toolbar「小说」+ search
//   menu, two tabs「推荐作品」(`RecmdNovelFeedFragment`, same header shape over
//   `ranking_novels` + `recy_novel` cards) and「热门标签」(`HotTagsFeedFragment(novel)`).

// MARK: - 推荐漫画 (RecmdMangaFeedFragment)

@MainActor
@Observable
private final class RecmdMangaFeedVM {
    var rankingIllusts: [Illust] = []
    var illusts: [Illust] = []
    var nextUrl: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)

    func loadIfNeeded() async { if illusts.isEmpty { await load() } }

    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            // Upstream `getRecommendedWorksWithRanking("manga")`: first page carries
            // `ranking_illusts` for the preview header.
            let r = try await api.recommendedWorksWithRanking(type: "manga")
            illusts = r.illusts
            rankingIllusts = r.rankingIllusts ?? []
            nextUrl = r.nextUrl
        } catch { errorMessage = error.localizedDescription }
    }

    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let r: HomeIllustResponse = try? await api.nextPage(url) {
            illusts.append(contentsOf: r.illusts)
            nextUrl = r.nextUrl
        }
    }
}

struct MangaRecommendView: View {
    @State private var vm = RecmdMangaFeedVM()
    @State private var mute = MuteStore.shared
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        let visible = mute.filter(vm.illusts)
        // Upstream mapRecmdPage: the ranking preview is filtered by the mute list
        // (blocked works / tags / artists, issue #543) but NOT by the R-18 taste
        // filter — a ranking board isn't personalised recommendation.
        let rankVisible = mute.filter(vm.rankingIllusts, applyR18: false)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if vm.illusts.isEmpty, let err = vm.errorMessage {
                    InlineError(message: err) { Task { await vm.load() } }
                        .padding(12)
                } else if visible.isEmpty, vm.isLoading {
                    WaterfallSkeleton(columns: mute.waterfallColumns)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                }

                if !rankVisible.isEmpty {
                    RecmdRankHeader(seeMoreRoute: .ranking(initialMode: "day_manga", kind: "manga")) {
                        RankIllustHeroStrip(illusts: rankVisible)
                    }
                }

                if !visible.isEmpty {
                    // SpacesItemWithHeadDecoration(8dp): 8pt gutters around the
                    // staggered cells under the full-span header.
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
                        .contextMenu { IllustCellContextMenuItems(illust: illust) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                }

                if vm.isLoadingMore {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
                } else if vm.nextUrl != nil, !vm.illusts.isEmpty {
                    Color.clear
                        .frame(height: 40)
                        .onAppear { Task { await vm.loadMore() } }
                }
            }
            .padding(.bottom, 12)
        }
        .background(Theme.v3Bg)
        .refreshable { await vm.load() }
        .navigationTitle(l10n.t(.centerRecommendMangaTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
    }
}

// MARK: - 小说 (FragmentNewNovel: 推荐作品 / 热门标签 pager)

struct NovelRecommendView: View {
    @State private var subTab: SubTab = .recommended
    // Both tabs' state lives here (upstream keeps both Fragments alive in the
    // pager): switching tabs and back must not refetch a new batch / lose scroll.
    @State private var recmdVM = RecmdNovelFeedVM()
    @State private var hotTagsVM = HotTagsVM(contentType: "novel")
    @Environment(OnboardingStore.self) private var l10n

    enum SubTab: Hashable, CaseIterable { case recommended, hotTag }

    private func title(_ tab: SubTab) -> String {
        switch tab {
        case .recommended: return l10n.t(.subRecommendedWorks)   // recommend_illust
        case .hotTag:      return l10n.t(.subPopularTags)        // hot_tag
        }
    }

    var body: some View {
        // Sub-tabs switch by condition (not a page controller — see the note in
        // `RecommendView`) so the nav-bar top inset stays stable. This also gives
        // the hot-tag tab its upstream lazy-load semantics (BEHAVIOR_RESUME_ONLY_
        // CURRENT_FRAGMENT): its request fires only once the tab is shown.
        Group {
            switch subTab {
            case .recommended: RecmdNovelFeedView(vm: recmdVM)
            case .hotTag:      HotTagsGridView(vm: hotTagsVM)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            PagerTabBar(
                titles: SubTab.allCases.map { ($0, title($0)) },
                selection: $subTab
            )
        }
        .navigationTitle(l10n.t(.profileNovels))   // type_novel
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // menu/fragment_left: a single always-shown search action → 搜索 page.
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: AppRoute.search) {
                    Image(systemName: "magnifyingglass")
                }
            }
        }
    }
}

// MARK: - 推荐小说 tab (RecmdNovelFeedFragment)

@MainActor
@Observable
private final class RecmdNovelFeedVM {
    var rankingNovels: [Novel] = []
    var novels: [Novel] = []
    var nextUrl: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)

    func loadIfNeeded() async { if novels.isEmpty { await load() } }

    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let r = try await api.recommendedNovelsWithRanking()
            novels = r.novels
            rankingNovels = r.rankingNovels ?? []
            nextUrl = r.nextUrl
        } catch { errorMessage = error.localizedDescription }
    }

    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let r: NovelResponse = try? await api.nextPage(url) {
            novels.append(contentsOf: r.novels)
            nextUrl = r.nextUrl
        }
    }
}

private struct RecmdNovelFeedView: View {
    let vm: RecmdNovelFeedVM
    @State private var mute = MuteStore.shared

    var body: some View {
        let visible = mute.filter(vm.novels)
        // Same as the manga page: mute list only, no R-18 taste filter on the board.
        let rankVisible = mute.filter(vm.rankingNovels, applyR18: false)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if vm.novels.isEmpty, let err = vm.errorMessage {
                    InlineError(message: err) { Task { await vm.load() } }
                        .padding(12)
                } else if visible.isEmpty, vm.isLoading {
                    NovelListSkeleton()
                }

                if !rankVisible.isEmpty {
                    RecmdRankHeader(seeMoreRoute: .ranking(initialMode: "day", kind: "novel")) {
                        RankNovelHeroStrip(novels: rankVisible)
                    }
                }

                if !visible.isEmpty {
                    NovelListContent(
                        novels: visible,
                        hasMore: vm.nextUrl != nil,
                        onLoadMore: { await vm.loadMore() }
                    )
                }

                if vm.isLoadingMore {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
                }
            }
            .padding(.bottom, 12)
        }
        .background(Theme.v3Bg)
        .refreshable { await vm.load() }
        .task { await vm.loadIfNeeded() }
    }
}

// MARK: - recy_recmd_header (ranking preview header + 「为你推荐」 row)

/// `recy_recmd_header.xml`: crown +「排行榜」(15sp bold, v3_text_1) with「查看更多 ›」
/// (13sp, colorPrimary) on the right, the horizontal ranking strip below, then a
/// 30dp `recmd` icon +「为你推荐」(15sp bold) introducing the feed underneath.
private struct RecmdRankHeader<Strip: View>: View {
    let seeMoreRoute: AppRoute
    @ViewBuilder let strip: () -> Strip
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.v3Gold)
                    Text(l10n.t(.centerRankingHeader))
                        .font(.system(size: 15, weight: .bold))
                        .kerning(0.15)
                        .foregroundStyle(Theme.v3Text1)
                }
                .padding(.leading, 8)
                Spacer(minLength: 16)
                NavigationLink(value: seeMoreRoute) {
                    HStack(spacing: 2) {
                        Text(l10n.t(.detailSeeMore))
                            .font(.system(size: 13))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.brand)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
            }
            .padding(.top, 12)
            .padding(.bottom, 4)

            strip()

            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 30, height: 30)
                Text(l10n.t(.centerRecmdForYou))
                    .font(.system(size: 15, weight: .bold))
                    .kerning(0.15)
                    .foregroundStyle(Theme.v3Text1)
            }
            .padding(.leading, 8)
            .padding(.top, 6)
        }
    }
}

// MARK: - Hero strips (recy_rank_illust_horizontal / recy_rank_novel_horizontal)

/// `bg_v3_card_scrim`: bottom #B3000000 → center #40000000 → top transparent.
private var heroScrim: LinearGradient {
    LinearGradient(
        stops: [
            .init(color: .black.opacity(0.70), location: 0),
            .init(color: .black.opacity(0.25), location: 0.5),
            .init(color: .clear, location: 1),
        ],
        startPoint: .bottom, endPoint: .top
    )
}

private let heroSide: CGFloat = 180

/// Upstream `RAdapter` strip: 180dp hero cards, 8dp apart (LinearItemHorizontalDecoration).
/// Tap opens the illust; long-press exposes the same card menu as the waterfall.
private struct RankIllustHeroStrip: View {
    let illusts: [Illust]

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(illusts) { illust in
                    NavigationLink(value: illust) {
                        RankIllustHeroCard(illust: illust)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { IllustCellContextMenuItems(illust: illust) }
                }
            }
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
    }
}

private struct RankIllustHeroCard: View {
    let illust: Illust

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // `GlideUtil.getLargeImage`: large (600x1200_90) is crisper than medium in a 180dp card.
            PixivAsyncImage(url: (illust.imageUrls?.large ?? illust.imageUrls?.medium).flatMap(URL.init(string:)))
                .frame(width: heroSide, height: heroSide)
                .clipped()
            heroScrim.frame(height: 96)
            VStack(alignment: .leading, spacing: 5) {
                Text(illust.title ?? "")
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    HeroAvatar(url: illust.user?.profileImageUrls?.medium, size: 20)
                    Text(illust.user?.name ?? "")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 9)
            .frame(width: heroSide, alignment: .leading)
        }
        .frame(width: heroSide, height: heroSide)
        .background(Theme.v3Surface2)
        .clipShape(.rect(cornerRadius: 16))
    }
}

/// `RecmdNovelRankAdapter` strip over `recy_rank_novel_horizontal`.
private struct RankNovelHeroStrip: View {
    let novels: [Novel]

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(novels) { novel in
                    NavigationLink(value: AppRoute.novelDetail(novel.id)) {
                        RankNovelHeroCard(novel: novel)
                    }
                    .buttonStyle(.plain)
                    .novelCardMenu(novel: novel) { novels }
                }
            }
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
        .cardMenuHost()
    }
}

private struct RankNovelHeroCard: View {
    let novel: Novel
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PixivAsyncImage(url: novel.imageUrls?.medium.flatMap(URL.init(string:)))
                .frame(width: heroSide, height: heroSide)
                .clipped()
            heroScrim.frame(height: 110)
            VStack(alignment: .leading, spacing: 5) {
                // Novel titles run long: two lines here (illust hero gets one).
                Text(novel.title ?? "")
                    .font(.system(size: 14, weight: .bold))
                    .kerning(-0.28)
                    .lineSpacing(1.5)
                    .lineLimit(2)
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    HeroAvatar(url: novel.user?.profileImageUrls?.medium, size: 20)
                    Text(novel.user?.name ?? "")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 9)
            .frame(width: heroSide, alignment: .leading)
        }
        .frame(width: heroSide, height: heroSide)
        .background(Theme.v3Surface2)
        .overlay(alignment: .topTrailing) {
            // bg_v3_rank_novel_pill: word-count capsule, #66000000, top-right 8dp.
            Text(l10n.t(.novelWordCountFmt, "\(novel.textLength ?? 0)"))
                .font(.system(size: 10, weight: .bold))
                .kerning(0.2)
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.black.opacity(0.4), in: .capsule)
                .padding(8)
        }
        .clipShape(.rect(cornerRadius: 16))
    }
}

private struct HeroAvatar: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        PixivAsyncImage(url: url.flatMap(URL.init(string:)))
            .frame(width: size, height: size)
            .clipShape(.circle)
    }
}

// MARK: - 热门标签 (HotTagsFeedFragment)

@MainActor
@Observable
final class HotTagsVM {
    let contentType: String
    var tags: [TrendingTag] = []
    var isLoading = false
    var errorMessage: String?

    @ObservationIgnored private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)

    init(contentType: String) { self.contentType = contentType }

    func loadIfNeeded() async { if tags.isEmpty { await load() } }

    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let r = try await api.trendingTags(type: contentType)
            // Drop nameless tags first (their key is the tag name; an empty one
            // can't open a search anyway).
            tags = r.trendTags.filter { !($0.tag ?? "").isEmpty }
        } catch { errorMessage = error.localizedDescription }
    }
}

/// `HotTagsFeedFragment`: 3-column grid, 1dp gutters (`TagItemDecoration(3, 1dp)`);
/// the first tag spans the full row at 0.66 height/width with the `large` image,
/// the rest are 1:1 squares with `medium`. Tap → search on that tag with the
/// illust/novel tab preselected; long-press → the representative illust.
struct HotTagsGridView: View {
    let vm: HotTagsVM
    private var contentType: String { vm.contentType }

    private let columns = [
        GridItem(.flexible(), spacing: 1),
        GridItem(.flexible(), spacing: 1),
        GridItem(.flexible(), spacing: 1),
    ]

    var body: some View {
        ScrollView {
            if vm.tags.isEmpty, let err = vm.errorMessage {
                InlineError(message: err) { Task { await vm.load() } }
                    .padding(12)
            } else if vm.tags.isEmpty, vm.isLoading {
                TagGridSkeleton(columns: 3)
            } else {
                LazyVStack(spacing: 1) {
                    if let head = vm.tags.first {
                        HotTagCell(tag: head, contentType: contentType, heightRatio: 0.66, large: true)
                    }
                    LazyVGrid(columns: columns, spacing: 1) {
                        ForEach(vm.tags.dropFirst()) { tag in
                            HotTagCell(tag: tag, contentType: contentType, heightRatio: 1.0, large: false)
                        }
                    }
                }
            }
        }
        .background(Theme.v3Bg)
        .refreshable { await vm.load() }
        .task { await vm.loadIfNeeded() }
    }
}

/// `recy_tag_grid.xml`: image with the `side_rank_horizon` foreground (transparent →
/// #66000000 at the bottom), and two centered, shadowed white bold lines pinned to
/// the bottom —「#译名」(12sp) above「#标签」(13sp), 4dp bottom margin.
private struct HotTagCell: View {
    let tag: TrendingTag
    let contentType: String
    let heightRatio: CGFloat
    let large: Bool
    /// Long-press target (upstream opens the tag's representative illust in VActivity).
    @State private var pushedIllust: Illust?

    var body: some View {
        NavigationLink(value: AppRoute.searchResults(word: tag.tag ?? "", section: contentType)) {
            PixivAsyncImage(url: imageURL, placeholder: Theme.lightBg)
                .aspectRatio(1 / heightRatio, contentMode: .fit)
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 0.5),
                            .init(color: .black.opacity(0.4), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(alignment: .bottom) {
                    VStack(spacing: 4) {
                        if let translated = tag.translatedName, !translated.isEmpty {
                            Text("#\(translated)")
                                .font(.system(size: 12, weight: .bold))
                        }
                        Text("#\(tag.tag ?? "")")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 1, x: 1, y: 1)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
                }
                .clipped()
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let illust = tag.illust {
                Button {
                    pushedIllust = illust
                } label: {
                    Label(illust.title ?? "#\(tag.tag ?? "")", systemImage: "photo")
                }
            }
        }
        // Same destination as `RouteHost`'s `Illust` registration; a `NavigationLink`
        // inside a context menu doesn't reliably push, a state-driven one does.
        .navigationDestination(item: $pushedIllust) { illust in
            IllustDetailView(illust: illust)
                .toolbar(.hidden, for: .tabBar)
                .background(SwipeBackEnabler())
        }
    }

    private var imageURL: URL? {
        let urls = tag.illust?.imageUrls
        let s = large
            ? (urls?.large ?? urls?.medium ?? urls?.squareMedium)
            : (urls?.medium ?? urls?.squareMedium ?? urls?.large)
        return s.flatMap(URL.init(string:))
    }
}

// MARK: - Novel card context menu (showNovelCardMenu — share / copy / open / mute author)

struct NovelCellContextMenuItems: View {
    let novel: Novel
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.openURL) private var openURL

    private var pixivURL: URL {
        URL(string: "https://www.pixiv.net/novel/show.php?id=\(novel.id)")!
    }

    var body: some View {
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
        if let user = novel.user {
            Divider()
            Button(role: .destructive) {
                MuteStore.shared.toggleUser(user.id)
            } label: {
                Label(l10n.t(.actionMuteArtist), systemImage: "speaker.slash")
            }
        }
    }
}
