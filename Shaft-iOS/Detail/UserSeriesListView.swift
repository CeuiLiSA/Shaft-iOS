import SwiftUI

// MARK: - A user's illust series

@MainActor
@Observable
private final class UserIllustSeriesVM {
    let userId: Int64
    var series: [IllustSeriesListItem] = []
    var nextUrl: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init(userId: Int64) {
        self.userId = userId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async { if series.isEmpty { await load() } }
    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let r = try await api.userIllustSeries(userId)
            series = r.illustSeriesDetails
            nextUrl = r.nextUrl
        } catch { errorMessage = error.localizedDescription }
    }
    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let r: IllustSeriesListResponse = try? await api.nextPage(url) {
            series.append(contentsOf: r.illustSeriesDetails)
            nextUrl = r.nextUrl
        }
    }
}

struct UserIllustSeriesListView: View {
    let userId: Int64
    @State private var vm: UserIllustSeriesVM
    @Environment(OnboardingStore.self) private var l10n

    init(userId: Int64) {
        self.userId = userId
        _vm = State(wrappedValue: UserIllustSeriesVM(userId: userId))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if vm.series.isEmpty, let err = vm.errorMessage {
                    InlineError(message: err) { Task { await vm.load() } }
                        .padding()
                }
                ForEach(vm.series) { item in
                    if let sid = item.id {
                        NavigationLink(value: AppRoute.illustSeries(seriesId: sid)) {
                            SeriesRow(
                                cover: item.coverImageUrls?.medium ?? item.coverImageUrls?.squareMedium,
                                title: item.title ?? "",
                                count: item.seriesWorkCount,
                                caption: item.caption
                            )
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 84)
                    }
                }
                if vm.nextUrl != nil, !vm.series.isEmpty {
                    Color.clear.frame(height: 40)
                        .onAppear { Task { await vm.loadMore() } }
                }
            }
            .padding(.vertical, 4)
        }
        .overlay {
            if vm.isLoading && vm.series.isEmpty { ProgressView() }
        }
        .navigationTitle(l10n.t(.userIllustSeriesTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
        .refreshable { await vm.load() }
    }
}

// MARK: - A user's novel series

@MainActor
@Observable
private final class UserNovelSeriesVM {
    let userId: Int64
    var series: [NovelSeriesListItem] = []
    var nextUrl: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init(userId: Int64) {
        self.userId = userId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async { if series.isEmpty { await load() } }
    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let r = try await api.userNovelSeries(userId)
            series = r.novelSeriesDetails
            nextUrl = r.nextUrl
        } catch { errorMessage = error.localizedDescription }
    }
    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let r: NovelSeriesListResponse = try? await api.nextPage(url) {
            series.append(contentsOf: r.novelSeriesDetails)
            nextUrl = r.nextUrl
        }
    }
}

struct UserNovelSeriesListView: View {
    let userId: Int64
    @State private var vm: UserNovelSeriesVM
    @Environment(OnboardingStore.self) private var l10n

    init(userId: Int64) {
        self.userId = userId
        _vm = State(wrappedValue: UserNovelSeriesVM(userId: userId))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if vm.series.isEmpty, let err = vm.errorMessage {
                    InlineError(message: err) { Task { await vm.load() } }
                        .padding()
                }
                ForEach(vm.series) { item in
                    if let sid = item.id {
                        NavigationLink(value: AppRoute.novelSeries(seriesId: sid)) {
                            SeriesRow(
                                cover: nil,
                                title: item.title ?? "",
                                count: item.contentCount,
                                caption: item.displayText
                            )
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 84)
                    }
                }
                if vm.nextUrl != nil, !vm.series.isEmpty {
                    Color.clear.frame(height: 40)
                        .onAppear { Task { await vm.loadMore() } }
                }
            }
            .padding(.vertical, 4)
        }
        .overlay {
            if vm.isLoading && vm.series.isEmpty { ProgressView() }
        }
        .navigationTitle(l10n.t(.userNovelSeriesTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
        .refreshable { await vm.load() }
    }
}

// MARK: - Shared row

private struct SeriesRow: View {
    let cover: String?
    let title: String
    let count: Int?
    let caption: String?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let cover, let url = URL(string: cover) {
                    PixivAsyncImage(url: url)
                } else {
                    ZStack {
                        Rectangle().fill(Color(.secondarySystemBackground))
                        Image(systemName: "books.vertical")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(.rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let count {
                    Text("\(count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(.rect)
    }
}
