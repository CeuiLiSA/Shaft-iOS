import SwiftUI

@MainActor
@Observable
final class WatchlistVM {
    /// `manga` or `novel` — the two endpoints are symmetric.
    let kind: String
    var items: [WatchlistItem] = []
    var nextUrl: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?
    /// Errors from row actions (remove) — shown as an alert, since the inline
    /// error overlay only renders on an empty list.
    var actionError: String?

    var isManga: Bool { kind == "manga" }

    @ObservationIgnored private let api: PixivAPI

    init(kind: String) {
        self.kind = kind
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async { if items.isEmpty { await load() } }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let r = try await api.watchlist(kind: kind)
            items = r.series
            nextUrl = r.nextUrl
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let r: WatchlistResponse = try? await api.nextPage(url) {
            items.append(contentsOf: r.series)
            nextUrl = r.nextUrl
        }
    }

    /// Optimistic removal; on failure the item is re-inserted at its original
    /// index (a whole-array snapshot would drop pages appended by a concurrent
    /// loadMore while the request was in flight).
    func remove(_ item: WatchlistItem) async {
        let removedIndex = items.firstIndex { $0.id == item.id }
        items.removeAll { $0.id == item.id }
        do {
            _ = try await api.removeFromWatchlist(kind: kind, seriesId: item.id)
        } catch {
            items.insert(item, at: min(removedIndex ?? items.count, items.count))
            actionError = error.localizedDescription
        }
    }
}

/// Shaft `FragmentCollection` watchlist tab — manga + novel 追更 lists.
struct WatchlistView: View {
    private enum Kind: Hashable { case manga, novel }
    @State private var kind: Kind = .manga
    @State private var mangaVM = WatchlistVM(kind: "manga")
    @State private var novelVM = WatchlistVM(kind: "novel")
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $kind) {
                Text(l10n.t(.profileManga)).tag(Kind.manga)
                Text(l10n.t(.profileNovels)).tag(Kind.novel)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            switch kind {
            case .manga: WatchlistPage(vm: mangaVM)
            case .novel: WatchlistPage(vm: novelVM)
            }
        }
        .navigationTitle(l10n.t(.watchlistTitle))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WatchlistPage: View {
    @Bindable var vm: WatchlistVM
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        List {
            ForEach(vm.items) { item in
                // Masked (deleted / restricted) entries render the same card
                // with only the server's mask text — no navigation, no delete.
                WatchlistRow(item: item, isManga: vm.isManga)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    // 12 between cards = upstream `LinearItemDecoration(12dp)`.
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .swipeActions(edge: .trailing) {
                        if !item.isMasked {
                            Button(role: .destructive) {
                                Task { await vm.remove(item) }
                            } label: {
                                Label(l10n.t(.actionDelete), systemImage: "trash")
                            }
                        }
                    }
            }
            if vm.nextUrl != nil, !vm.items.isEmpty {
                Color.clear
                    .frame(height: 40)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .onAppear { Task { await vm.loadMore() } }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.v3Bg)
        .overlay {
            if vm.isLoading && vm.items.isEmpty {
                RowSkeletonList { MediaRowSkeleton(coverWidth: 84, coverHeight: 112) }
            } else if vm.items.isEmpty, let err = vm.errorMessage {
                InlineError(message: err) { Task { await vm.load() } }.padding()
            } else if vm.items.isEmpty && !vm.isLoading {
                // `watchlist_empty`: an empty watchlist is the normal case, not 「居然啥也没有」.
                ContentUnavailableView(l10n.t(.watchlistEmpty), systemImage: "sparkles.tv")
            }
        }
        .refreshable { await vm.load() }
        .task { await vm.loadIfNeeded() }
        .alert(vm.actionError ?? "", isPresented: Binding(
            get: { vm.actionError != nil },
            set: { if !$0 { vm.actionError = nil } }
        )) {}
    }
}

/// Shared V3 series card (`WatchlistFeed.kt` renderers). Card tap → series page
/// for both kinds; the pill is 「查看最新话」→ series page for manga, but
/// 「阅读最新话」→ the latest *work* (`latest_content_id`) for novels.
/// Avatar / author name → artist profile. Masked entries do nothing.
private struct WatchlistRow: View {
    let item: WatchlistItem
    let isManga: Bool
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.pushRoute) private var pushRoute

    var body: some View {
        SeriesCard(
            model: cardModel,
            onAuthorTap: item.isMasked ? nil : { openAuthor() },
            onAction: item.isMasked ? nil : { openLatest() }
        )
        .onTapGesture { openSeries() }
    }

    /// `WatchlistSeries.toCardModel`: ISO datetime → date part only (safe prefix).
    private var cardModel: SeriesCardModel {
        if item.isMasked {
            return SeriesCardModel(
                title: "", coverUrl: nil, countText: "", subtitle: "", subtitleAccent: false,
                authorName: "", authorAvatarUrl: nil, maskText: item.maskText
            )
        }
        let date = item.lastPublishedContentDatetime.map { String($0.prefix(10)) } ?? ""
        return SeriesCardModel(
            title: item.title ?? "",
            coverUrl: item.url,
            countText: l10n.t(.seriesEpisodeCount, "\(item.publishedContentCount ?? 0)"),
            subtitle: date.isEmpty ? "" : l10n.t(.seriesUpdatedAt, date),
            subtitleAccent: false,
            authorName: item.user?.name ?? "",
            authorAvatarUrl: item.user?.profileImageUrls?.medium,
            actionText: l10n.t(isManga ? .watchlistViewLatest : .watchlistReadLatest)
        )
    }

    private func openSeries() {
        guard !item.isMasked else { return }
        pushRoute(isManga ? .illustSeries(seriesId: item.id) : .novelSeries(seriesId: item.id))
    }

    private func openLatest() {
        if isManga {
            openSeries()
        } else if let latest = item.latestContentId {
            // Upstream `PixivOperate.getNovelByID(latest_content_id)`; a missing id is
            // a server edge case — silently ignored rather than NPE'd like legacy.
            pushRoute(.novelDetail(latest))
        }
    }

    private func openAuthor() {
        guard let uid = item.user?.id, uid != 0 else { return }
        pushRoute(.userProfile(uid))
    }
}
