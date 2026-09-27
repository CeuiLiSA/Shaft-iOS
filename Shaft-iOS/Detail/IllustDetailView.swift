import SwiftUI
import Translation

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

    /// Bookmark / follow display state resolved through the app-wide
    /// `InteractionStore` (override layered on the model snapshot), so this
    /// page always agrees with the waterfall cells and every other surface.
    var isBookmarked: Bool {
        interactions.isBookmarked(id: illustId, fallback: illust?.isBookmarked)
    }
    var isBookmarking: Bool { interactions.bookmarkBusy.contains(illustId) }
    var authorFollowed: Bool {
        guard let user = illust?.user else { return false }
        return interactions.isFollowed(user)
    }

    // Lazy section state. Comments / author works / related each fire their
    // request only when that section first scrolls into view (parity with V3
    // `ArtworkDetailAdapter.onViewAttachedToWindow`). `*Loaded` flips true once
    // an attempt finishes so the section can swap its spinner for content/empty.
    var commentsLoaded = false
    var relatedLoaded = false
    var authorWorksLoaded = false
    /// `ArtworkCommentsItem.loadFailedMessage` (#592): a conclusive failure is a
    /// result, not a pending state — render the message, never the spinner.
    var commentsFailedMessage: String?
    /// Cursor for the related waterfall — see `loadMoreRelated`.
    var relatedNextUrl: String?
    var isLoadingMoreRelated = false
    /// `ArtworkV3ViewModel.forceOriginalPreview` — the overflow menu's "load the
    /// original for this work", overriding the global preview-resolution setting.
    var forceOriginalPreview = false
    @ObservationIgnored private var commentsTriggered = false
    @ObservationIgnored private var relatedTriggered = false
    @ObservationIgnored private var authorWorksTriggered = false

    @ObservationIgnored private let api: PixivAPI
    @ObservationIgnored private let interactions = InteractionStore.shared

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
    }

    private func loadDetail() async {
        do {
            let resp = try await api.illustDetail(illustId)
            illust = resp.illust
            // Fresh single-item truth — sync the app-wide bookmark/follow state.
            interactions.ingest(illust: resp.illust)
        } catch {
            // Keep any seeded illust so the page still renders (issue #569 parity).
            if illust == nil { errorMessage = error.localizedDescription }
        }
    }

    /// Fired from `V3RelatedSection.onAppear` — once per page. Mirrors
    /// `ArtworkSection.RELATED`: the first page of related works is fetched only
    /// when the section scrolls into view, and it hands its cursor to the feed so
    /// scrolling on keeps paging (`adoptCursorAndMutateItems`).
    func loadRelatedIfNeeded() async {
        guard !relatedTriggered else { return }
        relatedTriggered = true
        let resp = try? await api.relatedIllusts(illustId)
        related = resp?.illusts ?? []
        relatedNextUrl = resp?.nextUrl
        relatedLoaded = true
    }

    /// `ArtworkV3FeedSource.load(cursor)` — page 2+ of the related waterfall.
    func loadMoreRelated() async {
        guard let url = relatedNextUrl, !isLoadingMoreRelated else { return }
        isLoadingMoreRelated = true
        defer { isLoadingMoreRelated = false }
        guard let resp: IllustResponse = try? await api.nextPage(url) else {
            relatedNextUrl = nil
            return
        }
        let known = Set(related.map(\.id))
        related.append(contentsOf: resp.illusts.filter { !known.contains($0.id) })
        relatedNextUrl = resp.nextUrl
    }

    /// Fired from `V3CommentsSection.onAppear` — once per page. Upstream shows
    /// the first three (`fetchArtworkComments` … `.take(3)`), and renders a
    /// human-readable message instead of a spinner when the endpoint answers a
    /// permanent 404 for app-api-blocked works (#592).
    func loadCommentsIfNeeded() async {
        guard !commentsTriggered else { return }
        commentsTriggered = true
        do {
            let resp = try await api.illustComments(illustId)
            // Locally-posted comments stay in front, de-duped by id — upstream
            // `ArtworkCommentsItem.withComments`.
            let known = Set(comments.map(\.id))
            comments += resp.comments.prefix(3).filter { !known.contains($0.id) }
            totalComments = resp.totalComments
            commentsFailedMessage = nil
        } catch {
            commentsFailedMessage = error.localizedDescription
        }
        commentsLoaded = true
    }

    /// Post a top-level comment from the detail page's inline composer, then
    /// splice the server's echo (or a local stand-in) into the preview.
    func postComment(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard (try? await api.postIllustComment(illustId, comment: trimmed)) != nil else { return false }
        // app-api's POST answers with the created comment under `comment`, but
        // the shared client models it as `EmptyResponse`; re-reading page 1 is
        // both cheap and authoritative.
        if let resp = try? await api.illustComments(illustId) {
            comments = Array(resp.comments.prefix(3))
            totalComments = resp.totalComments
            commentsLoaded = true
        }
        return true
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

    /// Flip the artist's follow state through the app-wide store (optimistic,
    /// store reverts on failure). Long-press on the button follows privately.
    func toggleFollow(restrict: String? = nil) async {
        guard let user = illust?.user else { return }
        try? await interactions.toggleFollow(user, restrict: restrict)
    }

    func toggleBookmark(restrict: String? = nil) async {
        guard let cur = illust else { return }
        do {
            try await interactions.toggleBookmark(cur, restrict: restrict)
        } catch {
            BookmarkHaptics.failed()
            errorMessage = error.localizedDescription
        }
    }

    /// Existing bookmark state (registered tags + visibility) for pre-filling
    /// the bookmark sheet. Nil when the work isn't bookmarked yet.
    func bookmarkDetail() async -> (restrict: String, tags: [String])? {
        guard isBookmarked else { return nil }
        guard let d = try? await api.illustBookmarkDetail(illustId).bookmarkDetail else { return nil }
        return (d.restrict ?? "public", d.registeredTags)
    }

    /// Bookmark with explicit restrict + tags. Re-applies if already bookmarked
    /// (Pixiv replaces the bookmark with the new tag/restrict set).
    func bookmark(restrict: String, tags: [String]) async {
        do {
            try await interactions.bookmark(illustId: illustId, restrict: restrict, tags: tags)
        } catch {
            errorMessage = error.localizedDescription
        }
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
    @State private var showComicReader = false
    @State private var showBookmarkSheet = false
    @State private var showReport = false
    @State private var showMenu = false
    @State private var showMuteSettings = false
    @State private var showComposer = false
    @State private var translateText: String?
    @State private var showTranslate = false
    @State private var shareItem: ShareTarget?
    @State private var descExpanded = false
    @State private var mute = MuteStore.shared
    @State private var actionBarVisible = true
    @State private var toolbarTitleVisible = false
    /// Plain class box, deliberately NOT observable state: the anchor advances
    /// every ~8pt of scroll, and an `@State` write there re-evaluates the whole
    /// page body per scroll tick. Boxed, only the rare `actionBarVisible` flip
    /// invalidates the view.
    @State private var scrollAnchor = ScrollAnchor()
    /// 设置「多图自动展开」(#1090) 打开时进页即展开态：折叠态从一开始就不存在，
    /// 没有「展开剩余 X 张」覆盖层；右上角「收起」胶囊直接出现（无入场动效）。
    @State private var pagesExpanded = AppSettingsStore.shared.artworkV3AutoExpandMultiPage
    /// `ArtworkV3Fragment.detailPanelExpanded` — seeded from the setting (#1044),
    /// then owned by the page so scrolling away and back doesn't reset it.
    @State private var detailPanelExpanded = !AppSettingsStore.shared.detailPanelCollapsedByDefault
    /// Links each page image to the full-screen viewer for the system zoom
    /// transition (zoom in on open; interactive pull-down zooms back out).
    @Namespace private var viewerZoom
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss

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

    /// Stable id of the scroll-content top anchor — the floating "收起" pill
    /// snaps here on collapse (see `body`).
    private static let pagesTopID = "pagesTop"

    /// Anchor for the comment-jump FAB (#970) — `scrollToCommentsSection`.
    private static let commentsSectionID = "commentsSection"

    /// Whether the current work has enough pages to collapse — gates the floating
    /// "收起" pill, mirroring `content(for:)`'s `collapsible`.
    private var pagesAreCollapsible: Bool {
        guard let illust = vm.illust else { return false }
        return IllustPages.pages(for: illust).count > collapsePagesThreshold
    }

    /// Hide the action pill on scroll-down, reveal on scroll-up (Shaft V3
    /// behavior). `offset` is the content's top relative to the scroll view — it
    /// decreases as the user scrolls down. The anchor only advances past an 8pt
    /// threshold so slow scrolls still accumulate to a direction.
    private func handleScroll(_ offset: CGFloat) {
        setToolbarTitle(visible: offset < -240)
        if offset > -10 { setActionBar(visible: true); scrollAnchor.lastOffset = offset; return }
        let delta = offset - scrollAnchor.lastOffset
        if delta <= -8 { setActionBar(visible: false); scrollAnchor.lastOffset = offset }
        else if delta >= 8 { setActionBar(visible: true); scrollAnchor.lastOffset = offset }
    }

    private func setActionBar(visible: Bool) {
        guard actionBarVisible != visible else { return }
        withAnimation(.easeOut(duration: 0.2)) { actionBarVisible = visible }
    }

    /// Upstream `toolbar_title` (Montserrat Bold 18): invisible while the hero
    /// is on screen, fades in once the page has scrolled past it.
    private func setToolbarTitle(visible: Bool) {
        guard toolbarTitleVisible != visible else { return }
        withAnimation(.easeOut(duration: 0.2)) { toolbarTitleVisible = visible }
    }

    /// Rows of the V3 overflow menu — 1:1 with `ArtworkV3Fragment.showMoreMenu`
    /// (order, labels and actions), rendered by `V3MenuDialog`.
    ///
    /// Deviation: upstream's last three rows (AI upscale ×2 / "share to plaza")
    /// have no iOS counterpart — the first two run a bundled ncnn model, the
    /// third is behind `Dev.showPlazaShareInArtwork` and the plaza isn't ported.
    private var menuRows: [V3MenuRow] {
        guard let illust = vm.illust else { return [] }
        var rows: [V3MenuRow] = [
            V3MenuRow(title: l10n.t(.actionShare), icon: "square.and.arrow.up") {
                shareItem = ShareTarget(url: pixivURL)
            },
            V3MenuRow(title: l10n.t(.artworkV3ShareFirstImage), icon: "square.and.arrow.up") {
                Task { await shareFirstImage(illust) }
            },
            V3MenuRow(title: l10n.t(.artworkV3CopyWorkLink), icon: "arrow.up.forward.app") {
                UIPasteboard.general.string = pixivURL.absoluteString
            },
            V3MenuRow(title: l10n.t(.artworkV3MuteSettings), icon: "gearshape") {
                showMuteSettings = true
            },
            V3MenuRow(title: l10n.t(.artworkV3MuteThisWork), icon: "eye.slash") {
                mute.setIllustMuted(illustId, true)
            },
            V3MenuRow(title: l10n.t(.artworkV3FlagPost), icon: "flag") {
                showReport = true
            },
        ]
        if illust.type != "ugoira" {
            rows.append(V3MenuRow(title: l10n.t(.artworkV3LoadOriginal), icon: "eye") {
                vm.forceOriginalPreview = true
            })
        }
        return rows
    }

    /// Floating top bar that replaces the hidden navigation bar (see body): back
    /// and overflow controls as glass capsules over the edge-to-edge hero, with
    /// the title fading in (centered) once the hero scrolls away.
    private var detailTopBar: some View {
        ZStack {
            Text(vm.illust?.title ?? "")
                .font(.montserratBold(18))
                .foregroundStyle(Theme.v3Text1)
                .lineLimit(1)
                .padding(.horizontal, 56)
                .opacity(toolbarTitleVisible ? 1 : 0)
            HStack {
                Button { dismiss() } label: {
                    DetailGlassCircle(system: "chevron.backward")
                }
                .buttonStyle(.plain)
                Spacer()
                // Upstream `nav_more` opens a centered `V3MenuDialog`, not a
                // system menu — see the overlay on `body`.
                Button { showMenu = true } label: {
                    DetailGlassCircle(system: "ellipsis")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Scroll-edge bar background, matching the iOS Settings nav bar exactly:
        // absent on entry while the hero is immersive, then a uniform bar-material
        // band with a hairline separator fades in together with the title once the
        // page scrolls past the hero. No gradient — a crisp, system-style edge.
        .background(alignment: .top) {
            Rectangle()
                .fill(.bar)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color(uiColor: .separator))
                        .frame(height: 1 / UIScreen.main.scale)
                }
                .ignoresSafeArea(edges: .top)
                .opacity(toolbarTitleVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: toolbarTitleVisible)
                .allowsHitTesting(false)
        }
    }

    var body: some View {
        GeometryReader { geo in
            // 平板（设备最小边 ≥ 600）且窗口够宽：作品舞台 + 信息栏的新排版（#1087）；
            // 分屏 / 台前调度窄窗口回到手机排版。
            if AdaptiveStaggerColumns.isTablet, geo.size.width >= 600, let illust = vm.illust {
                tabletBody(illust: illust, size: CGSize(
                    width: geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing,
                    height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
                ))
            } else {
                phoneBody
            }
        }
        .modifier(detailPresentations)
    }

    // MARK: Tablet (ArtworkTabletStage, #1087)

    /// Window wider than tall: stage leading, info column trailing (36 % of the
    /// window, clamped 400–520pt, never more than half). Otherwise the stage
    /// takes the top 52 % and the info column sits below. The column is the page
    /// colour at 92 % over the blurred ambient artwork, rounded 28pt on the side
    /// facing the stage; its sections and actions are the phone ones.
    @ViewBuilder
    private func tabletBody(illust: Illust, size: CGSize) -> some View {
        let sideBySide = size.width > size.height
        let infoWidth = min(max(size.width * 0.36, 400), 520, size.width / 2)
        let stage = ArtworkTabletStage(
            illust: illust,
            pages: IllustPages.pages(for: illust),
            forceOriginal: vm.forceOriginalPreview,
            sideBySide: sideBySide,
            onBack: { dismiss() },
            onMore: { showMenu = true },
            onOpenReader: { showComicReader = true },
            onOpenViewer: { index in viewerIndex = index; showViewer = true }
        )
        ZStack {
            ArtworkTabletBackdrop(url: illust.imageUrls?.squareMedium.flatMap(URL.init(string:)))
            if sideBySide {
                HStack(spacing: 0) {
                    stage
                    tabletInfoColumn(illust: illust, panel: UnevenRoundedRectangle(
                        topLeadingRadius: 28, bottomLeadingRadius: 28, style: .continuous))
                        .frame(width: infoWidth)
                }
            } else {
                VStack(spacing: 0) {
                    stage.frame(height: size.height * 0.52)
                    tabletInfoColumn(illust: illust, panel: UnevenRoundedRectangle(
                        topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous))
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .overlay {
            if isMuted(illust) {
                MuteMaskOverlay(
                    illust: illust,
                    illustMuted: mute.isIllustMuted(illustId),
                    userMuted: illust.user.map { mute.isUserMuted($0.id) } ?? false,
                    onUnmuteIllust: { mute.setIllustMuted(illustId, false) },
                    onUnmuteUser: { if let u = illust.user { mute.toggleUser(u.id) } },
                    onLeave: { dismiss() }
                )
                .transition(.opacity)
            }
        }
    }

    private func tabletInfoColumn<S: Shape>(illust: Illust, panel: S) -> some View {
        ScrollViewReader { scrollProxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        infoSections(for: illust)
                    }
                    .padding(.top, 8)
                }
                BottomActionBar(
                    vm: vm,
                    onShowBookmarkSheet: { showBookmarkSheet = true },
                    onJumpToComments: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            scrollProxy.scrollTo(Self.commentsSectionID, anchor: .top)
                        }
                    }
                )
            }
        }
        // The panel runs edge to edge (under the status bar / home indicator);
        // the scroll content keeps its own safe-area inset.
        .background(panel.fill(Theme.v3Bg.opacity(0.92)).ignoresSafeArea(edges: [.top, .bottom]))
    }

    // MARK: Phone

    private var phoneBody: some View {
        ScrollViewReader { scrollProxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Top anchor — the floating "收起" pill snaps here on
                        // collapse (parity with `scrollToPositionWithOffset(0, 0)`)
                        // so the user isn't stranded in the space the removed
                        // pages leave behind.
                        Color.clear.frame(height: 0).id(Self.pagesTopID)
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
                BottomActionBar(
                    vm: vm,
                    onShowBookmarkSheet: { showBookmarkSheet = true },
                    onJumpToComments: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            scrollProxy.scrollTo(Self.commentsSectionID, anchor: .top)
                        }
                    }
                )
                .offset(y: actionBarVisible ? 0 : 180)
                .opacity(actionBarVisible ? 1 : 0)
            }
            // iOS 26 Liquid Glass paints a scroll-edge material on the navigation bar
            // that no toolbar-background modifier can clear, leaving a dark band over
            // the edge-to-edge hero. The bar is hidden entirely and its controls are
            // re-drawn as floating glass capsules (see detailTopBar) instead.
            .toolbar(.hidden, for: .navigationBar)
            // The toolbar row, plus the floating "收起" pill hanging below its
            // trailing edge while a collapsible multi-page work is expanded
            // (parity with `fragment_artwork_v3.xml` collapse_pill, gravity top|end).
            .overlay(alignment: .top) {
                VStack(alignment: .trailing, spacing: 8) {
                    detailTopBar
                    if pagesAreCollapsible && pagesExpanded {
                        FloatingCollapsePill {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                scrollProxy.scrollTo(Self.pagesTopID, anchor: .top)
                                pagesExpanded = false
                            }
                        }
                        .padding(.trailing, 12)
                        .transition(.opacity)
                    }
                }
            }
            // `abandoned_frame` is declared last in the Android FrameLayout, so
            // it covers the toolbar and the floating pill too — the mask must be
            // the topmost overlay here for the same reason (#983). Upstream
            // additionally hides the FAB bar because its 12dp elevation would
            // otherwise keep it clickable under the mask; a SwiftUI overlay with
            // a content shape already swallows the taps.
            .overlay {
                if let illust = vm.illust, isMuted(illust) {
                    MuteMaskOverlay(
                        illust: illust,
                        illustMuted: mute.isIllustMuted(illustId),
                        userMuted: illust.user.map { mute.isUserMuted($0.id) } ?? false,
                        onUnmuteIllust: { mute.setIllustMuted(illustId, false) },
                        onUnmuteUser: { if let u = illust.user { mute.toggleUser(u.id) } },
                        onLeave: { dismiss() }
                    )
                    .transition(.opacity)
                }
            }
        }
    }

    /// Loading, presentations and dialogs shared by the phone and tablet layouts.
    private var detailPresentations: DetailPresentations { DetailPresentations(host: self) }

    fileprivate func presentations<V: View>(_ content: V) -> some View {
        content
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
                            index: $viewerIndex,
                            ugoiraIllustId: vm.illust?.type == "ugoira" ? vm.illust?.id : nil)
                .navigationTransition(.zoom(sourceID: viewerIndex, in: viewerZoom))
        }
        .fullScreenCover(isPresented: $showComicReader) {
            if let illust = vm.illust {
                ComicReaderView(illust: illust)
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
        .sheet(isPresented: $showReport) {
            ReportIllustView(illustId: illustId)
        }
        // `MuteTagSheet.show(childFragmentManager, illust.tags, illust.user)`
        .sheet(isPresented: $showMuteSettings) {
            if let illust = vm.illust {
                MuteTargetsSheet(tags: illust.tags ?? [], user: illust.user)
            }
        }
        // The inline composer (`CommentComposerController`, ON_DEMAND_OVERLAY):
        // there's no persistent input bar, tapping "留下你的评论吧" raises one.
        .sheet(isPresented: $showComposer) {
            CommentComposerSheet { text in await vm.postComment(text) }
        }
        // `translateTitleAndCaption` / `translateComment` — upstream runs its own
        // translator (custom AI, else Google) and shows the result in a WitDialog.
        // Deviation: iOS has no bundled translator, so the same text goes to the
        // system translation sheet, which is the platform-native equivalent.
        .translationPresentation(isPresented: $showTranslate, text: translateText ?? "")
        // `V3MenuDialog`: a centered 78 %-width card, not a system menu.
        .v3MenuDialog(isPresented: $showMenu, rows: menuRows)
        .sheet(item: $shareItem) { target in
            V3ShareSheet(items: target.items)
        }
    }

    /// `translateTitleAndCaption` — title and caption joined the same way
    /// upstream joins them ("标题：… \n\n 简介：…") before handing them over.
    private func translate(title: String?, caption: String?) {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let c = (caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if !t.isEmpty { parts.append(l10n.t(.artworkV3TitleLabel) + t) }
        if !c.isEmpty { parts.append(l10n.t(.artworkV3CaptionLabel) + c) }
        guard !parts.isEmpty else { return }
        translateText = parts.joined(separator: "\n\n")
        showTranslate = true
    }

    /// `ShareIllust`'s "分享首图": hand the first page's bytes to the share sheet
    /// rather than the URL.
    private func shareFirstImage(_ illust: Illust) async {
        guard let url = IllustPages.pages(for: illust).first?.original
                ?? IllustPages.pages(for: illust).first?.large else { return }
        guard let data = await PixivImageCache.shared.loadData(url, onProgress: { _ in }),
              let image = UIImage(data: data) else { return }
        shareItem = ShareTarget(image: image)
    }

    /// Whether the whole-page mute mask applies — upstream watches the Room rows
    /// for this work and its artist (`attachMuteObserver`).
    private func isMuted(_ illust: Illust) -> Bool {
        if mute.isIllustMuted(illustId) { return true }
        if let u = illust.user, mute.isUserMuted(u.id) { return true }
        return false
    }

    @ViewBuilder
    private func content(for illust: Illust) -> some View {
        // Pages are emitted as direct LazyVStack children (not wrapped in an
        // opaque sub-VStack) so an expanded multi-page work materializes its
        // originals lazily as they scroll into view.
        let pages = IllustPages.pages(for: illust)
        let collapsible = pages.count > collapsePagesThreshold
        let collapsed = collapsible && !pagesExpanded
        // `IllustAdapter.onBindViewHolder` (#961): a 2-page **manga** opens the
        // reader on tap; a 2-page illustration must NOT — only the type check
        // keeps those out of the reader. 3P+ works keep the plain tap and get
        // the reader via the pill in the first page's overlay instead.
        let tapOpensReader = illust.type == "manga" && pages.count > 1 && !collapsible

        IllustFirstPage(
            illust: illust,
            pages: pages,
            collapsed: collapsed,
            forceOriginal: vm.forceOriginalPreview,
            onTap: {
                if tapOpensReader { showComicReader = true }
                else { viewerIndex = 0; showViewer = true }
            },
            onExpand: { withAnimation(.easeInOut(duration: 0.25)) { pagesExpanded = true } },
            onOpenReader: { showComicReader = true }
        )
        .matchedTransitionSource(id: 0, in: viewerZoom)

        if !collapsed {
            ForEach(Array(pages.enumerated()).dropFirst(), id: \.offset) { idx, page in
                StackedPage(urls: page, forceOriginal: vm.forceOriginalPreview) {
                    if tapOpensReader { showComicReader = true }
                    else { viewerIndex = idx; showViewer = true }
                }
                .matchedTransitionSource(id: idx, in: viewerZoom)
            }
            // Collapse is driven by the floating "收起" pill pinned below the
            // toolbar (see `body`), not an in-list button — 1:1 with V3.
        }

        infoSections(for: illust)
    }

    /// Everything below the pages. On a tablet (#1087) this is the whole info
    /// column; the artwork itself lives in `ArtworkTabletStage`.
    @ViewBuilder
    private func infoSections(for illust: Illust) -> some View {
        // Order below is `ArtworkV3FeedSource.buildArtworkHeaderItems`:
        // hero / (series) / artist / (desc) / tags / stats / detail panel /
        // comments / author works / related header + related waterfall.
        V3HeroSection(
            illust: illust,
            // `ArtworkHeroItem.showTranslate`: the stand-in translate button only
            // appears when the work has no caption block of its own.
            showTranslate: vm.captionPlain.isEmpty,
            onTranslate: { translate(title: illust.title, caption: nil) }
        )

        if let series = illust.series, let title = series.title, !title.isEmpty, series.id != nil {
            V3SeriesStrip(series: series)
        }

        V3ArtistCard(vm: vm)

        if !vm.captionPlain.isEmpty {
            V3CaptionSection(
                html: illust.caption ?? "",
                plain: vm.captionPlain,
                expanded: $descExpanded,
                onTranslate: { translate(title: illust.title, caption: vm.captionPlain) }
            )
        }

        // Upstream emits the tag block unconditionally (it is the stable anchor
        // the late-arriving caption is inserted before).
        V3TagsSection(tags: illust.tags ?? [], previewURL: illust.imageUrls?.squareMedium,
                      authorId: illust.user?.id, isManga: illust.type == "manga")

        V3StatsCard(illust: illust)

        V3DetailPanel(illust: illust, expanded: $detailPanelExpanded)

        V3CommentsSection(
            vm: vm,
            illustId: illustId,
            illustAuthorId: illust.user?.id ?? 0,
            onCompose: { showComposer = true },
            onTranslate: { text in translateText = text; showTranslate = true }
        )
        .id(Self.commentsSectionID)

        V3AuthorWorksSection(vm: vm, user: illust.user)

        V3RelatedSection(vm: vm, illustId: illustId)

        Color.clear.frame(height: 96) // clearance for the floating action pill
    }
}

private struct DetailPresentations: ViewModifier {
    let host: IllustDetailView
    func body(content: Content) -> some View { host.presentations(content) }
}

// MARK: - Pages (collapsible, stretchy first page; rest emitted lazily by content(for:))

/// Works with more than this many pages collapse to the first page behind an
/// "expand" pill so tags / comments / related are reachable without a long
/// scroll. `> 2` (i.e. 3+ pages) matches `CollapsibleIllustAdapter.shouldCollapse`.
private let collapsePagesThreshold = 2

private struct IllustFirstPage: View {
    let illust: Illust
    let pages: [IllustPageURLs]
    let collapsed: Bool
    let forceOriginal: Bool
    var onTap: () -> Void
    var onExpand: () -> Void
    var onOpenReader: () -> Void

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
                StretchyFirstPage(urls: first, aspect: firstAspect,
                                  forceOriginal: forceOriginal, onTap: onTap)
                .overlay(alignment: .bottom) {
                    if collapsed {
                        FirstPageOverlay(
                            remaining: pages.count - 1,
                            isManga: illust.type == "manga",
                            onExpand: onExpand,
                            onOpenReader: onOpenReader
                        )
                    }
                }
            }
            // `recy_illust_detail`'s `page_divider`: a hairline under every page
            // so stacked full-bleed images read as separate pages.
            Rectangle().fill(Theme.v3PageDivider).frame(height: 1 / UIScreen.main.scale)
        }
    }
}

