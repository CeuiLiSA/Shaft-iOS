import SwiftUI

/// Single source of truth for the `.navigationDestination` registration.
/// Apply once at the top-level NavigationStack of every tab so any route
/// pushed onto its `path` resolves to the right view.
struct RouteHost: ViewModifier {
    let auth: AuthViewModel
    @State private var mirror = BookmarkMirrorObserved.shared

    func body(content: Content) -> some View {
        content
            // Pushed pages hide the bottom tab bar — it belongs only to the tab
            // roots (推荐 / 发现 / 动态). It slides back in when you pop to a root.
            .navigationDestination(for: AppRoute.self) { route in
                destination(for: route)
                    .toolbar(.hidden, for: .tabBar)
                    // Pages that hide the nav bar (detail/profile) lose UIKit's
                    // edge-swipe-back; this re-enables it. Inert elsewhere.
                    .background(SwipeBackEnabler())
            }
            // Value-based navigation: pushing a full `Illust` (from a waterfall /
            // ranking cell) seeds the detail view so it paints instantly. ID-only
            // entry points (links, history) still use `AppRoute.illustDetail`.
            .navigationDestination(for: Illust.self) { illust in
                IllustDetailView(illust: illust)
                    .toolbar(.hidden, for: .tabBar)
                    .background(SwipeBackEnabler())
            }
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
            case .illustDetail(let id):
                IllustDetailView(illustId: id)
            case .novelDetail(let id):
                NovelDetailView(novelId: id)
            case .userProfile(let id):
                UserProfileView(userId: id)
            case .ranking(let mode, let kind):
                RankingDetailView(initialMode: mode, kind: kind)
            case .search:
                SearchView()
            case .searchResults(let word, let section):
                SearchResultsView(word: word, initialSection: section)
            case .tagResults(let tag):
                SearchResultsView(word: tag)
            case .relatedIllusts(let id):
                RelatedIllustsView(illustId: id)
            case .userIllusts(let userId, let type):
                UserIllustsView(userId: userId, type: type)
            case .userIllustTag(let userId, let tag, let category):
                UserIllustTagView(userId: userId, tag: tag, category: category)
            case .userWorksJump(let userId, let type, let offset, let targetDate):
                UserWorksJumpListView(userId: userId, type: type, offset: offset, targetDate: targetDate)
            // 「我的插画收藏」有两种落点：本地镜像已经完整同步过一次 → 直接进本地库
            //（能倒序、能按标签/作者/年份筛，而服务端接口给不了这些）；还没同步完 → 原始列表。
            // `classic` 是本地库自己的「原始收藏列表」入口发来的，必须原样给老页面，
            // 否则用户从库里点进去会被立刻重定向回来，两个页面互相踢皮球。
            case .userBookmarks(let userId, let classic):
                if !classic, userId == BookmarkMirrorService.loggedInUid(), mirror.isMirrorReady(contentType: .illust) {
                    BookmarkLibraryView(contentType: .illust, restrict: .public)
                } else {
                    UserBookmarksView(userId: userId)
                }
            case .userNovelBookmarks(let userId, let classic):
                if !classic, userId == BookmarkMirrorService.loggedInUid(), mirror.isMirrorReady(contentType: .novel) {
                    BookmarkLibraryView(contentType: .novel, restrict: .public)
                } else {
                    UserNovelBookmarksView(userId: userId)
                }
            case .bookmarkLibrary(let contentType, let restrict):
                BookmarkLibraryView(
                    contentType: MirrorContentType.of(contentType) ?? .illust,
                    restrict: MirrorRestrict.ofApiValue(restrict)
                )
            case .userNovels(let userId):
                UserNovelsView(userId: userId)
            case .illustSeries(let seriesId):
                IllustSeriesView(seriesId: seriesId)
            case .novelSeries(let seriesId):
                NovelSeriesView(seriesId: seriesId)
            case .userFollowing(let userId):
                UserFollowingView(userId: userId)
            case .userFollower(let userId):
                UserFollowerView(userId: userId)
            case .userMyPixiv(let userId):
                UserMyPixivView(userId: userId)
            case .userRelated(let userId):
                UserRelatedView(userId: userId)
            case .userIllustSeriesList(let userId):
                UserIllustSeriesListView(userId: userId)
            case .userNovelSeriesList(let userId):
                UserNovelSeriesListView(userId: userId)
            case .comments(let target):
                CommentsView(target: target)
            case .spotlight:
                SpotlightView()
            case .walkthrough:
                WalkthroughView()
            case .recommendUsers:
                RecommendUsersView()
            case .latestWorks:
                LatestWorksView()
            case .mangaRecommend:
                MangaRecommendView()
            case .novelRecommend:
                NovelRecommendView()
            case .more:
                MoreView(auth: auth)
            case .history:
                HistoryView()
            case .downloads:
                DownloadManagerView()
            case .mute:
                MutedView()
            case .settings:
                SettingsView(auth: auth)
            case .settingsSub(let title):
                PlaceholderView(title: title, systemImage: "wrench.and.screwdriver")
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
            case .about:
                AboutView()
            case .notifications:
                NotificationsView()
            case .notificationViewMore(let id, let title):
                NotificationViewMoreView(notificationId: id, title: title)
            case .infoCategory(let cid, let title):
                InfoCategoryView(categoryId: cid, title: title)
            case .watchlist:
                WatchlistView()
            case .novelMarkers:
                NovelMarkersView()
            case .primeTags:
                PrimeTagsView()
            case .primeTagDetail(let file, let title):
                PrimeTagDetailView(file: file, title: title)
            case .pinnedTags:
                PinnedTagsView()
            case .watchLater:
                WatchLaterView()
            case .currentHot:
                RecentRecommendView()
            case .siteRecommend:
                SiteRecommendView()
            case .eventHistory:
                EventHistoryView()
            case .webArticle(let urlString):
                if let url = URL(string: urlString) {
                    WebArticleView(url: url)
                } else {
                    PlaceholderView(title: urlString, systemImage: "link")
                }
            case .niceFriendWorks:
                NiceFriendIllustsView()
            case .followingNovels:
                FollowingNovelsView()
            // Discover "其他分类" entries whose upstream pages (shaft-api-v2 榜单 /
            // pixiv 漫画 / 算法发现流) are not ported yet — placeholder until then.
            case .artistRank(let mode):
                ArtistRankView(mode: mode)
            case .viewRank:
                ViewRankView()
            case .pixivComic:
                DiscoverPendingView(titleKey: .pixivComic)
            case .bookmarkRank(let aiOnly):
                BookmarkRankView(ai: aiOnly ? "only" : nil)
            case .yearRank:
                YearRankView()
            case .tagRank:
                TagRankView()
            case .wallpaperRank:
                WallpaperRankView()
            case .seriesRank:
                SeriesRankView()
            case .monthRank:
                MonthRankView()
            case .novelLengthRank:
                NovelLengthRankView()
            case .sfwRank:
                BookmarkRankView(restrict: "sfw")
            case .trendingArtists:
                TrendingArtistsView()
            case .ugoiraRank:
                UgoiraRankView()
            case .discoveryFeed:
                DiscoverPendingView(titleKey: .discoveryFeed)
            case .chatRoomList:
                ChatRoomListView()
            case .chatThread(let peerUid, let title):
                ChatThreadView(peerUid: peerUid, peerTitle: title)
        }
    }
}

extension View {
    func registerRoutes(auth: AuthViewModel) -> some View {
        modifier(RouteHost(auth: auth))
    }
}
