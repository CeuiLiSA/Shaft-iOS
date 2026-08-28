import Foundation

// MARK: - 榜单 (discover/* + trending/users) read endpoints of shaft-api-v2
//
// All GET, no auth. Each work item embeds the full IllustsBean/NovelBean as
// `bean`; we decode by hand (JSONSerialization) like `decodeWorks` so we can
// clear the reporter's stale `is_bookmarked` and lift the pill number onto
// `trendingScore`. Items whose bean fails to decode are skipped, never thrown.

// MARK: Query / result types

struct RankQuery: Hashable, Sendable {
    var type: String = "illust"        // illust | manga | novel
    var ai: String? = nil              // "only" | "exclude"
    var year: String? = nil
    var tag: String? = nil
    var restrict: String? = nil        // "sfw" | "r18"
    var month: String? = nil           // "YYYY-MM"
    var length: String? = nil          // "short" | "medium" | "long" — only sent when type == "novel"
    var limit: Int = 30
}

/// Which item field feeds the "▲ N" pill (`trendingScore`).
enum RankScoreKey: Sendable { case bookmarkCount, viewCount }

struct RankWorksPage: Sendable {
    var illusts: [Illust]
    var novels: [Novel]
    var nextUrl: String?
    var complete: Bool
}

struct TagBucket: Hashable, Sendable, Identifiable {
    var tag: String
    var translated: String?
    var count: Int
    var id: String { tag }
}

struct YearBucket: Hashable, Sendable, Identifiable {
    var year: String
    var count: Int
    var id: String { year }
}

struct MonthBucket: Hashable, Sendable, Identifiable {
    var month: String
    var count: Int
    var id: String { month }
}

struct ArtistRankItem: Sendable, Identifiable {
    var user: PixivUser
    var illusts: [Illust]
    var totalBookmarks: Int
    var avgBookmarks: Int?
    var workCount: Int
    var id: Int64 { user.id }
}

struct ArtistRankPage: Sendable {
    var items: [ArtistRankItem]
    var nextUrl: String?
}

struct SeriesRankItem: Hashable, Sendable, Identifiable {
    var seriesId: Int64
    var title: String
    var workCount: Int
    var totalBookmarks: Int
    var userId: Int64
    var userName: String
    var userAvatarUrl: String?
    /// manga: cover_bean.image_urls.square_medium ?? medium ?? large;
    /// novel: large ?? medium ?? square_medium (same preference as NovelDetailView).
    var coverUrl: String?
    /// Response `offset` + in-page index + 1.
    var rank: Int
    var id: Int64 { seriesId }
}

struct SeriesRankPage: Sendable {
    var items: [SeriesRankItem]
    var nextUrl: String?
    var complete: Bool
}

struct TrendingUserItem: Sendable, Identifiable {
    var user: PixivUser
    var rank: Int
    var followCount: Int
    var id: Int64 { user.id }
}

struct TrendingUsersPage: Sendable {
    var items: [TrendingUserItem]
    var nextUrl: String?
}

// MARK: - Client extension

extension ShaftApiV2Client {

    // MARK: works rankings

    /// `/discover/most-bookmarked` — pill = bookmark_count. `nil` filters are not sent;
    /// `length` only goes out for novels (the server 400s it for other types).
    func mostBookmarked(_ q: RankQuery) async throws -> RankWorksPage {
        var items = [URLQueryItem(name: "type", value: q.type),
                     URLQueryItem(name: "limit", value: String(q.limit)),
                     URLQueryItem(name: "offset", value: "0")]
        if let ai = q.ai { items.append(URLQueryItem(name: "ai", value: ai)) }
        if let year = q.year { items.append(URLQueryItem(name: "year", value: year)) }
        if let tag = q.tag { items.append(URLQueryItem(name: "tag", value: tag)) }
        if let restrict = q.restrict { items.append(URLQueryItem(name: "restrict", value: restrict)) }
        if let month = q.month { items.append(URLQueryItem(name: "month", value: month)) }
        if q.type == "novel", let length = q.length {
            items.append(URLQueryItem(name: "length", value: length))
        }
        let data = try await getData(path: "/api/v1/discover/most-bookmarked", query: items)
        return Self.decodeRankWorks(data, type: q.type, scoreKey: .bookmarkCount)
    }

