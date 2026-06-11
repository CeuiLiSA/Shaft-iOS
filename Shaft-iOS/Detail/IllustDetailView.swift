import SwiftUI

@MainActor
@Observable
final class IllustDetailViewModel {
    let illustId: Int64
    var illust: Illust? {
        didSet { captionPlain = illust?.caption.map { V3Caption.plain($0) } ?? "" }
    }
    /// Plaintext caption derived once per illust change — `V3Caption.plain`
    /// runs regex + entity replacement and must not run per body evaluation.
    private(set) var captionPlain: String = ""
    var related: [Illust] = []
    var comments: [CommentItem] = []
    var authorWorks: [Illust] = []
    var totalComments: Int?
    var isLoading = false
    var errorMessage: String?
    var isBookmarking = false
    /// Author follow state, seeded from the embedded `illust.user.is_followed`
    /// and toggled optimistically by the artist card's follow button.
    var authorFollowed = false

    // Lazy section state. Comments / author works / related each fire their
    // request only when that section first scrolls into view (parity with V3
    // `ArtworkDetailAdapter.onViewAttachedToWindow`). `*Loaded` flips true once
    // an attempt finishes so the section can swap its spinner for content/empty.
    var commentsLoaded = false
    var relatedLoaded = false
    var authorWorksLoaded = false
    @ObservationIgnored private var commentsTriggered = false
    @ObservationIgnored private var relatedTriggered = false
    @ObservationIgnored private var authorWorksTriggered = false

    @ObservationIgnored private let api: PixivAPI

    init(illustId: Int64) {
        self.illustId = illustId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    /// Seed with the full `Illust` the list already holds, so the detail renders
    /// immediately; `load()` then refreshes it and fetches related + comments +
    /// author works (which the list doesn't carry).
    init(illust: Illust) {
        self.illustId = illust.id
        self.illust = illust
        self.authorFollowed = illust.user?.isFollowed ?? false
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
        // didSet doesn't fire during init.
        self.captionPlain = illust.caption.map { V3Caption.plain($0) } ?? ""
    }

    private var hasLoaded = false

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        apiLog.notice("▶︎ illust-detail OPEN id=\(self.illustId, privacy: .public) — only /illust/detail up front; comments, author works & related load lazily on scroll")
        // Only the work itself loads up front. Comments / author works / related
        // are deferred to when their section scrolls into view, so a quick
        // glance-and-back doesn't burn three extra requests.
        await loadDetail()
        authorFollowed = illust?.user?.isFollowed ?? authorFollowed
    }

    private func loadDetail() async {
        do {
            let resp = try await api.illustDetail(illustId)
            illust = resp.illust
        } catch {
            // Keep any seeded illust so the page still renders (issue #569 parity).
            if illust == nil { errorMessage = error.localizedDescription }
        }
    }

    /// Fired from `V3RelatedSection.onAppear` — once per page.
    func loadRelatedIfNeeded() async {
        guard !relatedTriggered else { return }
        relatedTriggered = true
        let resp = try? await api.relatedIllusts(illustId)
        related = resp?.illusts ?? []
        relatedLoaded = true
    }

    /// Fired from `V3CommentsSection.onAppear` — once per page.
    func loadCommentsIfNeeded() async {
        guard !commentsTriggered else { return }
        commentsTriggered = true
        let resp = try? await api.illustComments(illustId)
        comments = resp?.comments ?? []
        totalComments = resp?.totalComments
        commentsLoaded = true
    }

    /// Fired from `V3AuthorWorksSection.onAppear` — once per page. Needs the
    /// artist id, which the detail load (or seed) has already provided by the
    /// time this section can scroll into view.
    func loadAuthorWorksIfNeeded() async {
        guard !authorWorksTriggered, let uid = illust?.user?.id else { return }
        authorWorksTriggered = true
        let resp = try? await api.userIllusts(uid, type: "illust")
        authorWorks = (resp?.illusts ?? []).filter { $0.id != illustId }
        authorWorksLoaded = true
    }

