import SwiftUI

@MainActor
@Observable
final class DiscoverViewModel {
    var illusts: [Illust] = []
    var isLoading = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init() {
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async {
        if illusts.isEmpty { await load() }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            illusts = try await api.walkthroughIllusts().illusts
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Discover tab — corresponds to Shaft FragmentCenter. Pixiv app-api exposes
/// "walkthrough" illusts as a curated discover feed; we render it as a
/// waterfall + a button into the spotlight (long-form articles) feed.
struct DiscoverView: View {
    @State private var vm = DiscoverViewModel()
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                NavigationLink(value: AppRoute.spotlight) {
                    Label(l10n.t(.discoverSpotlight), systemImage: "doc.richtext")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: .capsule)
                }
                Spacer()
                NavigationLink(value: AppRoute.ranking(initialMode: "day")) {
                    Label(l10n.t(.rankingTitle), systemImage: "trophy")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: .capsule)
                }
            }
            .padding(.horizontal, 12).padding(.top, 8)
            .buttonStyle(.plain)

            IllustWaterfallList(
                illusts: vm.illusts,
                isLoading: vm.isLoading,
                errorMessage: vm.errorMessage,
                onRefresh: { await vm.load() },
                onTap: { _ in }
            )
        }
        .task { await vm.loadIfNeeded() }
    }
}
