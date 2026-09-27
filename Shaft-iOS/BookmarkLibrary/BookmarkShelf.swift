import Foundation

/// 一个可镜像的「书架」= 谁的列表 × 什么内容 × 什么可见性。
///
/// 「关注」也叫书架而不另起一套：pixiv 的关注列表和收藏列表是同一种东西 —— 按时间倒序、
/// 分公开/私人、只能顺着 next_url 翻 —— 引擎、续传、限速、全量重扫一行都不用分叉，
/// 差别只在翻页接口（`BookmarkShelfFetcher`）和摊平哪些列（`BookmarkMirrorMapper`）。
///
/// 1:1 移植自 Pixiv-Shaft `ceui.pixiv.db.mirror.BookmarkShelf`。整套镜像系统（表、引擎、
/// 查询）都以 [BookmarkShelf] 为分区单位，**不是**围绕「我的插画公开收藏」这一种情况写死的：
/// 插画/小说、公开/悄悄收藏（private）各自是一个独立书架，各自有独立的续传游标与完成标记，
/// 互不干扰；将来要镜像别人的收藏也只是多一个 ownerUid，不需要动引擎。
///
/// `key` 是入库的分区列（`bookmark_mirror_table.shelfKey`），所有查询的第一个 WHERE 条件、
/// 所有复合索引的第一列都是它——一张表存 N 个书架，但每次查询只在自己那一段里走索引。
///
/// 编码刻意是「type:restrict:uid」而不是 uid 打头：书架数量极少（每账号 4 个），
/// 前缀可读性远比前缀分布重要，日志里一眼能认出是哪个书架。
struct BookmarkShelf: Hashable, Sendable, Codable {
    let ownerUid: Int64
    let contentType: MirrorContentType
    let restrict: MirrorRestrict

    var key: String { "\(contentType.code):\(restrict.code):\(ownerUid)" }

    /// 日志用的人类可读标签，例：`illust/public#12345`。
    var label: String { "\(contentType.tag)/\(restrict.apiValue)#\(ownerUid)" }

    func with(restrict: MirrorRestrict) -> BookmarkShelf {
        BookmarkShelf(ownerUid: ownerUid, contentType: contentType, restrict: restrict)
    }

    func with(contentType: MirrorContentType) -> BookmarkShelf {
        BookmarkShelf(ownerUid: ownerUid, contentType: contentType, restrict: restrict)
    }

    func with(ownerUid: Int64) -> BookmarkShelf {
        BookmarkShelf(ownerUid: ownerUid, contentType: contentType, restrict: restrict)
    }

    /// 从 [key] 还原。格式不认识返回 nil（库里读到脏行时用，不抛）。
    static func parse(_ key: String) -> BookmarkShelf? {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let typeCode = Int(parts[0]), let type = MirrorContentType.of(typeCode),
              let restrictCode = Int(parts[1]), let restrict = MirrorRestrict.of(restrictCode),
              let uid = Int64(parts[2]) else { return nil }
        return BookmarkShelf(ownerUid: uid, contentType: type, restrict: restrict)
    }

    /// 某账号的全部书架（每种内容类型 × 公开/悄悄）。
    static func allOf(ownerUid: Int64) -> [BookmarkShelf] {
        MirrorContentType.allCases.flatMap { type in
            MirrorRestrict.allCases.map { BookmarkShelf(ownerUid: ownerUid, contentType: type, restrict: $0) }
        }
    }
}

/// 镜像的内容类型。`code` 是入库值，**不能改**（改了等于把存量行的类型全认错）。
enum MirrorContentType: Int, CaseIterable, Sendable, Codable, Hashable {
    case illust = 0
    case novel = 1
    /// 关注的用户（`/v1/user/following`）。一行 = 一位关注的用户，payload 是 `UserPreview`。
    case user = 2

    var code: Int { rawValue }

    var tag: String {
        switch self {
        case .illust: return "illust"
        case .novel: return "novel"
        case .user: return "user"
        }
    }

    static func of(_ code: Int) -> MirrorContentType? { MirrorContentType(rawValue: code) }
}