    /// Optimistically flip the artist's follow state, then call the API; revert on
    /// failure. Long-press on the button follows privately.
    func toggleFollow(restrict: String = "public") async {
        guard let uid = illust?.user?.id else { return }
        let target = !authorFollowed
        authorFollowed = target
        do {
            if target {
                _ = try await api.followUser(uid, restrict: restrict)
            } else {
                _ = try await api.unfollowUser(uid)
            }
        } catch {
            authorFollowed = !target
        }
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

/// V3-style illust detail (`ArtworkV3Fragment`): pages stack vertically at the
/// top (multi-page collapses to the first page behind an "expand" pill), then
/// the title/meta, series, artist (with follow), caption, tags, stats, the
/// collapsible "Artwork Details" glass panel, comments, the author's other
/// works and related works — in that order. A floating download/bookmark pill
/// overlays and hides on scroll-down.
struct IllustDetailView: View {
    let illustId: Int64
    @State private var vm: IllustDetailViewModel
    @State private var showViewer = false
    @State private var viewerIndex = 0
    @State private var showBookmarkSheet = false
    @State private var actionBarVisible = true
    /// Plain class box, deliberately NOT observable state: the anchor advances
    /// every ~8pt of scroll, and an `@State` write there re-evaluates the whole
    /// page body per scroll tick. Boxed, only the rare `actionBarVisible` flip
    /// invalidates the view.
    @State private var scrollAnchor = ScrollAnchor()
    @State private var pagesExpanded = false
    @State private var detailPanelExpanded = true
    /// Links each page image to the full-screen viewer for the system zoom
    /// transition (zoom in on open; interactive pull-down zooms back out).
    @Namespace private var viewerZoom
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.openURL) private var openURL

    init(illustId: Int64) {
        self.illustId = illustId
        _vm = State(wrappedValue: IllustDetailViewModel(illustId: illustId))
    }

    init(illust: Illust) {
        self.illustId = illust.id
        _vm = State(wrappedValue: IllustDetailViewModel(illust: illust))
    }

    private var pixivURL: URL {
        URL(string: "https://www.pixiv.net/artworks/\(illustId)")!
    }

    /// Hide the action pill on scroll-down, reveal on scroll-up (Shaft V3
    /// behavior). `offset` is the content's top relative to the scroll view — it
    /// decreases as the user scrolls down. The anchor only advances past an 8pt
    /// threshold so slow scrolls still accumulate to a direction.
    private func handleScroll(_ offset: CGFloat) {
        if offset > -10 { setActionBar(visible: true); scrollAnchor.lastOffset = offset; return }
        let delta = offset - scrollAnchor.lastOffset
        if delta <= -8 { setActionBar(visible: false); scrollAnchor.lastOffset = offset }
        else if delta >= 8 { setActionBar(visible: true); scrollAnchor.lastOffset = offset }
    }

    private func setActionBar(visible: Bool) {
        guard actionBarVisible != visible else { return }
        withAnimation(.easeOut(duration: 0.2)) { actionBarVisible = visible }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let illust = vm.illust {
                        content(for: illust)
                    } else if vm.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
                    } else if let err = vm.errorMessage {
                        InlineError(message: err) { Task { await vm.load() } }
                            .padding()
                    }
                }
                .background(GeometryReader { proxy in
                    // .global, not a named scroll space: named-space frames
                    // come back stuck at 0 on iOS 26. Content top == screen
                    // top (top safe area ignored), so global minY is the
                    // scroll offset.
                    Color.clear.preference(
                        key: ScrollOffsetPreferenceKey.self,
                        value: proxy.frame(in: .global).minY
                    )
                })
            }
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                handleScroll(offset)
            }
            .ignoresSafeArea(.container, edges: .top)
            BottomActionBar(vm: vm, onShowBookmarkSheet: { showBookmarkSheet = true })
                .offset(y: actionBarVisible ? 0 : 180)
                .opacity(actionBarVisible ? 1 : 0)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
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
            // Unconditional content with navigationTransition as the ROOT
            // modifier: wrapping it in `if let` puts a ConditionalContent
            // above the transition and the zoom-present silently degrades to
            // an instant cut (dismissal still worked). sourceID follows the
            // page being viewed, so paging in the viewer and pulling down
            // zooms back to the matching inline page (center fallback when
            // it's collapsed).
            ImageViewerView(pages: vm.illust.map(IllustPages.pages(for:)) ?? [],
                            index: $viewerIndex)
                .navigationTransition(.zoom(sourceID: viewerIndex, in: viewerZoom))
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

    @ViewBuilder
    private func content(for illust: Illust) -> some View {
        // Pages are emitted as direct LazyVStack children (not wrapped in an
        // opaque sub-VStack) so an expanded multi-page work materializes its
        // originals lazily as they scroll into view.
        let pages = IllustPages.pages(for: illust)
        let collapsible = pages.count > collapsePagesThreshold
        let collapsed = collapsible && !pagesExpanded

        IllustFirstPage(
            illust: illust,
            pages: pages,
            collapsed: collapsed,
            onTap: { viewerIndex = 0; showViewer = true },
            onExpand: { withAnimation(.easeInOut(duration: 0.25)) { pagesExpanded = true } }
        )
        .matchedTransitionSource(id: 0, in: viewerZoom)

        if !collapsed {
            ForEach(Array(pages.enumerated()).dropFirst(), id: \.offset) { idx, page in
                StackedPage(urls: page) { viewerIndex = idx; showViewer = true }
                    .matchedTransitionSource(id: idx, in: viewerZoom)
            }
            if collapsible {
                CollapsePagesPill {
                    withAnimation(.easeInOut(duration: 0.25)) { pagesExpanded = false }
                }
                .padding(.vertical, 12)
            }
        }

        V3TitleCard(illust: illust)

        if let series = illust.series, let title = series.title, !title.isEmpty, series.id != nil {
            V3SeriesStrip(series: series)
        }

        V3ArtistCard(vm: vm)

        if !vm.captionPlain.isEmpty {
            V3CaptionView(text: vm.captionPlain)
        }

        if let tags = illust.tags, !tags.isEmpty {
            V3TagsSection(tags: tags)
        }

        V3StatsCard(illust: illust)

        V3DetailPanel(illust: illust, expanded: $detailPanelExpanded)

        V3CommentsSection(vm: vm, illustId: illustId)

        V3AuthorWorksSection(vm: vm, user: illust.user)

        V3RelatedSection(vm: vm, illustId: illustId)

        Color.clear.frame(height: 96) // clearance for the floating action pill
    }
}

