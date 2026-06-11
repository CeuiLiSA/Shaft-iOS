import SwiftUI

@MainActor
@Observable
final class NovelDetailViewModel {
    let novelId: Int64
    var novel: Novel? {
        didSet { captionPlain = novel?.caption.map { V3Caption.plain($0) } ?? "" }
    }
    /// Plaintext caption derived once per novel change — HTML stripping runs
    /// regex replacement and must not run per body evaluation.
    private(set) var captionPlain: String = ""
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

    func toggleBookmark(restrict: String = "public") async {
        guard let cur = novel else { return }
        isBookmarking = true
        defer { isBookmarking = false }
        do {
            if cur.isBookmarked == true {
                _ = try await api.unbookmarkNovel(novelId)
                update(isBookmarked: false)
            } else {
                _ = try await api.bookmarkNovel(novelId, restrict: restrict)
                update(isBookmarked: true)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func bookmarkDetail() async -> (restrict: String, tags: [String])? {
        guard novel?.isBookmarked == true else { return nil }
        guard let d = try? await api.novelBookmarkDetail(novelId).bookmarkDetail else { return nil }
        return (d.restrict ?? "public", d.registeredTags)
    }

    func bookmark(restrict: String, tags: [String]) async {
        isBookmarking = true
        defer { isBookmarking = false }
        do {
            _ = try await api.bookmarkNovel(novelId, restrict: restrict, tags: tags)
            update(isBookmarked: true)
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
            createDate: n.createDate, series: n.series,
            xRestrict: n.xRestrict, novelAIType: n.novelAIType
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
    @State private var showReader = false
    @State private var showBookmarkSheet = false
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.openURL) private var openURL

    init(novelId: Int64) {
        self.novelId = novelId
        _vm = State(wrappedValue: NovelDetailViewModel(novelId: novelId))
    }

    private var pixivURL: URL {
        URL(string: "https://www.pixiv.net/novel/show.php?id=\(novelId)")!
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
                            if let series = novel.series,
                               let title = series.title, !title.isEmpty,
                               let sid = series.id {
                                NavigationLink(value: AppRoute.novelSeries(seriesId: sid)) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "books.vertical")
                                        Text(title)
                                    }
                                    .font(.footnote)
                                    .foregroundStyle(.tint)
                                }
                            } else if let series = novel.series,
                                      let title = series.title, !title.isEmpty {
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

                        if !vm.captionPlain.isEmpty {
                            Text(vm.captionPlain)
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
                .contextMenu {
                    if vm.novel?.isBookmarked != true {
                        Button {
                            Task { await vm.toggleBookmark(restrict: "public") }
                        } label: {
                            Label(l10n.t(.bookmarkPublic), systemImage: "heart")
                        }
                        Button {
                            Task { await vm.toggleBookmark(restrict: "private") }
                        } label: {
                            Label(l10n.t(.bookmarkPrivate), systemImage: "lock")
                        }
                    }
                    Button {
                        showBookmarkSheet = true
                    } label: {
                        Label(l10n.t(.bookmarkWithTags), systemImage: "tag")
                    }
                }

                Button {
                    showReader = true
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: pixivURL) {
                        Label(l10n.t(.actionShare), systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = pixivURL.absoluteString
                    } label: {
                        Label(l10n.t(.actionCopyLink), systemImage: "doc.on.doc")
                    }
                    Button {
                        openURL(pixivURL)
                    } label: {
                        Label(l10n.t(.actionOpenInBrowser), systemImage: "safari")
                    }
                    if let user = vm.novel?.user {
                        Divider()
                        Button(role: .destructive) {
                            MuteStore.shared.toggleUser(user.id)
                        } label: {
                            let muted = MuteStore.shared.isUserMuted(user.id)
                            Label(muted ? l10n.t(.actionUnmuteUser) : l10n.t(.actionMuteArtist),
                                  systemImage: "speaker.slash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            await vm.loadIfNeeded()
            if let n = vm.novel { HistoryStore.shared.record(novel: n) }
        }
        .fullScreenCover(isPresented: $showReader) {
            NovelReaderView(novelId: novelId)
        }
        .sheet(isPresented: $showBookmarkSheet) {
            BookmarkTagsSheet(
                existingTags: (vm.novel?.tags ?? []).compactMap { $0.name },
                loadInitial: { await vm.bookmarkDetail() }
            ) { restrict, tags in
                await vm.bookmark(restrict: restrict, tags: tags)
            }
        }
    }

    private func avatar(for user: PixivUser) -> URL? {
        (user.profileImageUrls?.medium ?? user.profileImageUrls?.px170x170)
            .flatMap(URL.init(string:))
    }

    private func formatLen(_ n: Int) -> String {
        if n >= 10_000 { return "\(n / 1_000)k" }
        return "\(n)"
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
