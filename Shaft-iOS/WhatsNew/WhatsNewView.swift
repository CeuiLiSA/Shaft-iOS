import SwiftUI

// MARK: - View model — DynamicPageViewModel + the two lists' RestrictViewModels + user rail

/// 「动态」tab state, 1:1 with upstream:
///  · page state (`DynamicPageViewModel`): `restrict` (all/public/private) + `isIllustMode`;
///  · per-list state (`RestrictViewModel`): the restrict each list was actually fetched
///    with — switching mode re-pushes the page restrict to the now-visible list and only
///    refetches when it differs (no request for the list you can't see);
///  · the novel list is created lazily on first switch to 小说;
///  · 推荐用户 rail: first page only (`RecmdUserRailFeedFragment.loadMoreEnabled = false`).
@MainActor
@Observable
final class WhatsNewViewModel {
    static let restrictAll = "all", restrictPublic = "public", restrictPrivate = "private"

    var restrict: String = WhatsNewViewModel.restrictAll
    var isIllustMode = true

    var users: [UserPreview]?            // nil = not loaded yet (skeleton)

    var illusts: [Illust] = []
    var illustNext: String?
    var illustsLoading = false
    var illustsLoadingMore = false
    var illustError: String?

    var novels: [Novel] = []
    var novelNext: String?
    var novelsLoading = false
    var novelsLoadingMore = false
    var novelError: String?

    @ObservationIgnored private var started = false
    /// Restrict each list last fetched with (nil = never fetched).
    @ObservationIgnored private var illustRestrict: String?
    @ObservationIgnored private var novelRestrict: String?
    @ObservationIgnored private var illustGen = 0
    @ObservationIgnored private var novelGen = 0
    @ObservationIgnored private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)

    func start() async {
        if started { return }
        started = true
        async let rail: Void = loadUsers()
        async let list: Void = pushRestrictToActiveList()
        _ = await (rail, list)
    }

    /// Filter bar `onSelect` — only the visible list is (re)fetched.
    func setRestrict(_ r: String) async {
        guard r != restrict else { return }
        restrict = r
        await pushRestrictToActiveList()
    }

    /// Type bar `onSelect` — switch list; novel list is built on first use.
    func setIllustMode(_ illust: Bool) async {
        guard illust != isIllustMode else { return }
        isIllustMode = illust
        await pushRestrictToActiveList()
    }

    /// Filter-bar reselect / pull-to-refresh / tab re-tap: refetch the active list.
    func refreshActiveList() async {
        if isIllustMode { await loadIllusts() } else { await loadNovels() }
    }

    private func pushRestrictToActiveList() async {
        if isIllustMode {
            if illustRestrict != restrict { await loadIllusts() }
        } else {
            if novelRestrict != restrict { await loadNovels() }
        }
    }

    // MARK: illusts (FollowingIllustFeedFragment)

    private func loadIllusts() async {
        illustGen += 1
        let gen = illustGen
        let r = restrict
        illustRestrict = r
        illustsLoading = true
        illustError = nil
        defer { if gen == illustGen { illustsLoading = false } }
        do {
            let resp = try await api.newIllustsFromFollowing(restrict: r)
            guard gen == illustGen else { return }
            illusts = resp.illusts
            illustNext = resp.nextUrl
        } catch {
            guard gen == illustGen else { return }
            illustError = error.localizedDescription
        }
    }

    func loadMoreIllusts() async {
        guard let url = illustNext, !illustsLoadingMore else { return }
        let gen = illustGen
        illustsLoadingMore = true
        defer { illustsLoadingMore = false }
        if let r: IllustResponse = try? await api.nextPage(url) {
            guard gen == illustGen else { return }
            illusts.append(contentsOf: r.illusts)
            illustNext = r.nextUrl
        }
    }

    // MARK: novels (FollowingNovelFeedFragment, embedded form)

    private func loadNovels() async {
        novelGen += 1
        let gen = novelGen
        let r = restrict
        novelRestrict = r
        novelsLoading = true
        novelError = nil
        defer { if gen == novelGen { novelsLoading = false } }
        do {
            let resp = try await api.newNovelsFromFollowing(restrict: r)
            guard gen == novelGen else { return }
            novels = resp.novels
            novelNext = resp.nextUrl
        } catch {
            guard gen == novelGen else { return }
            novelError = error.localizedDescription
        }
    }

    func loadMoreNovels() async {
        guard let url = novelNext, !novelsLoadingMore else { return }
        let gen = novelGen
        novelsLoadingMore = true
        defer { novelsLoadingMore = false }
        if let r: NovelResponse = try? await api.nextPage(url) {
            guard gen == novelGen else { return }
            novels.append(contentsOf: r.novels)
            novelNext = r.nextUrl
        }
    }

    // MARK: 推荐用户 rail (RecmdUserRailFeedFragment — first page only)

    private func loadUsers() async {
        let r = try? await api.recommendedUsers()
        users = r?.userPreviews ?? []
    }
}

