import Foundation
import CryptoKit
import os

/// App-wide API request logger. Every Pixiv API call funnels through
/// `PixivAPI.perform` / `novelText`, so logging there records exactly one line
/// per network request — image loads go through `PixivImageCache`, not here, so
/// they're excluded by construction. Stream from a booted simulator with:
///   xcrun simctl spawn booted log stream --predicate \
///     'subsystem == "com.shaft.ShaftiOS" AND category == "API"' --style compact
let apiLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Shaft-iOS", category: "API")

protocol PixivTokenProvider: Sendable {
    func currentAccessToken() async -> String?
    func refreshAccessToken() async -> String?
}

actor PixivAPI {
    static let baseURL = URL(string: "https://app-api.pixiv.net")!
    private static let hashSecret = "28c1fdd170a5204386cb1313c7077b34f83e4aaf4aa829ce78c231e05b0bae2c"

    private let session: URLSession
    private let tokenProvider: any PixivTokenProvider
    /// Snapshotted with the session: when set, outgoing requests are rewritten
    /// host→IP and the session validates the resulting cert against the real
    /// host (see `DirectConnection`). Never on for an injected (test) session.
    private let directConnect: Bool

    init(
        tokenProvider: any PixivTokenProvider,
        session: URLSession? = nil
    ) {
        self.tokenProvider = tokenProvider
        self.directConnect = (session == nil) && DirectConnection.isEnabled
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 10
            cfg.timeoutIntervalForResource = 30
            self.session = directConnect ? DirectConnection.makeSession(cfg)
                                         : URLSession(configuration: cfg)
        }
    }

    /// Direct-connect-aware send: HTTP/3 for Cloudflare-fronted API hosts,
    /// host→IP-rewritten URLSession otherwise — a no-op when not in that mode.
    private func fetch(_ req: URLRequest) async throws -> (Data, URLResponse) {
        try await DirectConnection.data(for: req, using: session, directConnect: directConnect)
    }

    static func make(tokenProvider: any PixivTokenProvider) -> PixivAPI {
        PixivAPI(tokenProvider: tokenProvider)
    }

    enum APIError: Error, LocalizedError {
        case noToken
        case http(code: Int, body: String)
        case nonHTTP
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .noToken: return "Not signed in"
            case .http(let c, let b): return "HTTP \(c): \(b)"
            case .nonHTTP: return "Non-HTTP response"
            case .decoding(let m): return "Decoding failed: \(m)"
            }
        }
    }

    // MARK: Endpoints

    func recommendedIllusts(type: String = "illust") async throws -> HomeIllustResponse {
        try await get(path: "/v1/\(type)/recommended", query: [
            "include_ranking_illusts": "false",
            "include_privacy_policy": "true",
            "filter": "for_ios",
        ])
    }

    /// 1:1 with upstream `API.getRecommendedWorksWithRanking(type)` — the
    /// first page carries `ranking_illusts` for the horizontal ranking preview
    /// header (`RecmdIllustFeedFragment`). `type` is `illust` or `manga`.
    func recommendedWorksWithRanking(type: String) async throws -> HomeIllustResponse {
        try await get(path: "/v1/\(type)/recommended", query: [
            "include_ranking_illusts": "true",
            "include_privacy_policy": "true",
            "filter": "for_ios",
        ])
    }

    func recommendedManga() async throws -> HomeIllustResponse {
        try await get(path: "/v1/manga/recommended", query: [
            "include_ranking_illusts": "false",
            "include_privacy_policy": "true",
            "filter": "for_ios",
        ])
    }

    func trendingTags(type: String = "illust") async throws -> TrendingTagsResponse {
        try await get(path: "/v1/trending-tags/\(type)", query: ["filter": "for_ios"])
    }

    /// `mode` accepts `day`, `week`, `month`, `day_male`, `day_female`,
    /// `day_manga`, etc. — see Shaft `RankingIllustsFragment`.
    /// `date` (optional, `yyyy-MM-dd`) requests a past ranking — parity with
    /// upstream `RankActivity`'s date picker (`getRank(mode, date)`). Omitted →
    /// the latest published ranking.
    func rankingIllusts(mode: String = "day", date: String? = nil) async throws -> IllustResponse {
        var query = ["mode": mode, "filter": "for_ios"]
        if let date { query["date"] = date }
        return try await get(path: "/v1/illust/ranking", query: query)
    }

    /// Novel ranking. `mode` accepts `day`, `week`, `day_male`, `day_female`,
    /// `week_rookie`, `day_r18` — see Shaft `FragmentRankNovel`. `date` as above.
    func rankingNovels(mode: String = "day", date: String? = nil) async throws -> NovelResponse {
        var query = ["mode": mode, "filter": "for_ios"]
        if let date { query["date"] = date }
        return try await get(path: "/v1/novel/ranking", query: query)
    }

    func walkthroughIllusts() async throws -> IllustResponse {
        try await get(path: "/v1/walkthrough/illusts")
    }

    func newIllustsFromFollowing(restrict: String = "public") async throws -> IllustResponse {
        try await get(path: "/v2/illust/follow", query: [
            "restrict": restrict,
            "filter": "for_ios",
        ])
    }

    func newNovelsFromFollowing(restrict: String = "public") async throws -> NovelResponse {
        try await get(path: "/v1/novel/follow", query: ["restrict": restrict])
    }

    func spotlightArticles(category: String = "all") async throws -> ArticlesResponse {
        try await get(path: "/v1/spotlight/articles", query: ["category": category])
    }

    // MARK: Detail

    func illustDetail(_ illustId: Int64) async throws -> IllustDetailResponse {
        try await get(path: "/v1/illust/detail", query: ["illust_id": "\(illustId)"])
    }

    func relatedIllusts(_ illustId: Int64) async throws -> IllustResponse {
        try await get(path: "/v2/illust/related", query: ["illust_id": "\(illustId)"])
    }

    /// Animated-illust (ugoira) frame manifest: zip URLs + per-frame delays.
    func ugoiraMetadata(_ illustId: Int64) async throws -> UgoiraMetadataResponse {
        try await get(path: "/v1/ugoira/metadata", query: ["illust_id": "\(illustId)"])
    }

    /// Existing bookmark state for an illust — registered tags + visibility.
    func illustBookmarkDetail(_ illustId: Int64) async throws -> BookmarkDetailResponse {
        try await get(path: "/v2/illust/bookmark/detail", query: ["illust_id": "\(illustId)"])
    }

    /// Existing bookmark state for a novel — registered tags + visibility.
    func novelBookmarkDetail(_ novelId: Int64) async throws -> BookmarkDetailResponse {
        try await get(path: "/v2/novel/bookmark/detail", query: ["novel_id": "\(novelId)"])
    }

    func illustComments(_ illustId: Int64) async throws -> CommentsResponse {
        try await get(path: "/v3/illust/comments", query: ["illust_id": "\(illustId)"])
    }

    func novelDetail(_ novelId: Int64) async throws -> NovelDetailResponse {
        try await get(path: "/v2/novel/detail", query: ["novel_id": "\(novelId)"])
    }

    func novelComments(_ novelId: Int64) async throws -> CommentsResponse {
        try await get(path: "/v3/novel/comments", query: ["novel_id": "\(novelId)"])
    }

    func illustCommentReplies(_ commentId: Int64) async throws -> CommentsResponse {
        try await get(path: "/v1/illust/comment/replies", query: [
            "comment_id": "\(commentId)",
        ])
    }

    func novelCommentReplies(_ commentId: Int64) async throws -> CommentsResponse {
        try await get(path: "/v1/novel/comment/replies", query: [
            "comment_id": "\(commentId)",
        ])
    }

    func recommendedNovels() async throws -> NovelResponse {
        try await get(path: "/v1/novel/recommended", query: [
            "include_ranking_illusts": "false",
        ])
    }

    /// 1:1 with upstream `API.getRecommendedNovelsWithRanking()` — first page
    /// carries `ranking_novels` for the ranking preview header
    /// (`RecmdNovelFeedFragment`).
    func recommendedNovelsWithRanking() async throws -> NovelRecommendResponse {
        try await get(path: "/v1/novel/recommended", query: [
            "include_privacy_policy": "true",
            "filter": "for_ios",
            "include_ranking_novels": "true",
        ])
    }

    // MARK: User

    /// `v2` + `filter=for_ios`, matching upstream `AppApi.getUserDetailV2`: same
    /// shape as v1 plus `is_accept_request` / `badge` / `disabled_links` on the
    /// user object (v1 was deleted upstream, everything goes through v2).
    func userDetail(_ userId: Int64) async throws -> UserDetailResponse {
        let response: UserDetailResponse = try await get(path: "/v2/user/detail", query: [
            "user_id": "\(userId)",
            "filter": "for_ios",
        ])
        // Any real self-detail read refreshes the borrow pool's authoritative
        // membership observation, not only reads initiated from the search UI.
        if KeychainTokenStore.shared.load()?.user?.id == userId,
           let premium = response.profile?.isPremium {
            await PremiumObservationClock.shared.record(uid: userId)
            Task {
                await CurrentAccountOnlineReporter.report(uid: userId, isPremium: premium)
            }
        }
        return response
    }

    func userIllusts(_ userId: Int64, type: String = "illust") async throws -> IllustResponse {
        try await get(path: "/v1/user/illusts", query: [
            "user_id": "\(userId)",
            "type": type,
            "filter": "for_ios",
        ])
    }

    /// Same list starting at an arbitrary `offset` — the "跳转到插画…" entry point
    /// (upstream `UserIllustJumpHelper` / `buildOffsetUrl`). pixiv accepts any
    /// offset on this endpoint.
    func userIllusts(_ userId: Int64, type: String, offset: Int) async throws -> IllustResponse {
        try await get(path: "/v1/user/illusts", query: [
            "user_id": "\(userId)",
            "type": type,
            "filter": "for_ios",
            "offset": "\(offset)",
        ])
    }

    func userNovels(_ userId: Int64, offset: Int) async throws -> NovelResponse {
        try await get(path: "/v1/user/novels", query: [
            "user_id": "\(userId)",
            "offset": "\(offset)",
        ])
    }

    /// `is_followed` only says *whether*; this says *how* (public vs private),
    /// which the header pill needs to show 「悄悄关注中」 (upstream
    /// `AppApi.getFollowDetail` + `followRestrictOf`).
    func userFollowDetail(_ userId: Int64) async throws -> UserFollowDetailResponse {
        try await get(path: "/v1/user/follow/detail", query: ["user_id": "\(userId)"])
    }

    /// Commission plans, shown as the 约稿中 tab when `is_accept_request` is set.
    /// Single page, no `next_url` (upstream `getUserRequestPlans`).
    func userRequestPlans(_ userId: Int64) async throws -> UserRequestPlansResponse {
        try await get(path: "/v1/user/request-plans", query: ["user_id": "\(userId)"])
    }

    func userBookmarkedIllusts(
        _ userId: Int64,
        restrict: String = "public",
        tag: String? = nil
    ) async throws -> IllustResponse {
        var q: [String: String] = [
            "user_id": "\(userId)",
            "restrict": restrict,
            "filter": "for_ios",
        ]
        if let tag, !tag.isEmpty { q["tag"] = tag }
        return try await get(path: "/v1/user/bookmarks/illust", query: q)
    }

    func userBookmarkTags(_ userId: Int64, restrict: String = "public") async throws -> BookmarkTagsResponse {
        try await get(path: "/v1/user/bookmark-tags/illust", query: [
            "user_id": "\(userId)",
            "restrict": restrict,
        ])
    }

    func userBookmarkedNovels(_ userId: Int64, restrict: String = "public") async throws -> NovelResponse {
        try await get(path: "/v1/user/bookmarks/novel", query: [
            "user_id": "\(userId)",
            "restrict": restrict,
        ])
    }

    func userNovels(_ userId: Int64) async throws -> NovelResponse {
        try await get(path: "/v1/user/novels", query: ["user_id": "\(userId)"])
    }

    func userFollowing(_ userId: Int64, restrict: String = "public") async throws -> UserPreviewResponse {
        try await get(path: "/v1/user/following", query: [
            "user_id": "\(userId)",
            "restrict": restrict,
        ])
    }

    func userFollower(_ userId: Int64) async throws -> UserPreviewResponse {
        try await get(path: "/v1/user/follower", query: [
            "user_id": "\(userId)",
            "filter": "for_ios",
        ])
    }

    /// Mutual-follow friends ("My pixiv").
    func userMyPixiv(_ userId: Int64) async throws -> UserPreviewResponse {
        try await get(path: "/v1/user/mypixiv", query: [
            "user_id": "\(userId)",
            "filter": "for_ios",
        ])
    }

    /// Users related to a seed user (suggested similar artists).
    func userRelated(_ userId: Int64) async throws -> UserPreviewResponse {
        try await get(path: "/v1/user/related", query: [
            "seed_user_id": "\(userId)",
            "filter": "for_ios",
        ])
    }

    /// A user's own illust series.
    func userIllustSeries(_ userId: Int64) async throws -> IllustSeriesListResponse {
        try await get(path: "/v1/user/illust-series", query: [
            "user_id": "\(userId)",
            "filter": "for_ios",
        ])
    }

    /// A user's own novel series.
    func userNovelSeries(_ userId: Int64) async throws -> NovelSeriesListResponse {
        try await get(path: "/v1/user/novel-series", query: [
            "user_id": "\(userId)",
            "filter": "for_ios",
        ])
    }

    func selfProfile() async throws -> SelfProfileResponse {
        try await get(path: "/v1/user/me/state")
    }

    func recommendedUsers() async throws -> UserPreviewResponse {
        try await get(path: "/v1/user/recommended", query: ["filter": "for_ios"])
    }

    func latestIllusts(type: String = "illust") async throws -> IllustResponse {
        try await get(path: "/v1/illust/new", query: [
            "content_type": type,
            "filter": "for_ios",
        ])
    }

    func latestNovels() async throws -> NovelResponse {
        try await get(path: "/v1/novel/new")
    }

    /// 好P友作品 — illusts/manga from mutual "My pixiv" friends (upstream
    /// `API.getNiceFriendIllust`, `GET /v2/illust/mypixiv`, no params).
    func niceFriendIllusts() async throws -> IllustResponse {
        try await get(path: "/v2/illust/mypixiv")
    }

    // MARK: Series

    func illustSeries(_ seriesId: Int64) async throws -> IllustSeriesResponse {
        try await get(path: "/v1/illust/series", query: [
            "illust_series_id": "\(seriesId)",
            "filter": "for_ios",
        ])
    }

    func novelSeries(_ seriesId: Int64) async throws -> NovelSeriesDetailResponse {
        try await get(path: "/v2/novel/series", query: [
            "series_id": "\(seriesId)",
        ])
    }

    func novelText(_ novelId: Int64) async throws -> Data {
        let url = Self.baseURL.appendingPathComponent("/webview/v2/novel")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "id", value: "\(novelId)")]
        var req = URLRequest(url: comps.url!)
        guard let token = await tokenProvider.currentAccessToken() else { throw APIError.noToken }
        applyHeaders(&req, accessToken: token)
        Self.logRequest(req)
        let (data, resp) = try await fetch(req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.http(code: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                                body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    @discardableResult
    func postIllustComment(_ illustId: Int64, comment: String, parentId: Int64? = nil) async throws -> EmptyResponse {
        var form: [String: String] = [
            "illust_id": "\(illustId)",
            "comment": comment,
        ]
        if let parentId { form["parent_comment_id"] = "\(parentId)" }
        return try await post(path: "/v1/illust/comment/add", form: form)
    }

    @discardableResult
    func postNovelComment(_ novelId: Int64, comment: String, parentId: Int64? = nil) async throws -> EmptyResponse {
        var form: [String: String] = [
            "novel_id": "\(novelId)",
            "comment": comment,
        ]
        if let parentId { form["parent_comment_id"] = "\(parentId)" }
        return try await post(path: "/v1/novel/comment/add", form: form)
    }

    /// Delete one of the signed-in user's own comments. `type` is `illust` or
    /// `novel` — upstream Shaft uses one templated path for both.
    @discardableResult
    func deleteComment(type: String, commentId: Int64) async throws -> EmptyResponse {
        try await post(path: "/v1/\(type)/comment/delete", form: ["comment_id": "\(commentId)"])
    }

    // MARK: Notifications & announcements

    func notificationList() async throws -> NotificationListResponse {
        try await get(path: "/v1/notification/list")
    }

    /// Flattened sub-list of a grouped notification (one with `view_more`).
    func notificationViewMore(_ notificationId: Int64) async throws -> NotificationListResponse {
        try await get(path: "/v1/notification/view-more", query: [
            "notification_id": "\(notificationId)",
        ])
    }

    func infoLatest() async throws -> InfoLatestResponse {
        try await get(path: "/v1/info/latest")
    }

    func infoList(categoryId: Int) async throws -> InfoListResponse {
        try await get(path: "/v1/info/list", query: ["cid": "\(categoryId)"])
    }

    // MARK: Watchlist (追更)

    /// `kind` is `manga` or `novel` — the two endpoints are symmetric.
    func watchlist(kind: String) async throws -> WatchlistResponse {
        try await get(path: "/v1/watchlist/\(kind)")
    }

    @discardableResult
    func addToWatchlist(kind: String, seriesId: Int64) async throws -> EmptyResponse {
        try await post(path: "/v1/watchlist/\(kind)/add", form: ["series_id": "\(seriesId)"])
    }

    @discardableResult
    func removeFromWatchlist(kind: String, seriesId: Int64) async throws -> EmptyResponse {
        try await post(path: "/v1/watchlist/\(kind)/delete", form: ["series_id": "\(seriesId)"])
    }

    // MARK: Novel markers (小说书签)

    func novelMarkers() async throws -> NovelMarkersResponse {
        try await get(path: "/v2/novel/markers")
    }

    /// One marker per novel — re-adding with a different page overwrites it.
    @discardableResult
    func addNovelMarker(_ novelId: Int64, page: Int) async throws -> EmptyResponse {
        try await post(path: "/v1/novel/marker/add", form: [
            "novel_id": "\(novelId)",
            "page": "\(page)",
        ])
    }

    @discardableResult
    func deleteNovelMarker(_ novelId: Int64) async throws -> EmptyResponse {
        try await post(path: "/v1/novel/marker/delete", form: ["novel_id": "\(novelId)"])
    }

    /// Generic GET against an absolute pixiv next_url (already includes base
    /// + query params). Used by paginating list view models.
    func nextPage<T: Decodable>(_ next: String) async throws -> T {
        guard let url = URL(string: next) else {
            throw APIError.http(code: 0, body: "invalid next_url")
        }
        return try await perform(request: URLRequest(url: url))
    }

    /// Continue a cursor created with a borrowed account. The explicit token is
    /// never replaced with the app's logged-in token on a 400 response.
    func nextPage<T: Decodable>(_ next: String, accessToken: String) async throws -> T {
        guard let url = URL(string: next) else {
            throw APIError.http(code: 0, body: "invalid next_url")
        }
        return try await performExplicit(request: URLRequest(url: url), accessToken: accessToken)
    }

    // MARK: Search

    /// Full V3 illust search — every dimension is built by `SearchFilter.queryItems`.
    func searchIllust(word: String, filter: SearchFilter = SearchFilter()) async throws -> IllustResponse {
        try await get(path: "/v1/search/illust", query: filter.queryItems(word: word, isNovel: false))
    }

    func searchIllust(
        word: String, filter: SearchFilter, accessToken: String
    ) async throws -> IllustResponse {
        try await getExplicit(
            path: "/v1/search/illust",
            query: filter.queryItems(word: word, isNovel: false),
            accessToken: accessToken
        )
    }

    /// Full V3 novel search.
    func searchNovel(
        word: String,
        filter: SearchFilter = SearchFilter(),
        omitDefaultTarget: Bool = false
    ) async throws -> NovelResponse {
        try await get(
            path: "/v1/search/novel",
            query: filter.queryItems(
                word: word, isNovel: true, omitDefaultNovelTarget: omitDefaultTarget
            )
        )
    }

    func searchNovel(
        word: String,
        filter: SearchFilter,
        accessToken: String,
        omitDefaultTarget: Bool = false
    ) async throws -> NovelResponse {
        try await getExplicit(
            path: "/v1/search/novel",
            query: filter.queryItems(
                word: word, isNovel: true, omitDefaultNovelTarget: omitDefaultTarget
            ),
            accessToken: accessToken
        )
    }

    /// Curated "popular preview" illust search — the endpoint non-premium users are
    /// routed to for popular sorts (returns a single un-paginated preview page).
    func searchPopularPreviewIllust(word: String, filter: SearchFilter = SearchFilter()) async throws -> IllustResponse {
        var query = filter.queryItems(word: word, isNovel: false)
        // Pixiv's preview Retrofit method has no `sort` argument. In particular,
        // `popular_preview` is a client route name, not an accepted wire sort.
        query.removeValue(forKey: "sort")
        return try await get(path: "/v1/search/popular-preview/illust", query: query)
    }

    /// Curated "popular preview" novel search.
    func searchPopularPreviewNovel(
        word: String,
        filter: SearchFilter = SearchFilter(),
        omitDefaultTarget: Bool = false
    ) async throws -> NovelResponse {
        var query = filter.queryItems(
            word: word, isNovel: true,
            omitDefaultNovelTarget: omitDefaultTarget
        )
        query.removeValue(forKey: "sort")
        return try await get(path: "/v1/search/popular-preview/novel", query: query)
    }

    func searchUser(word: String) async throws -> UserPreviewResponse {
        try await get(path: "/v1/search/user", query: [
            "word": word,
            "filter": "for_ios",
        ])
    }

    /// Dynamic, account-aware filter options (tool / genre / language pickers).
    func searchOptions(word: String = "art") async throws -> SearchOptionsResponse {
        try await get(path: "/v1/search/options", query: ["word": word, "filter": "for_ios"])
    }

    func autocompleteTags(prefix: String) async throws -> AutoCompleteResponse {
        try await get(path: "/v2/search/autocomplete", query: [
            "word": prefix,
            "merge_plain_keyword_results": "true",
        ])
    }

    // MARK: Mutations

    @discardableResult
    func bookmarkIllust(_ illustId: Int64, restrict: String = "public", tags: [String] = []) async throws -> EmptyResponse {
        let referralUID = tokenProvider is AuthTokenProvider ? KeychainTokenStore.shared.load()?.user?.id : nil
        var pairs: [(String, String)] = [
            ("illust_id", "\(illustId)"),
            ("restrict", restrict),
        ]
        for t in tags { pairs.append(("tags[]", t)) }
        let response: EmptyResponse = try await postPairs(path: "/v2/illust/bookmark/add", pairs: pairs)
        if let referralUID { Task { await ReferralActivityReporter.shared.bookmark(uid: referralUID) } }
        return response
    }

    @discardableResult
    func unbookmarkIllust(_ illustId: Int64) async throws -> EmptyResponse {
        try await post(path: "/v1/illust/bookmark/delete", form: ["illust_id": "\(illustId)"])
    }

    @discardableResult
    func bookmarkNovel(_ novelId: Int64, restrict: String = "public", tags: [String] = []) async throws -> EmptyResponse {
        let referralUID = tokenProvider is AuthTokenProvider ? KeychainTokenStore.shared.load()?.user?.id : nil
        var pairs: [(String, String)] = [
            ("novel_id", "\(novelId)"),
            ("restrict", restrict),
        ]
        for t in tags { pairs.append(("tags[]", t)) }
        let response: EmptyResponse = try await postPairs(path: "/v2/novel/bookmark/add", pairs: pairs)
        if let referralUID { Task { await ReferralActivityReporter.shared.bookmark(uid: referralUID) } }
        return response
    }

    @discardableResult
    func unbookmarkNovel(_ novelId: Int64) async throws -> EmptyResponse {
        try await post(path: "/v1/novel/bookmark/delete", form: ["novel_id": "\(novelId)"])
    }

    @discardableResult
    func followUser(_ userId: Int64, restrict: String = "public") async throws -> EmptyResponse {
        try await post(path: "/v1/user/follow/add", form: [
            "user_id": "\(userId)",
            "restrict": restrict,
        ])
    }

    @discardableResult
    func unfollowUser(_ userId: Int64) async throws -> EmptyResponse {
        try await post(path: "/v1/user/follow/delete", form: ["user_id": "\(userId)"])
    }

    /// Report an illustration. 1:1 with upstream `postFlagIllust` —
    /// `type_of_problem` is one of the four `FlagReason` keys, `message` the
    /// user's free-text description.
    @discardableResult
    func reportIllust(_ illustId: Int64, typeOfProblem: String, message: String) async throws -> EmptyResponse {
        try await post(path: "/v1/illust/report", form: [
            "illust_id": "\(illustId)",
            "type_of_problem": typeOfProblem,
            "message": message,
        ])
    }

    // MARK: Internals

    private func get<T: Decodable>(path: String, query: [String: String] = [:]) async throws -> T {
        var comps = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return try await perform(request: URLRequest(url: comps.url!))
    }

    private func getExplicit<T: Decodable>(
        path: String,
        query: [String: String],
        accessToken: String
    ) async throws -> T {
        var comps = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return try await performExplicit(
            request: URLRequest(url: comps.url!), accessToken: accessToken
        )
    }

    private func post<T: Decodable>(path: String, form: [String: String]) async throws -> T {
        try await postPairs(path: path, pairs: form.map { ($0.key, $0.value) })
    }

    private func postPairs<T: Decodable>(path: String, pairs: [(String, String)]) async throws -> T {
        let url = Self.baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode(pairs).data(using: .utf8)
        return try await perform(request: req)
    }

    private func formEncode(_ pairs: [(String, String)]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return pairs.map { k, v in
            let key = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
            let val = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            return "\(key)=\(val)"
        }.joined(separator: "&")
    }

    private func perform<T: Decodable>(request original: URLRequest) async throws -> T {
        guard let token = await tokenProvider.currentAccessToken() else { throw APIError.noToken }

        var req = original
        applyHeaders(&req, accessToken: token)

        Self.logRequest(req)
        var (data, response) = try await fetch(req)
        if let http = response as? HTTPURLResponse,
           http.statusCode == 400, isTokenError(data: data) {
            if let newToken = await tokenProvider.refreshAccessToken() {
                var retried = original
                applyHeaders(&retried, accessToken: newToken)
                (data, response) = try await fetch(retried)
            }
        }

        return try decode(data: data, response: response)
    }

    private func performExplicit<T: Decodable>(
        request original: URLRequest,
        accessToken: String
    ) async throws -> T {
        var request = original
        applyHeaders(&request, accessToken: accessToken)
        Self.logRequest(request)
        let (data, response) = try await fetch(request)
        return try decode(data: data, response: response)
    }

    private func decode<T: Decodable>(data: Data, response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else { throw APIError.nonHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(code: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        if data.isEmpty, let empty = EmptyResponse() as? T { return empty }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    /// One log line per outgoing API request: method + path + query (host and
    /// auth headers omitted — the token lives in headers, not the URL).
    private static func logRequest(_ req: URLRequest) {
        let method = req.httpMethod ?? "GET"
        let comps = req.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let path = comps?.path ?? req.url?.absoluteString ?? "?"
        let query = comps?.query.map { "?\($0)" } ?? ""
        apiLog.info("→ \(method, privacy: .public) \(path, privacy: .public)\(query, privacy: .public)")
    }

    private func applyHeaders(_ req: inout URLRequest, accessToken: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let clientTime = formatter.string(from: Date())
        let hash = Insecure.MD5.hash(data: Data((clientTime + Self.hashSecret).utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        req.setValue("ios", forHTTPHeaderField: "app-os")
        req.setValue(PixivClientIdentity.osVersion, forHTTPHeaderField: "app-os-version")
        req.setValue(PixivClientIdentity.appVersion, forHTTPHeaderField: "app-version")
        req.setValue(clientTime, forHTTPHeaderField: "x-client-time")
        req.setValue(hash, forHTTPHeaderField: "x-client-hash")
        req.setValue(PixivClientIdentity.userAgent, forHTTPHeaderField: "user-agent")
        req.setValue(PixivClientIdentity.acceptLanguage(), forHTTPHeaderField: "accept-language")
        req.setValue(PixivClientIdentity.appAcceptLanguage(), forHTTPHeaderField: "app-accept-language")
    }

    private func isTokenError(data: Data) -> Bool {
        guard let s = String(data: data, encoding: .utf8) else { return false }
        return s.contains("Error occurred at the OAuth process")
            || s.contains("Invalid refresh token")
    }
}
