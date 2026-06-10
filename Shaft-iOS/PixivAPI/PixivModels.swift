import Foundation

struct EmptyResponse: Codable, Sendable {
    init() {}
    init(from decoder: Decoder) throws {} // tolerate empty / unknown JSON
    func encode(to encoder: Encoder) throws {}
}

struct ImageUrls: Codable, Hashable, Sendable {
    let url: String?
    let large: String?
    let medium: String?
    let original: String?
    let small: String?
    let squareMedium: String?
    let px170x170: String?
    let px50x50: String?

    enum CodingKeys: String, CodingKey {
        case url, large, medium, original, small
        case squareMedium = "square_medium"
        case px170x170 = "px_170x170"
        case px50x50 = "px_50x50"
    }
}

struct Tag: Codable, Hashable, Sendable {
    let name: String?
    let translatedName: String?

    enum CodingKeys: String, CodingKey {
        case name
        case translatedName = "translated_name"
    }

    var displayName: String { name ?? translatedName ?? "" }
}

struct PixivUser: Codable, Hashable, Sendable, Identifiable {
    let id: Int64
    let name: String?
    let account: String?
    let profileImageUrls: ImageUrls?
    let isFollowed: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, account
        case profileImageUrls = "profile_image_urls"
        case isFollowed = "is_followed"
    }
}

struct MetaSinglePage: Codable, Hashable, Sendable {
    let originalImageUrl: String?

    enum CodingKeys: String, CodingKey {
        case originalImageUrl = "original_image_url"
    }
}

struct MetaPage: Codable, Hashable, Sendable {
    let imageUrls: ImageUrls?

    enum CodingKeys: String, CodingKey {
        case imageUrls = "image_urls"
    }
}

struct Illust: Codable, Hashable, Sendable, Identifiable {
    let id: Int64
    let title: String?
    let caption: String?
    let type: String?
    let imageUrls: ImageUrls?
    let user: PixivUser?
    let tags: [Tag]?
    let pageCount: Int?
    let width: Int?
    let height: Int?
    let totalBookmarks: Int?
    let totalView: Int?
    let isBookmarked: Bool?
    let createDate: String?
    let metaSinglePage: MetaSinglePage?
    let metaPages: [MetaPage]?
    let series: IllustSeriesRef?
    /// Real age rating: 0 = all-ages, 1 = R-18, 2 = R-18G. Drives search R-18 filtering.
    let xRestrict: Int?
    /// 0/1 = human, 2 = AI-generated. Drives search "only AI" / "exclude AI" filtering.
    let illustAIType: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, caption, type
        case imageUrls = "image_urls"
        case user, tags
        case pageCount = "page_count"
        case width, height
        case totalBookmarks = "total_bookmarks"
        case totalView = "total_view"
        case isBookmarked = "is_bookmarked"
        case createDate = "create_date"
        case metaSinglePage = "meta_single_page"
        case metaPages = "meta_pages"
        case series
        case xRestrict = "x_restrict"
        case illustAIType = "illust_ai_type"
    }
}

struct IllustSeriesRef: Codable, Hashable, Sendable {
    let id: Int64?
    let title: String?
}

struct IllustResponse: Codable, Sendable {
    let illusts: [Illust]
    let nextUrl: String?

    enum CodingKeys: String, CodingKey {
        case illusts
        case nextUrl = "next_url"
    }
}

struct HomeIllustResponse: Codable, Sendable {
    let illusts: [Illust]
    let rankingIllusts: [Illust]?
    let nextUrl: String?

    enum CodingKeys: String, CodingKey {
        case illusts
        case rankingIllusts = "ranking_illusts"
        case nextUrl = "next_url"
    }
}

struct TrendingTag: Codable, Hashable, Sendable, Identifiable {
    let tag: String?
    let translatedName: String?
    let illust: Illust?

    enum CodingKeys: String, CodingKey {
        case tag
        case translatedName = "translated_name"
        case illust
    }

    var id: String { "\(tag ?? "")|\(translatedName ?? "")" }
}

struct TrendingTagsResponse: Codable, Sendable {
    let trendTags: [TrendingTag]
    let nextUrl: String?

    enum CodingKeys: String, CodingKey {
        case trendTags = "trend_tags"
        case nextUrl = "next_url"
    }
}

// MARK: - Detail / User / Comments / Novel / Spotlight

struct IllustDetailResponse: Codable, Sendable {
    let illust: Illust
}

