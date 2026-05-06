import Foundation
import CryptoKit
import UIKit

protocol PixivTokenProvider: Sendable {
    func currentAccessToken() async -> String?
    func refreshAccessToken() async -> String?
}

actor PixivAPI {
    static let baseURL = URL(string: "https://app-api.pixiv.net")!
    private static let hashSecret = "28c1fdd170a5204386cb1313c7077b34f83e4aaf4aa829ce78c231e05b0bae2c"
    private static let appVersion = "7.13.4"

    private let session: URLSession
    private let tokenProvider: any PixivTokenProvider
    private let osVersion: String
    private let deviceModel: String

    init(
        tokenProvider: any PixivTokenProvider,
        osVersion: String,
        deviceModel: String,
        session: URLSession? = nil
    ) {
        self.tokenProvider = tokenProvider
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 10
            cfg.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: cfg)
        }
    }

    @MainActor
    static func make(tokenProvider: any PixivTokenProvider) -> PixivAPI {
        PixivAPI(
            tokenProvider: tokenProvider,
            osVersion: UIDevice.current.systemVersion,
            deviceModel: UIDevice.current.model
        )
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
    func rankingIllusts(mode: String = "day") async throws -> IllustResponse {
        try await get(path: "/v1/illust/ranking", query: [
            "mode": mode,
            "filter": "for_ios",
        ])
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

    // MARK: User

    func userDetail(_ userId: Int64) async throws -> UserDetailResponse {
        try await get(path: "/v1/user/detail", query: [
            "user_id": "\(userId)",
            "filter": "for_ios",
        ])
    }

    func userIllusts(_ userId: Int64, type: String = "illust") async throws -> IllustResponse {
        try await get(path: "/v1/user/illusts", query: [
            "user_id": "\(userId)",
            "type": type,
            "filter": "for_ios",
        ])
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
        let (data, resp) = try await session.data(for: req)
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

    /// Generic GET against an absolute pixiv next_url (already includes base
    /// + query params). Used by paginating list view models.
    func nextPage<T: Decodable>(_ next: String) async throws -> T {
        guard let url = URL(string: next) else {
            throw APIError.http(code: 0, body: "invalid next_url")
        }
        return try await perform(request: URLRequest(url: url))
    }

    // MARK: Search

    func searchIllust(
        word: String,
        sort: String = "date_desc",
        searchTarget: String = "partial_match_for_tags"
    ) async throws -> IllustResponse {
        try await get(path: "/v1/search/illust", query: [
            "word": word,
            "sort": sort,
            "search_target": searchTarget,
            "filter": "for_ios",
        ])
    }

    func searchNovel(
        word: String,
        sort: String = "date_desc",
        searchTarget: String = "partial_match_for_tags"
    ) async throws -> NovelResponse {
        try await get(path: "/v1/search/novel", query: [
            "word": word,
            "sort": sort,
            "search_target": searchTarget,
        ])
    }

    func searchUser(word: String) async throws -> UserPreviewResponse {
        try await get(path: "/v1/search/user", query: [
            "word": word,
            "filter": "for_ios",
        ])
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
        var pairs: [(String, String)] = [
            ("illust_id", "\(illustId)"),
            ("restrict", restrict),
        ]
        for t in tags { pairs.append(("tags[]", t)) }
        return try await postPairs(path: "/v2/illust/bookmark/add", pairs: pairs)
    }

    @discardableResult
    func unbookmarkIllust(_ illustId: Int64) async throws -> EmptyResponse {
        try await post(path: "/v1/illust/bookmark/delete", form: ["illust_id": "\(illustId)"])
    }

    @discardableResult
    func bookmarkNovel(_ novelId: Int64, restrict: String = "public", tags: [String] = []) async throws -> EmptyResponse {
        var pairs: [(String, String)] = [
            ("novel_id", "\(novelId)"),
            ("restrict", restrict),
        ]
        for t in tags { pairs.append(("tags[]", t)) }
        return try await postPairs(path: "/v2/novel/bookmark/add", pairs: pairs)
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

    // MARK: Internals

    private func get<T: Decodable>(path: String, query: [String: String] = [:]) async throws -> T {
        var comps = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return try await perform(request: URLRequest(url: comps.url!))
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

        var (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse,
           http.statusCode == 400, isTokenError(data: data) {
            if let newToken = await tokenProvider.refreshAccessToken() {
                var retried = original
                applyHeaders(&retried, accessToken: newToken)
                (data, response) = try await session.data(for: retried)
            }
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.nonHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(code: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        if data.isEmpty, let empty = EmptyResponse() as? T {
            return empty
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
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
        req.setValue(osVersion, forHTTPHeaderField: "app-os-version")
        req.setValue(Self.appVersion, forHTTPHeaderField: "app-version")
        req.setValue(clientTime, forHTTPHeaderField: "x-client-time")
        req.setValue(hash, forHTTPHeaderField: "x-client-hash")
        req.setValue("PixivIOSApp/\(Self.appVersion) (iOS \(osVersion); \(deviceModel))",
                     forHTTPHeaderField: "user-agent")
        req.setValue(Self.acceptLanguage(), forHTTPHeaderField: "accept-language")
    }

    private func isTokenError(data: Data) -> Bool {
        guard let s = String(data: data, encoding: .utf8) else { return false }
        return s.contains("Error occurred at the OAuth process")
            || s.contains("Invalid refresh token")
    }

    private static func acceptLanguage() -> String {
        let pref = Locale.preferredLanguages.first ?? "en"
        let lang = Locale(identifier: pref).language.languageCode?.identifier ?? "en"
        let region = Locale(identifier: pref).region?.identifier ?? "US"
        return "\(lang)-\(region.lowercased()),\(lang);q=0.9,en-us;q=0.8,en;q=0.7"
    }
}