// MARK: - 动态 tab — 1:1 FragmentRight / fragment_new_right.xml

/// Header (drawer / title / search) = host nav bar. Below: the 推荐用户 block, then the
/// rounded content sheet (type bar · timeline toggle · restrict bar + the list), stacked
/// vertically in one scroll; the sheet toolbar pins at the top once the header scrolls off.
/// (Upstream's CoordinatorLayout collapse behaviors are intentionally not reproduced.)
struct WhatsNewView: View {
    @State private var vm = WhatsNewViewModel()
    @State private var settings = AppSettingsStore.shared
    @State private var mute = MuteStore.shared
    @State private var headerHeight: CGFloat = 0
    @Environment(OnboardingStore.self) private var l10n

    private static let topAnchor = "whatsnew-top"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    RecmdUserHeader(users: vm.users)
                        .id(Self.topAnchor)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }

                    Section {
                        sheetContent
                            .frame(maxWidth: .infinity)
                            .background(Theme.v3CardFill)
                    } header: {
                        SheetToolbar(
                            vm: vm,
                            timelineMode: !settings.useStaggeredLayout,
                            onToggleTimeline: { settings.useStaggeredLayout.toggle() },
                            onTapTitle: {
                                withAnimation { proxy.scrollTo(Self.topAnchor, anchor: .top) }
                            }
                        )
                    }
                }
            }
            .background {
                // v3_bg behind the header band, cardFill (the sheet) behind everything else —
                // so a short list still reads as one sheet running to the screen bottom.
                ZStack(alignment: .top) {
                    Theme.v3CardFill
                    Theme.v3Bg.frame(height: headerHeight)
                }
                .ignoresSafeArea()
            }
            .refreshable { await vm.refreshActiveList() }
            .task { await vm.start() }
        }
    }

    // MARK: sheet body (illust_list_container / novel_list_container)

    @ViewBuilder
    private var sheetContent: some View {
        if vm.isIllustMode {
            let visible = mute.filter(vm.illusts)
            if vm.illusts.isEmpty, let err = vm.illustError {
                InlineError(message: err) { Task { await vm.refreshActiveList() } }
                    .padding(12)
            } else if visible.isEmpty, vm.illustsLoading {
                if settings.useStaggeredLayout {
                    WaterfallSkeleton(columns: mute.waterfallColumns)
                } else {
                    TimelineSkeleton()
                }
            } else if settings.useStaggeredLayout {
                // IllustFeedFragment: StaggeredManager(lineCount) + 8dp SpacesItemDecoration
                WaterfallGrid(
                    items: visible,
                    columns: mute.waterfallColumns,
                    spacing: 8,
                    estimatedRelativeHeight: { $0.waterfallImageHeightRatio }
                ) { illust in
                    NavigationLink(value: illust) {
                        IllustWaterfallCell(illust: illust)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
            } else {
                // Timeline: single-column big cards (recy_timeline_illust), no extra decoration
                LazyVStack(spacing: 0) {
                    ForEach(visible) { illust in
                        TimelineIllustCard(illust: illust)
                    }
                }
            }
            if vm.illustsLoadingMore {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else if vm.illustNext != nil, !vm.illusts.isEmpty {
                Color.clear.frame(height: 40)
                    .onAppear { Task { await vm.loadMoreIllusts() } }
            }
        } else {
            if vm.novels.isEmpty, let err = vm.novelError {
                InlineError(message: err) { Task { await vm.refreshActiveList() } }
                    .padding(12)
            } else if vm.novels.isEmpty, vm.novelsLoading {
                NovelListSkeleton()
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(vm.novels) { novel in
                        NavigationLink(value: AppRoute.novelDetail(novel.id)) {
                            NovelRow(novel: novel)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { NovelCellContextMenuItems(novel: novel) }
                    }
                }
            }
            if vm.novelsLoadingMore {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else if vm.novelNext != nil, !vm.novels.isEmpty {
                Color.clear.frame(height: 40)
                    .onAppear { Task { await vm.loadMoreNovels() } }
            }
        }
        // Keep the sheet tall enough to always reach below the fold.
        Color.clear.frame(height: 24)
    }
}

// MARK: - 推荐用户 header block (imagesTitleBlockLayout)

/// 13sp bold v3_text_2 「推荐用户」(letterSpacing 0.06) + 「查看更多 ›」(13sp primary, 20dp
/// chevron, drawablePadding 2), paddings 20/16, marginTop 4 / bottom 10; 124dp rail; 10dp gap.
private struct RecmdUserHeader: View {
    let users: [UserPreview]?
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(l10n.t(.dynRecommendUsers))
                    .font(.system(size: 13, weight: .bold))
                    .tracking(13 * 0.06)
                    .foregroundStyle(Theme.v3Text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                NavigationLink(value: AppRoute.recommendUsers) {
                    HStack(spacing: 2) {
                        Text(l10n.t(.dynSeeMore)).font(.system(size: 13))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 20, height: 20)
                    }
                    .foregroundStyle(Theme.brand)
                }
                .buttonStyle(PressAlphaStyle())
            }
            .padding(.leading, 20)
            .padding(.trailing, 16)
            .padding(.top, 4)
            .padding(.bottom, 10)

            RecmdUserRail(users: users)
                .frame(height: 124)

            Color.clear.frame(height: 10)
        }
        .background(Theme.v3Bg)
    }
}