struct UserProfile: Codable, Hashable, Sendable {
    let webpage: String?
    let totalIllusts: Int?
    let totalManga: Int?
    let totalNovels: Int?
    let totalIllustBookmarksPublic: Int?
    let totalIllustSeries: Int?
    let totalNovelSeries: Int?
    let backgroundImageUrl: String?
    let twitterAccount: String?
    let twitterUrl: String?
    let pawooUrl: String?
    let isPremium: Bool?

    enum CodingKeys: String, CodingKey {
        case webpage
        case totalIllusts = "total_illusts"
        case totalManga = "total_manga"
        case totalNovels = "total_novels"
        case totalIllustBookmarksPublic = "total_illust_bookmarks_public"
        case totalIllustSeries = "total_illust_series"
        case totalNovelSeries = "total_novel_series"
        case backgroundImageUrl = "background_image_url"
        case twitterAccount = "twitter_account"
        case twitterUrl = "twitter_url"
        case pawooUrl = "pawoo_url"
        case isPremium = "is_premium"
    }
}

struct UserDetailResponse: Codable, Sendable {
    let user: PixivUser
    let profile: UserProfile?
}

struct UserPreview: Codable, Hashable, Sendable, Identifiable {
    let user: PixivUser
    let illusts: [Illust]?
    let novels: [Novel]?
    let isMuted: Bool?

    enum CodingKeys: String, CodingKey {
        case user, illusts, novels
        case isMuted = "is_muted"
    }

    var id: Int64 { user.id }
}

struct UserPreviewResponse: Codable, Sendable {
    let userPreviews: [UserPreview]
    let nextUrl: String?

    enum CodingKeys: String, CodingKey {
        case userPreviews = "user_previews"
        case nextUrl = "next_url"
    }
}

struct CommentItem: Codable, Hashable, Sendable, Identifiable {
    let id: Int64
    let comment: String?
    let date: String?
    let user: PixivUser?
    let hasReplies: Bool?
    let parentComment: ParentComment?

    enum CodingKeys: String, CodingKey {
        case id, comment, date, user
        case hasReplies = "has_replies"
        case parentComment = "parent_comment"
    }

    struct ParentComment: Codable, Hashable, Sendable {
        let id: Int64?
        let user: PixivUser?
        let comment: String?
    }
}

struct CommentsResponse: Codable, Sendable {
    let totalComments: Int?
    let comments: [CommentItem]
    let nextUrl: String?
    let commentAccessControl: Int?

    enum CodingKeys: String, CodingKey {
        case totalComments = "total_comments"
        case comments
        case nextUrl = "next_url"
        case commentAccessControl = "comment_access_control"
    }
}

struct Novel: Codable, Hashable, Sendable, Identifiable {
    let id: Int64
    let title: String?
    let caption: String?
    let imageUrls: ImageUrls?
    let user: PixivUser?
    let tags: [Tag]?
    let pageCount: Int?
    let textLength: Int?
    let isBookmarked: Bool?
    let totalBookmarks: Int?
    let totalView: Int?
    let createDate: String?
    let series: NovelSeries?
    /// Real age rating: 0 = all-ages, 1 = R-18, 2 = R-18G. Drives search R-18 filtering.
    let xRestrict: Int?
    /// 0/1 = human, 2 = AI-generated. Drives search "only AI" / "exclude AI" filtering.
    let novelAIType: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, caption
        case imageUrls = "image_urls"
        case user, tags
        case pageCount = "page_count"
        case textLength = "text_length"
        case isBookmarked = "is_bookmarked"
        case totalBookmarks = "total_bookmarks"
        case totalView = "total_view"
        case createDate = "create_date"
        case series
        case xRestrict = "x_restrict"
        case novelAIType = "novel_ai_type"
    }
}

struct NovelSeries: Codable, Hashable, Sendable {
    let id: Int64?
    let title: String?
}

// MARK: - Series detail responses

struct IllustSeriesDetail: Codable, Hashable, Sendable {
    let id: Int64?
    let title: String?
    let caption: String?
    let workCount: Int?
    let user: PixivUser?

    enum CodingKeys: String, CodingKey {
        case id, title, caption, user
        case workCount = "work_count"
    }
}

struct IllustSeriesResponse: Codable, Sendable {
    let illustSeriesDetail: IllustSeriesDetail?
    let illustSeriesFirstIllust: Illust?
    let illusts: [Illust]
    let nextUrl: String?

    enum CodingKeys: String, CodingKey {
        case illustSeriesDetail = "illust_series_detail"
        case illustSeriesFirstIllust = "illust_series_first_illust"
        case illusts
        case nextUrl = "next_url"
    }
}