// MARK: - Pages (collapsible, stretchy first page; rest emitted lazily by content(for:))

/// Works with more than this many pages collapse to the first page behind an
/// "expand" pill so tags / comments / related are reachable without a long
/// scroll (parity with `CollapsibleIllustAdapter`).
private let collapsePagesThreshold = 3

private struct IllustFirstPage: View {
    let illust: Illust
    let pages: [IllustPageURLs]
    let collapsed: Bool
    var onTap: () -> Void
    var onExpand: () -> Void

    private var firstAspect: CGFloat {
        let w = max(CGFloat(illust.width ?? 1), 1)
        let h = max(CGFloat(illust.height ?? 1), 1)
        return w / h
    }

    var body: some View {
        VStack(spacing: 0) {
            if illust.type == "ugoira" {
                UgoiraView(
                    illustId: illust.id,
                    fallbackURL: pages.first?.large ?? pages.first?.original,
                    contentMode: .fit,
                    onTap: onTap
                )
                .frame(maxWidth: .infinity)
                .frame(height: UIScreen.main.bounds.width / max(firstAspect, 0.1))
            } else if let first = pages.first {
                StretchyFirstPage(urls: first, aspect: firstAspect, onTap: onTap)
                .overlay(alignment: .topTrailing) {
                    if pages.count > 1 {
                        Label("\(pages.count)", systemImage: "square.on.square")
                            .font(.caption2.bold())
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: .capsule)
                            .foregroundStyle(.white)
                            .padding(12)
                    }
                }
                .overlay(alignment: .bottom) {
                    if collapsed {
                        ExpandPagesPill(remaining: pages.count - 1, onTap: onExpand)
                    }
                }
            }
        }
    }
}

/// First page with the classic iOS stretchy-header effect: pulling the scroll
/// view past its top enlarges the image (filling the revealed gap and zooming).
private struct StretchyFirstPage: View {
    let urls: IllustPageURLs
    let aspect: CGFloat
    var onTap: () -> Void

    @State private var loader = HeroImageLoader()

    private var baseHeight: CGFloat { UIScreen.main.bounds.width / max(aspect, 0.1) }

    var body: some View {
        GeometryReader { proxy in
            // Global frame: the hero is the first element of scroll content
            // that starts at the screen top, so global minY > 0 == overscroll.
            let minY = proxy.frame(in: .global).minY
            let stretch = max(0, minY)
            ZStack {
                Rectangle().fill(Color(.secondarySystemBackground))
                if let image = loader.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                }
                if loader.isLoadingOriginal {
                    HeroOriginalProgress(progress: loader.progress)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: proxy.size.width, height: baseHeight + stretch)
            .clipped()
            .offset(y: -stretch)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .task(id: urls.original) {
                await loader.run(large: urls.large, original: urls.original,
                                 pixelWidth: Int(proxy.size.width * UIScreen.main.scale))
            }
        }
        .frame(height: baseHeight)
    }
}

