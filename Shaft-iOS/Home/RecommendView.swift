import SwiftUI

@MainActor
@Observable
final class RecommendViewModel {
    var rankingIllusts: [Illust] = []
    var recommendedIllusts: [Illust] = []
    var recommendedNext: String?
    var trendingTags: [TrendingTag] = []
    var isLoadingRanking = false
    var isLoadingRecommended = false
    var isLoadingMoreRecommended = false
    var isLoadingTags = false
    var rankingError: String?
    var recommendedError: String?
    var tagError: String?

    @ObservationIgnored private let api: PixivAPI

    init() {
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    // MARK: Recommend page (ranking + waterfall recommendations)

    /// Either request can succeed or fail independently — each writes its own
    /// list and its own error so the UI can show a successful section even
    /// when the other section's request errored.
    func loadRecommendIfNeeded() async {
        await withTaskGroup(of: Void.self) { group in
            if rankingIllusts.isEmpty && !isLoadingRanking {
                group.addTask { @MainActor [weak self] in await self?.loadRanking() }
            }
            if recommendedIllusts.isEmpty && !isLoadingRecommended {
                group.addTask { @MainActor [weak self] in await self?.loadRecommended() }
            }
        }
    }

    func loadRecommend() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in await self?.loadRanking() }
            group.addTask { @MainActor [weak self] in await self?.loadRecommended() }
        }
    }

    func loadRanking() async {
        isLoadingRanking = true
        rankingError = nil
        defer { isLoadingRanking = false }
        do {
            let resp = try await api.rankingIllusts(mode: "day")
            rankingIllusts = resp.illusts
        } catch {
            rankingError = error.localizedDescription
        }
    }

    func loadRecommended() async {
        isLoadingRecommended = true
        recommendedError = nil
        defer { isLoadingRecommended = false }
        do {
            let resp = try await api.recommendedIllusts()
            recommendedIllusts = resp.illusts
            recommendedNext = resp.nextUrl
        } catch {
            recommendedError = error.localizedDescription
        }
    }

    func loadMoreRecommended() async {
        guard let url = recommendedNext, !isLoadingMoreRecommended else { return }
        isLoadingMoreRecommended = true
        defer { isLoadingMoreRecommended = false }
        if let r: HomeIllustResponse = try? await api.nextPage(url) {
            recommendedIllusts.append(contentsOf: r.illusts)
            recommendedNext = r.nextUrl
        }
    }

    // MARK: Hot tags page

    func loadTagsIfNeeded() async {
        guard trendingTags.isEmpty, !isLoadingTags else { return }
        await loadTags()
    }

    func loadTags() async {
        isLoadingTags = true
        tagError = nil
        defer { isLoadingTags = false }
        do {
            let resp = try await api.trendingTags()
            trendingTags = resp.trendTags
        } catch {
            tagError = error.localizedDescription
        }
    }
}

struct RecommendView: View {
    @State private var subTab: SubTab = .recommended
    @State private var vm = RecommendViewModel()
    @Environment(OnboardingStore.self) private var l10n

    enum SubTab: Hashable, CaseIterable {
        case recommended, hotTag
    }

    private func title(_ tab: SubTab) -> String {
        switch tab {
        case .recommended: return l10n.t(.subRecommendedWorks)
        case .hotTag:      return l10n.t(.subPopularTags)
        }
    }

    var body: some View {
        // NOTE: a paged `TabView(.page)` here was the bug. UIPageViewController
        // (what `.tabViewStyle(.page)` wraps) mismanages its child vertical
        // ScrollView's top content inset under the navigation bar: the nav bar
        // injects a top inset at launch, then drops it on the first real
        // scroll/pull-to-refresh, snapping "今日排行榜" up under the bar. (A repro
        // confirmed it tucks even with the nav bar hidden — the page controller
        // is the culprit, not the bar.) Switching the sub-tabs by condition —
        // i.e. a plain ScrollView, no page controller — gives a stable inset.
        // The strip is a top safe-area inset (not a VStack sibling) so the
        // ScrollView accounts for it; PagerTabBar is opaque so scrolled content
        // stays hidden under it.
        Group {
            switch subTab {
            case .recommended: RecommendedWorksView(vm: vm)
            case .hotTag:      PopularTagsView(vm: vm)
            }
        }
        // Let the waterfall scroll to the screen's bottom edge (under the
        // floating tab bar) instead of stopping above it.
        .ignoresSafeArea(.container, edges: .bottom)
        .safeAreaInset(edge: .top, spacing: 0) {
            PagerTabBar(
                titles: SubTab.allCases.map { ($0, title($0)) },
                selection: $subTab
            )
        }
    }
}

// MARK: - Recommended works (horizontal ranking + vertical waterfall)

struct RecommendedWorksView: View {
    let vm: RecommendViewModel
    @Environment(OnboardingStore.self) private var l10n
    @State private var mute = MuteStore.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if !vm.rankingIllusts.isEmpty {
                    SectionHeader(title: l10n.t(.rankingTodayTitle))
                        .padding(.horizontal, 16)
                    RankingStrip(illusts: vm.rankingIllusts)
                } else if let err = vm.rankingError {
                    ErrorBanner(message: err) { Task { await vm.loadRanking() } }
                        .padding(.horizontal, 12)
                } else if vm.isLoadingRanking {
                    SectionHeader(title: l10n.t(.rankingTodayTitle))
                        .padding(.horizontal, 16)
                    RankingStripSkeleton()
                }

