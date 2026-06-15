import Foundation

/// All in-app navigation destinations. One enum, one place to add a new
/// route — see `RouteHost` for the destination registration.
enum AppRoute: Hashable, Codable, Sendable {
    case illustDetail(Int64)
    case novelDetail(Int64)
    case userProfile(Int64)
    case ranking(initialMode: String)
    case search
    case searchResults(word: String)
    case tagResults(tag: String)
    case relatedIllusts(illustId: Int64)
    case userIllusts(userId: Int64, type: String)
    case userIllustTag(userId: Int64, tag: String)
    case userBookmarks(userId: Int64)
    case userNovelBookmarks(userId: Int64)
    case userNovels(userId: Int64)
    case illustSeries(seriesId: Int64)
    case novelSeries(seriesId: Int64)
    case userFollowing(userId: Int64)
    case userFollower(userId: Int64)
    case userMyPixiv(userId: Int64)
    case userRelated(userId: Int64)
    case userIllustSeriesList(userId: Int64)
    case userNovelSeriesList(userId: Int64)
    case comments(target: CommentTarget)
    case spotlight
    case walkthrough
    case recommendUsers
    case latestWorks
    case mangaRecommend
    case novelRecommend
    case more
    case history
    case downloads
    case mute
    case settings
    case settingsSub(title: String)
    case about
    case notifications
    case notificationViewMore(notificationId: Int64, title: String)
    case infoCategory(categoryId: Int, title: String)
    case watchlist
    case novelMarkers
    case primeTags

    enum CommentTarget: Hashable, Codable, Sendable {
        case illust(Int64)
        case novel(Int64)
    }
}

/// Strict `pixiv://` deep-link resolver — only the three types upstream
/// `NotificationTargetRouter` handles (illusts/novels/users); anything else
/// returns nil so the caller stays inert instead of guessing. The search box
/// keeps using `PixivLinkParser`, which is intentionally fuzzier.
enum PixivDeepLink {
    static func route(for url: String?) -> AppRoute? {
        guard let url else { return nil }
        let pattern = #"^pixiv://(illusts|novels|users)/(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: url, range: NSRange(url.startIndex..<url.endIndex, in: url)),
              let typeRange = Range(m.range(at: 1), in: url),
              let idRange = Range(m.range(at: 2), in: url),
              let id = Int64(url[idRange]) else { return nil }
        switch url[typeRange].lowercased() {
        case "illusts": return .illustDetail(id)
        case "novels": return .novelDetail(id)
        case "users": return .userProfile(id)
        default: return nil
        }
    }
}
