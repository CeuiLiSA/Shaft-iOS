import SwiftUI
import UIKit

// MARK: - Paged feeds behind the V3 profile tabs
//
// One small feed object per tab, created up front by `UserProfileViewModel` and
// loaded on first visit — the upstream ViewPager2 keeps its default offscreen
// limit, so entering the page only fires `user/detail`, never every tab's API.

/// 插画 / 漫画 / 小说 / 插画收藏 / 小说收藏 — every list that pages `[Illust]`
/// or `[Novel]` for one user.
@MainActor
@Observable
final class UserWorksFeed {
    enum Kind { case illust, manga, novel, bookmarkIllust, bookmarkNovel }

    let userId: Int64
    let kind: Kind
    var illusts: [Illust] = []
    var novels: [Novel] = []
    var nextUrl: String?
    var isLoading = false
    var errorMessage: String?
    /// Top tags aggregated from the first page (issue #569/#996): frequency
    /// desc, capped at 20, then re-sorted by rendered chip width so the two
    /// rows stack tidily.
    var tagChips: [Tag] = []

    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var isLoadingMore = false
    @ObservationIgnored private let api: PixivAPI

    private static let maxTagChips = 20

    init(userId: Int64, kind: Kind) {
        self.userId = userId
        self.kind = kind
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    var isNovelKind: Bool { kind == .novel || kind == .bookmarkNovel }
    var isEmpty: Bool { isNovelKind ? novels.isEmpty : illusts.isEmpty }

    func loadIfNeeded() async {
        guard !loaded, !isLoading else { return }
        await load()
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            switch kind {
            case .illust, .manga:
                let r = try await api.userIllusts(userId, type: kind == .manga ? "manga" : "illust")
                illusts = r.illusts
                nextUrl = r.nextUrl
                aggregateTags(from: MuteStore.shared.filter(r.illusts).compactMap(\.tags))
            case .novel:
                let r = try await api.userNovels(userId)
                novels = r.novels
                nextUrl = r.nextUrl
                aggregateTags(from: MuteStore.shared.filter(r.novels).compactMap(\.tags))
            case .bookmarkIllust:
                let r = try await api.userBookmarkedIllusts(userId)
                illusts = r.illusts
                nextUrl = r.nextUrl
            case .bookmarkNovel:
                let r = try await api.userBookmarkedNovels(userId)
                novels = r.novels
                nextUrl = r.nextUrl
            }
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if isNovelKind {
            if let r: NovelResponse = try? await api.nextPage(url) {
                novels.append(contentsOf: r.novels)
                nextUrl = r.nextUrl
            }
        } else {
            if let r: IllustResponse = try? await api.nextPage(url) {
                illusts.append(contentsOf: r.illusts)
                nextUrl = r.nextUrl
            }
        }
    }

    /// Muted works drop out before aggregation, so a muted tag never surfaces
    /// as a chip (upstream filters the first page the same way).
    private func aggregateTags(from tagLists: [[Tag]]) {
        var freq: [String: Int] = [:]
        var first: [String: Tag] = [:]
        var order: [String] = []
        for tags in tagLists {
            for tag in tags {
                guard let name = tag.name, !name.trimmingCharacters(in: .whitespaces).isEmpty
                else { continue }
                if freq[name] == nil {
                    first[name] = tag
                    order.append(name)
                }
                freq[name, default: 0] += 1
            }
        }
        guard !order.isEmpty else { return }
        tagChips = order
            .sorted { (freq[$0] ?? 0) > (freq[$1] ?? 0) }
            .prefix(Self.maxTagChips)
            .compactMap { first[$0] }
            .sorted { Self.chipVisualWidth($0) < Self.chipVisualWidth($1) }
    }

    /// CJK / kana count double, ASCII single — the same cheap estimate upstream
    /// uses to order chips short-to-long.
    private static func chipVisualWidth(_ tag: Tag) -> Int {
        func width(_ s: String?) -> Int {
            guard let s, !s.isEmpty else { return 0 }
            return s.unicodeScalars.reduce(0) { $0 + ($1.value > 0x2E7F ? 2 : 1) }
        }
        let translated = tag.translatedName?.isEmpty == false ? tag.translatedName : nil
        return width(tag.name) + (translated.map { 1 + width($0) } ?? 0)
    }
}

/// 漫画系列 tab (`UserMangaSeriesFeedFragment`).
@MainActor
@Observable
final class UserIllustSeriesFeed {
    let userId: Int64
    var items: [IllustSeriesListItem] = []
    var nextUrl: String?
    var isLoading = false
    var errorMessage: String?

    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var isLoadingMore = false
    @ObservationIgnored private let api: PixivAPI

