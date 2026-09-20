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

// MARK: - Remaining FragmentCenter destinations

/// Web destinations share the existing persistent browser session.
/// This shell does not reproduce Android's native comic or discovery feeds.
struct DiscoverWebDestinationView: View {
    let titleKey: LocalizedKey
    let url: URL
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        WebArticleView(url: url)
            .navigationTitle(l10n.t(titleKey))
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct PixivComicView: View {
    var body: some View {
        DiscoverWebDestinationView(
            titleKey: .pixivComic,
            url: URL(string: "https://comic.pixiv.net/")!
        )
    }
}

@MainActor
@Observable
private final class DiscoverIllustFeedVM {
    var illusts: [Illust] = []
    var nextURL: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    @ObservationIgnored private var generation = 0

    func loadIfNeeded() async { if illusts.isEmpty, !isLoading { await load() } }

    func load() async {
        generation += 1
        let loadGeneration = generation
        isLoading = true
        errorMessage = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let response = try await api.latestIllusts(type: "illust")
            guard generation == loadGeneration, !Task.isCancelled else { return }
            illusts = response.illusts
            nextURL = response.nextUrl
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let url = nextURL, !isLoadingMore, !isLoading else { return }
        let loadGeneration = generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let response: IllustResponse = try await api.nextPage(url)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            illusts.append(contentsOf: response.illusts)
            nextURL = response.nextUrl
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

/// Temporary latest-works feed. Android's local discovery pool and its
/// collection/ranking pipeline have not been ported to iOS yet.
struct DiscoveryFeedView: View {
    @State private var vm = DiscoverIllustFeedVM()
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        IllustWaterfallList(
            illusts: vm.illusts,
            isLoading: vm.isLoading,
            errorMessage: vm.errorMessage,
            onRefresh: { await vm.load() },
            onLoadMore: { await vm.loadMore() },
            hasMore: vm.nextURL != nil
        )
        .overlay(alignment: .bottom) {
            if let error = vm.errorMessage, !vm.illusts.isEmpty {
                InlineError(message: error) { Task { await vm.load() } }
                    .padding(8)
            }
        }
        .navigationTitle(l10n.t(.discoveryFeed))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
    }
}

@MainActor
@Observable
private final class DailyRecommendationsVM {
    var illusts: [Illust] = []
    var nextCursor: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?
    var errorKey: LocalizedKey?
    var isPersonalized = false
    var date: String?
    var refreshAt: Int64?

    @ObservationIgnored private let shaft = ShaftApiV2Client.shared
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var accountUID: Int64?

    func loadIfNeeded() async {
        guard !isLoading else { return }
        let uid = KeychainTokenStore.shared.load()?.user?.id ?? 0
        let expired = refreshAt.map { Date().timeIntervalSince1970 * 1000 >= Double($0) } ?? false
        if accountUID != uid || illusts.isEmpty || expired { await load() }
    }

