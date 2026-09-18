import SwiftUI

// MARK: - View model — 1:1 ceui.pixiv.ui.discovery.DiscoverViewModel

/// Data holder for the Discover tab shelves (upstream `DiscoverViewModel`):
///   · `primeTags`     热度标签 — local curated `prime_index.json`, shuffled, 15
///   · `latest`        最新     — `/v1/illust/new` (全站新投稿), 12
///   · `siteRecommend` 本月收藏 — shaft-api-v2 `/discover` `site` shelf, 12
///   · `recentHot`     当前最热 — shaft-api-v2 `/discover` `recent` shelf, 12
///   · `pivision`      特辑     — pixivision `category=illust`, single page
/// Each rail is `nil` until its first result lands (skeleton shown); `[]` means
/// loaded-empty / failed → the section collapses (upstream `View.GONE`). Data
/// lives here so tab switches don't refetch (`started` gate).
@MainActor
@Observable
final class DiscoverViewModel {
    var primeTags: [PrimeTag]?
    var latest: [Illust]?
    var recentHot: [Illust]?
    var siteRecommend: [Illust]?
    var pivision: [Article]?

    @ObservationIgnored private var started = false
    @ObservationIgnored private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    @ObservationIgnored private let v2 = ShaftApiV2Client.shared

    static let railLimit = 12
    static let tagLimit = 15

    /// First appearance only — subsequent tab switches are no-ops.
    func start() async {
        if started { return }
        started = true
        await reload()
    }

    /// forceRefresh: refetch every shelf (existing content stays until replaced).
    func reload() async {
        async let tags: Void = loadTags()
        async let latestRail: Void = loadLatest()
        async let discover: Void = loadDiscover()
        async let pv: Void = loadPivision()
        _ = await (tags, latestRail, discover, pv)
    }

    private func loadTags() async {
        // Random pick per VM construction — not re-shuffled on tab switches.
        primeTags = Array(PrimeTagsStore.all.shuffled().prefix(Self.tagLimit))
    }

    private func loadLatest() async {
        // Failure collapses silently (no toast for a background shelf).
        let r = try? await api.latestIllusts(type: "illust")
        latest = Array((r?.illusts ?? []).filter { $0.user != nil }.prefix(Self.railLimit))
    }

    private func loadDiscover() async {
        // One aggregate call for both shaft-api-v2 shelves; failure empties both.
        let r = try? await v2.discover(limit: Self.railLimit)
        siteRecommend = r?.site ?? []
        recentHot = r?.recent ?? []
    }

    private func loadPivision() async {
        let r = try? await api.spotlightArticles(category: "illust")
        pivision = r?.spotlightArticles ?? []
    }
}

// MARK: - Discover tab — 1:1 FragmentCenter / fragment_new_center.xml

