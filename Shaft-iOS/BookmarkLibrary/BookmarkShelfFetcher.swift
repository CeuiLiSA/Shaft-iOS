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

/// 一个书架的翻页协议。插画和小说各一个实现，公开/悄悄收藏只是 `restrict` 参数的差别。
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

/// 按书架类型选实现。
func fetcherFor(_ shelf: BookmarkShelf, api: PixivAPI) -> any BookmarkShelfFetcher {
    switch shelf.contentType {
    case .illust: return IllustBookmarkFetcher(shelf: shelf, api: api)
    case .novel: return NovelBookmarkFetcher(shelf: shelf, api: api)
    }
}