/// A non-first page in the vertical stack — laid out at the image's natural
/// aspect (Pixiv `meta_pages` carry no per-page dimensions, so the height
/// settles once the image loads).
private struct StackedPage: View {
    let urls: IllustPageURLs
    var onTap: () -> Void

    @State private var loader = HeroImageLoader()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            } else {
                Rectangle()
                    .fill(Color(.secondarySystemBackground))
                    .aspectRatio(0.8, contentMode: .fit)
                    .overlay(ProgressView())
            }
            if loader.isLoadingOriginal {
                HeroOriginalProgress(progress: loader.progress).allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .task(id: urls.original) {
            // Stacked pages span the full screen width (no geometry reader here).
            await loader.run(large: urls.large, original: urls.original,
                             pixelWidth: Int(UIScreen.main.bounds.width * UIScreen.main.scale))
        }
    }
}

private struct ExpandPagesPill: View {
    let remaining: Int
    var onTap: () -> Void
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .frame(height: 88)
                .allowsHitTesting(false)
            Button(action: onTap) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.stack.fill")
                    Text(l10n.t(.detailExpandRemainingFmt, "\(remaining)"))
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(.black.opacity(0.55), in: .capsule)
                .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 14)
        }
    }
}

private struct CollapsePagesPill: View {
    var onTap: () -> Void
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.up")
                Text(l10n.t(.detailCollapsePages)).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Theme.v3Text2)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .v3Glass(corner: 18)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - V3 sections

private struct V3TitleCard: View {
    let illust: Illust
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(illust.title ?? "")
                .font(.system(size: 23, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(Theme.v3Text1)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            HStack(spacing: 8) {
                Text(typeLabel)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.v3Text2)
                dot
                Text(V3Date.dateTime(illust.createDate))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.v3Text3)
                dot
                Text(pagesLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.v3Text3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private var dot: some View {
        Circle().fill(Theme.v3Text3).frame(width: 3, height: 3)
    }

    private var typeLabel: String {
        switch illust.type {
        case "manga": return l10n.t(.detailTypeManga)
        case "ugoira": return l10n.t(.detailTypeUgoira)
        default: return l10n.t(.detailTypeIllust)
        }
    }

    private var pagesLabel: String {
        let n = illust.pageCount ?? 1
        return n <= 1 ? l10n.t(.detailPageOne) : l10n.t(.detailPagesFmt, "\(n)")
    }
}

private struct V3SeriesStrip: View {
    let series: IllustSeriesRef
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        NavigationLink(value: AppRoute.illustSeries(seriesId: series.id ?? 0)) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.18))
                    Image(systemName: "rectangle.stack.fill").font(.system(size: 14)).foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text(l10n.t(.detailSeriesLabel).uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(series.title ?? "")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.8))
            }
            .padding(12)
            .background(Theme.brandGradient, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
    }
}

private struct V3ArtistCard: View {
    let vm: IllustDetailViewModel
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        if let user = vm.illust?.user {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    NavigationLink(value: AppRoute.userProfile(user.id)) {
                        HStack(spacing: 12) {
                            PixivAsyncImage(url: avatarURL(for: user), showsProgress: false)
                                .frame(width: 58, height: 58)
                                .clipShape(.circle)
                                .overlay(Circle().strokeBorder(Theme.v3Border, lineWidth: 3))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(user.name ?? "")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(Theme.v3Text1)
                                    .lineLimit(1)
                                Text("@\(user.account ?? "")")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.v3Text3)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 8)

                    FollowButton(followed: vm.authorFollowed) {
                        Task { await vm.toggleFollow() }
                    } onLongPress: {
                        Task { await vm.toggleFollow(restrict: "private") }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 18)
            .v3Glass(corner: 28)
            .padding(.horizontal, 12)
            .padding(.bottom, 18)
        }
    }

    private func avatarURL(for user: PixivUser) -> URL? {
        (user.profileImageUrls?.medium ?? user.profileImageUrls?.px170x170)
            .flatMap(URL.init(string:))
    }
}

private struct FollowButton: View {
    let followed: Bool
    var onTap: () -> Void
    var onLongPress: () -> Void
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        Button(action: onTap) {
            Text(followed ? l10n.t(.detailUnfollow) : l10n.t(.detailFollow))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(followed ? AnyShapeStyle(Theme.v3Text2) : AnyShapeStyle(Color.white))
                .padding(.horizontal, 18)
                .frame(height: 32)
                .background {
                    if followed {
                        Capsule().fill(Theme.v3Surface).overlay(Capsule().strokeBorder(Theme.v3Border, lineWidth: 1))
                    } else {
                        Capsule().fill(Theme.brandGradient)
                    }
                }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture().onEnded { _ in if !followed { onLongPress() } })
    }
}