/// 「发现」tab, V3 content-shelf version. Order (as in the XML):
/// 漫画/小说 big cards → pixivision 特辑 → 热度标签 → 最新 → 当前最热 → 本月收藏 → 其他分类 chips → 交流与分享.
/// The header row (drawer / title / search) is the host `HomeView` nav bar, as
/// on the 推荐 tab. Pull-to-refresh stands in for upstream's double-tap
/// `forceRefresh` (the only refresh affordance iOS tabs have).
struct DiscoverView: View {
    @State private var vm = DiscoverViewModel()
    @State private var showWebHomeComingSoon = false
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.pushRoute) private var pushRoute

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                bigModules

                PivisionRailSection(articles: vm.pivision)

                if vm.primeTags?.isEmpty != true {
                    TagRailSection(tags: vm.primeTags)
                }
                if vm.latest?.isEmpty != true {
                    IllustRailSection(title: l10n.t(.discoverLatest), illusts: vm.latest, more: .latestWorks)
                }
                if vm.recentHot?.isEmpty != true {
                    IllustRailSection(title: l10n.t(.currentHot), illusts: vm.recentHot, more: .currentHot)
                }
                if vm.siteRecommend?.isEmpty != true {
                    IllustRailSection(title: l10n.t(.siteRecommend), illusts: vm.siteRecommend, more: .siteRecommend)
                }

                otherCategories

                DiscoverSocialSection(onChat: { pushRoute(.chatRoomList) }, onCommunity: { pushRoute(.plaza) })
            }
            // NestedScrollView paddingBottom=24 (clipToPadding=false → just scroll slack).
            .padding(.bottom, 24)
        }
        .background(Theme.v3Bg)
        // Keep the bottom safe area: the last chips must scroll fully clear of
        // the tab bar (upstream's bottom nav is opaque and never overlaps content).
        .refreshable { await vm.reload() }
        .task { await vm.start() }
        // catWeb → WitDialog "Web 首页 / Coming soon... / OK" (github channel placeholder).
        .alert(l10n.t(.webHome), isPresented: $showWebHomeComingSoon) {
            Button("OK") {}
        } message: {
            Text("Coming soon...")
        }
    }

    // MARK: 重点模块：漫画 / 小说 (bigManga / bigNovel)

    private var bigModules: some View {
        HStack(alignment: .top, spacing: 12) {
            BigModuleCard(
                title: l10n.t(.discoverTypeManga),
                subtitle: l10n.t(.discoverRecommendManga),
                systemImage: "paintpalette.fill",
                route: .mangaRecommend
            )
            BigModuleCard(
                title: l10n.t(.discoverTypeNovel),
                subtitle: l10n.t(.discoverRecommendNovel),
                systemImage: "book.fill",
                route: .novelRecommend
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    // MARK: 其他分类 (FlexboxLayout of chips)

    private var otherCategories: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(l10n.t(.discoverOtherCategories))
                .font(.system(size: 13, weight: .bold))
                .tracking(13 * 0.06)
                .foregroundStyle(Theme.v3Text2)
                .padding(.leading, 20)
                .padding(.top, 24)
                .padding(.bottom, 12)

            FlowLayout(spacing: 9) {
                chip(.discoverWalkThrough, "photo.on.rectangle", .walkthrough)
                chip(.artistRank, "person.fill", .artistRank(mode: "total"))
                chip(.artistAvgRank, "star.fill", .artistRank(mode: "avg"))
                chip(.viewRank, "eye.fill", .viewRank)
                // catPixivComic is the one chip FragmentCenter does NOT restyle —
                // it keeps the plain bg_v3_chip look (no icon, surface fill).
                NavigationLink(value: AppRoute.pixivComic) {
                    PlainCategoryChip(title: l10n.t(.pixivComic))
                }
                .buttonStyle(PressScaleStyle())
                chip(.bookmarkRank, "heart.fill", .bookmarkRank(aiOnly: false))
                chip(.aiRank, "sparkles", .bookmarkRank(aiOnly: true))
                chip(.yearRank, "calendar", .yearRank)
                chip(.tagRank, "tag.fill", .tagRank)
                chip(.wallpaperRank, "photo.fill", .wallpaperRank)
                chip(.seriesRank, "list.bullet.rectangle", .seriesRank)
                chip(.monthRank, "sparkles.rectangle.stack", .monthRank)
                chip(.novelLengthRank, "book.fill", .novelLengthRank)
                chip(.sfwRank, "checkmark.circle.fill", .sfwRank)
                chip(.trendingArtists, "flame.fill", .trendingArtists)
                chip(.ugoiraRank, "play.fill", .ugoiraRank)
                chip(.followingNovels, "bookmark.fill", .followingNovels)
                chip(.discoveryFeed, "safari.fill", .discoveryFeed)
                Button {
                    showWebHomeComingSoon = true
                } label: {
                    CategoryChip(title: l10n.t(.webHome), systemImage: "globe")
                }
                .buttonStyle(PressScaleStyle())
                chip(.niceFriendWorks, "person.crop.circle.badge.checkmark", .niceFriendWorks)
            }
            .padding(.horizontal, 20)
        }
    }

    private func chip(_ key: LocalizedKey, _ systemImage: String, _ route: AppRoute) -> some View {
        NavigationLink(value: route) {
            CategoryChip(title: l10n.t(key), systemImage: systemImage)
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - Press feedback (animator/button_press_scale / button_press_alpha)

/// `button_press_scale`: scale to 0.95 while pressed (config_shortAnimTime).
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
}

/// `button_press_alpha`: alpha to 0.3 while pressed.
struct PressAlphaStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.3 : 1)
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - 漫画 / 小说 big card (bigManga / bigNovel + styleBigModule)

/// 42dp icon square (`seriesIconBg`: brand → hue+40° BL→TR, r12) + 16sp bold
/// title + 11sp subtitle, padding 14, card bg `seriesStripBg` (brand@35% →
/// hue+25°@30% BL→TR, 1px brand@15% stroke, r18).
private struct BigModuleCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let route: AppRoute
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Theme.brand, Theme.brand.hueShifted(40)],
                            startPoint: .bottomLeading, endPoint: .topTrailing
                        ))
                    Image(systemName: systemImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .foregroundStyle(.white)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.v3Text1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.v3Text2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Theme.brand.opacity(0.35), Theme.brand.hueShifted(25).opacity(0.30)],
                        startPoint: .bottomLeading, endPoint: .topTrailing
                    ))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.brand.opacity(0.15), lineWidth: 1 / displayScale)
            )
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - Shelf header (title + 查看全部 ›)