/// First page with the classic iOS stretchy-header effect: pulling the scroll
/// view past its top enlarges the image (filling the revealed gap and zooming).
private struct StretchyFirstPage: View {
    let urls: IllustPageURLs
    let aspect: CGFloat
    var forceOriginal: Bool = false
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
            // `forceOriginal` re-keys the task so the menu's "load original for
            // this work" re-runs the loader (upstream rebuilds the page adapter).
            .task(id: TaskKey(url: urls.original, forceOriginal: forceOriginal)) {
                await loader.run(large: urls.large, original: urls.original,
                                 pixelWidth: Int(proxy.size.width * UIScreen.main.scale),
                                 skipLarge: forceOriginal)
            }
        }
        .frame(height: baseHeight)
    }
}

/// Re-keys a page's load when the user opts into originals mid-page.
private struct TaskKey: Equatable {
    let url: URL?
    let forceOriginal: Bool
}

/// A non-first page in the vertical stack — laid out at the image's natural
/// aspect (Pixiv `meta_pages` carry no per-page dimensions, so the height
/// settles once the image loads).
///
/// Deviation: upstream backfills exact per-page dimensions from the web ajax
/// endpoint (`ArtworkV3ViewModel.pageDimensions`), which needs pixiv web
/// cookies the iOS app never holds; the height settles on decode instead.
private struct StackedPage: View {
    let urls: IllustPageURLs
    var forceOriginal: Bool = false
    var onTap: () -> Void

