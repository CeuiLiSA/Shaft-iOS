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

    func toggleBookmark(restrict: String? = nil) async {
        guard let cur = novel else { return }
        isBookmarking = true
        defer { isBookmarking = false }
        do {
            if cur.isBookmarked == true {
                _ = try await api.unbookmarkNovel(novelId)
                update(isBookmarked: false)
                Task { await ShaftEventReporter.shared.reportNovelBookmark(cur, added: false) }
                Task { await BookmarkMirrorService.shared.onUnbookmarked(contentType: .novel, targetId: novelId) }
            } else {
                let resolvedRestrict = restrict
                    ?? (AppSettingsStore.shared.privateStar ? "private" : "public")
                _ = try await api.bookmarkNovel(novelId, restrict: resolvedRestrict)
                update(isBookmarked: true)
                Task { await ShaftEventReporter.shared.reportNovelBookmark(cur, added: true) }
                syncMirror(cur, restrict: resolvedRestrict)
            }
        } catch {
            BookmarkHaptics.failed()
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
            if let n = novel {
                Task { await ShaftEventReporter.shared.reportNovelBookmark(n, added: true) }
                syncMirror(n, restrict: restrict)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 已被服务端确认的收藏同步进收藏镜像表（本页绕过 InteractionStore 直接打接口，
    /// 所以镜像也要在这里接一次）。
    private func syncMirror(_ n: Novel, restrict: String) {
        Task {
            await BookmarkMirrorService.shared.onNovelBookmarked(
                BookmarkMirrorMapper.withBookmarked(n, true), restrict: MirrorRestrict.ofApiValue(restrict)
            )
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
            xRestrict: n.xRestrict, novelAIType: n.novelAIType,
            visible: n.visible, isMuted: n.isMuted
        )
        novel = n
        InteractionStore.shared.noteNovelBookmark(id: novelId, isBookmarked)
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
    @State private var toolbarTitleVisible = false
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.openURL) private var openURL
    @Environment(\.pushRoute) private var pushRoute
    @Environment(\.dismiss) private var dismiss

    init(novelId: Int64) {
        self.novelId = novelId
        _vm = State(wrappedValue: NovelDetailViewModel(novelId: novelId))
    }

    private var pixivURL: URL {
        URL(string: "https://www.pixiv.net/novel/show.php?id=\(novelId)")!
    }

    var body: some View {
        GeometryReader { geo in
            let topInset = geo.safeAreaInsets.top
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let novel = vm.novel {
                        NovelHero(novel: novel, topInset: topInset)
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
                                    .contextMenu {
                                        Button {
                                            UIPasteboard.general.string = tag.name
                                        } label: { Label(l10n.t(.actionCopy), systemImage: "doc.on.doc") }
                                        // 「该作者相关作品」(#1102) — the author comes from the novel itself.
                                        if let authorId = novel.user?.id, authorId > 0, let name = tag.name, !name.isEmpty {
                                            Button {
                                                pushRoute(.userIllustTag(userId: authorId, tag: name, category: "novels"))
                                            } label: {
                                                Label(l10n.t(.tagMenuAuthorWorks), systemImage: "person.crop.rectangle.stack")
                                            }
                                        }
                                    }
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

                    } else if vm.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, topInset + 120)
                    } else if let err = vm.errorMessage {
                        InlineError(message: err) { Task { await vm.load() } }
                            .padding().padding(.top, topInset)
                    }
                }
                .padding(.bottom, 12)
                .background(GeometryReader { proxy in
                    // .global, not a named scroll space (named-space frames come
                    // back stuck at 0 on iOS 26). Content top == screen top (top
                    // safe area ignored), so global minY is the scroll offset.
                    Color.clear.preference(
                        key: NovelScrollOffsetKey.self,
                        value: proxy.frame(in: .global).minY
                    )
                })
            }
            .onPreferenceChange(NovelScrollOffsetKey.self) { offset in
                setToolbarTitle(visible: offset < -220)
            }
            // Hero bleeds edge-to-edge under the status bar (Apple Books style).
            .ignoresSafeArea(.container, edges: .top)
            // Native bottom action bar that auto-insets the scroll content and
            // clears the home indicator (no manual spacer).
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        }
        // iOS 26 Liquid Glass paints a scroll-edge material on the navigation bar
        // that no toolbar-background modifier can clear, leaving a dark band over
        // the edge-to-edge hero. The bar is hidden entirely and its controls are
        // re-drawn as floating glass capsules (see detailTopBar) instead.
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) { detailTopBar }
        .task {
            await vm.loadIfNeeded()
            if let n = vm.novel { HistoryStore.shared.record(novel: n) }
        }
        .fullScreenCover(isPresented: $showReader) {
            NovelReaderV3View(novelId: novelId)
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

    /// Floating top bar that replaces the hidden navigation bar: back and
    /// overflow controls as glass capsules over the edge-to-edge hero, with the
    /// title fading in (centered) once the hero scrolls away.
    private var detailTopBar: some View {
        ZStack {
            Text(vm.novel?.title ?? "")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 56)
                .opacity(toolbarTitleVisible ? 1 : 0)
            HStack {
                Button { dismiss() } label: {
                    DetailGlassCircle(system: "chevron.backward")
                }
                .buttonStyle(.plain)
                Spacer()
                Menu { moreMenu } label: {
                    DetailGlassCircle(system: "ellipsis")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var moreMenu: some View {
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
    }

    /// Native bottom action bar (App Store / Apple Books pattern): a secondary
    /// bookmark glyph beside the prominent full-width "Read" call to action, on a
    /// `.bar` material with a hairline top separator.
    private var bottomBar: some View {
        HStack(spacing: 14) {
            Button {
                BookmarkHaptics.commit(bookmarking: vm.novel?.isBookmarked != true)
                Task { await vm.toggleBookmark() }
            } label: {
                Image(systemName: (vm.novel?.isBookmarked == true) ? "heart.fill" : "heart")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle((vm.novel?.isBookmarked == true) ? Theme.v3Bookmarked : .secondary)
                    .bookmarkBounce(vm.novel?.isBookmarked == true)
                    .frame(width: 50, height: 50)
                    .background(Color(.tertiarySystemFill), in: .circle)
            }
            .buttonStyle(.bookmark)
            .disabled(vm.isBookmarking || vm.novel == nil)
            .contextMenu { bookmarkMenu }

            Button {
                showReader = true
            } label: {
                Label(l10n.t(.novelRead), systemImage: "book.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Theme.brandGradient, in: .capsule)
                    .shadow(color: Theme.brandShadow, radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(vm.novel == nil)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(.separator).opacity(0.6)).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var bookmarkMenu: some View {
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

    /// Title fades in once the hero has scrolled past, mirroring the illust page.
    private func setToolbarTitle(visible: Bool) {
        guard toolbarTitleVisible != visible else { return }
        withAnimation(.easeOut(duration: 0.2)) { toolbarTitleVisible = visible }
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

/// Immersive cover hero (Apple Books style): the cover blurred to fill the
/// width and bleed up into the top safe area, with the crisp cover floated on
/// top. A top scrim keeps the glass nav controls legible; the bottom fades into
/// the page background so the metadata block reads as one surface.
private struct NovelHero: View {
    let novel: Novel
    let topInset: CGFloat

    var body: some View {
        ZStack {
            // Blurred cover backdrop — extended past the edges so the blur and
            // the gentle zoom never reveal the placeholder rectangle.
            PixivAsyncImage(url: coverURL, showsProgress: false)
                .scaleEffect(1.3)
                .blur(radius: 36, opaque: true)
                .overlay(Color(.systemBackground).opacity(0.12))
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.35), location: 0),
                            .init(color: .clear, location: 0.35),
                            .init(color: .clear, location: 0.6),
                            .init(color: Color(.systemBackground), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            // Crisp cover, pushed below the floating glass controls.
            PixivAsyncImage(url: coverURL)
                .frame(width: 150, height: 212)
                .clipShape(.rect(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.white.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
                .padding(.top, topInset + 56)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var coverURL: URL? {
        let s = novel.imageUrls?.large
            ?? novel.imageUrls?.medium
            ?? novel.imageUrls?.squareMedium
        return s.flatMap(URL.init(string:))
    }
}

private struct NovelScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {}
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