    /// `/discover/most-viewed` — pill = view_count.
    func mostViewed(type: String, limit: Int = 30) async throws -> RankWorksPage {
        let data = try await getData(path: "/api/v1/discover/most-viewed",
                                     query: Self.pageQuery(("type", type), limit: limit))
        return Self.decodeRankWorks(data, type: type, scoreKey: .viewCount)
    }

    /// `/discover/wallpapers?screen=desktop|phone` — illust only, pill = bookmark_count.
    func wallpapers(screen: String, limit: Int = 30) async throws -> RankWorksPage {
        let data = try await getData(path: "/api/v1/discover/wallpapers",
                                     query: Self.pageQuery(("screen", screen), limit: limit))
        return Self.decodeRankWorks(data, type: "illust", scoreKey: .bookmarkCount)
    }

    /// Follow a server-supplied absolute `next_url` verbatim for any of the three works rankings.
    func rankWorksByUrl(_ url: String, type: String, scoreKey: RankScoreKey) async throws -> RankWorksPage {
        guard let u = URL(string: url) else { throw ShaftApiError.badURL }
        let data = try await getData(url: u)
        return Self.decodeRankWorks(data, type: type, scoreKey: scoreKey)
    }

    // MARK: filter buckets

    func discoverTags(type: String, limit: Int = 50) async throws -> (tags: [TagBucket], complete: Bool) {
        let data = try await getData(path: "/api/v1/discover/tags",
                                     query: Self.pageQuery(("type", type), limit: limit))
        let obj = try Self.jsonObject(data)
        var tags: [TagBucket] = []
        for raw in Self.objects(obj["tags"]) {
            guard let tag = raw["tag"] as? String, !tag.isEmpty else { continue }
            tags.append(TagBucket(tag: tag,
                                  translated: Self.nonEmptyString(raw["translated"]),
                                  count: Self.int(raw["count"]) ?? 0))
        }
        return (tags, Self.complete(obj))
    }

    func discoverYears(type: String) async throws -> [YearBucket] {
        let data = try await getData(path: "/api/v1/discover/years",
                                     query: [URLQueryItem(name: "type", value: type)])
        let obj = try Self.jsonObject(data)
        var years: [YearBucket] = []
        for raw in Self.objects(obj["years"]) {
            // Server sends "2026" as a string; tolerate a number too.
            guard let year = Self.stringOrNumber(raw["year"]) else { continue }
            years.append(YearBucket(year: year, count: Self.int(raw["count"]) ?? 0))
        }
        return years
    }

    func discoverMonths(type: String) async throws -> (months: [MonthBucket], complete: Bool) {
        let data = try await getData(path: "/api/v1/discover/months",
                                     query: [URLQueryItem(name: "type", value: type)])
        let obj = try Self.jsonObject(data)
        var months: [MonthBucket] = []
        for raw in Self.objects(obj["months"]) {
            guard let month = raw["month"] as? String, !month.isEmpty else { continue }
            months.append(MonthBucket(month: month, count: Self.int(raw["count"]) ?? 0))
        }
        return (months, Self.complete(obj))
    }

    // MARK: artists

    /// `/discover/artists?sort=total|avg`.
    func discoverArtists(sort: String, limit: Int = 30) async throws -> ArtistRankPage {
        let data = try await getData(path: "/api/v1/discover/artists",
                                     query: Self.pageQuery(("sort", sort), limit: limit))
        return try Self.decodeArtists(data)
    }