struct NovelSeriesDetail: Codable, Hashable, Sendable {
    let id: Int64?
    let title: String?
    let caption: String?
    let contentCount: Int?
    let user: PixivUser?
    /// Whether the series is in the signed-in user's watchlist (追更) —
    /// initial state for the series-page toggle.
    let watchlistAdded: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, caption, user
        case contentCount = "content_count"
        case watchlistAdded = "watchlist_added"
    }
}

struct NovelSeriesDetailResponse: Codable, Sendable {
    let novelSeriesDetail: NovelSeriesDetail?
    let novelSeriesFirstNovel: Novel?
    let novels: [Novel]
    let nextUrl: String?

    enum CodingKeys: String, CodingKey {
        case novelSeriesDetail = "novel_series_detail"
        case novelSeriesFirstNovel = "novel_series_first_novel"
        case novels
        case nextUrl = "next_url"
    }
}

struct NovelResponse: Codable, Sendable {
    let novels: [Novel]
    let nextUrl: String?

    enum CodingKeys: String, CodingKey {
        case novels
        case nextUrl = "next_url"
    }
}

struct NovelDetailResponse: Codable, Sendable {
    let novel: Novel
}

struct Article: Codable, Hashable, Sendable, Identifiable {
    let id: Int64
    let title: String?
    let pureTitle: String?
    let thumbnail: String?
    let articleUrl: String?
    let publishDate: String?
    let category: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case pureTitle = "pure_title"
        case thumbnail
        case articleUrl = "article_url"
        case publishDate = "publish_date"
        case category
    }
}

struct ArticlesResponse: Codable, Sendable {
    let spotlightArticles: [Article]
    let nextUrl: String?

    enum CodingKeys: String, CodingKey {
        case spotlightArticles = "spotlight_articles"
        case nextUrl = "next_url"
    }
}

struct BookmarkTag: Codable, Hashable, Sendable, Identifiable {
    let name: String?
    let count: Int?

    var id: String { name ?? "" }
}

struct BookmarkTagsResponse: Codable, Sendable {
    let bookmarkTags: [BookmarkTag]
    let nextUrl: String?

    enum CodingKeys: String, CodingKey {
        case bookmarkTags = "bookmark_tags"
        case nextUrl = "next_url"
    }
}

struct AutoCompleteTag: Codable, Hashable, Sendable, Identifiable {
    let name: String?
    let translatedName: String?

    enum CodingKeys: String, CodingKey {
        case name
        case translatedName = "translated_name"
    }

    var id: String { (name ?? "") + "|" + (translatedName ?? "") }
}

struct AutoCompleteResponse: Codable, Sendable {
    let tags: [AutoCompleteTag]
}

// MARK: - Search options (`/v1/search/options`)

/// Dynamic, account-aware filter options pixiv's iOS app pulls to populate the
/// search filter's tool / genre / language pickers. `illust` and `novel` scopes
/// are near-symmetric (illust carries `tool`, novel carries `genre`).
struct SearchOptionsResponse: Codable, Sendable {
    let illust: Scope?
    let novel: Scope?

    struct Scope: Codable, Sendable {
        let tool: ToolOptions?
        let genre: GenreOptions?
        let lang: LangOptions?
    }

    struct ToolOptions: Codable, Sendable {
        let options: [String]
    }

    struct GenreOptions: Codable, Sendable {
        let options: [GenreOption]
    }

    struct GenreOption: Codable, Sendable, Hashable, Identifiable {
        let id: Int
        let label: String
    }

    struct LangOptions: Codable, Sendable {
        let options: [LangOption]
    }

    struct LangOption: Codable, Sendable, Hashable, Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }
}

// MARK: - Ugoira (animated illust)

struct UgoiraFrame: Codable, Hashable, Sendable {
    let file: String?
    /// Frame delay in milliseconds.
    let delay: Int?
}

struct UgoiraMetadata: Codable, Hashable, Sendable {
    let zipUrls: ImageUrls?
    let frames: [UgoiraFrame]

    enum CodingKeys: String, CodingKey {
        case zipUrls = "zip_urls"
        case frames
    }
}

struct UgoiraMetadataResponse: Codable, Sendable {
    let ugoiraMetadata: UgoiraMetadata

    enum CodingKeys: String, CodingKey {
        case ugoiraMetadata = "ugoira_metadata"
    }
}

// MARK: - User series lists (a user's own illust / novel series)