/// RecmdUserRailFeedFragment: horizontal list, LinearItemHorizontalDecoration(12) =
/// top/right/bottom 12 for every card, left 12 for the first.
private struct RecmdUserRail: View {
    let users: [UserPreview]?

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                if let users {
                    ForEach(users) { preview in
                        RecmdUserCard(preview: preview)
                    }
                } else {
                    UserRailSkeleton()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .animation(.easeInOut(duration: 0.24), value: users == nil)
    }
}

/// recy_user_preview_horizontal: 85dp card r12 (`f0_and_black`, elevation 2), 56dp avatar
/// with 1dp primary ring (marginTop 12), 13sp bold primary name (marginTop/Bottom 8, H 6).
private struct RecmdUserCard: View {
    let preview: UserPreview

    var body: some View {
        NavigationLink(value: AppRoute.userProfile(preview.user.id)) {
            VStack(spacing: 0) {
                PixivAsyncImage(url: avatarURL, showsProgress: false, placeholder: Theme.lightBg)
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Theme.brand, lineWidth: 1))
                    .padding(.top, 12)
                Text(preview.user.name ?? "")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.brand)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            }
            .frame(width: 85)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(light: 0xF0F0F0, dark: 0x141414))
                    .shadow(color: .black.opacity(0.16), radius: 2, x: 0, y: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var avatarURL: URL? {
        preview.user.profileImageUrls?.medium.flatMap(URL.init(string:))
    }
}

/// FeedUserRailSkeletonView: per 85dp slot — 56dp avatar circle at top 12 + 50×13 name bar.
private struct UserRailSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<6, id: \.self) { _ in
                VStack(spacing: 8) {
                    SkeletonCircle(size: 56)
                    SkeletonBlock(width: 50, height: 13, corner: 4)
                }
                .frame(width: 85)
                .padding(.top, 12)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .shimmering()
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

// MARK: - Sheet toolbar (dynamic_title_layout)

/// Type bar (16sp) at start (marginStart 8, V 10); actions at end (marginStart/End 8):
/// 36dp timeline toggle (padding 6, marginEnd 8, primary when timeline else #7b7b7b — only
/// in illust mode) + restrict bar (13sp). Tapping the bar itself scrolls the list to top.
/// Background = the sheet's 20dp-top-rounded `cardFill`.
private struct SheetToolbar: View {
    @Bindable var vm: WhatsNewViewModel
    let timelineMode: Bool
    let onToggleTimeline: () -> Void
    let onTapTitle: () -> Void
    @Environment(OnboardingStore.self) private var l10n

    private static let restricts = [
        WhatsNewViewModel.restrictAll, WhatsNewViewModel.restrictPublic, WhatsNewViewModel.restrictPrivate,
    ]

