import Foundation

/// 「花式筛选」的筛选条件。**纯数据**，界面把它当状态传，`BookmarkMirrorQuery` 把它翻译成 SQL。
///
/// 1:1 移植自 `ceui.pixiv.db.mirror.BookmarkFilter`。加一个筛选维度只需要：这里加一个字段 →
/// `BookmarkMirrorQuery.buildWhere` 加一段条件 →（若要走索引）在 `BookmarkMirrorDatabase.schema`
/// 加列与索引。三处对齐，别处不动。
struct BookmarkFilter: Hashable, Sendable {
    var shelfKey: String

    /// 自由文本，空格分词后逐词 AND 匹配 `BookmarkMirrorEntity.searchText`。
    var keyword: String = ""

    /// 必须命中的标签（**小写归一**后的 tagName）。
    var tagNames: [String] = []
    /// true = 全部命中（AND），false = 命中任一（OR）。
    var tagMatchAll: Bool = true
    /// 必须不命中的标签（小写归一）。
    var excludedTagNames: [String] = []

    var authorIds: [Int64] = []
    /// `illust` / `manga` / `ugoira` / `novel`，空 = 不限。
    var workTypes: [String] = []
    /// 见 `BookmarkMirrorMapper.Orientation`，空 = 不限。
    var orientations: [Int] = []

    var ai: AiFilter = .any
    var age: AgeFilter = .any
    var pages: PageFilter = .any
    var validity: ValidityFilter = .any

    var minBookmarks: Int? = nil
    var maxBookmarks: Int? = nil
    var minTextLength: Int? = nil
    var maxTextLength: Int? = nil
    /// 作品发布时间区间（epoch ms），闭区间；nil = 不限。
    var createdFromMs: Int64? = nil
    var createdToMs: Int64? = nil
    /// 只看属于某个系列的作品。
    var seriesOnly: Bool = false

    var sort: BookmarkSort = .bookmarkNewest
    /// `BookmarkSort.random` 的种子：同一个种子翻页顺序稳定，换一个就重新洗牌。
    var randomSeed: Int64 = 1

    init(shelfKey: String) {
        self.shelfKey = shelfKey
    }

    /// 除了书架本身，用户还额外加了条件吗（界面上「清空筛选」按钮的可用性）。
    var hasAnyCondition: Bool {
        !keyword.trimmingCharacters(in: .whitespaces).isEmpty || !tagNames.isEmpty || !excludedTagNames.isEmpty ||
            !authorIds.isEmpty || !workTypes.isEmpty || !orientations.isEmpty ||
            ai != .any || age != .any || pages != .any ||
            validity != .any || minBookmarks != nil || maxBookmarks != nil ||
            minTextLength != nil || maxTextLength != nil ||
            createdFromMs != nil || createdToMs != nil || seriesOnly
    }

    /// chip 上那个数字：用户开了几个筛选维度。排序不算——它不减少结果。
    var conditionCount: Int {
        var count = 0
        if !keyword.trimmingCharacters(in: .whitespaces).isEmpty { count += 1 }
        if !tagNames.isEmpty { count += 1 }
        if !excludedTagNames.isEmpty { count += 1 }
        if !authorIds.isEmpty { count += 1 }
        if !workTypes.isEmpty { count += 1 }
        if !orientations.isEmpty { count += 1 }
        if ai != .any { count += 1 }
        if age != .any { count += 1 }
        if pages != .any { count += 1 }
        if validity != .any { count += 1 }
        if minBookmarks != nil || maxBookmarks != nil { count += 1 }
        if minTextLength != nil || maxTextLength != nil { count += 1 }
        if createdFromMs != nil || createdToMs != nil { count += 1 }
        if seriesOnly { count += 1 }
        return count
    }
}

enum AiFilter: Sendable, Hashable { case any, onlyAI, excludeAI }

enum AgeFilter: Sendable, Hashable { case any, allAges, r18, r18g }

enum PageFilter: Sendable, Hashable { case any, singlePage, multiPage }