struct IllustSeriesListItem: Codable, Hashable, Sendable, Identifiable {
    let id: Int64?
    let title: String?
    let caption: String?
    let coverImageUrls: ImageUrls?
    let seriesWorkCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, caption
        case coverImageUrls = "cover_image_urls"
        case seriesWorkCount = "series_work_count"
    }
}

struct IllustSeriesListResponse: Codable, Sendable {
    let illustSeriesDetails: [IllustSeriesListItem]
    let nextUrl: String?

    enum CodingKeys: String, CodingKey {
        case illustSeriesDetails = "illust_series_details"
        case nextUrl = "next_url"
    }
}

struct NovelSeriesListItem: Codable, Hashable, Sendable, Identifiable {
    let id: Int64?
    let title: String?
    /// Series description — Shaft's `NovelSeriesAdapter` reads `display_text`.
    let displayText: String?
    let contentCount: Int?
    let totalCharacterCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, title
        case displayText = "display_text"
        case contentCount = "content_count"
        case totalCharacterCount = "total_character_count"
    }
}

struct NovelSeriesListResponse: Codable, Sendable {
    let novelSeriesDetails: [NovelSeriesListItem]
    let nextUrl: String?

    enum CodingKeys: String, CodingKey {
        case novelSeriesDetails = "novel_series_details"
        case nextUrl = "next_url"
    }
}

// MARK: - Bookmark detail (existing tags + visibility for a work)

struct BookmarkDetail: Codable, Hashable, Sendable {
    let isBookmarked: Bool?
    let tags: [BookmarkDetailTag]
    let restrict: String?

    enum CodingKeys: String, CodingKey {
        case isBookmarked = "is_bookmarked"
        case tags, restrict
    }

    /// Tags the user has registered on this bookmark.
    var registeredTags: [String] { tags.filter { $0.isRegistered == true }.compactMap { $0.name } }
}

struct BookmarkDetailTag: Codable, Hashable, Sendable {
    let name: String?
    let isRegistered: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case isRegistered = "is_registered"
    }
}

struct BookmarkDetailResponse: Codable, Sendable {
    let bookmarkDetail: BookmarkDetail

    enum CodingKeys: String, CodingKey {
        case bookmarkDetail = "bookmark_detail"
    }
}

// MARK: - Notifications (`/v1/notification/list`, `/v1/notification/view-more`)

/// Both endpoints share this envelope — view-more is a flattened sub-list of a
/// grouped item (one whose `view_more` is non-nil). See Shaft
/// `NotificationResponse.kt`.
struct NotificationListResponse: Codable, Sendable {
    let notifications: [NotificationItem]
    let nextUrl: String?

    enum CodingKeys: String, CodingKey {
        case notifications
        case nextUrl = "next_url"
    }
}

struct NotificationItem: Codable, Hashable, Sendable, Identifiable {
    let id: Int64
    let createdDatetime: String?
    /// Server hint only (7 = bookmark, 8 = follow observed); rendering relies
    /// 100% on the HTML in `content.text`, so unknown types don't break.
    let type: Int?
    let content: NotificationContent?
    /// Non-nil means this row is a group head; tapping "view more" loads the
    /// full sub-list via `/v1/notification/view-more?notification_id=id`.
    let viewMore: NotificationViewMore?
    /// Always a `pixiv://` scheme URL (illusts/users/novels) — routed in-app.
    let targetUrl: String?
    let isRead: Bool?

    enum CodingKeys: String, CodingKey {
        case id, type, content
        case createdDatetime = "created_datetime"
        case viewMore = "view_more"
        case targetUrl = "target_url"
        case isRead = "is_read"
    }

    /// Tolerate a missing `id` (defaults to 0, like upstream's `id: Long = 0L`)
    /// — one odd row must not fail the whole list decode. The UI already
    /// guards `id > 0` before id-dependent actions.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        createdDatetime = try c.decodeIfPresent(String.self, forKey: .createdDatetime)
        type = try c.decodeIfPresent(Int.self, forKey: .type)
        content = try c.decodeIfPresent(NotificationContent.self, forKey: .content)
        viewMore = try c.decodeIfPresent(NotificationViewMore.self, forKey: .viewMore)
        targetUrl = try c.decodeIfPresent(String.self, forKey: .targetUrl)
        isRead = try c.decodeIfPresent(Bool.self, forKey: .isRead)
    }
}

struct NotificationContent: Codable, Hashable, Sendable {
    /// HTML with the user name in `<b>` — render bold from that, nothing else.
    let text: String?
    let leftIcon: String?
    let leftImage: String?
    let rightIcon: String?
    let rightImage: String?