    func artistsByUrl(_ url: String) async throws -> ArtistRankPage {
        guard let u = URL(string: url) else { throw ShaftApiError.badURL }
        return try Self.decodeArtists(try await getData(url: u))
    }

    // MARK: series

    /// `/discover/series?type=manga|novel`.
    func discoverSeries(type: String, limit: Int = 30) async throws -> SeriesRankPage {
        let data = try await getData(path: "/api/v1/discover/series",
                                     query: Self.pageQuery(("type", type), limit: limit))
        return try Self.decodeSeries(data)
    }

    func seriesByUrl(_ url: String) async throws -> SeriesRankPage {
        guard let u = URL(string: url) else { throw ShaftApiError.badURL }
        return try Self.decodeSeries(try await getData(url: u))
    }

    // MARK: trending users

    /// `/trending/users?window=day|week|month`.
    func trendingUsers(window: String, limit: Int = 30) async throws -> TrendingUsersPage {
        let data = try await getData(path: "/api/v1/trending/users",
                                     query: Self.pageQuery(("window", window), limit: limit))
        return try Self.decodeTrendingUsers(data)
    }

    func trendingUsersByUrl(_ url: String) async throws -> TrendingUsersPage {
        guard let u = URL(string: url) else { throw ShaftApiError.badURL }
        return try Self.decodeTrendingUsers(try await getData(url: u))
    }
}

// MARK: - Decoding (static, pure — also exercised by the offline verification script)

extension ShaftApiV2Client {

