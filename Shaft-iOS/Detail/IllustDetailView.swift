import SwiftUI

@MainActor
@Observable
final class IllustDetailViewModel {
    let illustId: Int64
    var illust: Illust?
    var related: [Illust] = []
    var comments: [CommentItem] = []
    var totalComments: Int?
    var isLoading = false
    var errorMessage: String?
    var isBookmarking = false

    @ObservationIgnored private let api: PixivAPI

    init(illustId: Int64) {
        self.illustId = illustId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async {
        if illust == nil { await load() }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in await self?.loadDetail() }
            group.addTask { @MainActor [weak self] in await self?.loadRelated() }
            group.addTask { @MainActor [weak self] in await self?.loadComments() }
        }
    }

    private func loadDetail() async {
        do {
            let resp = try await api.illustDetail(illustId)
            illust = resp.illust
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadRelated() async {
        let resp = try? await api.relatedIllusts(illustId)
        related = resp?.illusts ?? []
    }

    private func loadComments() async {
        let resp = try? await api.illustComments(illustId)
        comments = resp?.comments ?? []
        totalComments = resp?.totalComments
    }

    func toggleBookmark(restrict: String = "public") async {
        guard let cur = illust else { return }
        isBookmarking = true
        defer { isBookmarking = false }
        do {
            if cur.isBookmarked == true {
                _ = try await api.unbookmarkIllust(illustId)
                update(isBookmarked: false)
            } else {
                _ = try await api.bookmarkIllust(illustId, restrict: restrict)
                update(isBookmarked: true)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Existing bookmark state (registered tags + visibility) for pre-filling
    /// the bookmark sheet. Nil when the work isn't bookmarked yet.
    func bookmarkDetail() async -> (restrict: String, tags: [String])? {
        guard illust?.isBookmarked == true else { return nil }
        guard let d = try? await api.illustBookmarkDetail(illustId).bookmarkDetail else { return nil }
        return (d.restrict ?? "public", d.registeredTags)
    }

    /// Bookmark with explicit restrict + tags. Re-applies if already bookmarked
    /// (Pixiv replaces the bookmark with the new tag/restrict set).
    func bookmark(restrict: String, tags: [String]) async {
        isBookmarking = true
        defer { isBookmarking = false }
        do {
            _ = try await api.bookmarkIllust(illustId, restrict: restrict, tags: tags)
            update(isBookmarked: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func update(isBookmarked: Bool) {
        guard var i = illust else { return }
        i = Illust(
            id: i.id, title: i.title, caption: i.caption, type: i.type,
            imageUrls: i.imageUrls, user: i.user, tags: i.tags,
            pageCount: i.pageCount, width: i.width, height: i.height,
            totalBookmarks: i.totalBookmarks, totalView: i.totalView,
            isBookmarked: isBookmarked, createDate: i.createDate,
            metaSinglePage: i.metaSinglePage, metaPages: i.metaPages,
            series: i.series, xRestrict: i.xRestrict, illustAIType: i.illustAIType
        )
        illust = i
    }
}

/// V3-style illust detail: hero pages full-bleed at the top, scroll-aware
/// header that fades into the content, sections below for title/stats/tags
/// and related works. Bottom action bar overlays.
struct IllustDetailView: View {
    let illustId: Int64
    @State private var vm: IllustDetailViewModel
    @State private var showViewer = false
    @State private var viewerIndex = 0
    @State private var showBookmarkSheet = false
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.openURL) private var openURL

    init(illustId: Int64) {
        self.illustId = illustId
        _vm = State(wrappedValue: IllustDetailViewModel(illustId: illustId))
    }

    private var pixivURL: URL {
        URL(string: "https://www.pixiv.net/artworks/\(illustId)")!
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let illust = vm.illust {
                        IllustPagesHero(illust: illust, onTap: { showViewer = true })
                        IllustMetaSection(illust: illust)
                            .padding(.horizontal, 16)
                        IllustAuthorSection(illust: illust)
                            .padding(.horizontal, 16)
                        if let tags = illust.tags, !tags.isEmpty {
                            IllustTagsSection(tags: tags)
                                .padding(.horizontal, 16)
                        }
                        if !vm.related.isEmpty {
                            SectionLabel(title: l10n.t(.detailRelated))
                                .padding(.horizontal, 16)
                            WaterfallGrid(
                                items: Array(vm.related.prefix(20)),
                                columns: 2, spacing: 8,
                                estimatedRelativeHeight: { i in
                                    let w = max(Double(i.width ?? 1), 1)
                                    let h = max(Double(i.height ?? 1), 1)
                                    return 1.0 / max(0.5, min(w/h, 2.0)) + 0.18
                                }
                            ) { item in
                                NavigationLink(value: AppRoute.illustDetail(item.id)) {
                                    IllustWaterfallCell(illust: item)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                        }
                        if !vm.comments.isEmpty {
                            SectionLabel(title: l10n.t(.commentsTitle))
                                .padding(.horizontal, 16)
                            VStack(spacing: 12) {
                                ForEach(vm.comments.prefix(5)) { CommentRow(comment: $0) }
                                NavigationLink(value: AppRoute.comments(target: .illust(illustId))) {
                                    Text(l10n.t(.viewAllComments))
                                        .font(.footnote)
                                        .foregroundStyle(.tint)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        Color.clear.frame(height: 88) // space for bottom bar
                    } else if vm.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                    } else if let err = vm.errorMessage {
                        InlineError(message: err) { Task { await vm.load() } }
                            .padding()
                    }
                }
                .padding(.vertical, 8)
            }
            BottomActionBar(vm: vm, onShowBookmarkSheet: { showBookmarkSheet = true })
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
                    if let user = vm.illust?.user {
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
            if let i = vm.illust { HistoryStore.shared.record(illust: i) }
        }
        .fullScreenCover(isPresented: $showViewer) {
            if let urls = vm.illust.map(IllustPagesHero.urls(for:)), !urls.isEmpty {
                ImageViewerView(urls: urls, index: $viewerIndex)
            }
        }
        .sheet(isPresented: $showBookmarkSheet) {
            BookmarkTagsSheet(
                existingTags: (vm.illust?.tags ?? []).compactMap { $0.name },
                loadInitial: { await vm.bookmarkDetail() }
            ) { restrict, tags in
                await vm.bookmark(restrict: restrict, tags: tags)
            }
        }
    }
}

struct IllustPagesHero: View {
    let illust: Illust
    var onTap: () -> Void = {}
    @State private var index = 0

    var body: some View {
        let urls = Self.urls(for: illust)
        Group {
            if illust.type == "ugoira" {
                UgoiraView(
                    illustId: illust.id,
                    fallbackURL: urls.first,
                    contentMode: .fit,
                    onTap: onTap
                )
                .frame(maxWidth: .infinity)
            } else {
                TabView(selection: $index) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { i, url in
                        PixivAsyncImage(url: url, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: 480)
                            .onTapGesture { onTap() }
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: urls.count > 1 ? .always : .never))
            }
        }
        .frame(height: heroHeight)
        .background(Color(.secondarySystemBackground))
    }

    static func urls(for illust: Illust) -> [URL] {
        if let pages = illust.metaPages, !pages.isEmpty {
            return pages.compactMap { $0.imageUrls?.large.flatMap(URL.init(string:)) }
        }
        if let s = illust.metaSinglePage?.originalImageUrl
            ?? illust.imageUrls?.large
            ?? illust.imageUrls?.medium {
            return [URL(string: s)].compactMap { $0 }
        }
        return []
    }

    private var heroHeight: CGFloat {
        let w = max(CGFloat(illust.width ?? 1), 1)
        let h = max(CGFloat(illust.height ?? 1), 1)
        let aspect = max(0.5, min(w / h, 2.0))
        return min(540, UIScreen.main.bounds.width / aspect + 24)
    }
}

private struct IllustMetaSection: View {
    let illust: Illust

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(illust.title ?? "")
                .font(.title3.bold())
            if let series = illust.series,
               let title = series.title, !title.isEmpty,
               let sid = series.id {
                NavigationLink(value: AppRoute.illustSeries(seriesId: sid)) {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.stack")
                        Text(title)
                    }
                    .font(.footnote)
                    .foregroundStyle(.tint)
                }
            }
            HStack(spacing: 14) {
                if let v = illust.totalView {
                    Label("\(v)", systemImage: "eye")
                }
                if let b = illust.totalBookmarks {
                    Label("\(b)", systemImage: "heart")
                }
                if let date = illust.createDate {
                    Text(formatDate(date))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func formatDate(_ s: String) -> String {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: s) else { return s }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct IllustAuthorSection: View {
    let illust: Illust

    var body: some View {
        if let user = illust.user {
            NavigationLink(value: AppRoute.userProfile(user.id)) {
                HStack(spacing: 12) {
                    PixivAsyncImage(url: avatarURL(for: user))
                        .frame(width: 40, height: 40)
                        .clipShape(.circle)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(user.name ?? "")
                            .font(.subheadline.weight(.semibold))
                        Text("@\(user.account ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
                .foregroundStyle(.primary)
            }
        }
    }

    private func avatarURL(for user: PixivUser) -> URL? {
        (user.profileImageUrls?.medium ?? user.profileImageUrls?.px170x170)
            .flatMap(URL.init(string:))
    }
}

private struct IllustTagsSection: View {
    let tags: [Tag]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                NavigationLink(value: AppRoute.tagResults(tag: tag.name ?? "")) {
                    HStack(spacing: 4) {
                        Text("#\(tag.name ?? "")")
                            .font(.caption.bold())
                        if let translated = tag.translatedName, !translated.isEmpty {
                            Text(translated)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color(.secondarySystemBackground), in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct BottomActionBar: View {
    let vm: IllustDetailViewModel
    let onShowBookmarkSheet: () -> Void
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        HStack(spacing: 24) {
            Spacer()
            Button {
                Task { await vm.toggleBookmark() }
            } label: {
                Image(systemName: (vm.illust?.isBookmarked == true) ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle((vm.illust?.isBookmarked == true) ? .pink : .primary)
                    .frame(width: 44, height: 44)
            }
            .disabled(vm.isBookmarking || vm.illust == nil)
            .contextMenu {
                if vm.illust?.isBookmarked != true {
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
                    onShowBookmarkSheet()
                } label: {
                    Label(l10n.t(.bookmarkWithTags), systemImage: "tag")
                }
            }

            ShareLink(item: shareURL) {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private var shareURL: URL {
        URL(string: "https://www.pixiv.net/artworks/\(vm.illustId)")!
    }
}

private struct CommentRow: View {
    let comment: CommentItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PixivAsyncImage(url: avatarURL)
                .frame(width: 32, height: 32)
                .clipShape(.circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(comment.user?.name ?? "")
                    .font(.caption.bold())
                Text(comment.comment ?? "")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            Spacer()
        }
    }

    private var avatarURL: URL? {
        (comment.user?.profileImageUrls?.medium ?? comment.user?.profileImageUrls?.px170x170)
            .flatMap(URL.init(string:))
    }
}

struct SectionLabel: View {
    let title: String
    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
        }
    }
}

/// Minimal flow layout for tag chips. iOS 16+ has `Layout`; Pixiv tag rows
/// are typically a handful of items so a single-pass greedy layout is fine.
struct FlowLayout: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat = 6) {
        self.spacing = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
