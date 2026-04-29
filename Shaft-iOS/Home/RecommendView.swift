import SwiftUI

@MainActor
@Observable
final class RecommendViewModel {
    var illusts: [Illust] = []
    var rankingIllusts: [Illust] = []
    var trendingTags: [TrendingTag] = []
    var isLoadingIllusts = false
    var isLoadingTags = false
    var illustError: String?
    var tagError: String?

    @ObservationIgnored private let api = PixivAPI(tokenProvider: AuthTokenProvider.shared)

    func loadIllustsIfNeeded() async {
        guard illusts.isEmpty, !isLoadingIllusts else { return }
        await loadIllusts()
    }

    func loadIllusts() async {
        isLoadingIllusts = true
        illustError = nil
        defer { isLoadingIllusts = false }
        do {
            let resp = try await api.recommendedIllusts()
            illusts = resp.illusts
            rankingIllusts = resp.rankingIllusts ?? []
        } catch {
            illustError = error.localizedDescription
        }
    }

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

    enum SubTab: Hashable, CaseIterable {
        case recommended, hotTag

        var title: String {
            switch self {
            case .recommended: return "Recommended works"
            case .hotTag:      return "Popular Tags"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PagerTabBar(
                titles: SubTab.allCases.map { ($0, $0.title) },
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

struct RecommendedWorksView: View {
    @Bindable var vm: RecommendViewModel

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        ScrollView {
            if let err = vm.illustError {
                ErrorBanner(message: err) { Task { await vm.loadIllusts() } }
                    .padding()
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(vm.illusts) { illust in
                    IllustGridCell(illust: illust)
                }
            }
            .padding(8)
            if vm.isLoadingIllusts {
                ProgressView().padding()
            }
        }
        .refreshable { await vm.loadIllusts() }
        .task { await vm.loadIllustsIfNeeded() }
    }
}

struct PopularTagsView: View {
    @Bindable var vm: RecommendViewModel

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

private struct IllustGridCell: View {
    let illust: Illust

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PixivAsyncImage(url: imageURL)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 6))
            Text(illust.title ?? "")
                .font(.caption)
                .lineLimit(1)
            if let user = illust.user {
                Text(user.name ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var imageURL: URL? {
        let s = illust.imageUrls?.squareMedium
            ?? illust.imageUrls?.medium
            ?? illust.imageUrls?.large
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

private struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .lineLimit(3)
            Spacer()
            Button("Retry", action: retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
    }
}
