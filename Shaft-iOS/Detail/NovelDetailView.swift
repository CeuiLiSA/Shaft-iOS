import SwiftUI

@MainActor
@Observable
final class NovelDetailViewModel {
    let novelId: Int64
    var novel: Novel?
    var comments: [CommentItem] = []
    var totalComments: Int?
    var isLoading = false
    var errorMessage: String?
    var isBookmarking = false

    @ObservationIgnored private let api: PixivAPI

    init(novelId: Int64) {
        self.novelId = novelId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async {
        if novel == nil { await load() }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in await self?.loadDetail() }
            group.addTask { @MainActor [weak self] in await self?.loadComments() }
        }
    }

    private func loadDetail() async {
        do {
            let resp = try await api.novelDetail(novelId)
            novel = resp.novel
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadComments() async {
        let resp = try? await api.novelComments(novelId)
        comments = resp?.comments ?? []
        totalComments = resp?.totalComments
    }

    func toggleBookmark() async {
        guard let cur = novel else { return }
        isBookmarking = true
        defer { isBookmarking = false }
        do {
            if cur.isBookmarked == true {
                _ = try await api.unbookmarkNovel(novelId)
                update(isBookmarked: false)
            } else {
                _ = try await api.bookmarkNovel(novelId)
                update(isBookmarked: true)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func update(isBookmarked: Bool) {
        guard var n = novel else { return }
        n = Novel(
            id: n.id, title: n.title, caption: n.caption, imageUrls: n.imageUrls,
            user: n.user, tags: n.tags, pageCount: n.pageCount,
            textLength: n.textLength, isBookmarked: isBookmarked,
            totalBookmarks: n.totalBookmarks, totalView: n.totalView,
            createDate: n.createDate, series: n.series
        )
        novel = n
    }
}

/// V3-style novel detail: cover hero (square_medium card on a tinted bg),
/// metadata block, series chip, action bar at bottom. Tap hero/Read → opens
/// the reader (placeholder for now).
struct NovelDetailView: View {
    let novelId: Int64
    @State private var vm: NovelDetailViewModel
    @Environment(OnboardingStore.self) private var l10n

    init(novelId: Int64) {
        self.novelId = novelId
        _vm = State(wrappedValue: NovelDetailViewModel(novelId: novelId))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let novel = vm.novel {
                        NovelHero(novel: novel)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(novel.title ?? "")
                                .font(.title3.bold())
                            if let series = novel.series, let title = series.title, !title.isEmpty {
                                Text(title)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 14) {
                                if let v = novel.totalView { Label("\(v)", systemImage: "eye") }
                                if let b = novel.totalBookmarks { Label("\(b)", systemImage: "heart") }
                                if let len = novel.textLength { Label(formatLen(len), systemImage: "text.alignleft") }
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)

                        if let user = novel.user {
                            NavigationLink(value: AppRoute.userProfile(user.id)) {
                                HStack(spacing: 12) {
                                    PixivAsyncImage(url: avatar(for: user))
                                        .frame(width: 40, height: 40)
                                        .clipShape(.circle)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(user.name ?? "").font(.subheadline.weight(.semibold))
                                        Text("@\(user.account ?? "")").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
                                }
                                .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 16)
                        }

                        if let caption = novel.caption, !caption.isEmpty {
                            Text(htmlPlain(caption))
                                .font(.callout)
                                .padding(.horizontal, 16)
                        }

                        if let tags = novel.tags, !tags.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                                    NavigationLink(value: AppRoute.tagResults(tag: tag.name ?? "")) {
                                        Text("#\(tag.name ?? "")")
                                            .font(.caption.bold())
                                            .padding(.horizontal, 8).padding(.vertical, 5)
                                            .background(Color(.secondarySystemBackground), in: .capsule)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        if !vm.comments.isEmpty {
                            SectionLabel(title: l10n.t(.commentsTitle))
                                .padding(.horizontal, 16)
                            VStack(spacing: 12) {
                                ForEach(vm.comments.prefix(5)) { CommentRowMin(comment: $0) }
                                NavigationLink(value: AppRoute.comments(target: .novel(novelId))) {
                                    Text(l10n.t(.viewAllComments)).font(.footnote).foregroundStyle(.tint)
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        Color.clear.frame(height: 88)
                    } else if vm.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                    } else if let err = vm.errorMessage {
                        InlineError(message: err) { Task { await vm.load() } }.padding()
                    }
                }
                .padding(.vertical, 8)
            }

            HStack(spacing: 16) {
                Spacer()
                Button {
                    Task { await vm.toggleBookmark() }
                } label: {
                    Image(systemName: (vm.novel?.isBookmarked == true) ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundStyle((vm.novel?.isBookmarked == true) ? .pink : .primary)
                        .frame(width: 44, height: 44)
                }
                .disabled(vm.isBookmarking || vm.novel == nil)

                Button {
                    // TODO: open NovelReaderView with /webview/v2/novel content.
                } label: {
                    Text(l10n.t(.novelRead))
                        .font(.subheadline.bold())
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(.tint, in: .capsule)
                        .foregroundStyle(.white)
                }
                .disabled(vm.novel == nil)
                Spacer()
            }
            .padding(.vertical, 8)
            .background(.thinMaterial)
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
    }

    private func avatar(for user: PixivUser) -> URL? {
        (user.profileImageUrls?.medium ?? user.profileImageUrls?.px170x170)
            .flatMap(URL.init(string:))
    }

    private func formatLen(_ n: Int) -> String {
        if n >= 10_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }

    private func htmlPlain(_ s: String) -> String {
        s.replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<.+?>", with: "", options: .regularExpression)
    }
}

private struct NovelHero: View {
    let novel: Novel

    var body: some View {
        ZStack {
            // tinted backdrop
            LinearGradient(
                colors: [
                    Color(.tertiarySystemBackground),
                    Color(.secondarySystemBackground),
                ],
                startPoint: .top, endPoint: .bottom
            )
            HStack {
                Spacer()
                PixivAsyncImage(url: coverURL)
                    .frame(width: 160, height: 220)
                    .clipShape(.rect(cornerRadius: 8))
                    .shadow(radius: 8, y: 4)
                Spacer()
            }
            .padding(.vertical, 24)
        }
    }

    private var coverURL: URL? {
        let s = novel.imageUrls?.large
            ?? novel.imageUrls?.medium
            ?? novel.imageUrls?.squareMedium
        return s.flatMap(URL.init(string:))
    }
}

private struct CommentRowMin: View {
    let comment: CommentItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PixivAsyncImage(url: avatarURL)
                .frame(width: 32, height: 32)
                .clipShape(.circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(comment.user?.name ?? "").font(.caption.bold())
                Text(comment.comment ?? "").font(.caption)
            }
            Spacer()
        }
    }

    private var avatarURL: URL? {
        (comment.user?.profileImageUrls?.medium ?? comment.user?.profileImageUrls?.px170x170)
            .flatMap(URL.init(string:))
    }
}