    @State private var loader = HeroImageLoader()

    var body: some View {
        VStack(spacing: 0) {
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
            .task(id: TaskKey(url: urls.original, forceOriginal: forceOriginal)) {
                // Stacked pages span the full screen width (no geometry reader here).
                await loader.run(large: urls.large, original: urls.original,
                                 pixelWidth: Int(UIScreen.main.bounds.width * UIScreen.main.scale),
                                 skipLarge: forceOriginal)
            }
            Rectangle().fill(Theme.v3PageDivider).frame(height: 1 / UIScreen.main.scale)
        }
    }
}

/// `recy_illust_detail`'s `expand_overlay`, shown on page 0 while a 3P+ work is
/// collapsed: an 88dp bottom scrim (`bg_v3_first_page_scrim`, #CC000000 →
/// #55000000 → transparent, bottom-up) carrying two glass pills — "展开剩余 N 张"
/// and the reader entry ("阅读漫画" for manga, "用阅读器看" for illustrations,
/// #1029). Both use `bg_v3_expand_pill`: #B3111116, r=999, 1dp #33FFFFFF.
private struct FirstPageOverlay: View {
    let remaining: Int
    let isManga: Bool
    var onExpand: () -> Void
    var onOpenReader: () -> Void
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(1 / 3), location: 0.5),
                    .init(color: .black.opacity(0.8), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 88)
            .allowsHitTesting(false)

            HStack(spacing: 8) {
                ExpandOverlayPill(
                    system: "square.stack",
                    title: l10n.t(.artworkV3ExpandAllPagesFmt, "\(remaining)"),
                    action: onExpand
                )
                ExpandOverlayPill(
                    system: "book",
                    title: isManga ? l10n.t(.crEnter) : l10n.t(.artworkV3ReaderEnterIllust),
                    action: onOpenReader
                )
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
    }
}

