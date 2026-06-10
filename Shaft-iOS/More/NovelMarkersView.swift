import SwiftUI

@MainActor
@Observable
final class NovelMarkersVM {
    var items: [MarkedNovel] = []
    var nextUrl: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?
    /// Errors from row actions (remove) — shown as an alert, since the inline
    /// error overlay only renders on an empty list.
    var actionError: String?

    @ObservationIgnored private let api: PixivAPI

    init() {
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async { if items.isEmpty { await load() } }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let r = try await api.novelMarkers()
            items = r.markedNovels
            nextUrl = r.nextUrl
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let r: NovelMarkersResponse = try? await api.nextPage(url) {
            items.append(contentsOf: r.markedNovels)
            nextUrl = r.nextUrl
        }
    }

    /// Optimistic removal; on failure the item is re-inserted at its original
    /// index (a whole-array snapshot would drop pages appended by a concurrent
    /// loadMore while the request was in flight).
    func removeMarker(_ item: MarkedNovel) async {
        let removedIndex = items.firstIndex { $0.id == item.id }
        items.removeAll { $0.id == item.id }
        do {
            _ = try await api.deleteNovelMarker(item.novel.id)
        } catch {
            items.insert(item, at: min(removedIndex ?? items.count, items.count))
            actionError = error.localizedDescription
        }
    }
}

/// Shaft `FragmentNovelMarkers` — novels the user dropped a reading marker in,
/// each row badged with the marked page.
struct NovelMarkersView: View {
    @State private var vm = NovelMarkersVM()
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        List {
            ForEach(vm.items) { item in
                NavigationLink(value: AppRoute.novelDetail(item.novel.id)) {
                    HStack(alignment: .top, spacing: 12) {
                        PixivAsyncImage(url: coverURL(item.novel))
                            .frame(width: 64, height: 88)
                            .clipShape(.rect(cornerRadius: 6))
                            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.novel.title ?? "")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            if let name = item.novel.user?.name {
                                Text(name).font(.caption).foregroundStyle(.secondary)
                            }
                            if let page = item.novelMarker?.page, page > 0 {
                                Text(l10n.t(.markerPageFmt, "\(page)"))
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.accentColor.opacity(0.15), in: .capsule)
                                    .foregroundStyle(.tint)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await vm.removeMarker(item) }
                    } label: {
                        Label(l10n.t(.actionDelete), systemImage: "trash")
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
                ContentUnavailableView(l10n.t(.nothingHere), systemImage: "bookmark")
            }
        }
        .refreshable { await vm.load() }
        .task { await vm.loadIfNeeded() }
        .navigationTitle(l10n.t(.novelMarkersTitle))
        .navigationBarTitleDisplayMode(.inline)
        .alert(vm.actionError ?? "", isPresented: Binding(
            get: { vm.actionError != nil },
            set: { if !$0 { vm.actionError = nil } }
        )) {}
    }

    private func coverURL(_ novel: Novel) -> URL? {
        (novel.imageUrls?.medium ?? novel.imageUrls?.squareMedium ?? novel.imageUrls?.large)
            .flatMap(URL.init(string:))
    }
}