private struct RailHeader: View {
    let title: String
    let more: AppRoute
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .tracking(17 * 0.01)
                .foregroundStyle(Theme.v3Text1)
                .frame(maxWidth: .infinity, alignment: .leading)
            NavigationLink(value: more) {
                MoreLabel(title: l10n.t(.discoverViewAll))
            }
            .buttonStyle(PressAlphaStyle())
        }
        .padding(.leading, 20)
        .padding(.top, 24)
        .padding(.trailing, 16)
        .padding(.bottom, 12)
    }
}

/// 13sp `?attr/colorPrimary` text + `ic_chevron_right_black_24dp` drawableEnd.
private struct MoreLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 0) {
            Text(title).font(.system(size: 13))
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .foregroundStyle(Theme.brand)
    }
}

// MARK: - Horizontal rail container (RecyclerView: paddingStart 20 / end 8, 12dp gaps)

private struct Rail<Content: View>: View {
    let height: CGFloat
    /// `true` once real data is bound — drives the skeleton → content crossfade
    /// (upstream `crossfadeSwap`: fade out 140ms, swap, fade in 240ms).
    let loaded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal) {
            // Lazy like the RecyclerView it mirrors: cards (and their image
            // loads) materialize as they scroll in, not all 12–15 per rail at once.
            LazyHStack(spacing: 12, content: content)
                .padding(.leading, 20)
                .padding(.trailing, 8)
        }
        .scrollIndicators(.hidden)
        .frame(height: height)
        .animation(.easeInOut(duration: 0.24), value: loaded)
    }
}

/// `recy_skeleton_card`: v3_surface_2 r16 block + shimmer, full rail height.
private struct RailSkeletonCards: View {
    let count: Int
    let width: CGFloat
    var corner: CGFloat = 16

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Theme.v3Surface2)
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
            }
        }
        .shimmering()
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// `bg_v3_card_scrim`: bottom #B3000000 → center #40000000 → top transparent.
private struct CardScrim: View {
    let height: CGFloat
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(179 / 255), location: 0),
                .init(color: .black.opacity(64 / 255), location: 0.5),
                .init(color: .clear, location: 1),
            ],
            startPoint: .bottom, endPoint: .top
        )
        .frame(height: height)
    }
}

// MARK: - 热度标签 shelf (tagSection + DiscoverTagAdapter / recy_discover_tag)

private struct TagRailSection: View {
    let tags: [PrimeTag]?
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            RailHeader(title: l10n.t(.primeTagsTitle), more: .primeTags)
            Rail(height: 120, loaded: tags != nil) {
                if let tags {
                    ForEach(tags) { tag in
                        TagRailCard(tag: tag).transition(.opacity)
                    }
                } else {
                    RailSkeletonCards(count: 6, width: 120)
                }
            }
        }
    }
}

/// 120dp square: cover (`preview_square_urls[0]`) + 72dp bottom scrim + 13sp bold
/// white name (translated first), 2 lines, padding 10/9. Tap → PrimeTagDetail.
private struct TagRailCard: View {
    let tag: PrimeTag