private struct ExpandOverlayPill: View {
    let system: String
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: system).font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .tracking(0.26)   // letterSpacing 0.02 × 13sp
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(.white)
            .padding(.leading, 16)
            .padding(.trailing, 18)
            .padding(.vertical, 9)
            .background(Color(red: 17 / 255, green: 17 / 255, blue: 22 / 255).opacity(0.70), in: .capsule)
            .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(PressablePillStyle())
    }
}

/// `CollapsibleIllustAdapter.applyPillTouchFeedback` — 0.94 scale while held.
private struct PressablePillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Floating "收起" pill — Shaft V3 `collapse_pill` (`fragment_artwork_v3.xml`):
/// a glass capsule pinned below the toolbar's trailing edge, shown only while a
/// collapsible multi-page work is expanded. `#B3111116` fill, `#33FFFFFF`
/// hairline, up-chevron + 收起 in white 12sp bold; 12/14/7 padding (start/end/y).
private struct FloatingCollapsePill: View {
    var onTap: () -> Void
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .bold))
                // `v3_collapse_pages_title` is the same source string as
                // `v3_desc_collapse` in every locale upstream ships.
                Text(l10n.t(.artworkV3DescCollapse))
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.24)   // letterSpacing 0.02 × 12sp
            }
            .foregroundStyle(.white)
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .padding(.vertical, 7)
            .background(Color(red: 17 / 255, green: 17 / 255, blue: 22 / 255).opacity(0.70), in: .capsule)
            .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)   // elevation 8dp
        }
        .buttonStyle(.plain)
    }
}

// MARK: - V3 sections