    init(userId: Int64) {
        self.userId = userId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async {
        guard !loaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let r = try await api.userIllustSeries(userId)
            items = r.illustSeriesDetails
            nextUrl = r.nextUrl
            loaded = true
        } catch { errorMessage = error.localizedDescription }
    }

    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let r: IllustSeriesListResponse = try? await api.nextPage(url) {
            items.append(contentsOf: r.illustSeriesDetails)
            nextUrl = r.nextUrl
        }
    }
}

/// 小说系列 tab (`UserNovelSeriesFeedFragment`).
@MainActor
@Observable
final class UserNovelSeriesFeed {
    let userId: Int64
    var items: [NovelSeriesListItem] = []
    var nextUrl: String?
    var isLoading = false
    var errorMessage: String?

    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var isLoadingMore = false
    @ObservationIgnored private let api: PixivAPI

    init(userId: Int64) {
        self.userId = userId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async {
        guard !loaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let r = try await api.userNovelSeries(userId)
            items = r.novelSeriesDetails
            nextUrl = r.nextUrl
            loaded = true
        } catch { errorMessage = error.localizedDescription }
    }

    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let r: NovelSeriesListResponse = try? await api.nextPage(url) {
            items.append(contentsOf: r.novelSeriesDetails)
            nextUrl = r.nextUrl
        }
    }
}

// MARK: - 插画 / 漫画 / 小说 tab (UserV3WorkTabFragment)

/// Tag filter bar pinned above the work list — it lives *inside* the tab page,
/// not in the app bar, so it swipes away with its own list.
struct UserV3WorkTab: View {
    let userId: Int64
    @Bindable var feed: UserWorksFeed
    /// Web-ajax path segment: "illusts" / "manga" / "novels".
    let category: String

    @State private var showTagSheet = false
    @State private var pickedTag: UserWorkTag?
    @State private var mute = MuteStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !feed.tagChips.isEmpty {
                V3TagFilterBar(
                    tags: feed.tagChips,
                    userId: userId,
                    category: category,
                    onAdvancedSearch: { showTagSheet = true }
                )
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }

            if feed.isNovelKind {
                if feed.novels.isEmpty {
                    V3TabPlaceholder(
                        isLoading: feed.isLoading, error: feed.errorMessage, style: .rows
                    ) { Task { await feed.load() } }
                } else {
                    NovelListContent(
                        novels: feed.novels,
                        hasMore: feed.nextUrl != nil,
                        onLoadMore: { await feed.loadMore() }
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            } else {
                let visible = mute.filter(feed.illusts)
                if visible.isEmpty {
                    V3TabPlaceholder(isLoading: feed.isLoading, error: feed.errorMessage) {
                        Task { await feed.load() }
                    }
                } else {
                    V3InlineIllustGrid(
                        illusts: visible,
                        hasMore: feed.nextUrl != nil,
                        onLoadMore: { await feed.loadMore() }
                    )
                }
            }
        }
        .task { await feed.loadIfNeeded() }
        .sheet(isPresented: $showTagSheet) {
            // A sheet has no stack of its own to push onto, so it reports the
            // pick and this page performs the navigation.
            UserTagSearchSheet(userId: userId, category: category) { pickedTag = $0 }
        }
        .navigationDestination(item: $pickedTag) { picked in
            UserIllustTagView(userId: userId, tag: picked.tag, category: category)
        }
    }
}

// MARK: - 收藏 tab (UserV3CollectionFragment)

/// Two segmented pills over one embedded list — the old header's two bookmark
/// entry points folded into a single tab.
struct UserV3CollectionTab: View {
    @Bindable var illustFeed: UserWorksFeed
    @Bindable var novelFeed: UserWorksFeed