    enum CodingKeys: String, CodingKey {
        case text
        case leftIcon = "left_icon"
        case leftImage = "left_image"
        case rightIcon = "right_icon"
        case rightImage = "right_image"
    }
}

struct NotificationViewMore: Codable, Hashable, Sendable {
    let unreadExists: Bool?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case unreadExists = "unread_exists"
        case title
    }
}

// MARK: - Announcements (`/v1/info/latest`, `/v1/info/list`)

/// First-screen aggregate: a few recent entries per category, no pagination.
struct InfoLatestResponse: Codable, Sendable {
    let categorizedInfos: [CategorizedInfo]

    enum CodingKeys: String, CodingKey {
        case categorizedInfos = "categorized_infos"
    }
}

/// Single-category drill-in (`?cid=N`) — note the *singular* field name.
struct InfoListResponse: Codable, Sendable {
    let categorizedInfo: CategorizedInfo?
    let nextUrl: String?

    enum CodingKeys: String, CodingKey {
        case categorizedInfo = "categorized_info"
        case nextUrl = "next_url"
    }
}

struct CategorizedInfo: Codable, Hashable, Sendable, Identifiable {
    let categoryId: Int
    let categoryTitle: String?
    let infoList: [InfoItem]

    enum CodingKeys: String, CodingKey {
        case categoryId = "category_id"
        case categoryTitle = "category_title"
        case infoList = "info_list"
    }

    var id: Int { categoryId }
}

struct InfoItem: Codable, Hashable, Sendable, Identifiable {
    let id: Int64
    let title: String?
    let date: String?
    let url: String?
    let isRecent: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, date, url
        case isRecent = "is_recent"
    }

    /// Tolerate a missing `id` (upstream defaults to 0L) — one odd row must
    /// not fail the whole list decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        isRecent = try c.decodeIfPresent(Bool.self, forKey: .isRecent)
    }
}

// MARK: - Watchlist (`/v1/watchlist/{manga|novel}`)

/// Both manga and novel watchlists return `{series: […]}` with this item shape.
struct WatchlistResponse: Codable, Sendable {
    let series: [WatchlistItem]
    let nextUrl: String?

    enum CodingKeys: String, CodingKey {
        case series
        case nextUrl = "next_url"
    }
}

struct WatchlistItem: Codable, Hashable, Sendable, Identifiable {
    let id: Int64
    let title: String?
    let url: String?
    /// Non-nil with empty title/user means the series is masked (deleted /
    /// restricted) — show the mask text, disable navigation.
    let maskText: String?
    let publishedContentCount: Int?
    let lastPublishedContentDatetime: String?
    let latestContentId: Int64?
    let user: PixivUser?

    enum CodingKeys: String, CodingKey {
        case id, title, url, user
        case maskText = "mask_text"
        case publishedContentCount = "published_content_count"
        case lastPublishedContentDatetime = "last_published_content_datetime"
        case latestContentId = "latest_content_id"
    }

    /// Upstream `WatchlistMangaAdapter.isInvalidItem` parity: all four
    /// conditions must hold (empty title, no cover url, mask text present,
    /// zero/absent user). A missing `user` object counts as id 0 — upstream
    /// would NPE there, which is a bug, not a behavior to copy.
    var isMasked: Bool {
        (title ?? "").isEmpty && url == nil && maskText != nil && (user?.id ?? 0) == 0
    }
}

// MARK: - Novel markers (`/v2/novel/markers`)

struct NovelMarkersResponse: Codable, Sendable {
    let markedNovels: [MarkedNovel]
    let nextUrl: String?

    enum CodingKeys: String, CodingKey {
        case markedNovels = "marked_novels"
        case nextUrl = "next_url"
    }
}

struct MarkedNovel: Codable, Hashable, Sendable, Identifiable {
    let novel: Novel
    let novelMarker: NovelMarker?

    enum CodingKeys: String, CodingKey {
        case novel
        case novelMarker = "novel_marker"
    }

    var id: Int64 { novel.id }
}

struct NovelMarker: Codable, Hashable, Sendable {
    let page: Int?
}

struct SelfProfileResponse: Codable, Sendable {
    let profile: SelfProfile

    struct SelfProfile: Codable, Sendable {
        let userId: Int64?
        let pixivId: String?
        let isMailAuthorized: Bool?
        let hasMailAddress: Bool?
        let mailAddress: String?

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case pixivId = "pixiv_id"
            case isMailAuthorized = "is_mail_authorized"
            case hasMailAddress = "has_mail_address"
            case mailAddress = "mail_address"
        }
    }
}
