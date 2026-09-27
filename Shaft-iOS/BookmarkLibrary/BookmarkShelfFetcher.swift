import Foundation

/// 网络回来的一件作品：先只认 id（引擎要拿它去查「库里已有的序号」），
/// 等序号定了再 `toRow` 建行。
///
/// 做成延迟建行而不是直接给 `BookmarkMirrorEntity`，是因为 `bookmarkSeq` 只有引擎
/// 知道（要综合库里已有的值和本轮号段），而 JSON 序列化 + 标签展开又不该在引擎里重写一遍。
struct MirrorItem: Sendable {
    let id: Int64
    private let build: @Sendable (_ seq: Int64, _ generation: Int, _ now: Int64) -> MirrorRow

    init(id: Int64, build: @escaping @Sendable (_ seq: Int64, _ generation: Int, _ now: Int64) -> MirrorRow) {
        self.id = id
        self.build = build
    }

    func toRow(seq: Int64, generation: Int, now: Int64) -> MirrorRow { build(seq, generation, now) }
}

/// 一页网络结果。`nextUrl` 为空 = 这个书架翻到底了。
struct FetchedPage: Sendable {
    let items: [MirrorItem]
    let nextUrl: String?
}

/// 一个书架的翻页协议。插画收藏、小说收藏、关注各一个实现，公开/悄悄只是 `restrict` 参数的差别。
///
/// 新增可镜像的列表（例如「按收藏标签筛出来的子集」）= 加一个实现，引擎一行不用改。
protocol BookmarkShelfFetcher: Sendable {
    var shelf: BookmarkShelf { get }

    /// `nextUrl` 为 nil 拉第一页，否则续翻。抛出的异常由引擎分类处理。
    func load(nextUrl: String?) async throws -> FetchedPage
}

/// 插画/漫画收藏（`/v1/user/bookmarks/illust`）。
struct IllustBookmarkFetcher: BookmarkShelfFetcher {
    let shelf: BookmarkShelf
    let api: PixivAPI

    func load(nextUrl: String?) async throws -> FetchedPage {
        let response: IllustResponse
        if let nextUrl {
            response = try await api.nextPage(nextUrl)
        } else {
            response = try await api.userBookmarkedIllusts(shelf.ownerUid, restrict: shelf.restrict.apiValue)
        }
        let shelf = shelf
        return FetchedPage(
            items: response.illusts.map { illust in
                MirrorItem(id: illust.id) { seq, generation, now in
                    BookmarkMirrorMapper.fromIllust(shelf: shelf, illust: illust, bookmarkSeq: seq, generation: generation, now: now)
                }
            },
            nextUrl: response.nextUrl.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

/// 小说收藏（`/v1/user/bookmarks/novel`）。
struct NovelBookmarkFetcher: BookmarkShelfFetcher {
    let shelf: BookmarkShelf
    let api: PixivAPI

    func load(nextUrl: String?) async throws -> FetchedPage {
        let response: NovelResponse
        if let nextUrl {
            response = try await api.nextPage(nextUrl)
        } else {
            response = try await api.userBookmarkedNovels(shelf.ownerUid, restrict: shelf.restrict.apiValue)
        }
        let shelf = shelf
        return FetchedPage(
            items: response.novels.map { novel in
                MirrorItem(id: novel.id) { seq, generation, now in
                    BookmarkMirrorMapper.fromNovel(shelf: shelf, novel: novel, bookmarkSeq: seq, generation: generation, now: now)
                }
            },
            nextUrl: response.nextUrl.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

/// 关注的用户（`/v1/user/following`）。
///
/// 与收藏接口的区别只有一处：它的 next_url 是 **offset** 游标而不是 `max_bookmark_id`，
/// 对翻页途中的增删不稳定：
/// - 途中新关注一位 → 整体后移一格，下一页头一条是上一页见过的，按 id 沿用旧序号、无害；
/// - 途中取关一位 → 整体前移一格，下一页会**跳过一位仍在关注的人**。回填时他就缺席到下次重扫；
///   重扫时更糟 —— 这一轮没见过他，收尾的 `deleteStaleRows` 会把一个仍在关注的人删掉。
///   而「一边在关注库里取关、一边后台在扫」恰恰是最自然的操作。
///
/// 所以每页的续传 offset 回退 `pageOverlap` 格，让相邻两页重叠（见 `overlapNextUrl`）：
/// 两页之间最多取关 `pageOverlap` 位都不会漏人。重叠的人是已知 id，写入幂等；
/// 限速看的是请求间隔，重叠只让全量多翻几页，不提高请求频率。
struct FollowingUserFetcher: BookmarkShelfFetcher {
    let shelf: BookmarkShelf
    let api: PixivAPI

    /// 一页 30 位，回退 5 位：全量多翻约 1/5 的页数，换两页之间容得下 5 次取关。
    static let pageOverlap = 5

    func load(nextUrl: String?) async throws -> FetchedPage {
        let response: UserPreviewResponse
        if let nextUrl {
            response = try await api.nextPage(nextUrl)
        } else {
            response = try await api.userFollowing(shelf.ownerUid, restrict: shelf.restrict.apiValue)
        }
        let shelf = shelf
        return FetchedPage(
            // 没有身份的预览（id ≤ 0）渲染不出卡片，同原关注列表的口径丢掉
            items: response.userPreviews.compactMap { preview in
                guard preview.user.id > 0 else { return nil }
                return MirrorItem(id: preview.user.id) { seq, generation, now in
                    BookmarkMirrorMapper.fromUserPreview(shelf: shelf, preview: preview, bookmarkSeq: seq, generation: generation, now: now)
                }
            },
            nextUrl: overlapNextUrl(
                requested: nextUrl,
                next: response.nextUrl.flatMap { $0.isEmpty ? nil : $0 },
                overlap: Self.pageOverlap
            )
        )
    }
}

/// 把 offset 型 next_url 的 `offset` 回退 `overlap` 格，但**绝不回退到当前页或更早**
/// （否则引擎会原地打转）。不是 offset 型的 URL、解析不了的 URL 原样返回。
///
/// - Parameter requested: 本页请求用的 URL（nil = 第一页，offset 视为 0）
func overlapNextUrl(requested: String?, next: String?, overlap: Int) -> String? {
    guard let next, var components = URLComponents(string: next),
          let nextOffset = components.queryItems?.first(where: { $0.name == "offset" })?.value.flatMap(Int.init)
    else { return next }
    let current = requested.flatMap { URLComponents(string: $0) }?
        .queryItems?.first(where: { $0.name == "offset" })?.value.flatMap(Int.init) ?? 0
    let rewound = max(nextOffset - overlap, current + 1)
    if rewound >= nextOffset { return next }
    components.queryItems = components.queryItems?.map {
        $0.name == "offset" ? URLQueryItem(name: "offset", value: String(rewound)) : $0
    }
    return components.url?.absoluteString ?? next
}

/// 按书架类型选实现。
func fetcherFor(_ shelf: BookmarkShelf, api: PixivAPI) -> any BookmarkShelfFetcher {
    switch shelf.contentType {
    case .illust: return IllustBookmarkFetcher(shelf: shelf, api: api)
    case .novel: return NovelBookmarkFetcher(shelf: shelf, api: api)
    case .user: return FollowingUserFetcher(shelf: shelf, api: api)
    }
}
