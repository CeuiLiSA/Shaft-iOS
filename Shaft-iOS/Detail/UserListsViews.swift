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

    init(userId: Int64) {
        self.userId = userId
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
            onLoadMore: { await vm.loadMore() },
            hasMore: vm.nextUrl != nil
        )
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
        .refreshable { await vm.load() }
        .overlay {
            if vm.isLoading && vm.novels.isEmpty {
                ProgressView()
            } else if vm.novels.isEmpty, let err = vm.errorMessage {
                InlineError(message: err) { Task { await vm.load() } }.padding()
            }
        }
    }
}

// MARK: - Following / Followers

@MainActor
@Observable
private final class UserPreviewListVM {
    enum Source { case following(Int64), follower(Int64), recommended }
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
    init(userId: Int64) {
        self.userId = userId
        _vm = State(wrappedValue: UserPreviewListVM(source: .following(userId)))
    }
    var body: some View {
        UserPreviewList(
            items: vm.items,
            onLoadMore: { await vm.loadMore() },
            hasMore: vm.nextUrl != nil
        )
        .task { await vm.loadIfNeeded() }
        .refreshable { await vm.load() }
        .navigationBarTitleDisplayMode(.inline)
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

// MARK: - Manga recommendations

@MainActor
@Observable
private final class MangaRecommendVM {
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
            let r = try await api.recommendedManga()
            illusts = r.illusts
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
    @State private var vm = MangaRecommendVM()
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        IllustWaterfallList(
            illusts: vm.illusts, isLoading: vm.isLoading,
            errorMessage: vm.errorMessage,
            onRefresh: { await vm.load() },
            onLoadMore: { await vm.loadMore() },
            hasMore: vm.nextUrl != nil
        )
        .navigationTitle(l10n.t(.profileManga))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
    }
}

// MARK: - Novel recommendations

@MainActor
@Observable
private final class NovelRecommendVM {
    var novels: [Novel] = []
    var nextUrl: String?
    var isLoading = false; var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init() { self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared) }

    func loadIfNeeded() async { if novels.isEmpty { await load() } }
    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let r = try await api.recommendedNovels()
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

struct NovelRecommendView: View {
    @State private var vm = NovelRecommendVM()
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        NovelList(
            novels: vm.novels,
            onLoadMore: { await vm.loadMore() },
            hasMore: vm.nextUrl != nil
        )
        .refreshable { await vm.load() }
        .overlay {
            if vm.novels.isEmpty && vm.isLoading { ProgressView() }
            else if vm.novels.isEmpty, let err = vm.errorMessage {
                InlineError(message: err) { Task { await vm.load() } }.padding()
            }
        }
        .navigationTitle(l10n.t(.profileNovels))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
    }
}