enum ValidityFilter: Sendable, Hashable { case any, validOnly, invalidOnly }

/// 排序方式。`orderBy` 里的列名是**白名单常量**，永远不拼用户输入 —— 用户给的值一律走 `?` 绑定。
///
/// `bookmarkOldest` 就是这套系统存在的直接理由：收藏多了以后想看很久以前收藏的东西，
/// 只能一路滑。服务端给不了倒序，本地表一句 `ASC` 就有了。
enum BookmarkSort: Sendable, Hashable, CaseIterable {
    /// 收藏时间：新 → 旧（= pixiv 官方顺序）。
    case bookmarkNewest
    /// 收藏时间：旧 → 新。
    case bookmarkOldest
    /// 作品发布时间：新 → 旧 / 旧 → 新。
    ///
    /// 刻意**不**写成 `createDateMs = 0 ASC, createDateMs DESC` 去把「发布时间未知」的
    /// 作品钉在末尾：ORDER BY 里一出现表达式，`(shelfKey, createDateMs)` 索引就用不上了。
    case createdNewest
    case createdOldest
    /// 人气（总收藏数）。
    case popularDesc
    case popularAsc
    /// 浏览量。
    case viewsDesc
    /// 页数（找「长漫画」用）。
    case pagesDesc
    /// 字数（小说书架用）。
    case lengthDesc
    case lengthAsc
    /// 标题字典序，找特定作品用。不加 `COLLATE NOCASE`：pixiv 标题以日文为主，
    /// 大小写折叠几乎没有意义，却会让 `(shelfKey, title)` 索引失效。
    case titleAsc
    /// 随机漫游：种子在 SQL 里参与哈希，翻页稳定。
    case random

    var orderBy: String {
        switch self {
        case .bookmarkNewest: return "bookmarkSeq DESC"
        case .bookmarkOldest: return "bookmarkSeq ASC"
        case .createdNewest: return "createDateMs DESC"
        case .createdOldest: return "createDateMs ASC"
        case .popularDesc: return "totalBookmarks DESC"
        case .popularAsc: return "totalBookmarks ASC"
        case .viewsDesc: return "totalView DESC"
        case .pagesDesc: return "pageCount DESC"
        case .lengthDesc: return "textLength DESC"
        case .lengthAsc: return "textLength ASC"
        case .titleAsc: return "title ASC"
        case .random: return ""
        }
    }

    /// 这个排序键在**单个书架内是否已经唯一**。唯一就不需要再补全序兜底键 —— 而少补一列，
    /// `(shelfKey, <排序键>)` 索引就能独力满足整个 ORDER BY，SQLite 不再 `USE TEMP B-TREE`。
    /// `bookmarkSeq` 按构造就是书架内唯一的（见号段设计），其余排序键大量并列，必须补兜底键，
    /// 否则 LIMIT/OFFSET 翻页会漏条目 / 出重复。
    var uniqueKey: Bool {
        switch self {
        case .bookmarkNewest, .bookmarkOldest: return true
        default: return false
        }
    }

    var isRandom: Bool { self == .random }
}

/// SQL 绑定值。用户输入（关键词、标签名、作者 id、数值区间）一律经它绑定，绝不拼进 SQL。
enum SQLValue: Sendable, Hashable {
    case int(Int64)
    case real(Double)
    case text(String)
    case null
}

/// 一条可执行的 SQL：语句里的列名与顺序全是白名单常量，`args` 按 `?` 出现顺序绑定。
struct SQLQuery: Sendable, Hashable {
    let sql: String
    let args: [SQLValue]
}

/// `BookmarkFilter` → 可执行的 SQL。
///
/// 1:1 移植自 `ceui.pixiv.db.mirror.BookmarkMirrorQuery`。全部走位置参数：条件片段是代码里的
/// 常量字符串，用户输入一律 `?` 绑定，没有任何一处字符串拼接用户值。
///
/// 四个出口共用同一段 WHERE：
/// - `rows`         列表本体（LIMIT/OFFSET 分页）
/// - `count`        命中总数（界面上的「共 N 件」）
/// - `tagFacets`    当前结果里的标签云（= 可以继续下钻的标签及其条数）
/// - `authorFacets` 当前结果里的作者云
enum BookmarkMirrorQuery {

