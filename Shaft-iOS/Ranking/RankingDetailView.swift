import SwiftUI

@MainActor
@Observable
final class RankingDetailViewModel {
    var mode: String
    var illusts: [Illust] = []
    var nextUrl: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init(initialMode: String) {
        self.mode = initialMode
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func setMode(_ m: String) async {
        mode = m
        illusts = []
        nextUrl = nil
        await load()
    }

    func loadIfNeeded() async {
        if illusts.isEmpty { await load() }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let r = try await api.rankingIllusts(mode: mode)
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
        if let r: IllustResponse = try? await api.nextPage(url) {
            illusts.append(contentsOf: r.illusts)
            nextUrl = r.nextUrl
        }
    }
}

struct RankingDetailView: View {
    @State private var vm: RankingDetailViewModel
    @Environment(OnboardingStore.self) private var l10n

    /// Subset matching Shaft's RankingIllustsFragment most-used modes.
    static let modes = [
        "day", "week", "month",
        "day_male", "day_female",
        "week_rookie", "week_original",
        "day_manga",
    ]

    init(initialMode: String) {
        _vm = State(wrappedValue: RankingDetailViewModel(initialMode: initialMode))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Self.modes, id: \.self) { m in
                        Button {
                            Task { await vm.setMode(m) }
                        } label: {
                            Text(modeName(m))
                                .font(.subheadline.weight(vm.mode == m ? .bold : .regular))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(vm.mode == m ? Color.accentColor : Color(.secondarySystemBackground),
                                            in: .capsule)
                                .foregroundStyle(vm.mode == m ? Color.white : .primary)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)

            IllustWaterfallList(
                illusts: vm.illusts,
                isLoading: vm.isLoading,
                errorMessage: vm.errorMessage,
                onRefresh: { await vm.load() },
                onLoadMore: { await vm.loadMore() },
                hasMore: vm.nextUrl != nil
            )
        }
        .navigationTitle(l10n.t(.rankingTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
    }

    private func modeName(_ m: String) -> String {
        switch m {
        case "day":           return l10n.t(.rankModeDay)
        case "week":          return l10n.t(.rankModeWeek)
        case "month":         return l10n.t(.rankModeMonth)
        case "day_male":      return l10n.t(.rankModeDayMale)
        case "day_female":    return l10n.t(.rankModeDayFemale)
        case "week_rookie":   return l10n.t(.rankModeWeekRookie)
        case "week_original": return l10n.t(.rankModeWeekOriginal)
        case "day_manga":     return l10n.t(.rankModeDayManga)
        default: return m
        }
    }
}
