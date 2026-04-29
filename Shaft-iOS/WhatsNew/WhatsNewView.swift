import SwiftUI

@MainActor
@Observable
final class WhatsNewViewModel {
    var illusts: [Illust] = []
    var novels: [Novel] = []
    var isLoading = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init() {
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async {
        if illusts.isEmpty && novels.isEmpty { await load() }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                self.illusts = (try? await self.api.newIllustsFromFollowing())?.illusts ?? []
            }
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                self.novels = (try? await self.api.newNovelsFromFollowing())?.novels ?? []
            }
        }
    }
}

/// What's New (FragmentRight) — latest illusts and novels from followed users.
struct WhatsNewView: View {
    @State private var vm = WhatsNewViewModel()
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
        .task { await vm.loadIfNeeded() }
    }

    private func label(for s: Section) -> String {
        switch s {
        case .illust: return l10n.t(.searchTabIllust)
        case .novel:  return l10n.t(.searchTabNovel)
        }
    }
}
