import SwiftUI

// MARK: - 好P友作品 (NiceFriendIllustFeedFragment)

@MainActor
@Observable
private final class NiceFriendIllustsVM {
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
            let r = try await api.niceFriendIllusts()
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

/// 好P友的插画/漫画作品 — mypixiv (mutual friends) illust feed, plain nextUrl paging.
struct NiceFriendIllustsView: View {
    @State private var vm = NiceFriendIllustsVM()
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        IllustWaterfallList(
            illusts: vm.illusts,
            isLoading: vm.isLoading,
            errorMessage: vm.errorMessage,
            onRefresh: { await vm.load() },
            onLoadMore: { await vm.loadMore() },
            hasMore: vm.nextUrl != nil
        )
        .navigationTitle(l10n.t(.niceFriendWorksPageTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
    }
}

// MARK: - 关注者的小说 (FollowingNovelFeedFragment, standalone form)

@MainActor
@Observable
private final class FollowingNovelsVM {
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
            // TemplateActivity entry: restrict defaults to Params.TYPE_ALL.
            let r = try await api.newNovelsFromFollowing(restrict: "all")
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

/// 关注者的最新小说 — followed artists' newest novels (restrict=all).
struct FollowingNovelsView: View {
    @State private var vm = FollowingNovelsVM()
    @Environment(OnboardingStore.self) private var l10n

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
        .navigationTitle(l10n.t(.followingNovelsPageTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
    }
}

// MARK: - Not-yet-ported Discover destinations

/// Stand-in for Discover「其他分类」pages whose upstream screens (shaft-api-v2
/// 画师榜/均分榜/浏览量榜/收藏榜/AI榜/年代榜/标签榜/壁纸榜, pixiv 漫画, 算法发现流)
/// have no iOS port yet. Keeps the chip wiring 1:1 so each page can land later.
struct DiscoverPendingView: View {
    let titleKey: LocalizedKey
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        PlaceholderView(title: l10n.t(titleKey), systemImage: "hammer")
            .navigationTitle(l10n.t(titleKey))
            .navigationBarTitleDisplayMode(.inline)
    }
}
