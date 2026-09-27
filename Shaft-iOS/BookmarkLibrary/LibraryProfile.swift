import Foundation

/// 书架内容类型 → 本地库页面上随之变化的全部差异。
///
/// 1:1 移植自 `ceui.pixiv.ui.library.LibraryProfile`。插画收藏、小说收藏、关注三种本地库共用
/// 同一个页面（`BookmarkLibraryView`）、同一个筛选面板（`BookmarkFilterSheet`）和同一个 VM，
/// 逻辑上没有任何分叉；「这是哪一种库」只决定文案、可选的排序和面板露出哪几节，全部在这里集中声明。
/// 加一种可镜像的列表 = 加一个 `MirrorContentType` + 在 `of` 里补一份档案，页面代码不用动。
struct LibraryProfile: Sendable {
    let contentType: MirrorContentType
    let publicShelf: LocalizedKey
    let privateShelf: LocalizedKey
    let openClassic: LocalizedKey
    let searchHint: LocalizedKey
    let empty: LocalizedKey
    let emptyFiltered: LocalizedKey
    /// 「正在后台补齐 · 已 N 件」，%@ = 已镜像条数。
    let syncing: LocalizedKey
    let syncQueued: LocalizedKey
    /// 「共 N 件」，%@ = 书架总数。
    let totalCount: LocalizedKey
    /// 面板底部主操作「查看 N 件」，%@ = 当前命中数。
    let showResults: LocalizedKey
    let sorts: [BookmarkSort]
    /// 作品维度的筛选（分级 / AI / 作品状态 / 人气 / 系列 / 作者）。关注书架里一行是一个人，没有这些。
    let hasWorkFilters: Bool
    /// 按 `createDateMs` 分年的那一节叫什么：作品是「发布年份」，关注是「最近投稿年份」。
    let yearSection: LocalizedKey
    let tagHint: LocalizedKey

    var isIllust: Bool { contentType == .illust }
    var isNovel: Bool { contentType == .novel }
    var isUser: Bool { contentType == .user }

    /// 同一个排序键在不同书架上的说法：关注书架的「收藏时间」是关注时间，「发布时间」是最近投稿。
    func sortLabel(_ sort: BookmarkSort) -> LocalizedKey {
        if contentType == .user {
            switch sort {
            case .bookmarkNewest: return .followingSortFollowedNewest
            case .bookmarkOldest: return .followingSortFollowedOldest
            case .createdNewest: return .followingSortActiveNewest
            case .createdOldest: return .followingSortActiveOldest
            case .titleAsc: return .followingSortNameAsc
            default: break
            }
        }
        return BookmarkSortLabels.key(sort)
    }

    private static let workSortsHead: [BookmarkSort] = [
        .bookmarkNewest, .bookmarkOldest, .createdNewest, .createdOldest, .popularDesc, .popularAsc, .viewsDesc,
    ]

    private static let illust = LibraryProfile(
        contentType: .illust,
        publicShelf: .bookmarkShelfPublicIllust,
        privateShelf: .bookmarkShelfPrivateIllust,
        openClassic: .bookmarkLibraryOpenClassic,
        searchHint: .bookmarkLibrarySearchHint,
        empty: .bookmarkLibraryEmpty,
        emptyFiltered: .bookmarkLibraryEmptyFiltered,
        syncing: .bookmarkLibrarySyncing,
        syncQueued: .bookmarkLibrarySyncQueued,
        totalCount: .bookmarkLibraryTotalCount,
        showResults: .bookmarkLibraryFilterApply,
        sorts: workSortsHead + [.pagesDesc, .titleAsc, .random],
        hasWorkFilters: true,
        yearSection: .bookmarkFilterSectionYear,
        tagHint: .bookmarkFilterTagHint
    )

    private static let novel = LibraryProfile(
        contentType: .novel,
        publicShelf: .bookmarkShelfPublicNovel,
        privateShelf: .bookmarkShelfPrivateNovel,
        openClassic: .bookmarkLibraryOpenClassic,
        searchHint: .bookmarkLibrarySearchHint,
        empty: .bookmarkLibraryEmpty,
        emptyFiltered: .bookmarkLibraryEmptyFiltered,
        syncing: .bookmarkLibrarySyncing,
        syncQueued: .bookmarkLibrarySyncQueued,
        totalCount: .bookmarkLibraryTotalCount,
        showResults: .bookmarkLibraryFilterApply,
        sorts: workSortsHead + [.lengthDesc, .lengthAsc, .titleAsc, .random],
        hasWorkFilters: true,
        yearSection: .bookmarkFilterSectionYear,
        tagHint: .bookmarkFilterTagHint
    )

    private static let user = LibraryProfile(
        contentType: .user,
        publicShelf: .bookmarkShelfPublicUser,
        privateShelf: .bookmarkShelfPrivateUser,
        openClassic: .followingLibraryOpenClassic,
        searchHint: .followingLibrarySearchHint,
        empty: .followingLibraryEmpty,
        emptyFiltered: .followingLibraryEmptyFiltered,
        syncing: .followingLibrarySyncing,
        syncQueued: .followingLibrarySyncQueued,
        totalCount: .followingLibraryTotalCount,
        showResults: .followingLibraryFilterApply,
        // 人气 / 浏览量 / 页数 / 字数都是作品的属性，对人没有意义
        sorts: [.bookmarkNewest, .bookmarkOldest, .createdNewest, .createdOldest, .titleAsc, .random],
        hasWorkFilters: false,
        yearSection: .followingFilterSectionYear,
        tagHint: .followingFilterTagHint
    )

    static func of(_ contentType: MirrorContentType) -> LibraryProfile {
        switch contentType {
        case .illust: return illust
        case .novel: return novel
        case .user: return user
        }
    }
}
