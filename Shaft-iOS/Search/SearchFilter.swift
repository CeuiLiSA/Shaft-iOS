import Foundation

/// iOS port of Pixiv-Shaft's **V3 search filter** (`ui/search/v3/SearchFilterV3`).
///
/// Immutable value type carrying every search dimension pixiv's iOS app exposes.
/// Illustration and novel tabs retain independent instances;
/// `queryItems(word:isNovel:)` drops dimensions invalid for that endpoint
/// (mirrors Android `SearchViewModel.buildSearchConfig`).
///
/// Two dimensions have **no** server parameter and are applied client-side after
/// fetch (see `accepts`): `r18` filters by the work's real `x_restrict` age field
/// (not the `R-18` tag hack), and `ai`'s "only AI" mode filters by `*_ai_type == 2`.
struct SearchFilter: Equatable, Sendable {
    /// Pixiv-Shaft 4.8.7 defaults every search to official popularity.
    var sort: String = SortType.popularDesc
    var target: SearchTarget = .partialTags
    /// Official closed bookmark interval. Either edge may be open.
    var bookmarkRange: BookmarkRange? = nil
    /// Legacy "Nusers入り" tag hack appended to the query — works for non-premium. 0 = unset.
    var keywordUsers: Int = 0
    var tool: String? = nil          // illust only — dynamic from /v1/search/options
    var genre: Int? = nil            // novel only — dynamic
    var language: String? = nil      // both — dynamic
    var duration: DurationBucket? = nil          // mutually exclusive with start/end
    var startDate: Date? = nil
    var endDate: Date? = nil
    var ai: AIMode = .all
    var r18: R18Mode = .all
    var ratio: RatioPattern? = nil               // illust only
    var resolution: ResolutionBucket? = nil      // illust only
    var contentType: IllustContentType = .all    // illust only
    var bodyLength: BodyLength? = nil            // novel only
    var originalOnly: Bool = false               // novel only
    var replaceableOnly: Bool = false            // novel only
    /// Novel-only web search (`gs=1`), which collapses a series into one row.
    var groupBySeries: Bool = false

    /// Compatibility accessors keep the query layer explicit while the UI owns
    /// the interval as one atomic value (matching Android `BookmarkRangeSpec`).
    var bookmarkMin: Int { bookmarkRange?.min ?? 0 }
    var bookmarkMax: Int { bookmarkRange?.max ?? 0 }

