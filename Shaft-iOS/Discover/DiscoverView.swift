import SwiftUI

@MainActor
@Observable
final class DiscoverViewModel {
    var illusts: [Illust] = []
    var nextUrl: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init() {
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async {
        if illusts.isEmpty { await load() }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let r = try await api.walkthroughIllusts()
            illusts = r.illusts
            nextUrl = r.nextUrl
        } catch {
            errorMessage = error.localizedDescription
        }
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

/// Discover tab — corresponds to Shaft FragmentCenter. Pixiv app-api exposes
/// "walkthrough" illusts as a curated discover feed; we render it as a
/// waterfall + a button into the spotlight (long-form articles) feed.
struct DiscoverView: View {
    @State private var vm = DiscoverViewModel()
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    chip(.spotlight, label: l10n.t(.discoverSpotlight), icon: "doc.richtext")
                    chip(.ranking(initialMode: "day"), label: l10n.t(.rankingTitle), icon: "trophy")
                    chip(.latestWorks, label: l10n.t(.latestWorksTitle), icon: "clock.badge")
                    chip(.mangaRecommend, label: l10n.t(.profileManga), icon: "book")
                    chip(.novelRecommend, label: l10n.t(.profileNovels), icon: "text.book.closed")
                    chip(.recommendUsers, label: l10n.t(.recommendUsersTitle), icon: "person.2.crop.square.stack")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)

            IllustWaterfallList(
                illusts: vm.illusts,
                isLoading: vm.isLoading,
                errorMessage: vm.errorMessage,
                onRefresh: { await vm.load() },
                onLoadMore: { await vm.loadMore() },
                hasMore: vm.nextUrl != nil
            )
        }
        .task { await vm.loadIfNeeded() }
    }

    @ViewBuilder
    private func chip(_ route: AppRoute, label: String, icon: String) -> some View {
        NavigationLink(value: route) {
            Label(label, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: .capsule)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
}