/// 收藏可见性。`apiValue` 直接是 pixiv 的 `restrict` 参数值，`code` 是入库值（不能改）。
///
/// PRIVATE 就是「悄悄收藏 / 私人关注」：它与 PUBLIC 是**两条互不相交的列表**（pixiv 的
/// `/v1/user/bookmarks/…`、`/v1/user/following` 一次只回一种），所以必须是两个书架，不能靠一列布尔混在一起
/// ——混在一起就没法各自记续传游标，也没法各自判「同步完成过一次」。
enum MirrorRestrict: Int, CaseIterable, Sendable, Codable, Hashable {
    case `public` = 0
    case `private` = 1

    var code: Int { rawValue }

    var apiValue: String {
        switch self {
        case .public: return "public"
        case .private: return "private"
        }
    }

    static func of(_ code: Int) -> MirrorRestrict? { MirrorRestrict(rawValue: code) }

    /// 从 pixiv 的 restrict 字符串还原；不认识按 PUBLIC 兜底（对齐各调用点的默认值）。
    static func ofApiValue(_ value: String?) -> MirrorRestrict {
        value == "private" ? .private : .public
    }
}

/// `BookmarkMirrorStateEntity.phase` 的取值。入库值不能改。
enum MirrorPhase: Int, Sendable {
    /// 从未开始过。
    case never = 0
    /// 首次全量回填进行中（可能已经跑了一半，`nextUrl` 是断点）。
    case backfilling = 1
    /// 已完成过一次全量，之后只做增量维护。
    case synced = 2
    /// 到期全量重扫进行中（为了发现在别处取消的收藏）。表里的行照常可读。
    case resweeping = 3

    static func name(_ phase: Int) -> String {
        switch MirrorPhase(rawValue: phase) {
        case .never?: return "NEVER"
        case .backfilling?: return "BACKFILLING"
        case .synced?: return "SYNCED"
        case .resweeping?: return "RESWEEPING"
        case nil: return "UNKNOWN(\(phase))"
        }
    }
}

/// 一个书架的镜像同步状态。**一个书架一行，进程被杀就靠它续上**。
///
/// 断点续传的全部信息都在这里，而且是**每翻一页就落一次盘**：杀进程、崩溃、掉网、
/// 用户手动清后台，下次启动读回 `nextUrl` 从那一页接着翻，绝不从头再来一遍
/// （从头再来一遍不仅慢，更要命的是白白多打几百次请求去撞 pixiv 的频控）。
///
/// `phase` 的状态机：
/// ```
///   NEVER ──开始回填──▶ BACKFILLING ──走到 next_url 为空──▶ SYNCED
///                          ▲   │                              │
///                          └───┘ 每页落盘 nextUrl，杀进程后从这里续          │
///                                                                          │
///   SYNCED ──增量维护（只走表头几页）──▶ SYNCED                            │
///   SYNCED ──到期全量重扫（发现别处取消的收藏）──▶ RESWEEPING ─────────────┘
/// ```
/// `firstCompletedAt` > 0 就是「同步完成过一次」的判据：从此之后引擎只做维护，
/// 界面也可以放心地把本地表当作**完整**的收藏列表来排序/筛选。
struct BookmarkMirrorStateEntity: Hashable, Sendable {
    var shelfKey: String
    var ownerUid: Int64
    var contentType: Int
    /// 见 `MirrorRestrict.code`。列名避开 SQLite 的 RESTRICT 关键字。
    var restrictCode: Int

    /// 见 `MirrorPhase`。
    var phase: Int

    /// 续传游标：下一页的 `next_url`（内含 pixiv 的 `max_bookmark_id` keyset 游标，
    /// 对期间新增/取消的收藏是稳定的）。nil = 从第一页开始。
    var nextUrl: String?

    /// 当前（或最近一次）全量扫描的代号，收尾时用来删失联行。
    var generation: Int

    /// 全量回填下一个要分配的序号（0 起逐条递减），见 `BookmarkMirrorEntity.bookmarkSeq`。
    var nextBackfillSeq: Int64