    /// Search's R-18 mode is independent from the global feed switch, matching
    /// `SearchFilterV3.fromGlobalDefaults`: its default is always `.all`.
    static func makeDefault(forNovel: Bool = false) -> SearchFilter {
        var f = SearchFilter()
        f.sort = forNovel ? SortType.novelSafe(SearchDefaults.sort) : SearchDefaults.sort
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "st_deleteAIIllust") { f.ai = .excludeAI }
        let bucketIndex = defaults.integer(forKey: "st_searchFilter")
        if KeywordUsersOptions.values.indices.contains(bucketIndex) {
            f.keywordUsers = KeywordUsersOptions.values[bucketIndex]
        }
        f.r18 = .all
        return f
    }

    /// Number of non-default dimensions for the entry-button badge.
    func activeCount(isNovel: Bool) -> Int {
        var n = 0
        if sort != SortType.popularDesc { n += 1 }
        if target != .partialTags { n += 1 }
        if bookmarkRange != nil { n += 1 }
        if keywordUsers > 0 { n += 1 }
        if language != nil { n += 1 }
        if duration != nil || startDate != nil || endDate != nil { n += 1 }
        if ai != .all { n += 1 }
        if r18 != .all { n += 1 }
        if isNovel {
            if genre != nil { n += 1 }
            if bodyLength != nil { n += 1 }
            if originalOnly { n += 1 }
            if replaceableOnly { n += 1 }
            if groupBySeries { n += 1 }
        } else {
            if tool != nil { n += 1 }
            if ratio != nil { n += 1 }
            if resolution != nil { n += 1 }
            if contentType != .all { n += 1 }
        }
        return n
    }

    // MARK: Query building

    /// Builds the complete `[String: String]` query for `/v1/search/{illust,novel}`.
    /// `today` is injectable for tests; duration buckets resolve to `start_date`/`end_date`.
    func queryItems(
        word: String,
        isNovel: Bool,
        today: Date = Date(),
        omitDefaultNovelTarget: Bool = false
    ) -> [String: String] {
        var q: [String: String] = [
            "filter": "for_ios",
            "merge_plain_keyword_results": "true",
            "include_translated_tag_results": "true",
        ]

        var keyword = word
        // Latest Shaft intentionally suppresses the legacy users入り suffix on
        // novel searches when an official bookmark interval is present. Illust
        // keeps both dimensions; grouped novel web search follows novel rules.
        let hasPositiveBookmarkBound = (bookmarkRange?.min ?? 0) > 0
            || (bookmarkRange?.max ?? 0) > 0
        if keywordUsers > 0, !isNovel || !hasPositiveBookmarkBound {
            keyword += " \(keywordUsers)users入り"
        }
        q["word"] = keyword
        q["sort"] = sort

        // Default "partial tags" is omitted so pixiv merges title/keyword hits
        // (works whose tag set lacks the term still surface). Explicit picks pass
        // through — but only when valid for this endpoint, since one filter drives
        // both tabs (e.g. a novel-only "keyword" target is dropped for illust).
        let validTargets = isNovel ? SearchTarget.forNovel : SearchTarget.forIllust
        if validTargets.contains(target) {
            if isNovel, target == .partialTags, !omitDefaultNovelTarget {
                // Unlike illust, novel needs explicit partial matching for tag
                // synonyms/translations. Empty first pages are retried without it
                // by the search repository to preserve title-only hits (#1038).
                q["search_target"] = SearchTarget.partialTags.rawValue
            } else if let tv = target.queryValue {
                q["search_target"] = tv
            }
        }

        if let min = bookmarkRange?.min { q["bookmark_num_min"] = "\(min)" }
        if let max = bookmarkRange?.max { q["bookmark_num_max"] = "\(max)" }
        // Wire name is `lang` (matches Pixiv-Shaft's Retrofit `@Query("lang")`).
        if let language { q["lang"] = language }

        // Date posted (3-way mutually exclusive): bucket → custom → unset.
        if let (start, end) = resolvedDates(today: today) {
            if let start { q["start_date"] = start }
            if let end { q["end_date"] = end }
        }

        // AI: `search_ai_type` is always sent (0 = include, 1 = exclude). "Only AI"
        // sends 0 and is narrowed client-side. Matches Shaft `AiMode.searchAiType()`.
        q["search_ai_type"] = ai == .excludeAI ? "1" : "0"

        if isNovel {
            if let genre { q["genre"] = "\(genre)" }
            if let bodyLength {
                for (k, v) in bodyLength.queryItems() { q[k] = v }
            }
            // Wire names are `is_original_only` / `is_replaceable_only`.
            if originalOnly { q["is_original_only"] = "true" }
            if replaceableOnly { q["is_replaceable_only"] = "true" }
        } else {
            if let tool { q["tool"] = tool }
            if let ratio { q["ratio_pattern"] = ratio.apiValue }
            if contentType != .all { q["content_type"] = contentType.apiValue }
            if let resolution {
                if let v = resolution.widthMin { q["width_min"] = "\(v)" }
                if let v = resolution.widthMax { q["width_max"] = "\(v)" }
                if let v = resolution.heightMin { q["height_min"] = "\(v)" }
                if let v = resolution.heightMax { q["height_max"] = "\(v)" }
            }
        }
        return q
    }

    /// Resolves the post-date window to `(start, end)` `yyyy-MM-dd` strings, or nil.
    func resolvedDates(today: Date = Date()) -> (String?, String?)? {
        if let duration {
            let (s, e) = duration.range(today: today)
            return (Self.ymd(s), Self.ymd(e))
        }
        if startDate != nil || endDate != nil {
            return (startDate.map(Self.ymd), endDate.map(Self.ymd))
        }
        return nil
    }

    /// Local Date semantics without sharing DateFormatter across the app-api,
    /// grouped-web and main-actor call sites (DateFormatter is not Sendable).
    static func ymd(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }

    // MARK: Client-side filtering

    /// Shared client-side R-18 + AI decision. Illustration adds the legacy
    /// bookmark/users threshold below; latest Android novel `Mapper` does not.
    func accepts(xRestrict: Int?, aiType: Int?, bookmarks: Int?) -> Bool {
        r18.accepts(xRestrict) && ai.accepts(aiType)
    }

    func accepts(_ illust: Illust) -> Bool {
        guard accepts(
            xRestrict: illust.xRestrict,
            aiType: illust.illustAIType,
            bookmarks: illust.totalBookmarks
        ) else { return false }
        let count = illust.totalBookmarks ?? 0
        if count < max(bookmarkRange?.min ?? 0, keywordUsers) { return false }
        // Legacy FilterMapper treats max <= 0 as the unlimited sentinel even
        // when a custom range object exists.
        if let maximum = bookmarkRange?.max, maximum > 0, count > maximum { return false }
        return true
    }

    func accepts(_ novel: Novel) -> Bool {
        accepts(xRestrict: novel.xRestrict, aiType: novel.novelAIType,
                bookmarks: novel.totalBookmarks)
    }
}