    var body: some View {
        NavigationLink(value: AppRoute.primeTagDetail(file: tag.filePath, title: tag.translatedName)) {
            ZStack(alignment: .bottom) {
                PixivAsyncImage(url: coverURL, showsProgress: false, placeholder: Theme.v3Surface2)
                CardScrim(height: 72)
                Text(tag.translatedName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 9)
            }
            .frame(width: 120, height: 120)
            .background(Theme.v3Surface2)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var coverURL: URL? {
        tag.previewSquareUrls.first.flatMap(URL.init(string:))
    }
}

// MARK: - Illust shelf (latest / recent / site + RAdapter / recy_rank_illust_horizontal)

private struct IllustRailSection: View {
    let title: String
    let illusts: [Illust]?
    let more: AppRoute

    var body: some View {
        VStack(spacing: 0) {
            RailHeader(title: title, more: more)
            Rail(height: 180, loaded: illusts != nil) {
                if let illusts {
                    ForEach(illusts) { illust in
                        IllustRailCard(illust: illust).transition(.opacity)
                    }
                } else {
                    RailSkeletonCards(count: 4, width: 180)
                }
            }
        }
    }
}

/// V3 ranking hero card, 180dp square r16: `large` cover + 96dp bottom scrim,
/// 14sp bold white title (1 line) over 20dp avatar + 11sp #E6FFFFFF author.
private struct IllustRailCard: View {
    let illust: Illust

    var body: some View {
        NavigationLink(value: illust) {
            ZStack(alignment: .bottom) {
                PixivAsyncImage(url: coverURL, showsProgress: false, placeholder: Theme.v3Surface2)
                CardScrim(height: 96)
                VStack(alignment: .leading, spacing: 5) {
                    Text(illust.title ?? "")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        PixivAsyncImage(url: avatarURL, showsProgress: false, placeholder: Theme.lightBg)
                            .frame(width: 20, height: 20)
                            .clipShape(Circle())
                        Text(illust.user?.name ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(230 / 255))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
            }
            .frame(width: 180, height: 180)
            .background(Theme.v3Surface2)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var coverURL: URL? {
        // GlideUtil.getLargeImage — large (600x1200_90) reads sharper at 180dp.
        (illust.imageUrls?.large ?? illust.imageUrls?.medium).flatMap(URL.init(string:))
    }

    private var avatarURL: URL? {
        illust.user?.profileImageUrls?.medium.flatMap(URL.init(string:))
    }
}

// MARK: - pixivision 特辑 shelf (PivisionRailFeedFragment / fragment_pivision_rail_feed)

/// Header = pixivision logo (99x24, marginStart 20 / top 24) + 「查看更多 ›」
/// bottom-aligned to the logo (marginEnd 20 / bottom 2); rail 160dp tall,
/// marginTop 12, single page (`category=illust`).
private struct PivisionRailSection: View {
    let articles: [Article]?
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 16) {
                Image("pixivision_logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 99, height: 24)
                Spacer(minLength: 0)
                NavigationLink(value: AppRoute.spotlight) {
                    MoreLabel(title: l10n.t(.discoverSeeMore))
                }
                .buttonStyle(PressAlphaStyle())
                .padding(.bottom, 2)
            }
            .padding(.leading, 20)
            .padding(.top, 24)
            .padding(.trailing, 20)

            Rail(height: 160, loaded: articles != nil) {
                if let articles {
                    ForEach(articles) { article in
                        PivisionRailCard(article: article).transition(.opacity)
                    }
                } else {
                    // FeedArticleRailSkeletonView: whole-card 220x160 r20 blocks.
                    RailSkeletonCards(count: 3, width: 220, corner: 20)
                }
            }
            .padding(.top, 12)
        }
    }
}

/// `cell_pivision_rail` 220x160: cover over `settingsCardBg` (cardFill + 1dp
/// hairline, r20), `bg_request_cover_scrim`, tonal category pill top-left
/// (pillPrimary / floatingPillContent, Montserrat SemiBold 10.5), Montserrat Bold
/// 13 white title bottom (2 lines, shadow). Tap → article web page.
private struct PivisionRailCard: View {
    let article: Article

    var body: some View {
        Group {
            if let url = article.articleUrl, !url.isEmpty {
                NavigationLink(value: AppRoute.webArticle(url: url)) { card }
            } else {
                card
            }
        }
        .buttonStyle(PressScaleStyle())
    }

    private var card: some View {
        ZStack(alignment: .bottomLeading) {
            PixivAsyncImage(url: coverURL, showsProgress: false, placeholder: Theme.lightBg)
            // bg_request_cover_scrim: top transparent → center #22000000 → bottom #CC000000
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(34 / 255), location: 0.5),
                    .init(color: .black.opacity(204 / 255), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            Text(article.title ?? "")
                .font(.montserratBold(13))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .shadow(color: .black.opacity(179 / 255), radius: 3, x: 0, y: 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .overlay(alignment: .topLeading) {
            if let label = article.subcategoryLabel, !label.isEmpty {
                Text(label)
                    .font(.montserratSemiBold(10.5))
                    .tracking(10.5 * 0.02)
                    .foregroundStyle(Theme.v3FloatingPillContent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.brand, in: Capsule())
                    .padding(10)
            }
        }
        .frame(width: 220, height: 160)
        .background(Theme.v3CardFill)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.v3CardHairline, lineWidth: 1)
        )
    }

    private var coverURL: URL? {
        article.thumbnail.flatMap(URL.init(string:))
    }
}

// MARK: - 其他分类 chips (styleCatChip / bg_v3_chip)

/// `styleCatChip`: `pillSecondary` (brand@20% fill + 1dp brand@30% stroke, r14),
/// `textAccent` 13sp, 17dp leading icon (drawablePadding 7), padding 16/10.
private struct CategoryChip: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 17, height: 17)
            Text(title)
                .font(.system(size: 13))
        }
        .foregroundStyle(Theme.v3TextAccent)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.brand.opacity(0.20))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.brand.opacity(0.30), lineWidth: 1)
        )
        .contentShape(.rect)
    }
}

/// Unstyled `bg_v3_chip` (v3_surface_1 fill, 0.5dp v3_border_1 stroke, r14),
/// v3_text_1 13sp, padding 15/9 — only `catPixivComic` keeps this look.
private struct PlainCategoryChip: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13))
            .foregroundStyle(Theme.v3Text1)
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.v3Surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.v3Border1, lineWidth: 0.5)
            )
            .contentShape(.rect)
    }
}
