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

    func remove(_ item: WatchlistItem) async {
        let kept = items
        items.removeAll { $0.id == item.id }
        do {
            _ = try await api.removeFromWatchlist(kind: kind, seriesId: item.id)
        } catch {
            items = kept
            errorMessage = error.localizedDescription
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
            case .manga: WatchlistPage(vm: mangaVM, isManga: true)
            case .novel: WatchlistPage(vm: novelVM, isManga: false)
            }
        }
        .navigationTitle(l10n.t(.watchlistTitle))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WatchlistPage: View {
    @Bindable var vm: WatchlistVM
    let isManga: Bool
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        List {
            ForEach(vm.items) { item in
                if item.isMasked {
                    // Deleted / restricted series come back masked — show the
                    // server's mask text, no navigation.
                    Text(item.maskText ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    WatchlistRow(item: item, isManga: isManga)
                        .swipeActions(edge: .trailing) {
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
                    .onAppear { Task { await vm.loadMore() } }
            }
        }
        .listStyle(.plain)
        .overlay {
            if vm.isLoading && vm.items.isEmpty {
                ProgressView()
            } else if vm.items.isEmpty, let err = vm.errorMessage {
                InlineError(message: err) { Task { await vm.load() } }.padding()
            } else if vm.items.isEmpty && !vm.isLoading {
                ContentUnavailableView(l10n.t(.nothingHere), systemImage: "sparkles.tv")
            }
        }
        .refreshable { await vm.load() }
        .task { await vm.loadIfNeeded() }
    }
}

private struct WatchlistRow: View {
    let item: WatchlistItem
    let isManga: Bool
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        NavigationLink(value: seriesRoute) {
            HStack(alignment: .top, spacing: 12) {
                PixivAsyncImage(url: item.url.flatMap(URL.init(string:)))
                    .frame(width: 72, height: 96)
                    .clipShape(.rect(cornerRadius: 6))
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title ?? "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let name = item.user?.name {
                        Text(name).font(.caption).foregroundStyle(.secondary)
                    }
                    if let count = item.publishedContentCount {
                        Text(String(format: l10n.t(.episodesFmt), "\(count)"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let date = item.lastPublishedContentDatetime {
                        Text(String(date.prefix(10)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }

    private var seriesRoute: AppRoute {
        isManga ? .illustSeries(seriesId: item.id) : .novelSeries(seriesId: item.id)
    }
}
