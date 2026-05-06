import SwiftUI

@MainActor
@Observable
private final class RecommendUsersVM {
    var items: [UserPreview] = []
    var nextUrl: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init() { api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared) }

    func loadIfNeeded() async { if items.isEmpty { await load() } }
    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let r = try await api.recommendedUsers()
            items = r.userPreviews
            nextUrl = r.nextUrl
        } catch { errorMessage = error.localizedDescription }
    }
    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let r: UserPreviewResponse = try? await api.nextPage(url) {
            items.append(contentsOf: r.userPreviews)
            nextUrl = r.nextUrl
        }
    }
}

struct RecommendUsersView: View {
    @State private var vm = RecommendUsersVM()
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        UserPreviewList(
            items: vm.items,
            onLoadMore: { await vm.loadMore() },
            hasMore: vm.nextUrl != nil
        )
        .overlay {
            if vm.items.isEmpty && vm.isLoading { ProgressView() }
            else if vm.items.isEmpty, let err = vm.errorMessage {
                InlineError(message: err) { Task { await vm.load() } }.padding()
            }
        }
        .navigationTitle(l10n.t(.recommendUsersTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
        .refreshable { await vm.load() }
    }
}
