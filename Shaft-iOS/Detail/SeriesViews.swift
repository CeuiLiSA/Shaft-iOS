import SwiftUI

// MARK: - Illust series

@MainActor
@Observable
private final class IllustSeriesVM {
    let seriesId: Int64
    var detail: IllustSeriesDetail?
    var illusts: [Illust] = []
    var nextUrl: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init(seriesId: Int64) {
        self.seriesId = seriesId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async { if illusts.isEmpty { await load() } }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let r = try await api.illustSeries(seriesId)
            detail = r.illustSeriesDetail
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
        if let r: IllustSeriesResponse = try? await api.nextPage(url) {
            illusts.append(contentsOf: r.illusts)
            nextUrl = r.nextUrl
        }
    }
}

struct IllustSeriesView: View {
    let seriesId: Int64
    @State private var vm: IllustSeriesVM
    @Environment(OnboardingStore.self) private var l10n

    init(seriesId: Int64) {
        self.seriesId = seriesId
        _vm = State(wrappedValue: IllustSeriesVM(seriesId: seriesId))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let d = vm.detail {
                VStack(alignment: .leading, spacing: 4) {
                    Text(d.title ?? "")
                        .font(.title3.bold())
                    if let count = d.workCount {
                        Text("\(count)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let cap = d.caption, !cap.isEmpty {
                        Text(cap).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
            IllustWaterfallList(
                illusts: vm.illusts,
                isLoading: vm.isLoading,
                errorMessage: vm.errorMessage,
                onRefresh: { await vm.load() },
                onLoadMore: { await vm.loadMore() },
                hasMore: vm.nextUrl != nil
            )
        }
        .navigationTitle(vm.detail?.title ?? l10n.t(.seriesTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
    }
}

// MARK: - Novel series

@MainActor
@Observable
private final class NovelSeriesVM {
    let seriesId: Int64
    var detail: NovelSeriesDetail?
    var novels: [Novel] = []
    var nextUrl: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?
    /// Watchlist (追更) toggle state, seeded from `novel_series_detail.watchlist_added`.
    var watchlistAdded = false
    var isTogglingWatchlist = false

    @ObservationIgnored private let api: PixivAPI

    init(seriesId: Int64) {
        self.seriesId = seriesId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async { if novels.isEmpty { await load() } }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let r = try await api.novelSeries(seriesId)
            detail = r.novelSeriesDetail
            novels = r.novels
            nextUrl = r.nextUrl
            // Don't clobber an in-flight optimistic toggle with a response
            // that predates it (refresh racing the add/delete POST).
            if !isTogglingWatchlist {
                watchlistAdded = r.novelSeriesDetail?.watchlistAdded == true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Optimistic toggle, rolled back on failure — Shaft `toggleWatchlist`.
    func toggleWatchlist() async {
        guard !isTogglingWatchlist else { return }
        isTogglingWatchlist = true
        defer { isTogglingWatchlist = false }
        let next = !watchlistAdded
        watchlistAdded = next
        do {
            if next {
                _ = try await api.addToWatchlist(kind: "novel", seriesId: seriesId)
            } else {
                _ = try await api.removeFromWatchlist(kind: "novel", seriesId: seriesId)
            }
        } catch {
            // Roll back only if nothing else (e.g. a refresh) already moved it.
            if watchlistAdded == next { watchlistAdded = !next }
        }
    }

    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let r: NovelSeriesDetailResponse = try? await api.nextPage(url) {
            novels.append(contentsOf: r.novels)
            nextUrl = r.nextUrl
        }
    }
}

struct NovelSeriesView: View {
    let seriesId: Int64
    @State private var vm: NovelSeriesVM
    @Environment(OnboardingStore.self) private var l10n

    init(seriesId: Int64) {
        self.seriesId = seriesId
        _vm = State(wrappedValue: NovelSeriesVM(seriesId: seriesId))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let d = vm.detail {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(d.title ?? "")
                            .font(.title3.bold())
                        if let count = d.contentCount {
                            Text("\(count)").font(.caption).foregroundStyle(.secondary)
                        }
                        if let cap = d.caption, !cap.isEmpty {
                            Text(cap).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 追更 toggle — pixiv's native series-header watchlist switch.
                    Button {
                        Task { await vm.toggleWatchlist() }
                    } label: {
                        Label(
                            l10n.t(vm.watchlistAdded ? .watchlistAdded : .watchlistAdd),
                            systemImage: vm.watchlistAdded ? "checkmark" : "plus"
                        )
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(
                            vm.watchlistAdded
                                ? AnyShapeStyle(Color(.secondarySystemBackground))
                                : AnyShapeStyle(Color.accentColor.opacity(0.15)),
                            in: .capsule
                        )
                        .foregroundStyle(vm.watchlistAdded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isTogglingWatchlist)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
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
        }
        .navigationTitle(vm.detail?.title ?? l10n.t(.seriesTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
    }
}