    var body: some View {
        HStack(spacing: 0) {
            SegmentedToggle(
                titles: [l10n.t(.dynTypeIllustManga), l10n.t(.dynTypeNovel)],
                selected: vm.isIllustMode ? 0 : 1,
                textSize: 16,
                onSelect: { idx in Task { await vm.setIllustMode(idx == 0) } },
                onReselect: {}
            )
            .padding(.leading, 8)
            .padding(.vertical, 10)

            Spacer(minLength: 8)

            HStack(spacing: 0) {
                if vm.isIllustMode {
                    Button(action: onToggleTimeline) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(timelineMode ? Theme.brand : Color(hex: 0x7B7B7B))
                            .frame(width: 36, height: 36)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                }
                SegmentedToggle(
                    titles: [l10n.t(.dynRestrictAll), l10n.t(.dynRestrictPublic), l10n.t(.dynRestrictPrivate)],
                    selected: Self.restricts.firstIndex(of: vm.restrict) ?? 0,
                    textSize: 13,
                    onSelect: { idx in Task { await vm.setRestrict(Self.restricts[idx]) } },
                    onReselect: { Task { await vm.refreshActiveList() } }
                )
            }
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .onTapGesture(perform: onTapTitle)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20, style: .continuous)
                .fill(Theme.v3CardFill)
        )
    }
}

/// `SegmentedToggleLayout`: row of text cells on a `glare_bg` track (fragment_right_divider,
/// r6); cell padding 10/6; selected = primary text + 0.8dp primary stroke r6, others #7b7b7b.
struct SegmentedToggle: View {
    let titles: [String]
    let selected: Int
    let textSize: CGFloat
    let onSelect: (Int) -> Void
    let onReselect: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { idx, title in
                Button {
                    if idx == selected { onReselect() } else { onSelect(idx) }
                } label: {
                    Text(title)
                        .font(.system(size: textSize))
                        .lineLimit(1)
                        .foregroundStyle(idx == selected ? Theme.brand : Color(hex: 0x7B7B7B))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background {
                            if idx == selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Theme.brand, lineWidth: 0.8)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(PressAlphaStyle())
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(light: 0xF0F0F0, dark: 0x141414))
        )
    }
}

// MARK: - Timeline card (recy_timeline_illust / TimelineIllustCard.kt)

/// Flat card on v3_bg: 0.5dp divider (H 16) · avatar 42 (1dp v3_border_2 ring) + 14sp bold
/// name + 12sp v3_text_3 time-ago · 15sp title (2 lines) · r16 image area (single image
/// clamped 0.6…1.5, or 2/3-column square grid with “+N”) with 72dp bottom scrim, stats pill
/// (views · bookmarks) bottom-start and page-count badge top-end · 4dp bottom gap.
private struct TimelineIllustCard: View {
    let illust: Illust
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        NavigationLink(value: illust) {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Theme.v3Border1).frame(height: 0.5).padding(.horizontal, 16)