private struct V3CaptionView: View {
    /// Already-plaintext caption (HTML stripped by the view model).
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.v3Text2)
            .lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
    }
}

private struct V3TagsSection: View {
    let tags: [Tag]
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            V3Label(l10n.t(.detailTagsLabel))
            FlowLayout(spacing: 6) {
                ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                    NavigationLink(value: AppRoute.tagResults(tag: tag.name ?? "")) {
                        HStack(spacing: 4) {
                            Text("#\(tag.name ?? "")")
                                .font(.caption.bold())
                                .foregroundStyle(Theme.v3Ambient)
                            if let translated = tag.translatedName, !translated.isEmpty {
                                Text(translated)
                                    .font(.caption)
                                    .foregroundStyle(Theme.v3Text3)
                            }
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Theme.v3Surface, in: .capsule)
                        .overlay(Capsule().strokeBorder(Theme.v3Border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 18)
    }
}

private struct V3StatsCard: View {
    let illust: Illust
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        HStack(spacing: 0) {
            stat(value: illust.totalView ?? 0, label: l10n.t(.detailViewsLabel), gradient: Theme.v3ViewsGradient)
            Rectangle().fill(Theme.v3Border).frame(width: 1, height: 36)
            stat(value: illust.totalBookmarks ?? 0, label: l10n.t(.detailBookmarksLabel), gradient: Theme.v3BookmarksGradient)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 16)
        .v3Glass(corner: 20)
        .padding(.horizontal, 12)
        .padding(.bottom, 18)
    }

    private func stat(value: Int, label: String, gradient: LinearGradient) -> some View {
        VStack(spacing: 3) {
            Text(value.formatted(.number.grouping(.automatic)))
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(gradient)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(Theme.v3Text3)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct V3DetailPanel: View {
    let illust: Illust
    @Binding var expanded: Bool
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack {
                    V3Label(l10n.t(.detailArtworkDetails))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.v3Text3)
                        .rotationEffect(.degrees(expanded ? 0 : 180))
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, pair in
                        HStack(spacing: 8) {
                            chip(pair.0)
                            if let second = pair.1 { chip(second) } else { Color.clear.frame(maxWidth: .infinity) }
                        }
                    }
                }
                .padding(18)
                .v3Glass(corner: 28)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 18)
    }

    private struct Chip { let label: String; let value: String; let color: Color; let mono: Bool }

    private func chip(_ c: Chip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(c.label.uppercased())
                .font(.system(size: 9, weight: .regular))
                .tracking(0.7)
                .foregroundStyle(Theme.v3Text3)
            Text(c.value)
                .font(c.mono ? .system(size: 13, weight: .bold).monospaced() : .system(size: 13, weight: .bold))
                .foregroundStyle(c.color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.v3Surface, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.v3Border, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { UIPasteboard.general.string = c.value }
    }

    private var rows: [(Chip, Chip?)] {
        let all = chips
        var out: [(Chip, Chip?)] = []
        var i = 0
        while i < all.count {
            out.append((all[i], i + 1 < all.count ? all[i + 1] : nil))
            i += 2
        }
        return out
    }

    private var chips: [Chip] {
        let aiType = illust.illustAIType ?? 0
        let restrict = illust.xRestrict ?? 0
        let typeValue: String = {
            switch illust.type {
            case "manga": return l10n.t(.detailTypeManga)
            case "ugoira": return l10n.t(.detailTypeUgoira)
            default: return l10n.t(.detailTypeIllust)
            }
        }()
        let restrictValue: String = restrict == 1 ? "R-18" : (restrict == 2 ? "R-18G" : l10n.t(.dpAllAges))
        return [
            Chip(label: l10n.t(.dpArtworkId), value: "\(illust.id)", color: Theme.v3Ambient, mono: true),
            Chip(label: l10n.t(.dpUserId), value: illust.user.map { "\($0.id)" } ?? "--", color: Theme.v3Ambient, mono: true),
            Chip(label: l10n.t(.dpType), value: typeValue, color: Theme.v3Text1, mono: false),
            Chip(label: l10n.t(.dpResolution), value: "\(illust.width ?? 0) × \(illust.height ?? 0)", color: Theme.v3Text1, mono: false),
            Chip(label: l10n.t(.dpPages), value: "\(illust.pageCount ?? 1)", color: Theme.v3Text1, mono: false),
            Chip(label: l10n.t(.dpAI), value: aiType == 2 ? l10n.t(.dpAIYes) : l10n.t(.dpAINo), color: aiType == 2 ? Theme.v3Purple : Theme.v3Green, mono: false),
            Chip(label: l10n.t(.dpRestriction), value: restrictValue, color: restrict > 0 ? Theme.v3Pink : Theme.v3Blue, mono: false),
            Chip(label: l10n.t(.dpPublished), value: V3Date.dateTime(illust.createDate), color: Theme.v3Text1, mono: false),
        ]
    }
}

private struct V3CommentsSection: View {
    let vm: IllustDetailViewModel
    let illustId: Int64
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            V3Label(l10n.t(.commentsTitle))
                .padding(.bottom, 4)
            if !vm.commentsLoaded {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                if vm.comments.isEmpty {
                    // Upstream `comments_empty`: centered, paddingVertical
                    // 48dp with a 160dp floor so the section doesn't collapse.
                    Text(l10n.t(.commentsEmpty))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.v3Text3)
                        .padding(.vertical, 48)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    ForEach(Array(vm.comments.prefix(3).enumerated()), id: \.element.id) { idx, comment in
                        if idx > 0 { Rectangle().fill(Theme.v3Border).frame(height: 1) }
                        V3CommentRow(comment: comment)
                    }
                }
                // Upstream `comments_more`: full-width centered button with a
                // hairline `v3_border_2` r=14 outline, shown whenever comments
                // have loaded — the comments page stays reachable from the
                // empty state too.
                NavigationLink(value: AppRoute.comments(target: .illust(illustId))) {
                    Text(l10n.t(.viewAllComments))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.v3Text2)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.v3Border, lineWidth: 1))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
        .onScrolledIntoView { Task { await vm.loadCommentsIfNeeded() } }
    }
}