// MARK: - Bookmark range

struct BookmarkRange: Equatable, Hashable, Sendable {
    var min: Int?
    var max: Int?

    /// Static fallback captured from pixiv iOS 8.7.3. `/v1/search/options`
    /// replaces it when the account receives dynamic ranges.
    static let defaultPresets: [BookmarkRange] = [
        .init(min: 1000, max: nil),
        .init(min: 500, max: 999),
        .init(min: 300, max: 499),
        .init(min: 100, max: 299),
        .init(min: 50, max: 99),
        .init(min: 30, max: 49),
        .init(min: 10, max: 29),
    ]
}

// MARK: - Sort

enum SortType {
    static let popularPreview = "popular_preview"
    static let dateDesc = "date_desc"
    static let dateAsc = "date_asc"
    static let popularDesc = "popular_desc"
    static let popularMaleDesc = "popular_male_desc"
    static let popularFemaleDesc = "popular_female_desc"
    static let trendingBuiltin = "trending_builtin"

    /// Exact V3 picker order. Borrowed search makes every official popularity
    /// sort selectable by non-Premium users; only male/female are illust-only.
    static func choices(isNovel: Bool) -> [String] {
        var list = [popularPreview, dateDesc, dateAsc, popularDesc]
        if !isNovel { list += [popularMaleDesc, popularFemaleDesc] }
        return list
    }

    /// Whether this sort must route through `/v1/search/popular-preview/*` instead
    /// of `/v1/search/*` — matches Shaft `shouldUsePopularPreview`: the preview
    /// endpoint is the only place non-premium users can get popular results.
    static func isPremiumOnly(_ sort: String, isNovel: Bool) -> Bool {
        if sort == popularDesc { return true }
        return !isNovel && (sort == popularMaleDesc || sort == popularFemaleDesc)
    }

    static func novelSafe(_ sort: String) -> String {
        switch sort {
        case popularMaleDesc, popularFemaleDesc: return popularDesc
        case trendingBuiltin: return popularDesc
        default: return sort
        }
    }
}

// MARK: - Match target

enum SearchTarget: String, CaseIterable, Sendable {
    case partialTags = "partial_match_for_tags"
    case exactTags = "exact_match_for_tags"
    case titleCaption = "title_and_caption"   // illust
    case novelText = "text"                   // novel
    case novelKeyword = "keyword"             // novel

    static let forIllust: [SearchTarget] = [.partialTags, .exactTags, .titleCaption]
    static let forNovel: [SearchTarget] = [.partialTags, .exactTags, .novelText, .novelKeyword]

    /// Value actually sent: the default `partialTags` is omitted (returns nil).
    var queryValue: String? { self == .partialTags ? nil : rawValue }
}

// MARK: - Bookmark / users入り buckets (numeric, label-free)

enum KeywordUsersOptions {
    static let values: [Int] = [0, 500, 1000, 2000, 5000, 7500, 10000, 20000, 50000, 100000]
}

