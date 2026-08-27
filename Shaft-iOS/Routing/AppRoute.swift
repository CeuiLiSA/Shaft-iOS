import Foundation

/// All in-app navigation destinations. One enum, one place to add a new
/// route — see `RouteHost` for the destination registration.
enum AppRoute: Hashable, Codable, Sendable {
    case illustDetail(Int64)
    case novelDetail(Int64)
    case userProfile(Int64)
    /// `kind` = "illust" / "manga" / "novel" — which ranking board opens
    /// (upstream `RankActivity` `dataType` 插画/漫画/小说). Mode strings overlap
    /// between illust and novel boards ("day"), so the kind must be explicit.
    case ranking(initialMode: String, kind: String = "illust")
    case search
    /// `section` = "illust" / "novel" / "user" — the tab shown first (upstream
    /// `SearchActivity` `Params.INDEX`).
    case searchResults(word: String, section: String = "illust")
    case tagResults(tag: String)
    case relatedIllusts(illustId: Int64)
    case userIllusts(userId: Int64, type: String)
    /// Works of one author filtered by a tag. `category` is the upstream web
    /// ajax path segment — "illusts" / "manga" / "novels" (`UserTagSearchSheet`).
    case userIllustTag(userId: Int64, tag: String, category: String)
    /// A user's illust/manga/novel list opened at an arbitrary page offset —
    /// the 「跳转到…」 entry (upstream `UserIllustJumpHelper`).
    case userWorksJump(userId: Int64, type: String, offset: Int, targetDate: String?)
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
    case primeTagDetail(file: String, title: String)
    case pinnedTags
    case watchLater
    // shaft-api-v2 self-hosted feeds
    case currentHot
    case siteRecommend
    case eventHistory
    /// Discover tab (FragmentCenter) destinations
    case webArticle(url: String)
    case niceFriendWorks
    case followingNovels
    case artistRank(mode: String)        // "total" 画师榜 / "avg" 画师均分榜
    case viewRank
    case pixivComic
    case bookmarkRank(aiOnly: Bool)      // 收藏榜 / AI榜
    case yearRank
    case tagRank
    case wallpaperRank
    case discoveryFeed
    // 聊天室 (shaft-api-v2 chat)
    /// Conversation list — the 聊天室 drawer entry.
    case chatRoomList
    /// One thread's message list. `peerUid == nil` is the public 公屏闲聊 room;
    /// non-nil is a 1v1 DM with that pixiv uid.
    case chatThread(peerUid: Int64?, title: String?)

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