    /// 增量维护给**新收藏**分配序号的游标（在当前号段内**向下**发号）。
    ///
    /// 为什么要「号段 + 向下发号」这么绕：维护是从表头往后翻的，所以**先遇到的更新**，
    /// 序号必须**更大**；而我们又是一页一落盘（随时可能被杀），不能等整轮跑完再统一编号。
    /// 于是每轮开跑时先占一整段号（`headBlockCeiling` 抬高一个 HEAD_SEQ_BLOCK），
    /// 段内从顶往下发：先遇到的拿大号，页与页之间也自然递减，且这一轮的全部号段都高于
    /// 上一轮 —— 无论从哪一页被杀、从哪一页续上，顺序都不会乱。
    var headSeqCursor: Int64
    /// 当前号段的顶。下一轮从 `headBlockCeiling + HEAD_SEQ_BLOCK` 重新开段。
    var headBlockCeiling: Int64

    /// 本轮已翻页数 / 已见条目数，纯观测用（日志与状态条）。
    var pagesThisRun: Int
    var itemsThisRun: Int

    /// 首次全量完成的时间戳；> 0 = 「同步完成过一次」。
    var firstCompletedAt: Int64
    /// 最近一次成功跑完（回填完成 / 维护完成）的时间。
    var lastSyncedAt: Int64
    /// 最近一次全量重扫完成的时间，决定下次何时再重扫。
    var lastFullSweepAt: Int64

    /// 最近一次失败的时间与原因（人类可读，只进日志与调试页，不做协议）。
    var lastErrorAt: Int64
    var lastError: String?
    /// 连续失败次数，驱动指数退避；成功一次即清零。
    var consecutiveFailures: Int

    /// 被限流后的解冻时刻（epoch ms）。撞过 429 就把整个引擎冻到这个点之后，
    /// 并且**这一轮之后的每页间隔也会被永久放大**（见 `BookmarkMirrorService`）。
    var cooldownUntil: Int64

    var updatedAt: Int64

    var shelf: BookmarkShelf? { BookmarkShelf.parse(shelfKey) }

    var isFirstSyncDone: Bool { firstCompletedAt > 0 }
}

/// 收藏镜像的一行 = 某个书架（`BookmarkShelf`）里的一件作品。
///
/// ## 为什么要有这张表
///
/// pixiv 的 `/v1/user/bookmarks/…` 只能**从新到旧**顺着 `max_bookmark_id` 游标翻，
/// 既不能倒序、不能跳页，也不能按作者/热度/年份/长宽比筛。想看三年前收藏的那张图，
/// 只能一路滑几百页。在服务端能力不变的前提下，唯一的根治办法是**把整个收藏列表镜像到
/// 本地**，之后所有排序与筛选都在 SQLite 里做。
///
/// ## 收藏顺序怎么表达（`bookmarkSeq`）
///
/// pixiv 不回收藏时间，只保证列表是「新收藏在前」。所以顺序由本地分配的单调序号承载，
/// **约定：值越大 = 收藏得越晚**。
///
/// - **首次全量回填**从头往后走，第一条（最新的那条）拿 0，之后逐条递减：0, -1, -2 …
///   于是 `ORDER BY bookmarkSeq DESC` = 官方顺序，`ASC` = 倒序。
/// - **之后的增量维护**只从头走，新发现的条目拿正数号段里的号。新条目天然大于所有存量条目，
///   顺序自洽，**永远不需要给老行重新编号**。
///
/// ## 为什么要去规范化这一堆列
///
/// `payloadJson` 已经是完整的 `Illust` / `Novel` JSON，渲染卡片够用了。但「花式筛选」
/// 要的是**在 SQLite 里**按作者、热度、年份、AI、R-18、页数、长宽比过滤和排序——
/// 逐行反序列化 3 万条 JSON 再在内存里筛，是几百毫秒到几秒的量级。所以把可筛选的标量在
/// 入库时一次性摊平成列，配上复合索引（见 `BookmarkMirrorDatabase.schema`），
/// 查询就是纯索引扫描；JSON 只在真正要渲染那 60 张卡时才解析。
struct BookmarkMirrorEntity: Hashable, Sendable {
    /// 分区键，见 `BookmarkShelf.key`。
    var shelfKey: String
    /// 作品 id（illust id 或 novel id）。与 `shelfKey` 组成主键。
    var targetId: Int64

    // ── 书架身份的展开列（shelfKey 已经能推出它们，摊平只为免去在 SQL 里解析字符串）──
    var ownerUid: Int64
    var contentType: Int
    var restrictCode: Int

