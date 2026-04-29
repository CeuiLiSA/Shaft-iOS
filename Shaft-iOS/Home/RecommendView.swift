import SwiftUI

@MainActor
@Observable
final class RecommendViewModel {
    var rankingIllusts: [Illust] = []
    var recommendedIllusts: [Illust] = []
    var trendingTags: [TrendingTag] = []
    var isLoadingRanking = false
    var isLoadingRecommended = false
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
        } catch {
            recommendedError = error.localizedDescription
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
        VStack(spacing: 0) {
            PagerTabBar(
                titles: SubTab.allCases.map { ($0, title($0)) },
                selection: $subTab
            )
            TabView(selection: $subTab) {
                RecommendedWorksView(vm: vm)
                    .tag(SubTab.recommended)
                PopularTagsView(vm: vm)
                    .tag(SubTab.hotTag)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Recommended works (horizontal ranking + vertical waterfall)

struct RecommendedWorksView: View {
    let vm: RecommendViewModel
    @Environment(OnboardingStore.self) private var l10n

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
                }

                if !vm.recommendedIllusts.isEmpty {
                    WaterfallGrid(
                        items: vm.recommendedIllusts,
                        columns: 2,
                        spacing: 8,
                        estimatedRelativeHeight: relativeHeight(for:)
                    ) { illust in
                        NavigationLink(value: AppRoute.illustDetail(illust.id)) {
                            IllustWaterfallCell(illust: illust)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                } else if let err = vm.recommendedError {
                    ErrorBanner(message: err) { Task { await vm.loadRecommended() } }
                        .padding(.horizontal, 12)
                }

                if vm.isLoadingRanking || vm.isLoadingRecommended {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
                }
            }
            .padding(.vertical, 12)
        }
        .refreshable { await vm.loadRecommend() }
        .task { await vm.loadRecommendIfNeeded() }
    }

    private func relativeHeight(for illust: Illust) -> Double {
        // Cell layout: image (full width @ aspect = w/h) + ~0.18 column-widths
        // for the title/author label area below. Clamp the image aspect so a
        // single tall illust can't dominate the column.
        let w = max(Double(illust.width ?? 1), 1)
        let h = max(Double(illust.height ?? 1), 1)
        let aspect = max(0.5, min(w / h, 2.0))
        return 1.0 / aspect + 0.18
    }
}

// MARK: - Popular tags

struct PopularTagsView: View {
    let vm: RecommendViewModel

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        ScrollView {
            if let err = vm.tagError {
                ErrorBanner(message: err) { Task { await vm.loadTags() } }
                    .padding()
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(vm.trendingTags) { tag in
                    TagGridCell(tag: tag)
                }
            }
            .padding(8)
            if vm.isLoadingTags {
                ProgressView().padding()
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
                    NavigationLink(value: AppRoute.illustDetail(illust.id)) {
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

private struct TagGridCell: View {
    let tag: TrendingTag

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PixivAsyncImage(url: imageURL)
                .aspectRatio(1, contentMode: .fit)
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.7)],
                startPoint: .top, endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 1) {
                Text("#\(tag.tag ?? "")")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                if let translated = tag.translatedName, !translated.isEmpty {
                    Text(translated)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(6)
        }
        .clipShape(.rect(cornerRadius: 6))
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
