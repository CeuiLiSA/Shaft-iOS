import XCTest
@testable import Shaft_iOS

/// Port of Android `Nana7miSearchCacheTest`: key, freshness tiers, decode, wire.
final class BorrowedSearchCacheTests: XCTestCase {

    private let hour: Int64 = 3_600_000

    private var today: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 12))!
    }

    // MARK: Key — reuse depends on "same request → same key"

    func testSameRequestFromTwoCallersYieldsTheSameKey() {
        let params: [(String, String?)] = [("word", "原神"), ("sort", "popular_desc"), ("bookmark_num_min", "1000")]
        let a = BorrowedSearchCache.firstPageKey(kind: .illust, params: params)
        let b = BorrowedSearchCache.firstPageKey(kind: .illust, params: params)
        XCTAssertEqual(a, b)
        XCTAssertNotNil(a.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        // Byte-for-byte Android's canonical string (URLEncoder + sha256).
        XCTAssertEqual(a, "d47a6b1cf8b85ba4396b4b0a9dfe715ef96e74c5863cf3227cd89c81fc97ad73")
        XCTAssertEqual(
            BorrowedSearchCache.nextPageKey(kind: .novel, nextURL: "https://app-api.pixiv.net/v1/search/novel?word=a&offset=30"),
            "822dcd9f55d573df98033e7bd5658774d288e471861acfde4291bfc914fbffaa"
        )
    }

    func testAnyDifferingParameterKindOrPageCursorIsADifferentKey() {
        let base: [(String, String?)] = [("word", "原神"), ("sort", "popular_desc"), ("search_ai_type", "0")]
        let key = BorrowedSearchCache.firstPageKey(kind: .illust, params: base)
        XCTAssertNotEqual(key, BorrowedSearchCache.firstPageKey(kind: .illust, params: base.map { $0.0 == "search_ai_type" ? ($0.0, "1") : $0 }))
        XCTAssertNotEqual(key, BorrowedSearchCache.firstPageKey(kind: .illust, params: base.map { $0.0 == "sort" ? ($0.0, "date_desc") : $0 }))
        XCTAssertNotEqual(key, BorrowedSearchCache.firstPageKey(kind: .novel, params: base))
        XCTAssertNotEqual(key, BorrowedSearchCache.nextPageKey(kind: .illust, nextURL: "https://example.invalid/v1/search/illust?word=原神&offset=30"))
    }

    func testANilParameterIsAbsentNotAnEmptyStringAndValuesCannotCollideAcrossNames() {
        let absent = BorrowedSearchCache.firstPageKey(kind: .illust, params: [("word", "a"), ("tool", nil)])
        let empty = BorrowedSearchCache.firstPageKey(kind: .illust, params: [("word", "a"), ("tool", "")])
        XCTAssertNotEqual(absent, empty)
        let smuggled = BorrowedSearchCache.firstPageKey(kind: .illust, params: [("word", "a|tool=x")])
        let honest = BorrowedSearchCache.firstPageKey(kind: .illust, params: [("word", "a"), ("tool", "x")])
        XCTAssertNotEqual(smuggled, honest)
        XCTAssertEqual(BorrowedSearchCache.formEncode("原神 a|b*~"), "%E5%8E%9F%E7%A5%9E+a%7Cb*%7E")
    }

    func testTheWholeSentQueryIsTheKeyAndPlatformsDoNotShareIt() {
        var filter = SearchFilter()
        filter.sort = SortType.popularDesc
        let query = filter.queryItems(word: "原神", isNovel: false, today: today)
        XCTAssertEqual(query["filter"], "for_ios")
        let key = BorrowedSearchCache.firstPageKey(kind: .illust, params: BorrowedSearchCache.params(of: query))
        XCTAssertEqual(key, BorrowedSearchCache.firstPageKey(kind: .illust, params: BorrowedSearchCache.params(of: query)))
        filter.ai = .excludeAI
        XCTAssertNotEqual(key, BorrowedSearchCache.firstPageKey(
            kind: .illust,
            params: BorrowedSearchCache.params(of: filter.queryItems(word: "原神", isNovel: false, today: today))
        ))
    }

    // MARK: Freshness tiers

    func testPopularSortToleranceShrinksAsTheWindowReachesCloserToToday() {
        func popular(_ start: String?, _ end: String?, sort: String = "popular_desc") -> Int64 {
            BorrowedSearchCache.maxAgeMS(sort: sort, startDate: start, endDate: end, today: today)
        }
        // The default a tag tap opens: no period.
        XCTAssertEqual(popular(nil, nil), 7 * 24 * hour)
        XCTAssertEqual(popular(nil, nil, sort: "popular_male_desc"), 7 * 24 * hour)
        XCTAssertEqual(popular(nil, "2026-09-28"), 7 * 24 * hour, "only an end bound is still all-time")
        // Relative buckets, exactly as SearchFilter resolves them.
        func bucket(_ b: DurationBucket) -> Int64 {
            let (start, end) = b.range(today: today)
            return popular(SearchFilter.ymd(start), SearchFilter.ymd(end))
        }
        XCTAssertEqual(bucket(.last24Hours), 30 * 60_000)
        XCTAssertEqual(bucket(.lastWeek), 2 * hour)
        XCTAssertEqual(bucket(.lastMonth), 12 * hour)
        XCTAssertEqual(bucket(.lastHalfYear), 24 * hour)
        XCTAssertEqual(bucket(.lastYear), 24 * hour)
        // Custom periods.
        XCTAssertEqual(popular("2026-09-28", "2026-09-28"), 30 * 60_000)
        XCTAssertEqual(popular("2020-01-01", "2026-09-28"), 7 * 24 * hour)
        XCTAssertEqual(popular("2026-08-01", "2026-08-10"), 7 * 24 * hour, "a window that closed a month ago is settled")
        XCTAssertEqual(popular("2026-09-22", "2026-09-24"), 2 * hour)
        // Unparseable → strictest.
        XCTAssertEqual(popular("garbage", "2026-09-28"), 30 * 60_000)
        XCTAssertEqual(popular(nil, "garbage"), 30 * 60_000)
        XCTAssertEqual(popular("2026-02-30", "2026-09-28"), 30 * 60_000)
    }

    func testDateSortsStayFreshUnlessTheWholeWindowEndedOverAWeekAgo() {
        let fresh: Int64 = 30 * 60_000
        XCTAssertEqual(BorrowedSearchCache.maxAgeMS(sort: "date_desc", startDate: nil, endDate: nil, today: today), fresh)
        XCTAssertEqual(BorrowedSearchCache.maxAgeMS(sort: "date_asc", startDate: "2020-01-01", endDate: nil, today: today), fresh)
        XCTAssertEqual(BorrowedSearchCache.maxAgeMS(sort: "date_desc", startDate: "2026-09-01", endDate: "2026-09-21", today: today), fresh)
        XCTAssertEqual(BorrowedSearchCache.maxAgeMS(sort: "date_desc", startDate: "2026-09-01", endDate: "2026-09-20", today: today), 24 * hour)
        XCTAssertEqual(BorrowedSearchCache.maxAgeMS(sort: nil, startDate: nil, endDate: nil, today: today), fresh)
    }

    // MARK: Decode — a hit must become the same model a live search produces

    func testAHitDecodesIntoTheSameModelALiveSearchWouldProduce() throws {
        let illust = try XCTUnwrap(BorrowedSearchCache.decode(Data("""
        {"hit":true,"page":{"illusts":[{"id":101,"title":"one"},{"id":102,"title":"two"}],"next_url":"https://app-api.pixiv.net/v1/search/illust?offset=30"},"storedAt":1,"ageMs":5}
        """.utf8), as: IllustResponse.self))
        XCTAssertEqual(illust.illusts.map(\.id), [101, 102])
        XCTAssertEqual(illust.nextUrl, "https://app-api.pixiv.net/v1/search/illust?offset=30")

        let novel = try XCTUnwrap(BorrowedSearchCache.decode(Data("""
        {"hit":true,"page":{"novels":[{"id":7}],"next_url":null}}
        """.utf8), as: NovelResponse.self))
        XCTAssertEqual(novel.novels.count, 1)
        XCTAssertNil(novel.nextUrl)
    }

    func testAnythingThatIsNotACleanHitIsAMiss() {
        func miss(_ json: String) -> Bool {
            BorrowedSearchCache.decode(Data(json.utf8), as: IllustResponse.self) == nil
        }
        XCTAssertTrue(miss("null"))
        XCTAssertTrue(miss(#"{"hit":false,"storeToken":"t"}"#))
        XCTAssertTrue(miss(#"{"hit":true}"#))
        XCTAssertTrue(miss(#"{"hit":true,"page":[1,2]}"#))
        XCTAssertTrue(miss(#"{"hit":true,"page":{"illusts":"nope"}}"#))
        XCTAssertTrue(miss(#"{"hit":true,"page":{"next_url":"n"}}"#))
        XCTAssertTrue(miss(#"{"hit":true,"page":{"illusts":[{"id":1}],"next_url":"https://attacker.example/steal"}}"#))
        XCTAssertTrue(miss(#"{"hit":true,"page":{"illusts":[{"id":1}],"next_url":"https://u@app-api.pixiv.net/v1/x"}}"#))
        XCTAssertTrue(miss(#"{"hit":true,"page":{"illusts":[{"id":1}],"next_url":"http://app-api.pixiv.net/v1/x"}}"#))
    }

    func testAStoredPageRoundTripsWithIntegerIDsAndCreateDate() throws {
        let page = try JSONDecoder().decode(IllustResponse.self, from: Data("""
        {"illusts":[{"id":9007199254740991,"create_date":"2026-09-01T00:00:00+09:00"}],"next_url":null}
        """.utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
        let item = try XCTUnwrap((object["illusts"] as? [[String: Any]])?.first)
        // The server rejects a page whose ids are not integers and caps it by create_date.
        XCTAssertEqual((item["id"] as? NSNumber)?.int64Value, 9_007_199_254_740_991)
        XCTAssertEqual(item["create_date"] as? String, "2026-09-01T00:00:00+09:00")
    }

    // MARK: Wire — field names match the server's src/search-cache.js

    func testLookupPostsUidKindKeyMaxAgePageAndRequestId() throws {
        let key = String(repeating: "a", count: 64)
        let requestID = "823e4567-e89b-42d3-a456-426614174010"
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            BorrowedSearchCacheLookupRequest(uid: 42, kind: "illust", key: key, maxAgeMs: 60_000, page: "first", requestId: requestID)
        )) as? [String: Any])
        XCTAssertEqual(sent["uid"] as? Int, 42)
        XCTAssertEqual(sent["kind"] as? String, "illust")
        XCTAssertEqual(sent["key"] as? String, key)
        XCTAssertEqual(sent["maxAgeMs"] as? Int, 60_000)
        XCTAssertEqual(sent["page"] as? String, "first")
        XCTAssertEqual(sent["requestId"] as? String, requestID)
    }

    func testLegacyCapabilityOmitsRequestIdFromCacheLookupBody() throws {
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            BorrowedSearchCacheLookupRequest(uid: 42, kind: "illust", key: String(repeating: "b", count: 64), maxAgeMs: 60_000, page: "first", requestId: nil)
        )) as? [String: Any])
        XCTAssertNil(sent["requestId"])
        XCTAssertFalse(sent.keys.contains("requestId"))
    }

    func testRequestIDsAreLowercaseUUIDsTheServerAccepts() {
        let id = BorrowedSearchCache.newRequestID()
        XCTAssertNotNil(id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression))
    }
}