                let visible = mute.filter(vm.recommendedIllusts)
                if !visible.isEmpty {
                    WaterfallGrid(
                        items: visible,
                        columns: mute.waterfallColumns,
                        spacing: 8,
                        estimatedRelativeHeight: { $0.waterfallImageHeightRatio }
                    ) { illust in
                        NavigationLink(value: illust) {
                            IllustWaterfallCell(illust: illust)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { IllustCardMenuItems(illust: illust) { visible } }
                    }
                    .padding(.horizontal, 8)
                } else if let err = vm.recommendedError {
                    ErrorBanner(message: err) { Task { await vm.loadRecommended() } }
                        .padding(.horizontal, 12)
                } else if vm.isLoadingRecommended {
                    WaterfallSkeleton(columns: mute.waterfallColumns)
                }

                if vm.isLoadingRecommended, !vm.recommendedIllusts.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
                } else if vm.recommendedNext != nil, !vm.recommendedIllusts.isEmpty {
                    Color.clear
                        .frame(height: 40)
                        .onAppear { Task { await vm.loadMoreRecommended() } }
                }
            }
            .padding(.vertical, 12)
        }
        .refreshable { await vm.loadRecommend() }
        .cardMenuHost()
        .task { await vm.loadRecommendIfNeeded() }
    }
}

// MARK: - Popular tags

struct PopularTagsView: View {
    let vm: RecommendViewModel

    // Upstream uses a bare GridLayoutManager(ctx, 3): no item spacing, no
    // outer margins — the tag tiles butt up against each other edge to edge.
    private let columns = [
        GridItem(.flexible(), spacing: 0),
        GridItem(.flexible(), spacing: 0),
        GridItem(.flexible(), spacing: 0),
    ]

    var body: some View {
        ScrollView {
            if let err = vm.tagError {
                ErrorBanner(message: err) { Task { await vm.loadTags() } }
                    .padding()
            }
            if vm.trendingTags.isEmpty, vm.isLoadingTags {
                TagGridSkeleton(columns: 3)
            } else {
                LazyVGrid(columns: columns, spacing: 0) {
                    ForEach(vm.trendingTags) { tag in
                        NavigationLink(value: AppRoute.tagResults(tag: tag.tag ?? "")) {
                            TagGridCell(tag: tag)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .refreshable { await vm.loadTags() }
        .task { await vm.loadTagsIfNeeded() }
    }
}

// MARK: - Cells

private struct RankingStrip: View {
    let illusts: [Illust]

    /// Pixiv `/v1/illust/ranking` first page is already capped at ~30 items;
    /// this is a defensive cap so the home strip never balloons if the server
    /// changes the page size.
    private static let homeStripCap = 30

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 10) {
                ForEach(Array(illusts.prefix(Self.homeStripCap).enumerated()), id: \.element.id) { idx, illust in
                    NavigationLink(value: illust) {
                        RankingCard(rank: idx + 1, illust: illust)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }
}

private struct RankingCard: View {
    let rank: Int
    let illust: Illust

    private let cardWidth: CGFloat = 130

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                PixivAsyncImage(url: imageURL)
                    .frame(width: cardWidth, height: cardWidth)
                    .clipShape(.rect(cornerRadius: 8))
                Text("#\(rank)")
                    .font(.caption.bold())
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(rankBadgeColor, in: .capsule)
                    .foregroundStyle(.white)
                    .padding(6)
            }

            Text(illust.title ?? "")
                .font(.caption)
                .lineLimit(1)
                .frame(width: cardWidth, alignment: .leading)
            if let user = illust.user {
                Text(user.name ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: cardWidth, alignment: .leading)
            }
        }
    }

    private var rankBadgeColor: Color {
        switch rank {
        case 1: return Color(red: 0.85, green: 0.65, blue: 0.13)   // gold
        case 2: return Color(red: 0.66, green: 0.66, blue: 0.66)   // silver
        case 3: return Color(red: 0.78, green: 0.49, blue: 0.20)   // bronze
        default: return .black.opacity(0.6)
        }
    }

    private var imageURL: URL? {
        let s = illust.imageUrls?.squareMedium
            ?? illust.imageUrls?.medium
        return s.flatMap(URL.init(string:))
    }
}

/// 1:1 port of upstream `cell_trending_tag.xml`: square image, uniform
/// `black_overlay` (#66000000) scrim across the whole tile, and a centered
/// bottom text block — translated name (13sp) above `#tag` (12sp), no
/// corner rounding.
struct TagGridCell: View {
    let tag: TrendingTag

    var body: some View {
        PixivAsyncImage(url: imageURL)
            .aspectRatio(1, contentMode: .fit)
            .overlay(Color.black.opacity(0.4))
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    if let translated = tag.translatedName, !translated.isEmpty {
                        Text(translated)
                            .font(.system(size: 13))
                    }
                    Text("#\(tag.tag ?? "")")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(6)
            }
    }

    private var imageURL: URL? {
        let s = tag.illust?.imageUrls?.squareMedium
            ?? tag.illust?.imageUrls?.medium
        return s.flatMap(URL.init(string:))
    }
}

// MARK: - Reusable bits

private struct SectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.title3.bold())
            Spacer()
        }
    }
}

private struct ErrorBanner: View {
    let message: String
    let retry: () -> Void
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .lineLimit(3)
            Spacer()
            Button(l10n.t(.actionRetry), action: retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
    }
}