    static let rowsTable = "bookmark_mirror_table"
    static let tagsTable = "bookmark_mirror_tag_table"

    /// LIKE 的转义符。标题/标签里真出现 `%` `_` 的时候不该当通配符。
    private static let likeEscape: Character = "\\"

    /// 关键词分词的上限：多到这个数已经不是检索而是误输入，再多只是白白拖慢 LIKE。
    private static let maxKeywordTerms = 8

    static func rows(_ filter: BookmarkFilter, limit: Int, offset: Int) -> SQLQuery {
        var args: [SQLValue] = []
        let whereClause = buildWhere(filter, &args)
        let sql = "SELECT * FROM \(rowsTable) WHERE \(whereClause) ORDER BY \(orderClause(filter)) LIMIT ? OFFSET ?"
        args.append(.int(Int64(limit)))
        args.append(.int(Int64(offset)))
        return SQLQuery(sql: sql, args: args)
    }

    /// 默认顺序的续页锚定收藏序号：前面新增 / 删除行不会使下一页漂移（#1109）。
    static func rowsAfter(shelfKey: String, afterSeq: Int64, limit: Int) -> SQLQuery {
        SQLQuery(
            sql: "SELECT * FROM \(rowsTable) WHERE shelfKey = ? AND bookmarkSeq < ? ORDER BY bookmarkSeq DESC LIMIT ?",
            args: [.text(shelfKey), .int(afterSeq), .int(Int64(limit))]
        )
    }

    static func count(_ filter: BookmarkFilter) -> SQLQuery {
        var args: [SQLValue] = []
        let whereClause = buildWhere(filter, &args)
        return SQLQuery(sql: "SELECT COUNT(*) FROM \(rowsTable) WHERE \(whereClause)", args: args)
    }

    /// 当前筛选结果里的标签频次表。
    ///
    /// 刻意把已选标签也算进筛选条件（而不是把它们从条件里摘掉）：这样列出来的就是
    /// 「和已选标签**共现**的标签」，正是继续下钻时想看的东西。
    static func tagFacets(_ filter: BookmarkFilter, limit: Int) -> SQLQuery {
        var args: [SQLValue] = [.text(filter.shelfKey)]
        let whereClause = buildWhere(filter, &args)
        let sql = "SELECT t.tagName AS tagName, MAX(t.displayName) AS displayName, " +
            "MAX(t.translatedName) AS translatedName, COUNT(*) AS hitCount " +
            "FROM \(tagsTable) t WHERE t.shelfKey = ? AND t.targetId IN " +
            "(SELECT targetId FROM \(rowsTable) WHERE \(whereClause)) " +
            "GROUP BY t.tagName ORDER BY hitCount DESC, t.tagName ASC LIMIT ?"
        args.append(.int(Int64(limit)))
        return SQLQuery(sql: sql, args: args)
    }

    static func authorFacets(_ filter: BookmarkFilter, limit: Int) -> SQLQuery {
        var args: [SQLValue] = []
        let whereClause = buildWhere(filter, &args)
        let sql = "SELECT authorId AS authorId, MAX(authorName) AS authorName, COUNT(*) AS hitCount " +
            // 排除空作者名：失效/被删作品的 payload 里 user.name 是空串，放进作者云会渲染成
            // 一个光秃秃的数字 chip。它们由「作品状态」那一档筛选覆盖，不该混进作者维度。
            "FROM \(rowsTable) WHERE \(whereClause) AND authorId > 0 AND authorName != '' " +
            "GROUP BY authorId ORDER BY hitCount DESC, authorName ASC LIMIT ?"
        args.append(.int(Int64(limit)))
        return SQLQuery(sql: sql, args: args)
    }

