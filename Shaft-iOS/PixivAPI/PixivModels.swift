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

    enum CodingKeys: String, CodingKey {
        case id, title, caption, user
        case contentCount = "content_count"
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