/// `section_v3_hero.xml` — title (23sp bold, letterSpacing −0.03) over the meta
/// row `type · EXT · date · pages`, with the stand-in translate button on the
/// right when the work carries no caption block.
private struct V3HeroSection: View {
    let illust: Illust
    let showTranslate: Bool
    var onTranslate: () -> Void
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(illust.title ?? "")
                .font(.system(size: 23, weight: .bold))
                .tracking(-0.69)          // letterSpacing −0.03 em × 23sp
                .foregroundStyle(Theme.v3Text1)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(23 * 0.2)    // lineSpacingMultiplier 1.2
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = illust.title ?? ""
                    } label: { Label(l10n.t(.actionCopyLink), systemImage: "doc.on.doc") }
                }

            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text(typeLabel)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.v3Text2)
                    if let ext = pageExtension {
                        dot
                        Text(ext)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.v3Text2)
                    }
                    dot
                    Text(V3Date.dateTime(illust.createDate))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.v3Text3)
                    dot
                    Text(pagesLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.v3Text3)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

                if showTranslate {
                    Button(action: onTranslate) {
                        Image(systemName: "translate")
                            .resizable().scaledToFit().frame(width: 25, height: 25)
                            .foregroundStyle(Theme.v3Text3)
                            .frame(width: 25, height: 25)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(l10n.t(.artworkV3Translate))
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    /// `v3_nav_btn_bg` 3dp dot with 8dp on each side — the meta separators.
    private var dot: some View {
        Circle()
            .fill(Theme.v3NavBtnBg)
            .frame(width: 3, height: 3)
            .padding(.horizontal, 8)
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

    /// `page0Extension` — the uppercase file extension of page 0's original URL.
    private var pageExtension: String? {
        guard let url = IllustPages.pages(for: illust).first?.original?.absoluteString else { return nil }
        let clean = url.split(separator: "?").first.map(String.init)?
            .split(separator: "#").first.map(String.init) ?? url
        guard let dot = clean.lastIndex(of: "."), dot < clean.index(before: clean.endIndex) else { return nil }
        let ext = String(clean[clean.index(after: dot)...])
        guard ext.count <= 5, !ext.contains("/") else { return nil }
        return ext.uppercased()
    }
}

/// `section_v3_series.xml` + `V3Palette.seriesStripBg` / `seriesIconBg`: the
/// strip fill is the theme color at 35 % → hue+25° at 30 % (r=20, 15 % hairline),
/// the icon square is the solid theme color → hue+40° (r=10).
private struct V3SeriesStrip: View {
    let series: IllustSeriesRef
    @Environment(OnboardingStore.self) private var l10n

    private static let stripGradient = LinearGradient(
        colors: [Theme.brand.opacity(0.35), Theme.brand.hueShifted(25).opacity(0.30)],
        startPoint: .bottomLeading, endPoint: .topTrailing
    )
    private static let iconGradient = LinearGradient(
        colors: [Theme.brand, Theme.brand.hueShifted(40)],
        startPoint: .bottomLeading, endPoint: .topTrailing
    )

    var body: some View {
        NavigationLink(value: AppRoute.illustSeries(seriesId: series.id ?? 0)) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Self.iconGradient)
                    Image(systemName: "square.stack").font(.system(size: 16)).foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text(l10n.t(.detailSeriesLabel).uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.9)                       // letterSpacing 0.1 × 9sp
                        .foregroundStyle(Theme.v3SeriesStripText)
                        .opacity(0.7)
                    Text(series.title ?? "")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.v3SeriesStripText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("›")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.v3SeriesStripText)
            }
            .padding(12)
            .background(Self.stripGradient, in: .rect(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.brand.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(PressableCardStyle())
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
    }
}

/// `section_v3_artist.xml` — glass XL card (r=28), 58dp avatar with a 1.5dp
/// theme-colored ring, name/handle stack, the follow pill, and the 2-line bio.
private struct V3ArtistCard: View {
    let vm: IllustDetailViewModel
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        if let user = vm.illust?.user {
            // The whole glass card opens the artist page (1:1 with upstream's
            // `b.artistCard.setOnClickListener(openUser)`) — not just the name.
            // The follow pill is lifted into an overlay so it keeps its own tap
            // (and long-press → private) instead of triggering the navigation; a
            // hidden copy inside the link reserves its exact footprint so the
            // name truncates rather than running under it.
            NavigationLink(value: AppRoute.userProfile(user.id)) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        PixivAsyncImage(url: avatarURL(for: user), showsProgress: false)
                            .frame(width: 58, height: 58)
                            .clipShape(.circle)
                            .overlay(Circle().strokeBorder(Theme.brand, lineWidth: 1.5))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(user.name ?? "")
                                .font(.montserratBold(16))
                                .tracking(-0.16)      // letterSpacing −0.01 × 16sp
                                .foregroundStyle(Theme.v3Text1)
                                .lineLimit(1)
                            Text("@\(user.account ?? "")")
                                .font(.montserratMedium(11))
                                .foregroundStyle(Theme.v3Text3)
                        }
                        Spacer(minLength: 8)
                        FollowButton(followed: vm.authorFollowed, onTap: {}, onLongPress: {})
                            .hidden()
                    }
                    // `artist_bio`: 2 lines, 12sp, `v3_text_2`, 1.65 line spacing.
                    if let bio = user.comment, !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(V3Caption.plain(bio))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.v3Text2)
                            .lineSpacing(12 * 0.65)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 14)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .v3Glass(corner: 28)
                .contentShape(.rect(cornerRadius: 28))
            }
            .buttonStyle(PressableCardStyle())
            .overlay(alignment: .topTrailing) {
                FollowButton(followed: vm.authorFollowed) {
                    Task { await vm.toggleFollow() }
                } onLongPress: {
                    Task { await vm.toggleFollow(restrict: "private") }
                }
                .padding(.trailing, 12)
                .padding(.top, 31)   // 18dp card padding + (58 − 32) / 2 avatar centering
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 18)
        }
    }

    private func avatarURL(for user: PixivUser) -> URL? {
        (user.profileImageUrls?.medium ?? user.profileImageUrls?.px170x170)
            .flatMap(URL.init(string:))
    }
}

/// `V3Palette.applyFollowBtn` / `applyUnfollowBtn`: solid theme fill + white
/// label when not following; 20 % fill with a 30 % hairline and the muted
/// `textSecondary` label once followed. 32dp tall, 20dp side padding.
private struct FollowButton: View {
    let followed: Bool
    var onTap: () -> Void
    var onLongPress: () -> Void
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        Button(action: onTap) {
            Text(followed ? l10n.t(.detailUnfollow) : l10n.t(.detailFollow))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(followed ? AnyShapeStyle(Theme.v3TextSecondary) : AnyShapeStyle(Color.white))
                .padding(.horizontal, 20)
                .frame(height: 32)
                .background {
                    if followed {
                        Capsule().fill(Theme.brand.opacity(0.20))
                            .overlay(Capsule().strokeBorder(Theme.brand.opacity(0.30), lineWidth: 1))
                    } else {
                        Capsule().fill(Theme.brand)
                    }
                }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture().onEnded { _ in if !followed { onLongPress() } })
    }
}

/// Press feedback for whole-card tap targets (e.g. the artist card) — mirrors
/// upstream's `applyTouchScale`: a subtle scale + dim while held.
private struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // `applyTouchScale`: scale only, 200 ms, no dimming.
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
}

/// `section_v3_description.xml` — "简介" label + translate button, the caption
/// body (14sp, `v3_text_1` at 78 %, 1.65 line spacing, links in `v3_blue`), and
/// the 5-line collapse toggle from #965.
private struct V3CaptionSection: View {
    let html: String
    let plain: String
    @Binding var expanded: Bool
    var onTranslate: () -> Void
    @Environment(OnboardingStore.self) private var l10n

    /// #965: fold anything past this many lines. The issue suggested 3–5; the
    /// upper bound was taken.
    private static let collapsedLines = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                V3Label(l10n.t(.artworkV3DescLabel))
                Spacer(minLength: 0)
                Button(action: onTranslate) {
                    Image(systemName: "translate")
                        .resizable().scaledToFit().frame(width: 24, height: 24)
                        .foregroundStyle(Theme.v3Text3)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(l10n.t(.artworkV3Translate))
            }
            .frame(height: 48)          // the translate button's 48dp touch target
            .padding(.bottom, 10)       // header marginBottom

            Text(V3Caption.attributed(html, plain: plain))
                .font(.system(size: 14))
                .foregroundStyle(Theme.v3Text1.opacity(0.78))
                .tint(Theme.v3Blue)                 // textColorLink = v3_blue
                .lineSpacing(14 * 0.65)             // lineSpacingMultiplier 1.65
                .lineLimit(expanded ? nil : Self.collapsedLines)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            // Upstream only shows the toggle once the layout reports an overflow;
            // SwiftUI has no equivalent pre-draw hook, so it appears whenever the
            // caption is long enough to plausibly wrap past five lines.
            if plain.count > 120 || plain.contains("\n") {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Text(expanded ? l10n.t(.artworkV3DescCollapse) : l10n.t(.artworkV3DescExpand))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.v3Blue)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 18)
    }
}

