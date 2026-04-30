import SwiftUI

@MainActor
@Observable
private final class LatestWorksVM {
    var illusts: [Illust] = []
    var novels: [Novel] = []
    var isLoading = false
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
                self.illusts = (try? await self.api.latestIllusts())?.illusts ?? []
            }
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                self.novels = (try? await self.api.latestNovels())?.novels ?? []
            }
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
                    onTap: { _ in }
                ).tag(Section.illust)
                NovelList(novels: vm.novels).tag(Section.novel)
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