                HStack(spacing: 12) {
                    PixivAsyncImage(url: avatarURL, showsProgress: false, placeholder: Theme.lightBg)
                        .frame(width: 42, height: 42)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Theme.v3Border2, lineWidth: 1))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(illust.user?.name ?? "")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.v3Text1)
                            .lineLimit(1)
                        Text(TimeAgo.string(illust.createDate, justNow: l10n.t(.timeJustNow)))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.v3Text3)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                if let title = illust.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 15))
                        .tracking(-0.15)
                        .foregroundStyle(Theme.v3Text1)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                imageArea
                    .padding(.horizontal, 16)

                Color.clear.frame(height: 4)
            }
            .background(Theme.v3Bg)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var pageCount: Int { illust.pageCount ?? 1 }

    private var imageArea: some View {
        ZStack(alignment: .bottom) {
            if pageCount > 1, let pages = illust.metaPages, !pages.isEmpty {
                TimelineGrid(pages: pages)
            } else {
                PixivAsyncImage(url: largeURL, showsProgress: false, placeholder: Theme.v3Surface2)
                    .aspectRatio(1 / singleRatio, contentMode: .fit)
            }
            // gradient_bottom_scrim: transparent → #99000000
            LinearGradient(colors: [.clear, .black.opacity(153 / 255)], startPoint: .top, endPoint: .bottom)
                .frame(height: 72)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) { statsPill.padding(10) }
        .overlay(alignment: .topTrailing) {
            if pageCount > 1 { pageCountBadge.padding(10) }
        }
        .background(Theme.v3Surface2)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// bg_stats_pill (#66000000 r12, padding 10/5): 14dp eye + 11sp bold count, 14dp bookmark + count.
    private var statsPill: some View {
        HStack(spacing: 0) {
            Image(systemName: "eye.fill").font(.system(size: 11)).frame(width: 14, height: 14)
            Text((illust.totalView ?? 0).formatted(.number))
                .font(.system(size: 11, weight: .bold))
                .padding(.leading, 3)
            Image(systemName: "bookmark.fill").font(.system(size: 11)).frame(width: 14, height: 14)
                .padding(.leading, 12)
            Text((illust.totalBookmarks ?? 0).formatted(.number))
                .font(.system(size: 11, weight: .bold))
                .padding(.leading, 3)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(102 / 255), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// bg_page_count_overlay (#B3000000 r8, padding 8/4): 14dp grid icon + 12sp bold count.
    private var pageCountBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.grid.2x2.fill").font(.system(size: 11)).frame(width: 14, height: 14)
            Text("\(pageCount)").font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(179 / 255), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// TimelineIllustCard MIN/MAX_HEIGHT_RATIO 0.6…1.5 (narrower band than the waterfall cell).
    private var singleRatio: CGFloat {
        guard let w = illust.width, let h = illust.height, w > 0, h > 0 else { return 1 }
        return min(max(CGFloat(h) / CGFloat(w), 0.6), 1.5)
    }

    private var largeURL: URL? {
        (illust.imageUrls?.large ?? illust.imageUrls?.medium).flatMap(URL.init(string:))
    }

    private var avatarURL: URL? {
        illust.user?.profileImageUrls?.medium.flatMap(URL.init(string:))
    }
}

/// Multi-page grid: ≤4 pages → 2 columns (max 4 cells), more → 3 columns (max 9); 2dp gaps,
/// square cells; the last visible cell carries a “+N” overlay (#66000000, 20sp bold) when
/// pages were cut off. Cell tap = card tap (the whole card is the NavigationLink).
private struct TimelineGrid: View {
    let pages: [MetaPage]

    var body: some View {
        let total = pages.count
        let span = total <= 4 ? 2 : 3
        let maxShow = span == 2 ? 4 : 9
        let showCount = min(total, maxShow)
        let remaining = total - maxShow
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: span)
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(0..<showCount, id: \.self) { i in
                PixivAsyncImage(
                    url: (pages[i].imageUrls?.large ?? pages[i].imageUrls?.medium).flatMap(URL.init(string:)),
                    showsProgress: false,
                    placeholder: Theme.v3Surface2
                )
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if i == showCount - 1, remaining > 0 {
                        ZStack {
                            Color.black.opacity(102 / 255)
                            Text("+\(remaining)")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
        }
    }
}

/// FeedTimelineSkeletonView: avatar 42 + name/time bars, 68%-wide title bar, full-width
/// image block (ratio pattern 1.4 / 0.75 / 1.5 / 1.0 / 0.62), r16, 4dp gaps.
private struct TimelineSkeleton: View {
    private static let ratios: [CGFloat] = [1.4, 0.75, 1.5, 1.0, 0.62]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        SkeletonCircle(size: 42)
                        VStack(alignment: .leading, spacing: 4) {
                            SkeletonBlock(width: 120, height: 14).padding(.top, 6)
                            SkeletonBlock(width: 72, height: 12)
                        }
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                    SkeletonBlock(width: nil, height: 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .scaleEffect(x: 0.68, y: 1, anchor: .leading)
                        .padding(.bottom, 8)
                    SkeletonShape(corner: 16)
                        .aspectRatio(1 / Self.ratios[i % Self.ratios.count], contentMode: .fit)
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .shimmering()
        .allowsHitTesting(false)
    }
}

// MARK: - DateParse.getTimeAgo

/// 1:1 `ceui.loxia.DateParse.getTimeAgo`: <1 min → localized “Just now”; <60 → “N minute(s)
/// ago”; different year → “MMM d, yyyy”; different month → “MMM d”; different day → “N day(s)
/// ago”; else “N hour(s) ago”. The plural strings only exist in upstream's default
/// `values/` (English), so every locale shows them in English — reproduced as-is.
enum TimeAgo {
    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    static func string(_ createDate: String?, justNow: String, now: Date = Date()) -> String {
        guard let s = createDate, !s.isEmpty, let date = iso.date(from: s) else { return "" }
        let intervalSec = Int(now.timeIntervalSince(date))
        let mins = intervalSec / 60
        if mins < 1 { return justNow }
        if mins < 60 { return mins == 1 ? "1 minute ago" : "\(mins) minutes ago" }
        let cal = Calendar.current
        let d = cal.dateComponents([.year, .month, .day], from: date)
        let n = cal.dateComponents([.year, .month, .day], from: now)
        if d.year != n.year {
            return formatted(date, template: "MMMdyyyy")
        }
        if d.month != n.month {
            return formatted(date, template: "MMMd")
        }
        if d.day != n.day {
            let days = (n.day ?? 0) - (d.day ?? 0)
            return days == 1 ? "1 day ago" : "\(days) days ago"
        }
        let hours = intervalSec / 3600
        return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
    }

    private static func formatted(_ date: Date, template: String) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }
}