/// `section_v3_tags.xml` + `V3TagFlowView`: one chip per tag reading
/// `# name  translation` in `V3Palette.textTag`, on the 8 %-fill / 15 %-hairline
/// capsule, 13sp, 14×7 padding, 8dp gaps.
private struct V3TagsSection: View {
    let tags: [Tag]
    /// Square thumb of the host work, stored as the pin preview (mirrors
    /// upstream `buildPinnedTagPreviewJson`) when a tag is pinned via long-press.
    var previewURL: String?
    /// Author of the host work (#1102): the tag menu offers that author's works
    /// under the tag. Taken from the work itself — no tag stats are fetched on
    /// entry or when the menu opens.
    var authorId: Int64?
    var isManga = false
    @State private var pinned = PinnedTagsStore.shared
    @State private var legibility = TagLegibility.shared
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.pushRoute) private var pushRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            V3Label(l10n.t(.detailTagsLabel))
            FlowLayout(spacing: 8) {
                ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                    NavigationLink(value: AppRoute.tagResults(tag: tag.name ?? "")) {
                        // Only the original follows 标签原文亮暗度; the translation keeps
                        // the un-boosted tag colour (upstream textTagAux).
                        chipText(tag)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Theme.v3TagChipFill, in: .capsule)
                            .overlay(Capsule().strokeBorder(Theme.v3TagChipBorder, lineWidth: 1))
                    }
                    .buttonStyle(PressablePillStyle())
                    .contextMenu {
                        // `V3TagFlowView.showTagActionMenu`
                        Button {
                            UIPasteboard.general.string = tag.name
                        } label: { Label(l10n.t(.actionCopyLink), systemImage: "doc.on.doc") }
                        let isPinned = pinned.isPinned(tag.name)
                        Button {
                            pinned.toggle(name: tag.name,
                                          translatedName: tag.translatedName,
                                          previewURL: previewURL)
                        } label: {
                            Label(isPinned ? l10n.t(.actionUnpinTag) : l10n.t(.actionPinTag),
                                  systemImage: isPinned ? "pin.slash" : "pin")
                        }
                        // 「该作者相关作品」— last, only when the work has an author.
                        if let authorId, authorId > 0, let name = tag.name, !name.isEmpty {
                            Button {
                                pushRoute(.userIllustTag(userId: authorId, tag: name, category: isManga ? "manga" : "illusts"))
                            } label: {
                                Label(l10n.t(.tagMenuAuthorWorks), systemImage: "person.crop.rectangle.stack")
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 18)
    }

    private func chipText(_ tag: Tag) -> Text {
        var out = Text("# " + (tag.name ?? "")).foregroundColor(legibility.originalText)
        if let t = tag.translatedName, !t.isEmpty {
            out = out + Text("  " + t).foregroundColor(Theme.v3TagText)
        }
        return out
    }
}

/// `section_v3_stats.xml` — two gradient numbers on the glass surface, split by
/// a `v3_border_1` hairline.
///
/// Deviation: upstream's bookmark half opens "喜欢这个作品的用户" (who bookmarked
/// this), which is scraped from the pixiv web front end; there is no app-api
/// endpoint for it and the iOS client holds no web session, so the half is
/// rendered but not tappable.
private struct V3StatsCard: View {
    let illust: Illust
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        HStack(spacing: 0) {
            stat(value: illust.totalView ?? 0, label: l10n.t(.detailViewsLabel), gradient: Theme.v3ViewsGradient)
            Rectangle().fill(Theme.v3Border1).frame(width: 1)
                .padding(.vertical, 4)
            stat(value: illust.totalBookmarks ?? 0, label: l10n.t(.detailBookmarksLabel), gradient: Theme.v3BookmarksGradient)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 16)
        .v3Glass(corner: 20)
        .padding(.horizontal, 12)
        .padding(.bottom, 18)
    }

    private func stat(value: Int, label: String, gradient: LinearGradient) -> some View {
        VStack(spacing: 3) {
            Text(value.formatted(.number.grouping(.automatic)))
                // style/textMontserratBold, letterSpacing -0.03 em x 20sp
                .font(.montserratBold(20))
                .tracking(-0.6)
                .foregroundStyle(gradient)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.9)          // letterSpacing 0.1 em × 9sp
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
        // Upstream stacks the two TextViews with no margin between them.
        VStack(alignment: .leading, spacing: 0) {
            Text(c.label.uppercased())
                .font(.system(size: 9, weight: .regular))
                .tracking(0.72)          // letterSpacing 0.08 em × 9sp
                .foregroundStyle(Theme.v3Text3)
                .opacity(0.7)
            Text(c.value)
                .font(c.mono ? .system(size: 13, weight: .bold).monospaced() : .system(size: 13, weight: .bold))
                .foregroundStyle(c.color)
                .opacity(c.mono ? 1 : 0.8)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.v3Surface1, in: .rect(cornerRadius: 14))   // v3_detail_chip_bg
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.v3Border1, lineWidth: 1))
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
            Chip(label: l10n.t(.dpArtworkId), value: "\(illust.id)", color: Theme.v3TextAccent, mono: true),
            Chip(label: l10n.t(.dpUserId), value: illust.user.map { "\($0.id)" } ?? "--", color: Theme.v3TextAccent, mono: true),
            Chip(label: l10n.t(.dpType), value: typeValue, color: Theme.v3Text1, mono: false),
            Chip(label: l10n.t(.dpResolution), value: "\(illust.width ?? 0) × \(illust.height ?? 0)", color: Theme.v3Text1, mono: false),
            Chip(label: l10n.t(.dpPages), value: "\(illust.pageCount ?? 1)", color: Theme.v3Text1, mono: false),
            Chip(label: l10n.t(.dpAI), value: aiType == 2 ? l10n.t(.dpAIYes) : l10n.t(.dpAINo), color: aiType == 2 ? Theme.v3Purple : Theme.v3Green, mono: false),
            Chip(label: l10n.t(.dpRestriction), value: restrictValue, color: restrict > 0 ? Theme.v3Pink : Theme.v3Blue, mono: false),
            Chip(label: l10n.t(.dpPublished), value: V3Date.dateTime(illust.createDate), color: Theme.v3Text1, mono: false),
        ]
    }
}

/// `section_v3_comments.xml` — the "COMMENTS · see more" header, the
/// "留下你的评论吧" entry pill that raises the composer, then at most three
/// preview cards (or the spinner / empty / #592 failure text).
private struct V3CommentsSection: View {
    let vm: IllustDetailViewModel
    let illustId: Int64
    let illustAuthorId: Int64
    var onCompose: () -> Void
    var onTranslate: (String) -> Void
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                V3Label(l10n.t(.commentsTitle))
                Spacer(minLength: 0)
                // `comments_more` sits on the right unconditionally — the full
                // list stays reachable even from the empty state.
                NavigationLink(value: AppRoute.comments(target: .illust(illustId))) {
                    Text(l10n.t(.detailSeeMore))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.v3TextAccent)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 14)

            // `add_comment_entry`: a fake input capsule on the settings-card
            // fill (r=22 + 1dp hairline), avatar 32dp, hint 14sp.
            Button(action: onCompose) {
                HStack(spacing: 10) {
                    // `add_comment_avatar` — the signed-in user's icon.
                    MyAvatarView(userId: KeychainTokenStore.shared.load()?.user?.id, size: 32)
                    Text(l10n.t(.artworkV3AddCommentHint))
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.v3Text3)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Theme.v3CardFill, in: .rect(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.v3CardHairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 14)

            if !vm.commentsLoaded {
                ProgressView()
                    .controlSize(.large)            // 36dp indeterminate
                    .tint(Theme.v3Text3)            // indeterminateTint=v3_text_3
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 50)
            } else if vm.comments.isEmpty {
                // One label carries both states: "还没有评论" on a successful
                // empty read, the server message on a conclusive failure (#592).
                Text(vm.commentsFailedMessage ?? l10n.t(.artworkV3NoCommentsYet))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.v3Text3)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 48)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                VStack(spacing: 8) {
                    ForEach(vm.comments.prefix(3)) { comment in
                        V3CommentPreviewCard(
                            comment: comment,
                            isAuthor: comment.user?.id == illustAuthorId,
                            onTranslate: onTranslate
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 18)
        .onScrolledIntoView { Task { await vm.loadCommentsIfNeeded() } }
    }

}

