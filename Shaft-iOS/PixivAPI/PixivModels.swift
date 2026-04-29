import Foundation

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
    }
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