    @State private var segment = 0     // 0 = 插画/漫画收藏, 1 = 小说收藏
    @State private var mute = MuteStore.shared
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                segmentPill(title: l10n.t(.userV3SegIllustBookmarks), index: 0)
                segmentPill(title: l10n.t(.userV3SegNovelBookmarks), index: 1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)

            if segment == 0 {
                let visible = mute.filter(illustFeed.illusts)
                if visible.isEmpty {
                    V3TabPlaceholder(
                        isLoading: illustFeed.isLoading, error: illustFeed.errorMessage
                    ) { Task { await illustFeed.load() } }
                } else {
                    V3InlineIllustGrid(
                        illusts: visible,
                        hasMore: illustFeed.nextUrl != nil,
                        onLoadMore: { await illustFeed.loadMore() }
                    )
                }
            } else {
                if novelFeed.novels.isEmpty {
                    V3TabPlaceholder(
                        isLoading: novelFeed.isLoading, error: novelFeed.errorMessage,
                        style: .rows
                    ) { Task { await novelFeed.load() } }
                } else {
                    NovelListContent(
                        novels: novelFeed.novels,
                        hasMore: novelFeed.nextUrl != nil,
                        onLoadMore: { await novelFeed.loadMore() }
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
        // Lazy like upstream: the segment's list only requests when the tab is
        // actually shown (never during the ViewPager's neighbour prefetch).
        .task(id: segment) {
            if segment == 0 { await illustFeed.loadIfNeeded() }
            else { await novelFeed.loadIfNeeded() }
        }
    }

    private func segmentPill(title: String, index: Int) -> some View {
        let active = segment == index
        return Button {
            segment = index
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                // `V3Palette.textSecondary`, same pair as the follow pill.
                .foregroundStyle(active ? Theme.v3Text1 : Theme.v3TextSecondary)
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background(
                    active ? AnyShapeStyle(Theme.brand)
                           : AnyShapeStyle(Theme.brand.opacity(0.20)),
                    in: .capsule
                )
                .overlay {
                    if !active {
                        Capsule().strokeBorder(Theme.brand.opacity(0.30), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 漫画系列 / 小说系列 tabs

struct UserV3IllustSeriesTab: View {
    @Bindable var feed: UserIllustSeriesFeed

    var body: some View {
        VStack(spacing: 0) {
            if feed.items.isEmpty {
                V3TabPlaceholder(
                    isLoading: feed.isLoading, error: feed.errorMessage, style: .rows
                ) { Task { await feed.loadIfNeeded() } }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(feed.items) { item in
                        if let sid = item.id {
                            NavigationLink(value: AppRoute.illustSeries(seriesId: sid)) {
                                V3SeriesRow(
                                    cover: item.coverImageUrls?.medium
                                        ?? item.coverImageUrls?.squareMedium,
                                    title: item.title ?? "",
                                    count: item.seriesWorkCount,
                                    caption: item.caption
                                )
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 84)
                        }
                    }
                    if feed.nextUrl != nil {
                        Color.clear.frame(height: 40)
                            .onAppear { Task { await feed.loadMore() } }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .task { await feed.loadIfNeeded() }
    }
}

struct UserV3NovelSeriesTab: View {
    @Bindable var feed: UserNovelSeriesFeed

    var body: some View {
        VStack(spacing: 0) {
            if feed.items.isEmpty {
                V3TabPlaceholder(
                    isLoading: feed.isLoading, error: feed.errorMessage, style: .rows
                ) { Task { await feed.loadIfNeeded() } }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(feed.items) { item in
                        if let sid = item.id {
                            NavigationLink(value: AppRoute.novelSeries(seriesId: sid)) {
                                V3SeriesRow(
                                    cover: nil,
                                    title: item.title ?? "",
                                    count: item.contentCount,
                                    caption: item.displayText
                                )
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 84)
                        }
                    }
                    if feed.nextUrl != nil {
                        Color.clear.frame(height: 40)
                            .onAppear { Task { await feed.loadMore() } }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .task { await feed.loadIfNeeded() }
    }
}

private struct V3SeriesRow: View {
    let cover: String?
    let title: String
    let count: Int?
    let caption: String?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let cover, let url = URL(string: cover) {
                    PixivAsyncImage(url: url)
                } else {
                    ZStack {
                        Rectangle().fill(Theme.v3Surface1)
                        Image(systemName: "books.vertical")
                            .foregroundStyle(Theme.v3Text3)
                    }
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(.rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.v3Text1)
                    .lineLimit(2)
                if let count {
                    Text("\(count)")
                        .font(.caption).foregroundStyle(Theme.v3Text3)
                }
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.caption2).foregroundStyle(Theme.v3Text3).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.v3Text3)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(.rect)
    }
}

// MARK: - Shared tab pieces

/// Empty / loading / error state for an embedded tab. Upstream feeds show a
/// skeleton while loading and 「居然啥也没有」 when a list really is empty.
struct V3TabPlaceholder: View {
    enum Style { case waterfall, rows }

    let isLoading: Bool
    let error: String?
    var style: Style = .waterfall
    let retry: () -> Void

    @State private var mute = MuteStore.shared
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        Group {
            if let error, !isLoading {
                InlineError(message: error) { retry() }
                    .padding()
            } else if isLoading {
                switch style {
                case .waterfall: WaterfallSkeleton(columns: mute.waterfallColumns)
                case .rows: NovelListSkeleton()
                }
            } else {
                Text(l10n.t(.userV3EmptyList))
                    .font(.footnote)
                    .foregroundStyle(Theme.v3Text3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
            }
        }
    }
}

/// Waterfall without its own `ScrollView` — the profile page keeps one outer
/// scroll view so the collapsing header can travel with any tab.
struct V3InlineIllustGrid: View {
    let illusts: [Illust]
    let hasMore: Bool
    let onLoadMore: () async -> Void

    @State private var mute = MuteStore.shared

    var body: some View {
        VStack(spacing: 0) {
            WaterfallGrid(
                items: illusts,
                columns: mute.waterfallColumns,
                spacing: 8,
                estimatedRelativeHeight: { $0.waterfallImageHeightRatio }
            ) { illust in
                NavigationLink(value: illust) {
                    IllustWaterfallCell(illust: illust)
                }
                .buttonStyle(.plain)
                .contextMenu { IllustCardMenuItems(illust: illust) { illusts } }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            if hasMore {
                Color.clear
                    .frame(height: 40)
                    .onAppear { Task { await onLoadMore() } }
            }
        }
        .cardMenuHost()
    }
}

// MARK: - Tag filter bar (V3TagFlowView, compact + 2 rows + action cell)

/// Compact chips (11.5pt, no `#` prefix) capped at exactly two rows, with a
/// permanent 「高级搜索」 cell at the end. Upstream measures flexbox lines
/// off-screen and drops what doesn't fit; `TwoRowChipLayout` does the same in
/// one layout pass.
struct V3TagFilterBar: View {
    let tags: [Tag]
    let userId: Int64
    let category: String
    let onAdvancedSearch: () -> Void

    @State private var appeared = false
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        TwoRowChipLayout(spacing: 6) {
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                NavigationLink(value: AppRoute.userIllustTag(
                    userId: userId, tag: tag.name ?? "", category: category
                )) {
                    chipLabel(text: chipText(tag), color: Theme.v3TagText)
                }
                .buttonStyle(.plain)
                .contextMenu { tagMenu(tag) }
            }
            // Always last, always laid out: the action cell reserves its slot
            // before any chip is dropped.
            Button(action: onAdvancedSearch) {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 11.5))
                    Text(l10n.t(.userV3AdvancedSearch))
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(Theme.v3TextAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.v3TagChipFill, in: .capsule)
                .overlay(Capsule().strokeBorder(Theme.v3TagChipBorder, lineWidth: 1 / UIScreen.main.scale))
            }
            .buttonStyle(.plain)
        }
        .opacity(appeared ? 1 : 0)
        // Upstream trims off-screen and then fades the finished bar in (250ms)
        // so no one sees seven rows of chips snap back to two.
        .onAppear { withAnimation(.easeIn(duration: 0.25)) { appeared = true } }
    }

    private func chipText(_ tag: Tag) -> String {
        var s = tag.name ?? ""
        if let t = tag.translatedName, !t.isEmpty { s += "  \(t)" }
        return s
    }

    private func chipLabel(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.v3TagChipFill, in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.v3TagChipBorder, lineWidth: 1 / UIScreen.main.scale))
    }

    /// Long-press menu from `V3TagFlowView.showTagActionMenu` minus the entries
    /// its host doesn't provide here (pin needs an `onPinTag` host, the synonym
    /// dictionary is a separate opt-in feature this app doesn't ship).
    @ViewBuilder
    private func tagMenu(_ tag: Tag) -> some View {
        let name = tag.name ?? ""
        Button {
            UIPasteboard.general.string = name
        } label: {
            Label(l10n.t(.userV3TagCopyOriginal), systemImage: "doc.on.doc")
        }
        if let t = tag.translatedName, !t.isEmpty {
            Button {
                UIPasteboard.general.string = t
            } label: {
                Label(l10n.t(.userV3TagCopyTranslation), systemImage: "doc.on.doc")
            }
        }
        let muted = MuteStore.shared.isTagMuted(name)
        Button(role: muted ? nil : .destructive) {
            MuteStore.shared.toggleTag(name)
        } label: {
            Label(muted ? l10n.t(.userV3TagUnmute) : l10n.t(.userV3TagMute),
                  systemImage: "eye.slash")
        }
    }
}

/// Flow layout hard-capped at two rows. The **last** subview is the action cell
/// and is always placed; chips that no longer fit once it is reserved are moved
/// far off-canvas instead of being drawn clipped in half.
struct TwoRowChipLayout: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat = 6) { self.spacing = spacing }

    private struct Plan {
        var rows: [[Int]] = []
        var height: CGFloat = 0
        var placed: Set<Int> = []
    }

    private func plan(_ subviews: Subviews, width: CGFloat) -> Plan {
        guard !subviews.isEmpty else { return Plan() }
        let actionIndex = subviews.count - 1
        let actionSize = subviews[actionIndex].sizeThatFits(.unspecified)

        var rows: [[Int]] = [[]]
        var rowWidths: [CGFloat] = [0]
        var rowHeights: [CGFloat] = [0]
        var placed = Set<Int>()

        func fits(_ w: CGFloat, in row: Int) -> Bool {
            let used = rowWidths[row]
            return used == 0 ? w <= width : used + spacing + w <= width
        }
        func append(_ index: Int, size: CGSize, row: Int) {
            rowWidths[row] += (rowWidths[row] == 0 ? 0 : spacing) + size.width
            rowHeights[row] = max(rowHeights[row], size.height)
            rows[row].append(index)
            placed.insert(index)
        }

        for index in 0..<actionIndex {
            let size = subviews[index].sizeThatFits(.unspecified)
            var row = rows.count - 1
            if !fits(size.width, in: row) {
                if row == 0 {
                    rows.append([]); rowWidths.append(0); rowHeights.append(0)
                    row = 1
                } else {
                    break   // two rows are full
                }
            }
            // Reserve room for the action cell on the last allowed row.
            if row == 1 {
                let after = rowWidths[row] + (rowWidths[row] == 0 ? 0 : spacing) + size.width
                if after + spacing + actionSize.width > width { break }
            }
            append(index, size: size, row: row)
        }

        // Place the action cell, opening a second row only if it is still free.
        var actionRow = rows.count - 1
        if !fits(actionSize.width, in: actionRow), actionRow == 0 {
            rows.append([]); rowWidths.append(0); rowHeights.append(0)
            actionRow = 1
        }
        append(actionIndex, size: actionSize, row: actionRow)

        var p = Plan()
        p.rows = rows
        p.placed = placed
        p.height = rowHeights.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * spacing
        return p
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let p = plan(subviews, width: width)
        return CGSize(width: width.isFinite ? width : 0, height: p.height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let p = plan(subviews, width: bounds.width)
        var y = bounds.minY
        for row in p.rows {
            var x = bounds.minX
            var rowHeight: CGFloat = 0
            for index in row {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
            y += rowHeight + spacing
        }
        // Everything that didn't fit goes far off-canvas — SwiftUI has no
        // "don't render this subview", and clipping them would show half chips.
        for index in subviews.indices where !p.placed.contains(index) {
            subviews[index].place(at: CGPoint(x: -10000, y: -10000), proposal: .zero)
        }
    }
}