/// `cell_comment_preview.xml` — a `v3_surface_2` r=14 card: 32dp ringed avatar,
/// optional "作者" badge, name, relative time, then the body (text or a 64dp
/// sticker). Long-press opens copy / translate / view-user, exactly the rows
/// upstream builds with `showV3Menu("PreviewCommentMenu")`.
private struct V3CommentPreviewCard: View {
    let comment: CommentItem
    let isAuthor: Bool
    var onTranslate: (String) -> Void
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                PixivAsyncImage(url: avatarURL, showsProgress: false)
                    .frame(width: 32, height: 32)
                    .clipShape(.circle)
                    .overlay(Circle().strokeBorder(isAuthor ? Theme.v3TextAccent : Theme.v3Border2, lineWidth: 1.5))
                    .padding(.trailing, 10)
                if isAuthor {
                    Text(l10n.t(.artworkV3AuthorBadge))
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.18)
                        .foregroundStyle(Theme.v3TextAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Theme.brand.opacity(0.15), in: .rect(cornerRadius: 6))
                        .padding(.trailing, 6)
                }
                Text(comment.user?.name ?? "")
                    .font(.montserratSemiBold(13))
                    .tracking(-0.13)
                    .foregroundStyle(Theme.v3Text1)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(V3Date.relative(comment.date))
                    .font(.system(size: 11))
                    .tracking(0.22)
                    .foregroundStyle(Theme.v3Text3)
                    .lineLimit(1)
            }

            Group {
                if let stamp = comment.stamp?.stampUrl.flatMap(URL.init(string:)) {
                    // `RoundImageView` scaleType=fitCenter — a non-square
                    // sticker must letterbox, not centre-crop.
                    PixivAsyncImage(url: stamp, contentMode: .fit, showsProgress: false)
                        .frame(width: 64, height: 64)
                        .clipShape(.rect(cornerRadius: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(comment.comment ?? "")
                        .font(.system(size: 13))
                        .tracking(0.13)
                        .lineSpacing(13 * 0.3)
                        .foregroundStyle(Theme.v3Text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, 42)
            .padding(.top, 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.v3Surface2, in: .rect(cornerRadius: 14))
        .contextMenu {
            if let text = comment.comment, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                Button {
                    UIPasteboard.general.string = text
                } label: { Label(l10n.t(.artworkV3CopyComment), systemImage: "doc.on.doc") }
                Button {
                    onTranslate(text)
                } label: { Label(l10n.t(.artworkV3Translate), systemImage: "character.bubble") }
            }
            if let uid = comment.user?.id {
                NavigationLink(value: AppRoute.userProfile(uid)) {
                    Label(l10n.t(.artworkV3ViewUser), systemImage: "person.crop.circle")
                }
            }
        }
    }

    private var avatarURL: URL? {
        (comment.user?.profileImageUrls?.medium ?? comment.user?.profileImageUrls?.px170x170)
            .flatMap(URL.init(string:))
    }
}

/// `section_v3_author_works.xml` — the label + "see more", then a full-bleed
/// horizontal rail of square covers. Cover side is `(screenWidth − 48dp) / 3`
/// (`LAdapter.imageSize`), r=12, 8dp gaps, 12dp content insets.
private struct V3AuthorWorksSection: View {
    let vm: IllustDetailViewModel
    let user: PixivUser?
    @Environment(OnboardingStore.self) private var l10n

    private var coverSide: CGFloat { (UIScreen.main.bounds.width - 48) / 3 }

    var body: some View {
        Group {
            if !vm.authorWorksLoaded {
                VStack(alignment: .leading, spacing: 12) {
                    header(seeAll: false)
                    ProgressView().controlSize(.large).tint(Theme.v3Text3)
                        .frame(maxWidth: .infinity).padding(.vertical, 50)
                }
                .padding(.bottom, 18)
            } else if !vm.authorWorks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    header(seeAll: true)
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 8) {
                            // `fetchAuthorWorks` keeps the first 10, current work excluded.
                            ForEach(vm.authorWorks.prefix(10)) { work in
                                NavigationLink(value: work) {
                                    PixivAsyncImage(url: thumbURL(work))
                                        .frame(width: coverSide, height: coverSide)
                                        .clipShape(.rect(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: coverSide + 16)   // RV height = imageSize + 16dp
                }
                .padding(.bottom, 18)
            }
            // Loaded but empty → render nothing (the whole section collapses,
            // label included — `renderAuthorWorks`).
        }
        .onScrolledIntoView { Task { await vm.loadAuthorWorksIfNeeded() } }
    }

    @ViewBuilder
    private func header(seeAll: Bool) -> some View {
        HStack(spacing: 0) {
            V3Label(l10n.t(.detailAuthorWorksFmt, user?.name ?? ""))
            Spacer(minLength: 0)
            if seeAll, let user {
                NavigationLink(value: AppRoute.userIllusts(userId: user.id, type: "illust")) {
                    Text(l10n.t(.detailSeeMore))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.v3TextAccent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
    }

    private func thumbURL(_ illust: Illust) -> URL? {
        (illust.imageUrls?.squareMedium ?? illust.imageUrls?.medium).flatMap(URL.init(string:))
    }
}

/// `section_v3_related_header.xml` + the related waterfall the feed pages
/// through. The header's "see more" only appears once the section has loaded
/// and found something (`ArtworkRelatedHeaderItem.state == true`).
private struct V3RelatedSection: View {
    let vm: IllustDetailViewModel
    let illustId: Int64
    @Environment(OnboardingStore.self) private var l10n
    @State private var mute = MuteStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                V3Label(l10n.t(.detailRelated))
                Spacer(minLength: 0)
                if vm.relatedLoaded, !vm.related.isEmpty {
                    NavigationLink(value: AppRoute.relatedIllusts(illustId: illustId)) {
                        Text(l10n.t(.detailSeeMore))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.v3TextAccent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 12)

            if !vm.relatedLoaded {
                // `related_loading_container`: a centred spinner, not a grid
                // skeleton — the header above it is already real content.
                ProgressView()
                    .controlSize(.large)            // 36dp indeterminate
                    .tint(Theme.v3Text3)            // indeterminateTint=v3_text_3
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 50)
            } else {
                let visible = mute.filter(vm.related)
                if visible.isEmpty {
                    Text(l10n.t(.detailNoRelated))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.v3Text3)
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 64)
                } else {
                    WaterfallGrid(
                        items: visible,
                        columns: mute.waterfallColumns,
                        spacing: 8,
                        estimatedRelativeHeight: { $0.waterfallImageHeightRatio }
                    ) { item in
                        NavigationLink(value: item) {
                            IllustWaterfallCell(illust: item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { IllustCardMenuItems(illust: item) { visible } }
                    }
                    .padding(.horizontal, 8)
                    .cardMenuHost()

                    // `section_v3_loading_more.xml`: a 120dp footer that also
                    // triggers the next related page (the feed's `loadMore`).
                    if vm.relatedNextUrl != nil {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .onAppear { Task { await vm.loadMoreRelated() } }
                    }
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
            .tracking(1.44)   // letterSpacing 0.12 em × 12sp
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

    /// Captions carry `<a href>` links, and #552/#960 were exactly about them
    /// disappearing. Rewrite anchors as markdown so `Text` renders them tappable
    /// (upstream: `HtmlCompat.fromHtml` + `LinkMovementMethod`), then strip what
    /// is left. `plain` is the already-computed fallback for captions without
    /// links, so the common case costs nothing extra.
    static func attributed(_ html: String, plain: String) -> AttributedString {
        guard html.range(of: "<a ", options: .caseInsensitive) != nil else {
            return AttributedString(plain)
        }
        var s = html
        for br in ["<br />", "<br/>", "<br>", "</p>", "</P>"] {
            s = s.replacingOccurrences(of: br, with: "\n")
        }
        // <a href="URL" ...>label</a> → [label](URL)
        s = s.replacingOccurrences(
            of: "<a[^>]*href=\"([^\"]*)\"[^>]*>(.*?)</a>",
            with: "[$2]($1)",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
        ]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // `.inlineOnlyPreservingWhitespace` keeps the caption's own line breaks;
        // full markdown parsing would eat them.
        if let a = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return a
        }
        return AttributedString(plain)
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
    // Upstream is `Common.getLocalYYYYMMDDHHMMString`: java.time renders the
    // ISO chronology regardless of locale, so Android always shows a Gregorian
    // year and a 24-hour clock. A bare DateFormatter would instead follow the
    // device's calendar (era year on th_TH/ja_JP-japanese) and let a 12-hour
    // region rewrite `HH` — pin calendar + locale, keep the local time zone.
    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
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
    /// `skipLarge` mirrors the menu's "load the original for this work": don't
    /// paint the `large` placeholder first, go straight for the original.
    func run(large: URL?, original: URL?, pixelWidth: Int, skipLarge: Bool = false) async {
        // Memoized display-sized original from a previous visit — skip
        // the large placeholder and the disk round-trip entirely.
        if let original, let cached = PixivImageCache.shared.displayImage(for: original) {
            image = cached
            showedOriginal = true
            return
        }

        if let large, !skipLarge {
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

/// `view_v3_fab_bar.xml` + `V3FabBarController` — the floating download /
/// bookmark (/ jump-to-comments) capsule shared with the second-level image
/// page. 48dp tall, 6dp side padding, 60×40 buttons, 1×24 dividers with 2dp
/// margins. The plate is NOT the drawable's fixed `#CC1A1A2E`: `applyPalette`
/// repaints it with `floatingPillBg` (the theme-tinted card fill at 80 %) and
/// tints every icon with `floatingPillContent`.
private struct BottomActionBar: View {
    let vm: IllustDetailViewModel
    let onShowBookmarkSheet: () -> Void
    var onJumpToComments: () -> Void
    @Environment(OnboardingStore.self) private var l10n

    @State private var download: DownloadState = .idle
    @State private var showResolutionPicker = false
    @State private var settings = AppSettingsStore.shared

    enum DownloadState: Equatable {
        case idle, downloading(Double), done, failed
        var isActive: Bool { if case .downloading = self { return true }; return false }
    }

    var body: some View {
        let position = settings.resolvedFabPosition
        HStack(spacing: 0) {
            // `applyLayoutPreference` (#1090): centred, the order follows the
            // download / bookmark preference; pinned to an edge, the bookmark
            // heart sits on the outer (screen-edge) end and the rest mirror, so
            // the comment segment lands on the inner end.
            if position == AppSettingsStore.fabPositionRight {
                if settings.artworkV3ShowCommentJumpFab {
                    commentButton
                    divider
                }
                downloadButton
                divider
                bookmarkButton
            } else {
                if position == AppSettingsStore.fabPositionLeft || !settings.artworkV3FabDownloadOnLeft {
                    bookmarkButton
                    divider
                    downloadButton
                } else {
                    downloadButton
                    divider
                    bookmarkButton
                }
                if settings.artworkV3ShowCommentJumpFab {
                    divider
                    commentButton
                }
            }
        }
        .frame(height: 48)
        .padding(.horizontal, 6)
        .background(Theme.v3CardFill.opacity(0.80), in: .capsule)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)   // elevation 12dp
        // 靠边时离屏幕边 20dp（与二级大图页那一行的左右留白一致）；横屏的
        // 刘海 / 灵动岛由安全区让开，外侧收藏心不会被压住。
        .frame(maxWidth: .infinity, alignment: Self.alignment(for: position))
        .padding(.leading, position == AppSettingsStore.fabPositionLeft ? 20 : 0)
        .padding(.trailing, position == AppSettingsStore.fabPositionRight ? 20 : 0)
        .padding(.bottom, 24)                                   // V3FabBarController: inset + 24dp
        // Long-press on the download half → the four-resolution picker
        // (`WitDialog.MenuDialogBuilder` over the `resolution_*` strings).
        .confirmationDialog(
            l10n.t(.downloadsTitle), isPresented: $showResolutionPicker, titleVisibility: .hidden
        ) {
            Button(l10n.t(.artworkV3ResOriginal)) { Task { await runDownload(.original) } }
            Button(l10n.t(.artworkV3ResLarge)) { Task { await runDownload(.large) } }
            Button(l10n.t(.artworkV3ResMedium)) { Task { await runDownload(.medium) } }
            Button(l10n.t(.artworkV3ResSquareMedium)) { Task { await runDownload(.squareMedium) } }
            Button(l10n.t(.actionCancel), role: .cancel) {}
        }
    }

    private static func alignment(for position: Int) -> Alignment {
        switch position {
        case AppSettingsStore.fabPositionLeft: return .leading
        case AppSettingsStore.fabPositionRight: return .trailing
        default: return .center
        }
    }

    private var divider: some View {
        Theme.v3FloatingPillContent.opacity(0.20)
            .frame(width: 1, height: 24)
            .padding(.horizontal, 2)
    }

    // MARK: Download

    private var downloadButton: some View {
        Button {
            // Tap = the 默认图片清晰度 setting; long-press picks a size on the spot.
            Task { await runDownload(.default) }
        } label: {
            Group {
                switch download {
                case .idle:
                    Image(systemName: "arrow.down.to.line").font(.system(size: 24))
                        .foregroundStyle(Theme.v3FloatingPillContent)
                case .downloading(let p):
                    ZStack {
                        ProgressRing(progress: p, lineWidth: 3,
                                     tint: Theme.v3FloatingPillContent,
                                     track: Theme.v3FloatingPillContent.opacity(0.20))
                    }
                    .frame(width: 24, height: 24)   // ring only — upstream draws no percentage
                case .done:
                    // `ic_file_download_done_24dp` tinted `has_downloaded`.
                    Image(systemName: "arrow.down.to.line.circle.fill").font(.system(size: 24))
                        .foregroundStyle(Theme.v3HasDownloaded)
                case .failed:
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 24)).foregroundStyle(.orange)
                }
            }
            .frame(width: 60, height: 40)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(download.isActive || vm.illust == nil)
        .accessibilityLabel(l10n.t(.downloadsTitle))
        .simultaneousGesture(LongPressGesture().onEnded { _ in showResolutionPicker = true })
    }

    private func runDownload(_ resolution: ImageResolution) async {
        guard let illust = vm.illust else { return }
        let urls = resolution.urls(for: illust)
        guard !urls.isEmpty else { return }
        // Low storage pauses every download and says so once (pixez#1361).
        guard StorageSpaceGuard.hasRoomForDownload() else {
            DownloadManager.shared.pauseForLowStorage()
            await flashFailed()
            return
        }
        guard await PhotoLibrarySaver.requestAuthorization() else { await flashFailed(); return }

        // `isAutoPostLikeWhenDownload`: bookmark the work as the download starts.
        if settings.autoPostLikeWhenDownload, !vm.isBookmarked {
            Task { await vm.toggleBookmark() }
        }

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
        DownloadManager.shared.recordCompleted(illust)   // surface in Downloads → Done
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
            let willBookmark = !vm.isBookmarked
            BookmarkHaptics.commit(bookmarking: willBookmark)
            Task {
                await vm.toggleBookmark()
                // `isAutoDownloadAfterStar`: bookmarking pulls every page down.
                if willBookmark, settings.autoDownloadAfterStar {
                    await runDownload(.default)
                }
            }
        } label: {
            // Upstream `ic_favorite`: the heart is ALWAYS filled — the pill's
            // content color when not bookmarked, `has_bookmarked` red when it is.
            Image(systemName: "heart.fill")
                .font(.system(size: 24))
                .foregroundStyle(vm.isBookmarked ? Theme.v3Bookmarked : Theme.v3FloatingPillContent)
                .bookmarkBounce(vm.isBookmarked)
                .frame(width: 60, height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(.bookmark)
        .disabled(vm.isBookmarking || vm.illust == nil)
        // Upstream long-press goes straight to `SelectTagBottomSheet`; the
        // public/private rows ride along because iOS has no separate gesture
        // for the "私密收藏" preference the Android setting covers.
        .contextMenu {
            if !vm.isBookmarked {
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

    // MARK: Jump to comments (#970)

    private var commentButton: some View {
        Button(action: onJumpToComments) {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 24))
                .foregroundStyle(Theme.v3FloatingPillContent)
                .frame(width: 60, height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(l10n.t(.artworkV3JumpToComments))
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

// MARK: - Floating detail-page nav control

/// Circular translucent capsule for the floating back / overflow buttons the V3
/// detail pages draw in place of the hidden navigation bar (hidden because iOS 26
/// Liquid Glass paints an unclearable scroll-edge material on it). Mirrors the
/// look of the system bar buttons it replaces.
struct DetailGlassCircle: View {
    let system: String
    var body: some View {
        Image(systemName: system)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 36, height: 36)
            .background(.regularMaterial, in: .circle)
            .overlay(Circle().stroke(.white.opacity(0.12)))
    }
}