private struct V3CommentRow: View {
    let comment: CommentItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PixivAsyncImage(url: avatarURL, showsProgress: false)
                .frame(width: 36, height: 36)
                .clipShape(.circle)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(comment.user?.name ?? "")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.v3Text1)
                    Text(V3Date.relative(comment.date))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.v3Text3)
                }
                if let text = comment.comment, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.v3Text1.opacity(0.72))
                        .lineSpacing(4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
    }

    private var avatarURL: URL? {
        (comment.user?.profileImageUrls?.medium ?? comment.user?.profileImageUrls?.px170x170)
            .flatMap(URL.init(string:))
    }
}

private struct V3AuthorWorksSection: View {
    let vm: IllustDetailViewModel
    let user: PixivUser?
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        Group {
            if !vm.authorWorksLoaded {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { V3Label(l10n.t(.detailAuthorWorksFmt, user?.name ?? "")); Spacer() }
                    ProgressView().frame(maxWidth: .infinity, minHeight: 110)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 18)
            } else if !vm.authorWorks.isEmpty, let user {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        V3Label(l10n.t(.detailAuthorWorksFmt, user.name ?? ""))
                        Spacer()
                        NavigationLink(value: AppRoute.userProfile(user.id)) {
                            Text(l10n.t(.detailSeeMore))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.v3Ambient)
                        }
                        .buttonStyle(.plain)
                    }
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 8) {
                            ForEach(vm.authorWorks.prefix(12)) { work in
                                NavigationLink(value: work) {
                                    PixivAsyncImage(url: thumbURL(work))
                                        .frame(width: 110, height: 110)
                                        .clipShape(.rect(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 18)
            }
            // Loaded but empty → render nothing (the section collapses).
        }
        .onScrolledIntoView { Task { await vm.loadAuthorWorksIfNeeded() } }
    }

    private func thumbURL(_ illust: Illust) -> URL? {
        (illust.imageUrls?.squareMedium ?? illust.imageUrls?.medium).flatMap(URL.init(string:))
    }
}

private struct V3RelatedSection: View {
    let vm: IllustDetailViewModel
    let illustId: Int64
    @Environment(OnboardingStore.self) private var l10n
    @State private var mute = MuteStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                V3Label(l10n.t(.detailRelated))
                Spacer()
                if !vm.related.isEmpty {
                    NavigationLink(value: AppRoute.relatedIllusts(illustId: illustId)) {
                        Text(l10n.t(.detailSeeMore))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.v3Ambient)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)

