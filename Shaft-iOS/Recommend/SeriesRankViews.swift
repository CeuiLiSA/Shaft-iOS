import SwiftUI

// MARK: - 系列榜 (SeriesRankFragment / SeriesRankFeedFragment)

@MainActor
@Observable
final class SeriesRankVM {
    /// Server enum: "manga" | "novel" (never localized).
    let type: String
    var items: [SeriesRankItem] = []
    var nextUrl: String?
    /// First page reported `complete == false` → 「榜单统计中」 notice at the top.
    /// Only the first page decides; paging never re-adds it.
    var showIncompleteNotice = false
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    var isNovel: Bool { type == "novel" }

    @ObservationIgnored private let client = ShaftApiV2Client.shared

    init(type: String) { self.type = type }

    func loadIfNeeded() async { if items.isEmpty { await load() } }

    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await client.discoverSeries(type: type)
            items = dedup(page.items)
            nextUrl = page.nextUrl
            showIncompleteNotice = !page.complete && !items.isEmpty
        } catch {
            if isCancellation(error) { return }   // tab switch cancelled the task, not a failure
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let page = try? await client.seriesByUrl(url) {
            let seen = Set(items.map(\.id))
            items.append(contentsOf: dedup(page.items).filter { !seen.contains($0.id) })
            nextUrl = page.nextUrl
        }
    }

    /// Upstream skips `series_id == 0` and collapses duplicate identities.
    private func dedup(_ list: [SeriesRankItem]) -> [SeriesRankItem] {
        var seen = Set<Int64>()
        return list.filter { $0.seriesId != 0 && seen.insert($0.seriesId).inserted }
    }
}

/// 漫画 / 小说 segments (manga first — stronger series mindset), one VM per tab
/// so switching back doesn't refetch (upstream pager keeps both fragments).
struct SeriesRankView: View {
    private enum Kind: Hashable { case manga, novel }
    @State private var kind: Kind = .manga
    @State private var mangaVM = SeriesRankVM(type: "manga")
    @State private var novelVM = SeriesRankVM(type: "novel")
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $kind) {
                Text(l10n.t(.profileManga)).tag(Kind.manga)
                Text(l10n.t(.profileNovels)).tag(Kind.novel)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            switch kind {
            case .manga: SeriesRankTab(vm: mangaVM)
            case .novel: SeriesRankTab(vm: novelVM)
            }
        }
        .navigationTitle(l10n.t(.seriesRankTitle))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One tab: optional `item_rank_notice` line (v3_text_3 12sp, centered) followed
/// by V3 series cards 12 apart. Card → series page, avatar / author → profile.
private struct SeriesRankTab: View {
    @Bindable var vm: SeriesRankVM
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.pushRoute) private var pushRoute

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if vm.showIncompleteNotice {
                    Text(l10n.t(.rankIncompleteNotice))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.v3Text3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
                }
                ForEach(vm.items) { item in
                    SeriesCard(model: cardModel(item), onAuthorTap: { openAuthor(item) })
                        .onTapGesture { openSeries(item) }
                }
                if vm.nextUrl != nil, !vm.items.isEmpty {
                    Color.clear.frame(height: 40)
                        .onAppear { Task { await vm.loadMore() } }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(Theme.v3Bg)
        .overlay {
            if vm.isLoading && vm.items.isEmpty {
                RowSkeletonList { MediaRowSkeleton(coverWidth: 84, coverHeight: 112) }
            } else if vm.items.isEmpty, let err = vm.errorMessage {
                InlineError(message: err) { Task { await vm.load() } }.padding()
            } else if vm.items.isEmpty && !vm.isLoading {
                ContentUnavailableView(l10n.t(.nothingHere), systemImage: "sparkles.tv")
            }
        }
        .refreshable { await vm.load() }
        .task { await vm.loadIfNeeded() }
    }

    private func cardModel(_ item: SeriesRankItem) -> SeriesCardModel {
        SeriesCardModel(
            title: item.title,
            coverUrl: item.coverUrl,
            countText: l10n.t(.seriesEpisodeCount, "\(item.workCount)"),
            subtitle: l10n.t(.seriesTotalBookmarks, RankCountFormat.compact(item.totalBookmarks)),
            subtitleAccent: true,
            authorName: item.userName,
            authorAvatarUrl: item.userAvatarUrl,
            rank: item.rank
        )
    }

    private func openSeries(_ item: SeriesRankItem) {
        guard item.seriesId != 0 else { return }
        pushRoute(vm.isNovel ? .novelSeries(seriesId: item.seriesId) : .illustSeries(seriesId: item.seriesId))
    }

    private func openAuthor(_ item: SeriesRankItem) {
        guard item.userId != 0 else { return }
        pushRoute(.userProfile(item.userId))
    }
}