    func load() async {
        generation += 1
        let loadGeneration = generation
        isLoading = true
        isLoadingMore = false
        errorMessage = nil
        errorKey = nil
        defer { if generation == loadGeneration { isLoading = false } }
        let uid = KeychainTokenStore.shared.load()?.user?.id ?? 0
        if accountUID != uid {
            accountUID = uid
            illusts = []
            nextCursor = nil
            date = nil
            refreshAt = nil
            isPersonalized = false
        }
        guard uid > 0 else {
            errorKey = .dailyRecommendationsLogin
            return
        }
        guard ShaftEventsConfig.hmacEnabled else {
            errorKey = .dailyRecommendationsUnavailable
            return
        }
        do {
            let page = try await shaft.dailyRecommendations(uid: uid)
            try Task.checkCancellation()
            guard generation == loadGeneration,
                  KeychainTokenStore.shared.load()?.user?.id == uid else { return }
            illusts = page.illusts
            errorMessage = nil
            errorKey = nil
            nextCursor = page.nextCursor
            date = page.date
            refreshAt = page.refreshAt
            isPersonalized = page.mode == "personalized"
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration, !Task.isCancelled,
                  KeychainTokenStore.shared.load()?.user?.id == uid else { return }
            errorKey = dailyErrorKey(for: error)
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard !isLoadingMore, !isLoading else { return }
        let uid = KeychainTokenStore.shared.load()?.user?.id ?? 0
        guard accountUID == uid else { await load(); return }
        guard uid > 0, let cursor = nextCursor, errorKey == nil else { return }
        let loadGeneration = generation
        isLoadingMore = true
        defer { if generation == loadGeneration { isLoadingMore = false } }
        do {
            let page = try await shaft.dailyRecommendations(uid: uid, cursor: cursor)
            try Task.checkCancellation()
            guard generation == loadGeneration,
                  KeychainTokenStore.shared.load()?.user?.id == uid else { return }
            illusts.append(contentsOf: page.illusts)
            nextCursor = page.nextCursor
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration, !Task.isCancelled,
                  KeychainTokenStore.shared.load()?.user?.id == uid else { return }
            errorKey = dailyErrorKey(for: error)
            errorMessage = error.localizedDescription
        }
    }

    private func dailyErrorKey(for error: Error) -> LocalizedKey {
        if case ShaftApiError.http(let status) = error, status == 409 {
            return .dailyRecommendationsExpired
        }
        return .dailyRecommendationsUnavailable
    }
}

/// Daily recommendations are the account-aware Shaft feed; a signed-out or
/// unavailable account is shown as an explicit state instead of a different feed.
struct DailyRecommendationsView: View {
    @State private var vm = DailyRecommendationsVM()
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.scenePhase) private var scenePhase
    @State private var mute = MuteStore.shared

    var body: some View {
        VStack(spacing: 0) {
            Text(dailySummary)
                .font(.montserratMedium(14))
                .foregroundStyle(Theme.v3Text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            IllustWaterfallList(
                illusts: vm.illusts,
                isLoading: vm.isLoading,
                errorMessage: vm.errorKey.map { l10n.t($0) } ?? vm.errorMessage,
                onRefresh: { await vm.load() },
                onLoadMore: { await vm.loadMore() },
                hasMore: vm.nextCursor != nil && vm.errorKey == nil
            )
            .overlay {
                if mute.filter(vm.illusts).isEmpty, !vm.isLoading,
                   vm.errorKey == nil, vm.errorMessage == nil {
                    Text(l10n.t(.dailyRecommendationsEmpty))
                        .font(.footnote)
                        .foregroundStyle(Theme.v3Text2)
                        .multilineTextAlignment(.center)
                        .padding(24)
                }
            }
            .overlay(alignment: .bottom) {
                if !vm.illusts.isEmpty,
                   let message = vm.errorKey.map({ l10n.t($0) }) ?? vm.errorMessage {
                    InlineError(message: message) { Task { await vm.load() } }
                        .padding(8)
                }
            }
        }
        .navigationTitle(l10n.t(.dailyRecommendations))
        .navigationBarTitleDisplayMode(.inline)
        .background(Theme.v3Bg)
        .task(id: scenePhase) {
            if scenePhase == .active { await vm.loadIfNeeded() }
        }
    }

    private var dailySummary: String {
        guard let date = vm.date, !date.isEmpty else {
            return l10n.t(.dailyRecommendationsIntro)
        }
        let key: LocalizedKey = vm.isPersonalized
            ? .dailyRecommendationsPersonalized
            : .dailyRecommendationsPopular
        return String(format: l10n.t(key), date)
    }
}

@MainActor
@Observable
private final class CorpusLibraryVM {
    var tags: [CorpusTagSummary] = []
    var isLoading = false
    var errorMessage: String?
    @ObservationIgnored private let api = ShaftApiV2Client.shared
    @ObservationIgnored private var generation = 0

