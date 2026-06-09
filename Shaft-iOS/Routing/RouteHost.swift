import SwiftUI

/// Single source of truth for the `.navigationDestination` registration.
/// Apply once at the top-level NavigationStack of every tab so any route
/// pushed onto its `path` resolves to the right view.
struct RouteHost: ViewModifier {
    let auth: AuthViewModel

    func body(content: Content) -> some View {
        content
            // Pushed pages hide the bottom tab bar — it belongs only to the tab
            // roots (推荐 / 发现 / 动态). It slides back in when you pop to a root.
            .navigationDestination(for: AppRoute.self) { route in
                destination(for: route)
                    .toolbar(.hidden, for: .tabBar)
            }
            // Value-based navigation: pushing a full `Illust` (from a waterfall /
            // ranking cell) seeds the detail view so it paints instantly. ID-only
            // entry points (links, history) still use `AppRoute.illustDetail`.
            .navigationDestination(for: Illust.self) { illust in
                IllustDetailView(illust: illust)
                    .toolbar(.hidden, for: .tabBar)
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
            case .ranking(let mode):
                RankingDetailView(initialMode: mode)
            case .search:
                SearchView()
            case .searchResults(let word):
                SearchResultsView(word: word)
            case .tagResults(let tag):
                SearchResultsView(word: tag)
            case .relatedIllusts(let id):
                RelatedIllustsView(illustId: id)
            case .userIllusts(let userId, let type):
                UserIllustsView(userId: userId, type: type)
            case .userBookmarks(let userId):
                UserBookmarksView(userId: userId)
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
                DownloadsView()
            case .mute:
                MutedView()
            case .settings:
                SettingsView()
            case .about:
                AboutView()
        }
    }
}

extension View {
    func registerRoutes(auth: AuthViewModel) -> some View {
        modifier(RouteHost(auth: auth))
    }
}