// MARK: - Duration

enum DurationBucket: String, CaseIterable, Sendable {
    case last24Hours, lastWeek, lastMonth, lastHalfYear, lastYear

    /// `end = today`, `start = today − offset` — matches pixiv iOS 8.6.6 capture.
    func range(today: Date) -> (Date, Date) {
        let cal = Calendar(identifier: .gregorian)
        let start: Date
        switch self {
        case .last24Hours:  start = cal.date(byAdding: .day, value: -1, to: today) ?? today
        case .lastWeek:     start = cal.date(byAdding: .day, value: -7, to: today) ?? today
        case .lastMonth:    start = cal.date(byAdding: .month, value: -1, to: today) ?? today
        case .lastHalfYear: start = cal.date(byAdding: .month, value: -6, to: today) ?? today
        case .lastYear:     start = cal.date(byAdding: .year, value: -1, to: today) ?? today
        }
        return (start, today)
    }
}

// MARK: - R-18 (client-side, by x_restrict)

enum R18Mode: String, CaseIterable, Sendable {
    case all, safeOnly, r18Only

    /// `x_restrict` nil/0 = all-ages; 1 = R-18; 2 = R-18G.
    func accepts(_ xRestrict: Int?) -> Bool {
        switch self {
        case .all: return true
        case .safeOnly: return (xRestrict ?? 0) <= 0
        case .r18Only: return (xRestrict ?? 0) > 0
        }
    }
}

// MARK: - AI mode

enum AIMode: String, CaseIterable, Sendable {
    case all, excludeAI, onlyAI

    /// `*_ai_type == 2` means AI-generated. "exclude" is also enforced server-side.
    func accepts(_ aiType: Int?) -> Bool {
        switch self {
        case .all: return true
        case .excludeAI: return (aiType ?? 0) != 2
        case .onlyAI: return (aiType ?? 0) == 2
        }
    }
}

// MARK: - Aspect ratio (illust)

enum RatioPattern: String, CaseIterable, Sendable {
    case landscape, portrait, square
    var apiValue: String { rawValue }
}

// MARK: - Content type (illust)

enum IllustContentType: String, CaseIterable, Sendable {
    case all = "illust_and_manga_and_ugoira"
    case illustAndUgoira = "illust_and_ugoira"
    case illust
    case ugoira
    case manga
    var apiValue: String { rawValue }
}

// MARK: - Resolution buckets (illust)

enum ResolutionBucket: String, CaseIterable, Sendable {
    case above3000, between1000And2999, below1000

    var widthMin: Int? { self == .above3000 ? 3000 : (self == .between1000And2999 ? 1000 : nil) }
    var widthMax: Int? { self == .between1000And2999 ? 2999 : (self == .below1000 ? 999 : nil) }
    var heightMin: Int? { widthMin }
    var heightMax: Int? { widthMax }
}

// MARK: - Body length (novel)

enum BodyLengthUnit: String, CaseIterable, Sendable {
    case characters, words, readingTime

    var minKey: String {
        switch self {
        case .characters: return "text_length_min"
        case .words: return "word_count_min"
        case .readingTime: return "reading_time_min"
        }
    }
    var maxKey: String {
        switch self {
        case .characters: return "text_length_max"
        case .words: return "word_count_max"
        case .readingTime: return "reading_time_max"
        }
    }

    /// Preset (min, max) buckets pixiv's picker offers, per unit.
    var buckets: [(min: Int?, max: Int?)] {
        switch self {
        case .characters:
            return [(nil, 4999), (5000, 19999), (20000, 79999), (80000, nil)]
        case .words:
            return [(nil, 4999), (5000, 19999), (20000, 79999), (80000, nil)]
        case .readingTime:
            return [(nil, 9), (10, 59), (60, 179), (180, nil)]
        }
    }
}

struct BodyLength: Equatable, Hashable, Sendable {
    var unit: BodyLengthUnit
    var min: Int?
    var max: Int?

    func queryItems() -> [String: String] {
        var q: [String: String] = [:]
        if let min { q[unit.minKey] = "\(min)" }
        if let max { q[unit.maxKey] = "\(max)" }
        return q
    }
}
