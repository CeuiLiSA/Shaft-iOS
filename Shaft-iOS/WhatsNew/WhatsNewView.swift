import SwiftUI

@MainActor
@Observable
final class WhatsNewViewModel {
    var illusts: [Illust] = []
    var novels: [Novel] = []
    var illustNext: String?
    var novelNext: String?
    var restrict: String = "public"
    var isLoading = false
    var isLoadingMoreIllusts = false
    var isLoadingMoreNovels = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init() {
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async {
        if illusts.isEmpty && novels.isEmpty { await load() }
    }

    func setRestrict(_ r: String) async {
        guard r != restrict else { return }
        restrict = r
        illusts = []
        novels = []
        illustNext = nil
        novelNext = nil
        await load()
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                let r = try? await self.api.newIllustsFromFollowing(restrict: self.restrict)
                self.illusts = r?.illusts ?? []
                self.illustNext = r?.nextUrl
            }
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                let r = try? await self.api.newNovelsFromFollowing(restrict: self.restrict)
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

/// What's New (FragmentRight) — latest illusts and novels from followed users.
/// Public/private restrict toggle mirrors Pixiv-Shaft's segmented control.
struct WhatsNewView: View {
    @State private var vm = WhatsNewViewModel()
    @State private var section: Section = .illust
    @Environment(OnboardingStore.self) private var l10n

    enum Section: Hashable, CaseIterable { case illust, novel }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                restrictChip("public", label: l10n.t(.followingPublic))
                restrictChip("private", label: l10n.t(.followingPrivate))
                restrictChip("mypixiv", label: l10n.t(.followingMyPixiv))
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 8)

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
        .task { await vm.loadIfNeeded() }
    }

    @ViewBuilder
    private func restrictChip(_ r: String, label: String) -> some View {
        Button {
            Task { await vm.setRestrict(r) }
        } label: {
            Text(label)
                .font(.subheadline.weight(vm.restrict == r ? .bold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(vm.restrict == r ? Color.accentColor : Color(.secondarySystemBackground),
                            in: .capsule)
                .foregroundStyle(vm.restrict == r ? Color.white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func label(for s: Section) -> String {
        switch s {
        case .illust: return l10n.t(.searchTabIllust)
        case .novel:  return l10n.t(.searchTabNovel)
        }
    }
}
