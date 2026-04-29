import SwiftUI

@MainActor
@Observable
final class CommentsViewModel {
    let target: AppRoute.CommentTarget
    var comments: [CommentItem] = []
    var totalComments: Int?
    var isLoading = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init(target: AppRoute.CommentTarget) {
        self.target = target
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async {
        if comments.isEmpty { await load() }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let resp: CommentsResponse
            switch target {
            case .illust(let id): resp = try await api.illustComments(id)
            case .novel(let id):  resp = try await api.novelComments(id)
            }
            comments = resp.comments
            totalComments = resp.totalComments
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CommentsView: View {
    let target: AppRoute.CommentTarget
    @State private var vm: CommentsViewModel
    @Environment(OnboardingStore.self) private var l10n

    init(target: AppRoute.CommentTarget) {
        self.target = target
        _vm = State(wrappedValue: CommentsViewModel(target: target))
    }

    var body: some View {
        List(vm.comments) { c in
            HStack(alignment: .top, spacing: 12) {
                NavigationLink(value: c.user.map { AppRoute.userProfile($0.id) } ?? .more) {
                    PixivAsyncImage(url: avatar(c))
                        .frame(width: 36, height: 36)
                        .clipShape(.circle)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.user?.name ?? "").font(.subheadline.bold())
                    Text(c.comment ?? "").font(.callout)
                    if let date = c.date {
                        Text(date).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .listStyle(.plain)
        .navigationTitle(l10n.t(.commentsTitle))
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if vm.isLoading && vm.comments.isEmpty {
                ProgressView()
            } else if vm.comments.isEmpty, let err = vm.errorMessage {
                InlineError(message: err) { Task { await vm.load() } }.padding()
            } else if vm.comments.isEmpty && !vm.isLoading {
                ContentUnavailableView(l10n.t(.commentsEmpty), systemImage: "bubble.left.and.bubble.right")
            }
        }
        .task { await vm.loadIfNeeded() }
        .refreshable { await vm.load() }
    }

    private func avatar(_ c: CommentItem) -> URL? {
        (c.user?.profileImageUrls?.medium ?? c.user?.profileImageUrls?.px170x170)
            .flatMap(URL.init(string:))
    }
}
