import SwiftUI

@MainActor
@Observable
private final class LatestWorksVM {
    var illusts: [Illust] = []
    var novels: [Novel] = []
    var illustNext: String?
    var novelNext: String?
    var isLoading = false
    var isLoadingMoreIllusts = false
    var isLoadingMoreNovels = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init() { api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared) }

    func loadIfNeeded() async {
        if illusts.isEmpty && novels.isEmpty { await load() }
    }

    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                let r = try? await self.api.latestIllusts()
                self.illusts = r?.illusts ?? []
                self.illustNext = r?.nextUrl
            }
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                let r = try? await self.api.latestNovels()
                self.novels = r?.novels ?? []
                self.novelNext = r?.nextUrl
            }
        }
    }

    func loadMoreIllusts() async {
        guard let url = illustNext, !isLoadingMoreIllusts else { return }
        isLoadingMoreIllusts = true
        defer { isLoadingMoreIllusts = false }
        if let r: IllustResponse = try? await api.nextPage(url) {
            illusts.append(contentsOf: r.illusts)
            illustNext = r.nextUrl
        }
    }

    func loadMoreNovels() async {
        guard let url = novelNext, !isLoadingMoreNovels else { return }
        isLoadingMoreNovels = true
        defer { isLoadingMoreNovels = false }
        if let r: NovelResponse = try? await api.nextPage(url) {
            novels.append(contentsOf: r.novels)
            novelNext = r.nextUrl
        }
    }
}

/// FragmentLatestWorks + FragmentLatestNovel — globally newest illusts/novels.
struct LatestWorksView: View {
    @State private var vm = LatestWorksVM()
    @State private var section: Section = .illust
    @Environment(OnboardingStore.self) private var l10n

    enum Section: Hashable, CaseIterable { case illust, novel }

    var body: some View {
        VStack(spacing: 0) {
            PagerTabBar(
                titles: Section.allCases.map { ($0, label(for: $0)) },
                selection: $section
            )
            TabView(selection: $section) {
                IllustWaterfallList(
                    illusts: vm.illusts, isLoading: vm.isLoading,
                    errorMessage: vm.errorMessage,
                    onRefresh: { await vm.load() },
                    onLoadMore: { await vm.loadMoreIllusts() },
                    hasMore: vm.illustNext != nil
                ).tag(Section.illust)
                NovelList(
                    novels: vm.novels,
                    isLoading: vm.isLoading,
                    onLoadMore: { await vm.loadMoreNovels() },
                    hasMore: vm.novelNext != nil
                ).tag(Section.novel)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle(l10n.t(.latestWorksTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
    }

    private func label(for s: Section) -> String {
        switch s {
        case .illust: return l10n.t(.searchTabIllust)
        case .novel:  return l10n.t(.searchTabNovel)
        }
    }
}
