import SwiftUI

// MARK: - Shared feed VM (BookmarkRankFeedSource / ViewRankFeedSource / WallpaperFeedSource)

/// Where a rank feed page pulls its first page from. Paging always goes through
/// `rankWorksByUrl` with the shaft `next_url` — that URL is a shaft absolute URL,
/// never an app-api cursor, so it is *not* handed to the detail pager (the
/// waterfall pushes the plain `Illust` value, same as TrendingFeedView).
enum RankFeedSource: Hashable, Sendable {
    /// discover/most-bookmarked with the given query (收藏榜 / AI 榜 / 全年龄榜 /
    /// 年代榜 / 标签专区 / 新作榜 / 长篇小说榜 / 动图榜 all share this).
    case bookmark(RankQuery)
    /// discover/most-viewed?type=
    case view(type: String)
    /// discover/wallpapers?screen= ("phone" | "desktop"), illust only.
    case wallpaper(screen: String)

    var type: String {
        switch self {
        case .bookmark(let q): return q.type
        case .view(let t): return t
        case .wallpaper: return "illust"
        }
    }
    var isNovel: Bool { type == "novel" }
    var scoreKey: RankScoreKey {
        if case .view = self { return .viewCount }
        return .bookmarkCount
    }
}

/// Switching a segment (or re-pointing a source) cancels the previous SwiftUI `.task`;
/// `URLSession` then throws `URLError.cancelled` (or `CancellationError`). That is not
/// a failure — surfacing it as `errorMessage` would leave the tab stuck on an error
/// state when the user comes back (and `loadIfNeeded` would refuse to refetch).
/// Android's ViewModel never sees this because a pager tab switch doesn't cancel it.
func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}

/// One rank feed: first page + `next_url` paging, with a generation counter so a
/// source switch mid-flight discards the stale result (same shape as ShaftWorksVM).
@MainActor
@Observable
final class RankWorksVM {
    private(set) var source: RankFeedSource
    var illusts: [Illust] = []
    var novels: [Novel] = []
    var nextUrl: String?
    /// Server `complete` flag of the first page; false → "榜单统计中" notice on top.
    var complete = true
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let client = ShaftApiV2Client.shared
    @ObservationIgnored private var generation = 0

    init(source: RankFeedSource) { self.source = source }

    var isNovel: Bool { source.isNovel }
    var isEmpty: Bool { illusts.isEmpty && novels.isEmpty }

    func loadIfNeeded() async {
        if isEmpty, !isLoading, errorMessage == nil { await load() }
    }

    /// Swap the query (e.g. a new tag / month) and reload; no-op for the same source.
    func setSource(_ s: RankFeedSource) async {
        guard s != source else { return }
        source = s
        generation += 1
        illusts = []; novels = []; nextUrl = nil; complete = true
        await load()
    }

    func load() async {
        let gen = generation
        let src = source
        isLoading = true
        errorMessage = nil
        defer { if gen == generation { isLoading = false } }
        do {
            let page: RankWorksPage
            switch src {
            case .bookmark(let q): page = try await client.mostBookmarked(q)
            case .view(let t): page = try await client.mostViewed(type: t)
            case .wallpaper(let s): page = try await client.wallpapers(screen: s)
            }
            guard gen == generation else { return }
            illusts = page.illusts
            novels = page.novels
            nextUrl = page.nextUrl?.isEmpty == false ? page.nextUrl : nil
            complete = page.complete
        } catch {
            guard gen == generation, !isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore, !isLoading else { return }
        let gen = generation
        let src = source
        isLoadingMore = true
        defer { if gen == generation { isLoadingMore = false } }
        if let page = try? await client.rankWorksByUrl(url, type: src.type, scoreKey: src.scoreKey) {
            guard gen == generation else { return }
            illusts.append(contentsOf: page.illusts)
            novels.append(contentsOf: page.novels)
            nextUrl = page.nextUrl?.isEmpty == false ? page.nextUrl : nil
        }
    }
}

/// The feed itself (waterfall or novel rows) plus the incomplete-rank notice.
/// No type picker — hosts compose that above (or not at all, e.g. 动图榜).
struct RankWorksBody: View {
    let vm: RankWorksVM
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            if !vm.complete, !vm.isEmpty {
                Text(l10n.t(.rankIncompleteNotice))
                    .font(.caption)
                    .foregroundStyle(Theme.v3Text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 6)
            }
            if vm.isNovel {
                NovelList(
                    novels: vm.novels,
                    isLoading: vm.isLoading,
                    onLoadMore: { await vm.loadMore() },
                    hasMore: vm.nextUrl != nil
                )
                .refreshable { await vm.load() }
                .overlay {
                    if vm.novels.isEmpty, !vm.isLoading, let err = vm.errorMessage {
                        InlineError(message: err) { Task { await vm.load() } }.padding()
                    }
                }
            } else {
                IllustWaterfallList(
                    illusts: vm.illusts,
                    isLoading: vm.isLoading,
                    errorMessage: vm.errorMessage,
                    onRefresh: { await vm.load() },
                    onLoadMore: { await vm.loadMore() },
                    hasMore: vm.nextUrl != nil
                )
            }
        }
        .task { await vm.loadIfNeeded() }
    }
}

// MARK: - Tabbed host (TypeTabsRankFragment)

/// One segment of a tabbed rank page: a stable id (server enum), its title and feed source.
struct RankTab: Identifiable, Hashable {
    let id: String
    let title: String
    let source: RankFeedSource
}