    func loadIfNeeded() async { if tags.isEmpty, !isLoading { await load() } }

    func load() async {
        generation += 1
        let loadGeneration = generation
        isLoading = true
        errorMessage = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let tags = try await api.corpusTags()
            guard generation == loadGeneration, !Task.isCancelled else { return }
            self.tags = tags
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

struct CorpusLibraryView: View {
    @State private var vm = CorpusLibraryVM()
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                if vm.isLoading && vm.tags.isEmpty {
                    ForEach(0..<6, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Theme.v3Surface2)
                            .frame(height: 112)
                            .shimmering()
                    }
                } else if let error = vm.errorMessage, vm.tags.isEmpty {
                    InlineError(message: error) { Task { await vm.load() } }
                } else {
                    ForEach(vm.tags) { tag in
                        NavigationLink(value: AppRoute.corpusTagDetail(tag: tag.name)) {
                            CorpusTagCard(tag: tag)
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.v3Bg)
        .refreshable { await vm.load() }
        .navigationTitle(l10n.t(.corpusLibrary))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
    }
}

private struct CorpusTagCard: View {
    let tag: CorpusTagSummary
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tag.name)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.v3Text1)
                .lineLimit(1)
                .padding(.bottom, 4)
            Text(l10n.t(.corpusTagWorkCount, String(tag.count)))
                .font(.system(size: 15))
                .foregroundStyle(Theme.v3Text2)
            if !tag.previewURLs.isEmpty {
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { index in
                            if index < tag.previewURLs.count {
                                PixivAsyncImage(
                                    url: URL(string: tag.previewURLs[index]),
                                    showsProgress: false,
                                    placeholder: Theme.v3Surface2
                                )
                                .frame(width: (proxy.size.width - 4) / 3,
                                       height: (proxy.size.width - 4) / 3)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                            } else {
                                Color.clear
                                    .frame(width: (proxy.size.width - 4) / 3,
                                           height: (proxy.size.width - 4) / 3)
                            }
                        }
                    }
                }
                .aspectRatio(3, contentMode: .fit)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

@MainActor
@Observable
private final class CorpusTagWorksVM {
    let tag: String
    var illusts: [Illust] = []
    var cursor: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?
    @ObservationIgnored private let api = ShaftApiV2Client.shared
    @ObservationIgnored private var generation = 0

    init(tag: String) { self.tag = tag }
    func loadIfNeeded() async { if illusts.isEmpty, !isLoading { await load() } }
    func load() async {
        generation += 1
        let loadGeneration = generation
        isLoading = true; errorMessage = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let page = try await api.corpusWorks(tag: tag, r18: MuteStore.shared.hideR18 ? 0 : 2)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            illusts = page.illusts; cursor = page.nextCursor
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
    func loadMore() async {
        guard let cursor, !isLoadingMore, !isLoading else { return }
        let loadGeneration = generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await api.corpusWorks(tag: tag, cursor: cursor,
                                                 r18: MuteStore.shared.hideR18 ? 0 : 2)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            illusts.append(contentsOf: page.illusts); self.cursor = page.nextCursor
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

struct CorpusTagWorksView: View {
    let tag: String
    @State private var vm: CorpusTagWorksVM

    init(tag: String) { self.tag = tag; _vm = State(wrappedValue: CorpusTagWorksVM(tag: tag)) }

    var body: some View {
        IllustWaterfallList(
            illusts: vm.illusts,
            isLoading: vm.isLoading,
            errorMessage: vm.errorMessage,
            onRefresh: { await vm.load() },
            onLoadMore: { await vm.loadMore() },
            hasMore: vm.cursor != nil
        )
        .overlay(alignment: .bottom) {
            if let error = vm.errorMessage, !vm.illusts.isEmpty {
                InlineError(message: error) { Task { await vm.load() } }
                    .padding(8)
            }
        }
        .navigationTitle(tag)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
    }
}
