import SwiftUI

// MARK: - User illusts / manga / bookmarks / novels (full-screen lists)

@MainActor
@Observable
private final class UserIllustsVM {
    let userId: Int64
    let type: String
    var illusts: [Illust] = []
    var nextUrl: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init(userId: Int64, type: String) {
        self.userId = userId; self.type = type
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async { if illusts.isEmpty { await load() } }
    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let r = try await api.userIllusts(userId, type: type)
            illusts = r.illusts
            nextUrl = r.nextUrl
        } catch { errorMessage = error.localizedDescription }
    }
    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let r: IllustResponse = try? await api.nextPage(url) {
            illusts.append(contentsOf: r.illusts)
            nextUrl = r.nextUrl
        }
    }
}

struct UserIllustsView: View {
    let userId: Int64
    let type: String
    @State private var vm: UserIllustsVM

    init(userId: Int64, type: String) {
        self.userId = userId; self.type = type
        _vm = State(wrappedValue: UserIllustsVM(userId: userId, type: type))
    }

    var body: some View {
        IllustWaterfallList(
            illusts: vm.illusts, isLoading: vm.isLoading,
            errorMessage: vm.errorMessage,
            onRefresh: { await vm.load() },
            onLoadMore: { await vm.loadMore() },
            hasMore: vm.nextUrl != nil
        )
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
    }
}

@MainActor
@Observable
private final class UserBookmarksVM {
    let userId: Int64
    var illusts: [Illust] = []
    var nextUrl: String?
    var isLoading = false; var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init(userId: Int64) {
        self.userId = userId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async { if illusts.isEmpty { await load() } }
    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let r = try await api.userBookmarkedIllusts(userId)
            illusts = r.illusts
            nextUrl = r.nextUrl
        } catch { errorMessage = error.localizedDescription }
    }
    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let r: IllustResponse = try? await api.nextPage(url) {
            illusts.append(contentsOf: r.illusts)
            nextUrl = r.nextUrl
        }
    }
}

struct UserBookmarksView: View {
    let userId: Int64
    @State private var vm: UserBookmarksVM
    @Environment(\.pushRoute) private var pushRoute
    @Environment(OnboardingStore.self) private var l10n

    /// 算一次就够：body 每次重算都去查钥匙串没有意义。
    private let isOwn: Bool

    init(userId: Int64) {
        self.userId = userId
        self.isOwn = userId == BookmarkMirrorService.loggedInUid()
        _vm = State(wrappedValue: UserBookmarksVM(userId: userId))
    }