            if !vm.relatedLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                let visible = mute.filter(vm.related)
                if visible.isEmpty {
                    Text(l10n.t(.detailNoRelated))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.v3Text3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else {
                    WaterfallGrid(
                        items: visible,
                        columns: mute.waterfallColumns,
                        spacing: 8,
                        estimatedRelativeHeight: { $0.waterfallEstimatedCellHeight }
                    ) { item in
                        NavigationLink(value: item) {
                            IllustWaterfallCell(illust: item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { IllustCellContextMenuItems(illust: item) }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .onScrolledIntoView { Task { await vm.loadRelatedIfNeeded() } }
    }
}

/// Fires `action` once — when the view's top edge first scrolls up into the
/// screen. Used to defer a section's API request until it is genuinely visible.
/// Gating on the global frame (not `onAppear`) is robust whether `LazyVStack`
/// realizes the row lazily or — because these sections come from a single
/// `@ViewBuilder` function — eagerly as one unit.
private struct OnScrolledIntoView: ViewModifier {
    let action: () -> Void
    @State private var fired = false

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                let minY = geo.frame(in: .global).minY
                Color.clear
                    .onAppear { fire(whenTopAt: minY) }
                    .onChange(of: minY) { _, newValue in fire(whenTopAt: newValue) }
            }
        )
    }

    private func fire(whenTopAt minY: CGFloat) {
        // minY is the section's top in screen coords. Fire once it has scrolled
        // up past the lower ~15% of the screen — i.e. the section is genuinely
        // in view, not peeking a sliver at the very bottom edge. This keeps the
        // three stacked sections firing in turn as each is reached, rather than
        // all at once the instant the region's top edge appears.
        guard !fired, minY < UIScreen.main.bounds.height * 0.85 else { return }
        fired = true
        action()
    }
}

private extension View {
    func onScrolledIntoView(perform action: @escaping () -> Void) -> some View {
        modifier(OnScrolledIntoView(action: action))
    }
}

/// Small uppercase section label — `v3_text_3`, tracked, bold (the recurring
/// "TAGS" / "ARTWORK DETAILS" / "RELATED" header style).
private struct V3Label: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(Theme.v3Text3)
    }
}

// MARK: - HTML caption + date helpers

enum V3Caption {
    /// Pixiv captions are HTML; render their text content (line breaks kept,
    /// tags stripped, common entities decoded). Links aren't tappable but the
    /// text is shown — parity with the V3 description block.
    /// `trimmed: false` keeps surrounding whitespace — needed when decoding a
    /// fragment mid-sentence (notification text around a `<b>` name).
    static func plain(_ html: String, trimmed: Bool = true) -> String {
        var s = html
        for br in ["<br />", "<br/>", "<br>", "</p>", "</P>"] {
            s = s.replacingOccurrences(of: br, with: "\n")
        }
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
        ]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        return trimmed ? s.trimmingCharacters(in: .whitespacesAndNewlines) : s
    }
}

enum V3Date {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s)
    }

    // Formatters are expensive to construct (locale/calendar load) and these
    // run in list-row bodies — cache them like `iso` above. Calls are
    // main-thread only (view bodies), matching DateFormatter's thread rules.
    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func dateTime(_ s: String?) -> String {
        guard let d = parse(s) else { return s ?? "" }
        return dateTimeFormatter.string(from: d)
    }

    static func relative(_ s: String?) -> String {
        guard let d = parse(s) else { return "" }
        return relativeFormatter.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Progressive hero loader

/// Drives the two-stage hero load (cached `large` → progress-tracked `original`).
/// `@MainActor` so its observable state is mutated safely; the structured `.task`
/// that calls `run` cancels the download when the page leaves the screen.
@MainActor
@Observable
private final class HeroImageLoader {
    var image: UIImage?
    var progress: Double = 0
    var isLoadingOriginal = false
    private var showedOriginal = false

    /// `pixelWidth` is the rendered width in physical pixels — geometry is the
    /// view's knowledge, not this loader's.
    func run(large: URL?, original: URL?, pixelWidth: Int) async {
        // Memoized display-sized original from a previous visit — skip
        // the large placeholder and the disk round-trip entirely.
        if let original, let cached = PixivImageCache.shared.displayImage(for: original) {
            image = cached
            showedOriginal = true
            return
        }

        if let large {
            if let cached = PixivImageCache.shared.image(for: large) {
                if !showedOriginal { image = cached }
            } else if let img = await PixivImageCache.shared.load(large), !showedOriginal {
                image = img
            }
        }
        if Task.isCancelled { return }

        // Already showing the same URL at full res, or nothing better — done.
        guard let original, !showedOriginal else { return }
        if original == large, image != nil { return }

        isLoadingOriginal = true
        // Disk-cached bytes shared with the zoom viewer — one download serves
        // both pages. The hero only ever decodes a display-sized bitmap.
        let data = await PixivImageCache.shared.loadData(original) { [weak self] p in
            self?.progress = p
        }
        isLoadingOriginal = false
        guard !Task.isCancelled, let data,
              let img = await PixivImageCache.decodeForDisplay(data, pixelWidth: pixelWidth)
        else { return }
        PixivImageCache.shared.setDisplayImage(img, for: original)
        image = img
        showedOriginal = true
    }
}

/// Small ring + percentage shown while the `original` downloads over the
/// already-visible `large` image.
private struct HeroOriginalProgress: View {
    let progress: Double

    var body: some View {
        HStack(spacing: 6) {
            ProgressRing(progress: progress, track: .white.opacity(0.3))
                .frame(width: 15, height: 15)
            Text("\(Int(progress * 100))%")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: .capsule)
        .padding(12)
    }
}

/// Last scroll anchor for direction detection — reference type so per-tick
/// updates don't invalidate the page (see `IllustDetailView.scrollAnchor`).
private final class ScrollAnchor {
    var lastOffset: CGFloat = 0
}

/// Tracks the detail scroll view's content top so the action pill can hide on
/// scroll-down / show on scroll-up.
private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {}
}