/// Segmented tabs over per-tab feeds. Each tab keeps its own VM (like Android's
/// ViewPager children) and only the visible one fetches (`autoLoad=false` +
/// RESUME_ONLY_CURRENT parity — the read endpoint is rate-limited per IP).
/// If a tab's `source` changes while the VM exists (月份切换) it is reset in place.
struct RankTabbedFeed: View {
    let tabs: [RankTab]
    @Binding var selection: String
    @State private var store: RankTabStore

    init(tabs: [RankTab], selection: Binding<String>) {
        self.tabs = tabs
        self._selection = selection
        self._store = State(initialValue: RankTabStore(tabs: tabs))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selection) {
                ForEach(tabs) { Text($0.title).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            if let tab = tabs.first(where: { $0.id == selection }) ?? tabs.first {
                let vm = store.vm(for: tab)
                RankWorksBody(vm: vm)
                    .id(tab.id)
                    // Source drift (e.g. 月份切换) resets the existing VM in place;
                    // same source → no-op, the body's own task does the first load.
                    .task(id: tab.source) { await vm.setSource(tab.source) }
            }
        }
    }
}

/// VMs for every tab, created eagerly (cheap — nothing fetches until visible).
@MainActor
final class RankTabStore {
    private var vms: [String: RankWorksVM]

    init(tabs: [RankTab]) {
        vms = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, RankWorksVM(source: $0.source)) })
    }

    func vm(for tab: RankTab) -> RankWorksVM {
        if let vm = vms[tab.id] { return vm }
        let vm = RankWorksVM(source: tab.source)   // tab list grew; not a SwiftUI state write
        vms[tab.id] = vm
        return vm
    }
}

/// 插画 / 漫画 / 小说 type tabs (RankType.ALL / ILLUST_MANGA) with a source builder.
@MainActor
func rankTypeTabs(_ l10n: OnboardingStore, novel: Bool = true,
                  source: (String) -> RankFeedSource) -> [RankTab] {
    var tabs = [
        RankTab(id: "illust", title: l10n.t(.profileIllusts), source: source("illust")),
        RankTab(id: "manga", title: l10n.t(.profileManga), source: source("manga")),
    ]
    if novel { tabs.append(RankTab(id: "novel", title: l10n.t(.profileNovels), source: source("novel"))) }
    return tabs
}

// MARK: - 收藏榜 / AI 榜 / 全年龄榜 (BookmarkRankFragment)

/// discover/most-bookmarked. `ai == "only"` → AI 榜 (插画/漫画 only: novel has no
/// illust_ai_type and the server 400s); `restrict == "sfw"` → 全年龄榜; both nil → 收藏榜.
struct BookmarkRankView: View {
    let ai: String?
    let restrict: String?
    @State private var selection = "illust"
    @Environment(OnboardingStore.self) private var l10n

    init(ai: String? = nil, restrict: String? = nil) {
        // Only exact enum values count; anything else falls back to the plain rank.
        self.ai = ai == "only" ? "only" : nil
        self.restrict = restrict == "sfw" ? "sfw" : nil
    }

    private var titleKey: LocalizedKey {
        if ai != nil { return .aiRankTitle }
        if restrict != nil { return .sfwRankTitle }
        return .bookmarkRankTitle
    }

    var body: some View {
        RankTabbedFeed(
            tabs: rankTypeTabs(l10n, novel: ai == nil) { type in
                .bookmark(RankQuery(type: type, ai: type == "novel" ? nil : ai, restrict: restrict))
            },
            selection: $selection
        )
        .navigationTitle(l10n.t(titleKey))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 浏览量榜 (ViewRankFragment)

struct ViewRankView: View {
    @State private var selection = "illust"
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        RankTabbedFeed(
            tabs: rankTypeTabs(l10n) { .view(type: $0) },
            selection: $selection
        )
        .navigationTitle(l10n.t(.viewRankTitle))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 长篇小说榜 (NovelLengthRankFragment)

/// discover/most-bookmarked?type=novel&length= — 长篇 / 中篇 / 短篇, long first.
struct NovelLengthRankView: View {
    @State private var selection = "long"
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        RankTabbedFeed(
            tabs: [
                RankTab(id: "long", title: l10n.t(.novelLengthLong),
                        source: .bookmark(RankQuery(type: "novel", length: "long"))),
                RankTab(id: "medium", title: l10n.t(.novelLengthMedium),
                        source: .bookmark(RankQuery(type: "novel", length: "medium"))),
                RankTab(id: "short", title: l10n.t(.novelLengthShort),
                        source: .bookmark(RankQuery(type: "novel", length: "short"))),
            ],
            selection: $selection
        )
        .navigationTitle(l10n.t(.novelLengthRankTitle))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 壁纸榜 (WallpaperRankFragment)

/// discover/wallpapers — 手机 (portrait) / 桌面 (landscape), phone first.
struct WallpaperRankView: View {
    @State private var selection = "phone"
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        RankTabbedFeed(
            tabs: [
                RankTab(id: "phone", title: l10n.t(.wallpaperScreenPhone), source: .wallpaper(screen: "phone")),
                RankTab(id: "desktop", title: l10n.t(.wallpaperScreenDesktop), source: .wallpaper(screen: "desktop")),
            ],
            selection: $selection
        )
        .navigationTitle(l10n.t(.wallpaperRankTitle))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 动图榜 (UgoiraRankFragment)

/// pixiv auto-tags every ugoira うごイラ, so this is the tag rank pinned to that
/// tag — no picker, no type tabs.
struct UgoiraRankView: View {
    @State private var vm = RankWorksVM(source: .bookmark(RankQuery(type: "illust", tag: "うごイラ")))
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        RankWorksBody(vm: vm)
            .navigationTitle(l10n.t(.ugoiraRankTitle))
            .navigationBarTitleDisplayMode(.inline)
    }
}
