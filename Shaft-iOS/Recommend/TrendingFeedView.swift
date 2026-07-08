import SwiftUI

/// Shared view model for the two shaft-api-v2 work feeds:
/// - 当前最热 (`.recent`) — window nil (实时) / day / week / month.
/// - 本月收藏·站长推荐 (`.trending`) — fixed window=week, sort=bookmark.
/// Content type (插画/漫画/小说) maps 1:1 to the server `type` enum.
@MainActor
@Observable
final class ShaftWorksVM {
    enum Source { case recent, trending }
    enum Kind: String, CaseIterable { case illust, manga, novel }

    let source: Source
    var kind: Kind = .illust
    /// Recent-only window; nil = 实时 live feed. Unused by `.trending`.
    var window: String?
    var illusts: [Illust] = []
    var novels: [Novel] = []
    var nextUrl: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let client = ShaftApiV2Client.shared
    /// Bumped on every kind/window switch; in-flight loads captured under an old
    /// generation discard their result instead of appending stale data.
    @ObservationIgnored private var generation = 0
    private var scoreFromBookmark: Bool { source == .recent }

    init(source: Source) { self.source = source }

    func loadIfNeeded() async {
        if illusts.isEmpty && novels.isEmpty { await load() }
    }

    func setKind(_ k: Kind) async { guard k != kind else { return }; kind = k; await reset() }
    func setWindow(_ w: String?) async { guard w != window else { return }; window = w; await reset() }

    private func reset() async {
        generation += 1
        illusts = []; novels = []; nextUrl = nil
        await load()
    }

    func load() async {
        let gen = generation
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page: WorksPage
            switch source {
            case .recent:   page = try await client.recentWorks(type: kind.rawValue, window: window)
            case .trending: page = try await client.trendingWorks(type: kind.rawValue)
            }
            guard gen == generation else { return }   // superseded by a kind/window switch
            illusts = page.illusts
            novels = page.novels
            nextUrl = page.nextUrl
        } catch {
            guard gen == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        let gen = generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let page = try? await client.worksByUrl(url, type: kind.rawValue, scoreFromBookmark: scoreFromBookmark) {
            guard gen == generation else { return }   // kind/window changed mid-flight
            illusts.append(contentsOf: page.illusts)
            novels.append(contentsOf: page.novels)
            nextUrl = page.nextUrl
        }
    }
}

/// The inner content: 插画/漫画/小说 segments + the waterfall / novel list.
/// (Both cell types already render the trending "▲ N" pill from `trendingScore`.)
private struct ShaftWorksBody: View {
    @Bindable var vm: ShaftWorksVM
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(
                get: { vm.kind },
                set: { k in Task { await vm.setKind(k) } }
            )) {
                Text(l10n.t(.profileIllusts)).tag(ShaftWorksVM.Kind.illust)
                Text(l10n.t(.profileManga)).tag(ShaftWorksVM.Kind.manga)
                Text(l10n.t(.profileNovels)).tag(ShaftWorksVM.Kind.novel)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            if vm.kind == .novel {
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
            } else {
                IllustWaterfallList(
                    illusts: vm.illusts,
                    isLoading: vm.isLoading,
                    errorMessage: vm.errorMessage,
                    onRefresh: { await vm.load() },
                    onLoadMore: { await vm.loadMore() },
                    hasMore: vm.nextUrl != nil
                )
            }
        }
        .task { await vm.loadIfNeeded() }
    }
}

/// 当前最热 — recent bookmarks, with a 实时/日/周/月 window selector.
struct RecentRecommendView: View {
    @State private var vm = ShaftWorksVM(source: .recent)
    @State private var gate = SensitiveGateStore.shared
    @Environment(OnboardingStore.self) private var l10n

    private var windowOptions: [(String?, LocalizedKey)] {
        [(nil, .recentWindowLive), ("day", .recentWindowDay),
         ("week", .recentWindowWeek), ("month", .recentWindowMonth)]
    }
    private var windowLabel: String {
        let key = windowOptions.first { $0.0 == vm.window }?.1 ?? .recentWindowLive
        return l10n.t(key)
    }

    var body: some View {
        SensitiveGate { ShaftWorksBody(vm: vm) }
            .navigationTitle(l10n.t(.currentHot))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Only after the gate is acked — avoids a pre-consent fetch if the
                // window menu were tapped on the gate panel.
                if gate.acked {
                    ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(windowOptions, id: \.1) { opt in
                            Button {
                                Task { await vm.setWindow(opt.0) }
                            } label: {
                                if vm.window == opt.0 { Label(l10n.t(opt.1), systemImage: "checkmark") }
                                else { Text(l10n.t(opt.1)) }
                            }
                        }
                    } label: {
                        Label(windowLabel, systemImage: "clock.arrow.circlepath")
                            .font(.subheadline)
                    }
                    }
                }
            }
    }
}

/// 本月收藏 / 站长推荐 — fixed week/bookmark trending (no window selector).
/// NB: the label says 本月收藏 but the query is week — faithful to upstream.
struct SiteRecommendView: View {
    @State private var vm = ShaftWorksVM(source: .trending)
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        SensitiveGate { ShaftWorksBody(vm: vm) }
            .navigationTitle(l10n.t(.siteRecommend))
            .navigationBarTitleDisplayMode(.inline)
    }
}