    /// 收藏顺序序号，越大越新。见类文档。
    var bookmarkSeq: Int64

    /// 完整的 `Illust` / `Novel` / `UserPreview` JSON，渲染时才反序列化。
    var payloadJson: String

    // ── 去规范化的筛选/排序列 ──────────────────────────────────────────────
    var title: String
    var authorId: Int64
    var authorName: String
    /// `illust` / `manga` / `ugoira` / `novel` / `user`。
    var workType: String
    /// 插画页数；小说恒 1。
    var pageCount: Int
    var width: Int
    var height: Int
    /// 宽高比（width/height），未知为 0。小说恒 0。
    var aspectRatio: Double
    /// 画幅取向，见 `BookmarkMirrorMapper.Orientation`：0=未知 1=横图 2=竖图 3=方图。
    var orientation: Int
    var totalBookmarks: Int
    var totalView: Int
    /// 小说字数；插画恒 0。
    var textLength: Int
    /// 作品发布时间（epoch ms），解析不出为 0。
    var createDateMs: Int64
    /// pixiv 的 AI 标记：0=未知 1=否 2=是。
    var aiType: Int
    /// 0=全年龄 1=R-18 2=R-18G。
    var xRestrict: Int
    var sanityLevel: Int
    /// 作品是否仍可见（被删/仅限好P友 = false）。
    var isVisible: Bool
    var isMuted: Bool
    var seriesId: Int64
    var tagCount: Int

    /// 全文检索列：标题 + 作者名 + 全部标签（含译名），**已小写归一**。
    ///
    /// 刻意不上 FTS：pixiv 的标题/标签绝大多数是日文，系统 SQLite 的分词器不切 CJK，
    /// 建了 FTS 也只对拉丁词有效。这里一行文本配 `LIKE '%kw%'` 对 CJK 是**正确**的，
    /// 在单个书架几万行的量级上也就几十毫秒。
    var searchText: String

    /// 这一行最近一次从网络刷新的时间。
    var syncedAt: Int64
    /// 写入这一行时的全量扫描代号。全量重扫收尾时删掉 `generation < 当前代号` 的行，
    /// 即「服务端已经没有它了」——这是唯一能发现「在别处取消了收藏」的机制。
    var generation: Int
}

/// 收藏镜像的标签倒排表：一件作品的每个标签一行。
///
/// 主表已经把标签拼进 `searchText` 了，为什么还要单开一张？因为「花式筛选」对标签的要求
/// 不是模糊匹配，而是**集合运算**：精确命中、多标签 AND、标签云 / facet 计数。
/// 这三件事在倒排表上都是走索引的一次聚合，在主表上则是全表 + 逐行拆字符串。
///
/// `tagName` 是**小写归一**后的名字（匹配与去重都按它），`displayName` 保留原始大小写
/// 用于展示，`translatedName` 给中文用户看译名。主键 (shelfKey, targetId, tagName)
/// 天然把同一作品的重名标签去重（pixiv 偶尔会重复下发）。
struct BookmarkMirrorTagEntity: Hashable, Sendable {
    var shelfKey: String
    var targetId: Int64
    var tagName: String
    var displayName: String
    var translatedName: String
}

/// 标签云 / facet 查询的投影：一个标签 + 它在当前筛选结果里的命中数。
struct BookmarkTagFacet: Hashable, Sendable, Identifiable {
    var tagName: String
    var displayName: String
    var translatedName: String
    var hitCount: Int
    var id: String { tagName }
}

/// 作者 facet 的投影：一个作者 + 他在当前书架里被收藏了多少件。
struct BookmarkAuthorFacet: Hashable, Sendable, Identifiable {
    var authorId: Int64
    var authorName: String
    var hitCount: Int
    var id: Int64 { authorId }
}

/// 年份 facet 投影。
struct BookmarkYearFacet: Hashable, Sendable, Identifiable {
    var year: Int
    var hitCount: Int
    var id: Int { year }
}

/// 一条作品映射出来的全部行：主表一行 + 标签表 N 行。
struct MirrorRow: Sendable {
    var row: BookmarkMirrorEntity
    var tags: [BookmarkMirrorTagEntity]
}
