import SwiftUI

@MainActor
@Observable
final class CommentsViewModel {
    let target: AppRoute.CommentTarget
    var comments: [CommentItem] = []
    var totalComments: Int?
    var nextUrl: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    /// Replies keyed by parent comment id.
    var replies: [Int64: [CommentItem]] = [:]
    var loadingReplies: Set<Int64> = []
    var expandedReplies: Set<Int64> = []

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
            nextUrl = resp.nextUrl
            replies.removeAll()
            expandedReplies.removeAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let r: CommentsResponse = try? await api.nextPage(url) {
            comments.append(contentsOf: r.comments)
            nextUrl = r.nextUrl
        }
    }

    func toggleReplies(for commentId: Int64) async {
        if expandedReplies.contains(commentId) {
            expandedReplies.remove(commentId)
            return
        }
        expandedReplies.insert(commentId)
        // load if not yet fetched
        guard replies[commentId] == nil, !loadingReplies.contains(commentId) else { return }
        loadingReplies.insert(commentId)
        defer { loadingReplies.remove(commentId) }
        do {
            let resp: CommentsResponse
            switch target {
            case .illust: resp = try await api.illustCommentReplies(commentId)
            case .novel:  resp = try await api.novelCommentReplies(commentId)
            }
            replies[commentId] = resp.comments
        } catch {
            // leave nil so user can retry by collapsing/expanding
        }
    }

    func post(_ text: String, parentId: Int64? = nil) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            switch target {
            case .illust(let id): _ = try await api.postIllustComment(id, comment: trimmed, parentId: parentId)
            case .novel(let id):  _ = try await api.postNovelComment(id, comment: trimmed, parentId: parentId)
            }
            if let parentId {
                // refresh that thread; collapsed expand it again
                replies[parentId] = nil
                expandedReplies.insert(parentId)
                await toggleReplies(for: parentId)
                expandedReplies.insert(parentId) // toggleReplies inverts; ensure expanded
            } else {
                await load()
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

struct CommentsView: View {
    let target: AppRoute.CommentTarget
    @State private var vm: CommentsViewModel
    @State private var draft: String = ""
    @State private var isPosting = false
    @State private var replyTarget: CommentItem?
    @FocusState private var inputFocused: Bool
    @Environment(OnboardingStore.self) private var l10n

    init(target: AppRoute.CommentTarget) {
        self.target = target
        _vm = State(wrappedValue: CommentsViewModel(target: target))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.comments) { c in
                        CommentCell(
                            comment: c,
                            isExpanded: vm.expandedReplies.contains(c.id),
                            isLoadingReplies: vm.loadingReplies.contains(c.id),
                            replies: vm.replies[c.id],
                            onToggleReplies: { Task { await vm.toggleReplies(for: c.id) } },
                            onReply: { target in
                                replyTarget = target
                                inputFocused = true
                            }
                        )
                        Divider()
                    }
                    if vm.nextUrl != nil, !vm.comments.isEmpty {
                        Color.clear
                            .frame(height: 40)
                            .onAppear { Task { await vm.loadMore() } }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .overlay {
                if vm.isLoading && vm.comments.isEmpty {
                    ProgressView()
                } else if vm.comments.isEmpty, let err = vm.errorMessage {
                    InlineError(message: err) { Task { await vm.load() } }.padding()
                } else if vm.comments.isEmpty && !vm.isLoading {
                    ContentUnavailableView(l10n.t(.commentsEmpty), systemImage: "bubble.left.and.bubble.right")
                }
            }
            .refreshable { await vm.load() }

            VStack(alignment: .leading, spacing: 4) {
                if let r = replyTarget {
                    HStack(spacing: 6) {
                        Image(systemName: "arrowshape.turn.up.left")
                            .foregroundStyle(.tint)
                        Text(replyHint(for: r))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            replyTarget = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                HStack(spacing: 8) {
                    TextField(l10n.t(.commentCompose), text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($inputFocused)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
                    Button {
                        Task {
                            isPosting = true
                            let parentId = replyTarget?.id
                            if await vm.post(draft, parentId: parentId) {
                                draft = ""
                                replyTarget = nil
                                inputFocused = false
                            }
                            isPosting = false
                        }
                    } label: {
                        Image(systemName: isPosting ? "ellipsis" : "paperplane.fill")
                            .frame(width: 36, height: 36)
                            .foregroundStyle(.white)
                            .background(.tint, in: .circle)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPosting)
                }
            }
            .padding(8)
            .background(.thinMaterial)
        }
        .navigationTitle(l10n.t(.commentsTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
    }

    private func replyHint(for c: CommentItem) -> String {
        let name = c.user?.name ?? ""
        return "@\(name)"
    }
}

private struct CommentCell: View {
    let comment: CommentItem
    let isExpanded: Bool
    let isLoadingReplies: Bool
    let replies: [CommentItem]?
    let onToggleReplies: () -> Void
    let onReply: (CommentItem) -> Void

    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            commentRow(comment)
                .padding(.vertical, 4)

            HStack(spacing: 14) {
                Button(action: { onReply(comment) }) {
                    Label(l10n.t(.commentReply), systemImage: "arrowshape.turn.up.left")
                        .font(.caption2)
                }
                if comment.hasReplies == true {
                    Button(action: onToggleReplies) {
                        Label(
                            isExpanded ? l10n.t(.commentHideReplies) : l10n.t(.commentShowReplies),
                            systemImage: isExpanded ? "chevron.up" : "chevron.down"
                        )
                        .font(.caption2)
                    }
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)

            if isExpanded {
                if isLoadingReplies {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        .padding(.vertical, 4)
                } else if let replies, !replies.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(replies) { reply in
                            HStack(alignment: .top) {
                                Color.clear.frame(width: 24)
                                commentRow(reply)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func commentRow(_ c: CommentItem) -> some View {
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
            Spacer(minLength: 0)
        }
    }

    private func avatar(_ c: CommentItem) -> URL? {
        (c.user?.profileImageUrls?.medium ?? c.user?.profileImageUrls?.px170x170)
            .flatMap(URL.init(string:))
    }
}