/// Floating download + bookmark pill (Shaft V3 `fab_bar`). No full-width mask —
/// a compact capsule that floats over the content; the parent slides/fades it
/// with scroll direction.
private struct BottomActionBar: View {
    let vm: IllustDetailViewModel
    let onShowBookmarkSheet: () -> Void
    @Environment(OnboardingStore.self) private var l10n

    @State private var download: DownloadState = .idle

    enum DownloadState: Equatable {
        case idle, downloading(Double), done, failed
        var isActive: Bool { if case .downloading = self { return true }; return false }
    }

    var body: some View {
        // 1:1 with upstream `fab_bar`: 48dp capsule `#CC1A1A2E` (same in light
        // mode — the drawable isn't theme-aware), 60×40 buttons, 6dp side
        // padding, 1×24 divider `#33FFFFFF` with 2dp side margins.
        HStack(spacing: 0) {
            downloadButton
            Theme.v3FabDivider
                .frame(width: 1, height: 24)
                .padding(.horizontal, 2)
            bookmarkButton
        }
        .frame(height: 48)
        .padding(.horizontal, 6)
        .background(Theme.v3FabBar, in: .capsule)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .padding(.bottom, 10)
    }

    // MARK: Download

    private var downloadButton: some View {
        Button {
            Task { await runDownload() }
        } label: {
            Group {
                switch download {
                case .idle:
                    Image(systemName: "arrow.down.to.line").font(.title3).foregroundStyle(.white)
                case .downloading(let p):
                    ZStack {
                        ProgressRing(progress: p, lineWidth: 3, tint: .white, track: Theme.v3FabDivider)
                        Text("\(Int(p * 100))")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                    .frame(width: 24, height: 24)
                case .done:
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
                case .failed:
                    Image(systemName: "exclamationmark.triangle").font(.title3).foregroundStyle(.orange)
                }
            }
            .frame(width: 60, height: 40)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(download.isActive || vm.illust == nil)
        .accessibilityLabel(l10n.t(.downloadsTitle))
    }

    private func runDownload() async {
        guard let illust = vm.illust else { return }
        let urls = IllustPages.urls(for: illust)   // originals (fallback large)
        guard !urls.isEmpty else { return }
        guard await PhotoLibrarySaver.requestAuthorization() else { await flashFailed(); return }

        let total = Double(urls.count)
        download = .downloading(0)
        for (i, url) in urls.enumerated() {
            let data = await PixivImageCache.shared.loadData(url) { p in
                download = .downloading((Double(i) + p) / total)
            }
            guard let data else { await flashFailed(); return }
            do { try await PhotoLibrarySaver.save(data: data) } catch { await flashFailed(); return }
            download = .downloading(Double(i + 1) / total)
        }
        download = .done
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if download == .done { download = .idle }
    }

    private func flashFailed() async {
        download = .failed
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if download == .failed { download = .idle }
    }

    // MARK: Bookmark

    private var bookmarkButton: some View {
        Button {
            Task { await vm.toggleBookmark() }
        } label: {
            // Upstream `ic_favorite`: the heart is ALWAYS filled — white when
            // not bookmarked, `has_bookmarked` red when bookmarked.
            Image(systemName: "heart.fill")
                .font(.title3)
                .foregroundStyle((vm.illust?.isBookmarked == true) ? Theme.v3Bookmarked : .white)
                .frame(width: 60, height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
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