    var body: some View {
        IllustWaterfallList(
            illusts: vm.illusts, isLoading: vm.isLoading,
            errorMessage: vm.errorMessage,
            onRefresh: { await vm.load() },
            onLoadMore: { await vm.loadMore() },
            hasMore: vm.nextUrl != nil
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 「按条件浏览收藏」：本页唯一能做倒序 / 按标签 / 按作者 / 按年份筛的入口
            //（pixiv 的收藏接口只能从新到旧顺着翻）。只对自己的收藏出现。
            if isOwn {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            pushRoute(.bookmarkLibrary(contentType: MirrorContentType.illust.code, restrict: "public"))
                        } label: {
                            Label(l10n.t(.bookmarkLibraryMenuEntry), systemImage: "line.3.horizontal.decrease.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        // 打开**自己**的收藏页 = 开启这个书架的本地镜像（见 `trackBookmarkShelfVisit`）。
        .onAppear { trackBookmarkShelfVisit(userId: userId, restrict: "public", contentType: .illust) }
        .task { await vm.loadIfNeeded() }
    }
}

@MainActor
@Observable
private final class UserNovelsVM {
    let userId: Int64
    var novels: [Novel] = []
    var nextUrl: String?
    var isLoading = false; var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init(userId: Int64) {
        self.userId = userId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async { if novels.isEmpty { await load() } }
    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let r = try await api.userNovels(userId)
            novels = r.novels
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

struct UserNovelsView: View {
    let userId: Int64
    @State private var vm: UserNovelsVM

    init(userId: Int64) {
        self.userId = userId
        _vm = State(wrappedValue: UserNovelsVM(userId: userId))
    }

    var body: some View {
        NovelList(
            novels: vm.novels,
            isLoading: vm.isLoading,
            onLoadMore: { await vm.loadMore() },
            hasMore: vm.nextUrl != nil
        )
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
        .refreshable { await vm.load() }
        .overlay {
            if vm.novels.isEmpty, !vm.isLoading, let err = vm.errorMessage {
                InlineError(message: err) { Task { await vm.load() } }.padding()
            }
        }
    }
}

// MARK: - Following / Followers

@MainActor
@Observable
private final class UserPreviewListVM {
    enum Source { case following(Int64), follower(Int64), recommended, mypixiv(Int64), related(Int64) }
    let source: Source
    var items: [UserPreview] = []
    var nextUrl: String?
    var isLoading = false; var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init(source: Source) {
        self.source = source
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async { if items.isEmpty { await load() } }
    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let r: UserPreviewResponse
            switch source {
            case .following(let id):  r = try await api.userFollowing(id)
            case .follower(let id):   r = try await api.userFollower(id)
            case .recommended:        r = try await api.recommendedUsers()
            case .mypixiv(let id):    r = try await api.userMyPixiv(id)
            case .related(let id):    r = try await api.userRelated(id)
            }
            items = r.userPreviews
            nextUrl = r.nextUrl
        } catch { errorMessage = error.localizedDescription }
    }
    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let r: UserPreviewResponse = try? await api.nextPage(url) {
            items.append(contentsOf: r.userPreviews)
            nextUrl = r.nextUrl
        }
    }
}

struct UserFollowingView: View {
    let userId: Int64
    @State private var vm: UserPreviewListVM
    @Environment(\.pushRoute) private var pushRoute
    @Environment(OnboardingStore.self) private var l10n
    private let isOwn: Bool

    init(userId: Int64) {
        self.userId = userId
        self.isOwn = userId == BookmarkMirrorService.loggedInUid()
        _vm = State(wrappedValue: UserPreviewListVM(source: .following(userId)))
    }
    var body: some View {
        UserPreviewList(
            items: vm.items,
            isLoading: vm.isLoading,
            onLoadMore: { await vm.loadMore() },
            hasMore: vm.nextUrl != nil
        )
        .task { await vm.loadIfNeeded() }
        .refreshable { await vm.load() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 「按条件浏览关注」：倒序 / 按最近投稿 / 按名字与最近作品标签搜的入口
            //（pixiv 的关注接口只能从新到旧顺着翻）。只对自己的关注出现。
            if isOwn {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            pushRoute(.bookmarkLibrary(contentType: MirrorContentType.user.code, restrict: "public"))
                        } label: {
                            Label(l10n.t(.followingLibraryMenuEntry), systemImage: "line.3.horizontal.decrease.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        // 打开**自己**的关注列表 = 开启关注书架的本地镜像（与收藏页同一个入口函数，隐私边界同一条）。
        .onAppear { trackBookmarkShelfVisit(userId: userId, restrict: "public", contentType: .user) }
    }
}

struct UserFollowerView: View {
    let userId: Int64
    @State private var vm: UserPreviewListVM
    init(userId: Int64) {
        self.userId = userId
        _vm = State(wrappedValue: UserPreviewListVM(source: .follower(userId)))
    }
    var body: some View {
        UserPreviewList(
            items: vm.items,
            isLoading: vm.isLoading,
            onLoadMore: { await vm.loadMore() },
            hasMore: vm.nextUrl != nil
        )
        .task { await vm.loadIfNeeded() }
        .refreshable { await vm.load() }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct UserMyPixivView: View {
    let userId: Int64
    @State private var vm: UserPreviewListVM
    init(userId: Int64) {
        self.userId = userId
        _vm = State(wrappedValue: UserPreviewListVM(source: .mypixiv(userId)))
    }
    var body: some View {
        UserPreviewList(
            items: vm.items,
            isLoading: vm.isLoading,
            onLoadMore: { await vm.loadMore() },
            hasMore: vm.nextUrl != nil
        )
        .task { await vm.loadIfNeeded() }
        .refreshable { await vm.load() }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct UserRelatedView: View {
    let userId: Int64
    @State private var vm: UserPreviewListVM
    init(userId: Int64) {
        self.userId = userId
        _vm = State(wrappedValue: UserPreviewListVM(source: .related(userId)))
    }
    var body: some View {
        UserPreviewList(
            items: vm.items,
            isLoading: vm.isLoading,
            onLoadMore: { await vm.loadMore() },
            hasMore: vm.nextUrl != nil
        )
        .task { await vm.loadIfNeeded() }
        .refreshable { await vm.load() }
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Related illusts

@MainActor
@Observable
private final class RelatedIllustsVM {
    let illustId: Int64
    var illusts: [Illust] = []
    var nextUrl: String?
    var isLoading = false; var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init(illustId: Int64) {
        self.illustId = illustId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async { if illusts.isEmpty { await load() } }
    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let r = try await api.relatedIllusts(illustId)
            illusts = r.illusts
            nextUrl = r.nextUrl
        } catch { errorMessage = error.localizedDescription }
    }
    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let r: IllustResponse = try? await api.nextPage(url) {
            illusts.append(contentsOf: r.illusts)
            nextUrl = r.nextUrl
        }
    }
}

struct RelatedIllustsView: View {
    let illustId: Int64
    @State private var vm: RelatedIllustsVM
    init(illustId: Int64) {
        self.illustId = illustId
        _vm = State(wrappedValue: RelatedIllustsVM(illustId: illustId))
    }
    var body: some View {
        IllustWaterfallList(
            illusts: vm.illusts, isLoading: vm.isLoading,
            errorMessage: vm.errorMessage,
            onRefresh: { await vm.load() },
            onLoadMore: { await vm.loadMore() },
            hasMore: vm.nextUrl != nil
        )
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
    }
}

// MARK: - Spotlight / Walkthrough / RecommendedUsers

@MainActor
@Observable
private final class SpotlightVM {
    var articles: [Article] = []
    var nextUrl: String?
    var isLoading = false; var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init() { self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared) }

    func loadIfNeeded() async { if articles.isEmpty { await load() } }
    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let r = try await api.spotlightArticles()
            articles = r.spotlightArticles
            nextUrl = r.nextUrl
        } catch { errorMessage = error.localizedDescription }
    }
    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let r: ArticlesResponse = try? await api.nextPage(url) {
            articles.append(contentsOf: r.spotlightArticles)
            nextUrl = r.nextUrl
        }
    }
}

struct SpotlightView: View {
    @State private var vm = SpotlightVM()
    @State private var openURL: URL?
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        List {
            ForEach(vm.articles) { article in
                Button {
                    if let s = article.articleUrl, let url = URL(string: s) {
                        openURL = url
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let url = article.thumbnail.flatMap(URL.init(string:)) {
                            PixivAsyncImage(url: url)
                                .frame(maxWidth: .infinity)
                                .frame(height: 160)
                                .clipShape(.rect(cornerRadius: 8))
                        }
                        Text(article.title ?? article.pureTitle ?? "")
                            .font(.headline)
                        if let date = article.publishDate {
                            Text(date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            if vm.nextUrl != nil, !vm.articles.isEmpty {
                Color.clear
                    .frame(height: 40)
                    .listRowSeparator(.hidden)
                    .onAppear { Task { await vm.loadMore() } }
            }
        }
        .listStyle(.plain)
        .overlay {
            if vm.isLoading, vm.articles.isEmpty {
                RowSkeletonList(count: 5, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonShape(corner: 8).frame(height: 160)
                        SkeletonBlock(height: 16)
                        SkeletonBlock(width: 120, height: 10)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(l10n.t(.discoverSpotlight))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
        .refreshable { await vm.load() }
        .navigationDestination(isPresented: Binding(
            get: { openURL != nil },
            set: { if !$0 { openURL = nil } }
        )) {
            if let url = openURL {
                WebArticleView(url: url)
            }
        }
    }
}

@MainActor
@Observable
private final class WalkthroughVM {
    var illusts: [Illust] = []
    var nextUrl: String?
    var isLoading = false; var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init() { self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared) }

    func loadIfNeeded() async { if illusts.isEmpty { await load() } }
    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let r = try await api.walkthroughIllusts()
            illusts = r.illusts
            nextUrl = r.nextUrl
        } catch { errorMessage = error.localizedDescription }
    }
    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let r: IllustResponse = try? await api.nextPage(url) {
            illusts.append(contentsOf: r.illusts)
            nextUrl = r.nextUrl
        }
    }
}

struct WalkthroughView: View {
    @State private var vm = WalkthroughVM()

    var body: some View {
        IllustWaterfallList(
            illusts: vm.illusts, isLoading: vm.isLoading,
            errorMessage: vm.errorMessage,
            onRefresh: { await vm.load() },
            onLoadMore: { await vm.loadMore() },
            hasMore: vm.nextUrl != nil
        )
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
    }
}

// MARK: - User novel bookmarks (V3 profile "小说收藏" nav chip)

@MainActor
@Observable
private final class UserNovelBookmarksVM {
    let userId: Int64
    var novels: [Novel] = []
    var nextUrl: String?
    var isLoading = false; var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init(userId: Int64) {
        self.userId = userId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async { if novels.isEmpty { await load() } }
    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let r = try await api.userBookmarkedNovels(userId)
            novels = r.novels
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

struct UserNovelBookmarksView: View {
    let userId: Int64
    @State private var vm: UserNovelBookmarksVM
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.pushRoute) private var pushRoute

    private let isOwn: Bool

    init(userId: Int64) {
        self.userId = userId
        self.isOwn = userId == BookmarkMirrorService.loggedInUid()
        _vm = State(wrappedValue: UserNovelBookmarksVM(userId: userId))
    }

    var body: some View {
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
        .navigationTitle(l10n.t(.navNovelBookmarks))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isOwn {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            pushRoute(.bookmarkLibrary(contentType: MirrorContentType.novel.code, restrict: "public"))
                        } label: {
                            Label(l10n.t(.bookmarkLibraryMenuEntry), systemImage: "line.3.horizontal.decrease.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .onAppear { trackBookmarkShelfVisit(userId: userId, restrict: "public", contentType: .novel) }
        .task { await vm.loadIfNeeded() }
    }
}

// MARK: - User works filtered by tag (V3 work-tab filter bar / advanced search)

/// Pages the author's works through the app API and keeps only the ones
/// carrying `tag`. `category` mirrors the upstream web-ajax path segment
/// ("illusts" / "manga" / "novels"), which is how `UserTagSearchSheet.routeOf`
/// picks the destination list.
///
/// Deviation: upstream routes this to the pixiv **web** ajax endpoint, which
/// returns the server-side filtered id list. That endpoint needs a web session
/// (PHPSESSID) we don't have on iOS, so we page the app API and filter
/// client-side, chasing a few extra pages while matches are thin.
@MainActor
@Observable
private final class UserWorksByTagVM {
    let userId: Int64
    let tag: String
    let category: String
    var illusts: [Illust] = []
    var novels: [Novel] = []
    var nextUrl: String?
    var isLoading = false; var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init(userId: Int64, tag: String, category: String) {
        self.userId = userId; self.tag = tag; self.category = category
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    var isNovel: Bool { category == "novels" }
    private var illustType: String { category == "manga" ? "manga" : "illust" }
    private var count: Int { isNovel ? novels.count : illusts.count }

    private func matches(_ tags: [Tag]?) -> Bool {
        tags?.contains { $0.name == tag } ?? false
    }

    func loadIfNeeded() async { if illusts.isEmpty && novels.isEmpty { await load() } }

    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            if isNovel {
                let r = try await api.userNovels(userId)
                novels = r.novels.filter { matches($0.tags) }
                nextUrl = r.nextUrl
            } else {
                let r = try await api.userIllusts(userId, type: illustType)
                illusts = r.illusts.filter { matches($0.tags) }
                nextUrl = r.nextUrl
            }
            await fillIfThin()
        } catch { errorMessage = error.localizedDescription }
    }

    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if isNovel {
            if let r: NovelResponse = try? await api.nextPage(url) {
                novels.append(contentsOf: r.novels.filter { matches($0.tags) })
                nextUrl = r.nextUrl
            }
        } else {
            if let r: IllustResponse = try? await api.nextPage(url) {
                illusts.append(contentsOf: r.illusts.filter { matches($0.tags) })
                nextUrl = r.nextUrl
            }
        }
    }

    /// A page can filter down to zero matches; chase a few more pages so the
    /// first screen isn't empty even though more matches exist further in.
    private func fillIfThin() async {
        var hops = 0
        while count < 10, nextUrl != nil, hops < 5 {
            await loadMore()
            hops += 1
        }
    }
}

struct UserIllustTagView: View {
    let userId: Int64
    let tag: String
    let category: String
    @State private var vm: UserWorksByTagVM

    init(userId: Int64, tag: String, category: String = "illusts") {
        self.userId = userId; self.tag = tag; self.category = category
        _vm = State(wrappedValue: UserWorksByTagVM(userId: userId, tag: tag, category: category))
    }

    var body: some View {
        Group {
            if vm.isNovel {
                NovelList(
                    novels: vm.novels,
                    isLoading: vm.isLoading,
                    onLoadMore: { await vm.loadMore() },
                    hasMore: vm.nextUrl != nil
                )
                .refreshable { await vm.load() }
            } else {
                IllustWaterfallList(
                    illusts: vm.illusts, isLoading: vm.isLoading,
                    errorMessage: vm.errorMessage,
                    onRefresh: { await vm.load() },
                    onLoadMore: { await vm.loadMore() },
                    hasMore: vm.nextUrl != nil
                )
            }
        }
        .navigationTitle("#\(tag)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
    }
}