    static func pageQuery(_ first: (String, String), limit: Int, offset: Int = 0) -> [URLQueryItem] {
        [URLQueryItem(name: first.0, value: first.1),
         URLQueryItem(name: "limit", value: String(limit)),
         URLQueryItem(name: "offset", value: String(offset))]
    }

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ShaftApiError.decode
        }
        return obj
    }

    /// Array of JSON objects; non-object entries (e.g. `null`) are dropped
    /// instead of failing the whole `[[String: Any]]` cast.
    static func objects(_ v: Any?) -> [[String: Any]] {
        (v as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    static func int(_ v: Any?) -> Int? {
        guard let n = int64(v), let i = Int(exactly: n) else { return nil }
        return i
    }

    static func nonEmptyString(_ v: Any?) -> String? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return s
    }

    static func stringOrNumber(_ v: Any?) -> String? {
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    /// `complete` defaults to true when the server omits it.
    static func complete(_ obj: [String: Any]) -> Bool {
        (obj["complete"] as? Bool) ?? true
    }

    /// Decode one `bean` object with `is_bookmarked` cleared. Returns nil (skip) on failure.
    static func decodeBean<T: Decodable>(_ raw: Any?, as _: T.Type, dec: JSONDecoder) -> T? {
        guard var bean = raw as? [String: Any] else { return nil }
        bean["is_bookmarked"] = false
        guard let beanData = try? JSONSerialization.data(withJSONObject: bean) else { return nil }
        return try? dec.decode(T.self, from: beanData)
    }

    /// Shared shape of most-bookmarked / most-viewed / wallpapers.
    static func decodeRankWorks(_ data: Data, type: String, scoreKey: RankScoreKey) -> RankWorksPage {
        guard let obj = try? jsonObject(data) else {
            return RankWorksPage(illusts: [], novels: [], nextUrl: nil, complete: true)
        }
        let dec = JSONDecoder()
        var illusts: [Illust] = []
        var novels: [Novel] = []
        for it in objects(obj["items"]) {
            guard let targetId = int64(it["target_id"]), targetId != 0 else { continue }
            let scoreField = scoreKey == .viewCount ? "view_count" : "bookmark_count"
            let score = Double(int64(it[scoreField]) ?? 0)
            if type == "novel" {
                guard var n = decodeBean(it["bean"], as: Novel.self, dec: dec) else { continue }
                n.trendingScore = score
                novels.append(n)
            } else {
                guard var il = decodeBean(it["bean"], as: Illust.self, dec: dec) else { continue }
                il.trendingScore = score
                illusts.append(il)
            }
        }
        return RankWorksPage(illusts: illusts, novels: novels,
                             nextUrl: nonEmptyString(obj["next_url"]), complete: complete(obj))
    }

    static func decodeArtists(_ data: Data) throws -> ArtistRankPage {
        let obj = try jsonObject(data)
        let dec = JSONDecoder()
        var items: [ArtistRankItem] = []
        for it in objects(obj["user_previews"]) {
            guard let user = decodeBean(it["user"], as: PixivUser.self, dec: dec), user.id != 0 else { continue }
            var illusts: [Illust] = []
            for raw in objects(it["illusts"]) {
                if let il = decodeBean(raw, as: Illust.self, dec: dec) { illusts.append(il) }
            }
            items.append(ArtistRankItem(user: user, illusts: illusts,
                                        totalBookmarks: int(it["total_bookmarks"]) ?? 0,
                                        avgBookmarks: int(it["avg_bookmarks"]),
                                        workCount: int(it["work_count"]) ?? 0))
        }
        return ArtistRankPage(items: items, nextUrl: nonEmptyString(obj["next_url"]))
    }

    static func decodeSeries(_ data: Data) throws -> SeriesRankPage {
        let obj = try jsonObject(data)
        let isNovel = (obj["type"] as? String) == "novel"
        let offset = int(obj["offset"]) ?? 0
        var items: [SeriesRankItem] = []
        for it in objects(obj["items"]) {
            guard let seriesId = int64(it["series_id"]), seriesId != 0,
                  let user = it["user"] as? [String: Any],
                  let userId = int64(user["id"]) else { continue }
            let cover = it["cover_bean"] as? [String: Any]
            let urls = cover?["image_urls"] as? [String: Any]
            let coverUrl: String? = isNovel
                ? (nonEmptyString(urls?["large"]) ?? nonEmptyString(urls?["medium"]) ?? nonEmptyString(urls?["square_medium"]))
                : (nonEmptyString(urls?["square_medium"]) ?? nonEmptyString(urls?["medium"]) ?? nonEmptyString(urls?["large"]))
            let avatar = (user["profile_image_urls"] as? [String: Any])?["medium"]
            items.append(SeriesRankItem(seriesId: seriesId,
                                        title: (it["title"] as? String) ?? "",
                                        workCount: int(it["work_count"]) ?? 0,
                                        totalBookmarks: int(it["total_bookmarks"]) ?? 0,
                                        userId: userId,
                                        userName: (user["name"] as? String) ?? "",
                                        userAvatarUrl: nonEmptyString(avatar),
                                        coverUrl: coverUrl,
                                        rank: offset + items.count + 1))
        }
        return SeriesRankPage(items: items, nextUrl: nonEmptyString(obj["next_url"]), complete: complete(obj))
    }

    static func decodeTrendingUsers(_ data: Data) throws -> TrendingUsersPage {
        let obj = try jsonObject(data)
        let offset = int(obj["offset"]) ?? 0
        var items: [TrendingUserItem] = []
        for it in objects(obj["items"]) {
            guard let targetId = int64(it["target_id"]), targetId != 0,
                  let meta = it["meta"] as? [String: Any] else { continue }
            let avatar = nonEmptyString(meta["avatar_url"])
            let user = PixivUser(
                id: targetId,
                name: meta["name"] as? String,
                account: meta["account"] as? String,
                profileImageUrls: avatar.map {
                    ImageUrls(url: nil, large: nil, medium: $0, original: nil, small: nil,
                              squareMedium: nil, px170x170: nil, px50x50: nil)
                },
                isFollowed: false)
            items.append(TrendingUserItem(user: user,
                                          rank: offset + items.count + 1,
                                          followCount: int(it["follow_count"]) ?? 0))
        }
        return TrendingUsersPage(items: items, nextUrl: nonEmptyString(obj["next_url"]))
    }
}