    /// 「我收藏过的年份」——年份筛选器的可选项，顺带给出每年多少件。
    static func yearFacets(shelfKey: String) -> SQLQuery {
        SQLQuery(
            // 按**本地时区**切年：选中某一年时筛选面板按本地日历算区间，这里若按 UTC 切，
            // 元旦前后发布的作品会被数进相邻那一年，件数与点进去的结果对不上。
            sql: "SELECT CAST(strftime('%Y', createDateMs / 1000, 'unixepoch', 'localtime') AS INTEGER) AS year, COUNT(*) AS hitCount " +
                "FROM \(rowsTable) WHERE shelfKey = ? AND createDateMs > 0 " +
                "GROUP BY year ORDER BY year DESC",
            args: [.text(shelfKey)]
        )
    }

    // MARK: 内部

    private static func orderClause(_ filter: BookmarkFilter) -> String {
        let primary: String
        if filter.sort.isRandom {
            // 确定性洗牌：种子由界面生成、是本地 Int64，不是用户输入，可以安全内联
            // （绑定参数放进 ORDER BY 表达式在部分 SQLite 版本上会被当成常量列序号）。
            primary = "(targetId * 2654435761 + \(filter.randomSeed)) % 1000000007"
        } else {
            primary = filter.sort.orderBy
        }
        // 排序键本身已经唯一时不再补兜底键：多那一列会让 SQLite 为「ORDER BY 的最后一项」
        // 起一棵临时 B 树。键不唯一时兜底键是必须的：并列行的相对次序 SQLite 不保证，
        // 而我们是 LIMIT/OFFSET 翻页的，次序一抖就会出现某条重复出现、另一条永远看不到。
        return filter.sort.uniqueKey ? primary : "\(primary), targetId DESC"
    }

    /// 拼 WHERE，同时把绑定值按出现顺序追加进 `args`。
    private static func buildWhere(_ filter: BookmarkFilter, _ args: inout [SQLValue]) -> String {
        var clauses: [String] = []

        clauses.append("shelfKey = ?")
        args.append(.text(filter.shelfKey))

        appendKeyword(filter, &clauses, &args)
        appendTags(filter, &clauses, &args)
        appendInList(&clauses, &args, column: "authorId", values: filter.authorIds.map { SQLValue.int($0) })
        appendInList(&clauses, &args, column: "workType", values: filter.workTypes.map { SQLValue.text($0) })
        appendInList(&clauses, &args, column: "orientation", values: filter.orientations.map { SQLValue.int(Int64($0)) })

        switch filter.ai {
        case .any: break
        // pixiv 的 ai_type：0=未知 1=否 2=是。只有 2 是明确的 AI 生成。
        case .onlyAI: clauses.append("aiType = 2")
        case .excludeAI: clauses.append("aiType != 2")
        }

        switch filter.age {
        case .any: break
        case .allAges: clauses.append("xRestrict = 0")
        case .r18: clauses.append("xRestrict = 1")
        case .r18g: clauses.append("xRestrict = 2")
        }

        switch filter.pages {
        case .any: break
        case .singlePage: clauses.append("pageCount <= 1")
        case .multiPage: clauses.append("pageCount > 1")
        }

        switch filter.validity {
        case .any: break
        case .validOnly: clauses.append("isVisible = 1")
        // 「失效的收藏」单独看得见，才谈得上清理它们
        case .invalidOnly: clauses.append("isVisible = 0")
        }

        appendRange(&clauses, &args, column: "totalBookmarks",
                    min: filter.minBookmarks.map { Int64($0) }, max: filter.maxBookmarks.map { Int64($0) })
        appendRange(&clauses, &args, column: "textLength",
                    min: filter.minTextLength.map { Int64($0) }, max: filter.maxTextLength.map { Int64($0) })
        // 发布时间未知（0）的作品不该混进任何一个年份区间里
        if filter.createdFromMs != nil || filter.createdToMs != nil {
            clauses.append("createDateMs > 0")
        }
        appendRange(&clauses, &args, column: "createDateMs", min: filter.createdFromMs, max: filter.createdToMs)

        if filter.seriesOnly { clauses.append("seriesId > 0") }

        return clauses.joined(separator: " AND ")
    }

