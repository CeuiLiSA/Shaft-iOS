import SwiftUI

@MainActor
@Observable
private final class RecommendUsersVM {
    var items: [UserPreview] = []
    var isLoading = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init() { api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared) }

    func loadIfNeeded() async { if items.isEmpty { await load() } }
    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do { items = try await api.recommendedUsers().userPreviews }
        catch { errorMessage = error.localizedDescription }
    }
}

struct RecommendUsersView: View {
    @State private var vm = RecommendUsersVM()
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        UserPreviewList(items: vm.items)
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