    /// 关键词：按空白分词，**逐词 AND**。
    ///
    /// 分词而不是整串匹配，是因为用户脑子里的检索是「东方 + 灵梦」而不是一个连续子串；
    /// 而逐词 AND 而不是 OR，是因为多打一个词的意图永远是「再缩小一点」。
    private static func appendKeyword(_ filter: BookmarkFilter, _ clauses: inout [String], _ args: inout [SQLValue]) {
        var seen = Set<String>()
        let terms = filter.keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(maxKeywordTerms)
        for term in terms {
            if let asId = Int64(term), asId > 0 {
                // 纯数字：既可能是想找某一件作品（illust_id），也可能是想找某个画师的全部收藏
                //（作者 uid）—— 用户脑子里就是「我把这串数字贴进来」，不该逼他先选类型。
                // 同时保留文本匹配：标题/标签里本来就带数字的作品照样命中。
                clauses.append("(searchText LIKE ? ESCAPE '\(likeEscape)' OR targetId = ? OR authorId = ?)")
                args.append(.text("%\(escapeLike(term))%"))
                args.append(.int(asId))
                args.append(.int(asId))
            } else {
                clauses.append("searchText LIKE ? ESCAPE '\(likeEscape)'")
                args.append(.text("%\(escapeLike(term))%"))
            }
        }
    }

    private static func appendTags(_ filter: BookmarkFilter, _ clauses: inout [String], _ args: inout [SQLValue]) {
        let include = distinct(filter.tagNames.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        if !include.isEmpty {
            let placeholders = Array(repeating: "?", count: include.count).joined(separator: ",")
            if filter.tagMatchAll {
                clauses.append(
                    "targetId IN (SELECT targetId FROM \(tagsTable) WHERE shelfKey = ? AND tagName IN (\(placeholders)) " +
                        "GROUP BY targetId HAVING COUNT(DISTINCT tagName) = ?)"
                )
                args.append(.text(filter.shelfKey))
                args.append(contentsOf: include.map { SQLValue.text($0) })
                args.append(.int(Int64(include.count)))
            } else {
                clauses.append("targetId IN (SELECT targetId FROM \(tagsTable) WHERE shelfKey = ? AND tagName IN (\(placeholders)))")
                args.append(.text(filter.shelfKey))
                args.append(contentsOf: include.map { SQLValue.text($0) })
            }
        }
        let exclude = distinct(filter.excludedTagNames.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        if !exclude.isEmpty {
            let placeholders = Array(repeating: "?", count: exclude.count).joined(separator: ",")
            clauses.append("targetId NOT IN (SELECT targetId FROM \(tagsTable) WHERE shelfKey = ? AND tagName IN (\(placeholders)))")
            args.append(.text(filter.shelfKey))
            args.append(contentsOf: exclude.map { SQLValue.text($0) })
        }
    }

    private static func appendInList(_ clauses: inout [String], _ args: inout [SQLValue], column: String, values: [SQLValue]) {
        if values.isEmpty { return }
        var seen = Set<SQLValue>()
        let unique = values.filter { seen.insert($0).inserted }
        clauses.append("\(column) IN (\(Array(repeating: "?", count: unique.count).joined(separator: ",")))")
        args.append(contentsOf: unique)
    }

    private static func appendRange(_ clauses: inout [String], _ args: inout [SQLValue], column: String, min: Int64?, max: Int64?) {
        if let min {
            clauses.append("\(column) >= ?")
            args.append(.int(min))
        }
        if let max {
            clauses.append("\(column) <= ?")
            args.append(.int(max))
        }
    }

    private static func distinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func escapeLike(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count + 4)
        for ch in raw {
            if ch == "%" || ch == "_" || ch == likeEscape { out.append(likeEscape) }
            out.append(ch)
        }
        return out
    }
}
