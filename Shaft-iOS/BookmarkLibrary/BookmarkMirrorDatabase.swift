import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 收藏镜像的读写口 —— Android 侧 Room `BookmarkMirrorDao` + `AppDatabase` 建表迁移的 iOS 版，
/// 直接压在系统 `SQLite3` 上：表名、列名、索引与 Android 完全一致，`BookmarkMirrorQuery`
/// 拼出来的 SQL 两边通用。
///
/// 做成 actor：所有语句串行执行（一个连接、一个执行者），引擎的写与界面的读互不撕裂；
/// 每个操作都是毫秒级，排队代价可以忽略。文件放 Application Support，不进 iCloud 备份
/// ——它是可以随时重建的派生数据。
actor BookmarkMirrorDatabase {

    static let shared = BookmarkMirrorDatabase()

    private var handle: OpaquePointer?

    struct DatabaseError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    // MARK: 打开与建表

    private func db() throws -> OpaquePointer {
        if let handle { return handle }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent("bookmark_mirror.sqlite")
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &opened, flags, nil) == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let opened { sqlite3_close(opened) }
            throw DatabaseError(message: message)
        }
        // 派生数据：不进 iCloud 备份，重建一遍就有了。
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        // 建表失败就把连接关掉、handle 不落：否则下一次调用会拿着半初始化的库跳过建表，
        // 之后每条语句都以「no such table」失败，而且再也没有机会重建。
        do {
            for statement in ["PRAGMA journal_mode=WAL", "PRAGMA synchronous=NORMAL", "PRAGMA foreign_keys=OFF"] + Self.schema {
                try Self.exec(opened, statement)
            }
        } catch {
            sqlite3_close(opened)
            throw error
        }
        handle = opened
        return opened
    }

    /// v41 -> v42 迁移的原样搬运：三张表（主表 / 标签倒排表 / 每书架同步状态）。
    ///
    /// 索引数量偏多是**故意的**：这张表存在的全部意义就是让「按收藏顺序倒序 / 按作者 / 按热度 /
    /// 按年份 / 按标签」这些服务端给不了的排序筛选在本地即时出结果，而写入只发生在每 5 秒一页
    /// 的后台回填里，写放大完全不在用户感知路径上。索引一律以 `shelfKey` 打头：任何查询的
    /// 第一个条件都是它，索引前缀不是它就等于全表扫。
    private static let schema: [String] = [
        """
        CREATE TABLE IF NOT EXISTS bookmark_mirror_table (
            shelfKey TEXT NOT NULL,
            targetId INTEGER NOT NULL,
            ownerUid INTEGER NOT NULL,
            contentType INTEGER NOT NULL,
            restrictCode INTEGER NOT NULL,
            bookmarkSeq INTEGER NOT NULL,
            payloadJson TEXT NOT NULL,
            title TEXT NOT NULL,
            authorId INTEGER NOT NULL,
            authorName TEXT NOT NULL,
            workType TEXT NOT NULL,
            pageCount INTEGER NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            aspectRatio REAL NOT NULL,
            orientation INTEGER NOT NULL,
            totalBookmarks INTEGER NOT NULL,
            totalView INTEGER NOT NULL,
            textLength INTEGER NOT NULL,
            createDateMs INTEGER NOT NULL,
            aiType INTEGER NOT NULL,
            xRestrict INTEGER NOT NULL,
            sanityLevel INTEGER NOT NULL,
            isVisible INTEGER NOT NULL,
            isMuted INTEGER NOT NULL,
            seriesId INTEGER NOT NULL,
            tagCount INTEGER NOT NULL,
            searchText TEXT NOT NULL,
            syncedAt INTEGER NOT NULL,
            generation INTEGER NOT NULL,
            PRIMARY KEY (shelfKey, targetId)
        )
        """,
        // 默认排序（正序 = 官方顺序，倒序）；也是分页 keyset 的走索引路径
        "CREATE INDEX IF NOT EXISTS index_bookmark_mirror_table_shelfKey_bookmarkSeq ON bookmark_mirror_table(shelfKey, bookmarkSeq)",
        // 其余排序键
        "CREATE INDEX IF NOT EXISTS index_bookmark_mirror_table_shelfKey_createDateMs ON bookmark_mirror_table(shelfKey, createDateMs)",
        "CREATE INDEX IF NOT EXISTS index_bookmark_mirror_table_shelfKey_totalBookmarks ON bookmark_mirror_table(shelfKey, totalBookmarks)",
        "CREATE INDEX IF NOT EXISTS index_bookmark_mirror_table_shelfKey_totalView ON bookmark_mirror_table(shelfKey, totalView)",
        "CREATE INDEX IF NOT EXISTS index_bookmark_mirror_table_shelfKey_textLength ON bookmark_mirror_table(shelfKey, textLength)",
        "CREATE INDEX IF NOT EXISTS index_bookmark_mirror_table_shelfKey_title ON bookmark_mirror_table(shelfKey, title)",
        // 高基数筛选：按作者看收藏（顺带带上排序键，作者页内的排序也不用临时表）
        "CREATE INDEX IF NOT EXISTS index_bookmark_mirror_table_shelfKey_authorId_bookmarkSeq ON bookmark_mirror_table(shelfKey, authorId, bookmarkSeq)",
        "CREATE INDEX IF NOT EXISTS index_bookmark_mirror_table_shelfKey_seriesId ON bookmark_mirror_table(shelfKey, seriesId)",
        // 低基数筛选 + 默认排序的组合：单独索引没意义，配上 bookmarkSeq 才值钱
        "CREATE INDEX IF NOT EXISTS index_bookmark_mirror_table_shelfKey_workType_bookmarkSeq ON bookmark_mirror_table(shelfKey, workType, bookmarkSeq)",
        "CREATE INDEX IF NOT EXISTS index_bookmark_mirror_table_shelfKey_xRestrict_bookmarkSeq ON bookmark_mirror_table(shelfKey, xRestrict, bookmarkSeq)",
        "CREATE INDEX IF NOT EXISTS index_bookmark_mirror_table_shelfKey_aiType_bookmarkSeq ON bookmark_mirror_table(shelfKey, aiType, bookmarkSeq)",
        "CREATE INDEX IF NOT EXISTS index_bookmark_mirror_table_shelfKey_pageCount_bookmarkSeq ON bookmark_mirror_table(shelfKey, pageCount, bookmarkSeq)",
        "CREATE INDEX IF NOT EXISTS index_bookmark_mirror_table_shelfKey_orientation_bookmarkSeq ON bookmark_mirror_table(shelfKey, orientation, bookmarkSeq)",
        // 全量重扫收尾时按代号删除失联行
        "CREATE INDEX IF NOT EXISTS index_bookmark_mirror_table_shelfKey_generation ON bookmark_mirror_table(shelfKey, generation)",
        // 取消收藏时不知道它在哪个书架（公开/悄悄），按作品 id 跨书架删
        "CREATE INDEX IF NOT EXISTS index_bookmark_mirror_table_targetId ON bookmark_mirror_table(targetId)",
        """
        CREATE TABLE IF NOT EXISTS bookmark_mirror_tag_table (
            shelfKey TEXT NOT NULL,
            targetId INTEGER NOT NULL,
            tagName TEXT NOT NULL,
            displayName TEXT NOT NULL,
            translatedName TEXT NOT NULL,
            PRIMARY KEY (shelfKey, targetId, tagName)
        )
        """,
        "CREATE INDEX IF NOT EXISTS index_bookmark_mirror_tag_table_shelfKey_tagName ON bookmark_mirror_tag_table(shelfKey, tagName)",
        "CREATE INDEX IF NOT EXISTS index_bookmark_mirror_tag_table_shelfKey_targetId ON bookmark_mirror_tag_table(shelfKey, targetId)",
        "CREATE INDEX IF NOT EXISTS index_bookmark_mirror_tag_table_targetId ON bookmark_mirror_tag_table(targetId)",
        """
        CREATE TABLE IF NOT EXISTS bookmark_mirror_state_table (
            shelfKey TEXT NOT NULL PRIMARY KEY,
            ownerUid INTEGER NOT NULL,
            contentType INTEGER NOT NULL,
            restrictCode INTEGER NOT NULL,
            phase INTEGER NOT NULL,
            nextUrl TEXT,
            generation INTEGER NOT NULL,
            nextBackfillSeq INTEGER NOT NULL,
            headSeqCursor INTEGER NOT NULL,
            headBlockCeiling INTEGER NOT NULL,
            pagesThisRun INTEGER NOT NULL,
            itemsThisRun INTEGER NOT NULL,
            firstCompletedAt INTEGER NOT NULL,
            lastSyncedAt INTEGER NOT NULL,
            lastFullSweepAt INTEGER NOT NULL,
            lastErrorAt INTEGER NOT NULL,
            lastError TEXT,
            consecutiveFailures INTEGER NOT NULL,
            cooldownUntil INTEGER NOT NULL,
            updatedAt INTEGER NOT NULL
        )
        """,
    ]

    // MARK: 写入

    /// 落一页：先清掉这批作品的旧标签行，再整体覆写主表与标签表。
    ///
    /// 必须是一个事务：主表写进去了而标签没写，界面上这些作品就凭空少了标签；
    /// 反过来清了标签又没写回，标签云会缺一块。中途被杀也只会整页回滚，
    /// 而续传游标是**在这之后**才落盘的（见引擎），所以最坏结果是下次重放这一页 ——
    /// 重放是幂等的（REPLACE + 序号由调用方保持不变）。
    func writePage(rows: [BookmarkMirrorEntity], tags: [BookmarkMirrorTagEntity]) throws {
        guard let first = rows.first else { return }
        try transaction {
            try deleteTagsOf(shelfKey: first.shelfKey, targetIds: rows.map(\.targetId))
            try insertRows(rows)
            if !tags.isEmpty { try insertTags(tags) }
        }
    }

    private func insertRows(_ rows: [BookmarkMirrorEntity]) throws {
        let sql = "INSERT OR REPLACE INTO bookmark_mirror_table (" + Self.rowColumns.joined(separator: ", ") + ") VALUES (" +
            Array(repeating: "?", count: Self.rowColumns.count).joined(separator: ",") + ")"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for row in rows {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            try bind(stmt, Self.rowValues(row))
            try stepDone(stmt)
        }
    }

    private func insertTags(_ tags: [BookmarkMirrorTagEntity]) throws {
        let stmt = try prepare(
            "INSERT OR REPLACE INTO bookmark_mirror_tag_table (shelfKey, targetId, tagName, displayName, translatedName) VALUES (?,?,?,?,?)"
        )
        defer { sqlite3_finalize(stmt) }
        for tag in tags {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            try bind(stmt, [.text(tag.shelfKey), .int(tag.targetId), .text(tag.tagName), .text(tag.displayName), .text(tag.translatedName)])
            try stepDone(stmt)
        }
    }

    private func deleteTagsOf(shelfKey: String, targetIds: [Int64]) throws {
        if targetIds.isEmpty { return }
        // SQLite 的绑定参数上限默认 999；一页最多几十条，分块只是防御。
        for chunk in stride(from: 0, to: targetIds.count, by: 500) {
            let slice = Array(targetIds[chunk..<min(chunk + 500, targetIds.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            try run(
                "DELETE FROM bookmark_mirror_tag_table WHERE shelfKey = ? AND targetId IN (\(placeholders))",
                [.text(shelfKey)] + slice.map { SQLValue.int($0) }
            )
        }
    }

    /// 这批作品在库里已有的收藏序号。
    ///
    /// 增量维护会反复走到表头那些**早就镜像过**的作品，它们的 `bookmarkSeq` 必须原样保留
    /// —— 重新分配等于把用户的收藏顺序打乱。所以每页写库前先查一次，命中的沿用旧序号，
    /// 没命中的才是真·新收藏。
    func existingSeqs(shelfKey: String, targetIds: [Int64]) throws -> [Int64: Int64] {
        if targetIds.isEmpty { return [:] }
        let placeholders = Array(repeating: "?", count: targetIds.count).joined(separator: ",")
        let stmt = try prepare(
            "SELECT targetId, bookmarkSeq FROM bookmark_mirror_table WHERE shelfKey = ? AND targetId IN (\(placeholders))",
            [.text(shelfKey)] + targetIds.map { SQLValue.int($0) }
        )
        defer { sqlite3_finalize(stmt) }
        var result: [Int64: Int64] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            result[sqlite3_column_int64(stmt, 0)] = sqlite3_column_int64(stmt, 1)
        }
        return result
    }

    /// 全量重扫收尾：删掉本轮没再出现过的行 = 已经在别处取消了收藏。
    @discardableResult
    func deleteStaleRows(shelfKey: String, generation: Int) throws -> Int {
        try run("DELETE FROM bookmark_mirror_table WHERE shelfKey = ? AND generation < ?", [.text(shelfKey), .int(Int64(generation))])
        return changes()
    }

    @discardableResult
    func deleteOrphanTags(shelfKey: String) throws -> Int {
        try run(
            "DELETE FROM bookmark_mirror_tag_table WHERE shelfKey = ? AND targetId NOT IN (SELECT targetId FROM bookmark_mirror_table WHERE shelfKey = ?)",
            [.text(shelfKey), .text(shelfKey)]
        )
        return changes()
    }

    /// 本地取消收藏后即时抹掉（跨公开/悄悄两个书架，因为调用点未必知道它在哪边）。
    @discardableResult
    func deleteTarget(ownerUid: Int64, contentType: Int, targetId: Int64) throws -> Int {
        try run(
            "DELETE FROM bookmark_mirror_table WHERE ownerUid = ? AND contentType = ? AND targetId = ?",
            [.int(ownerUid), .int(Int64(contentType)), .int(targetId)]
        )
        return changes()
    }

    /// 配套 `deleteTarget` 清标签。shelfKey 由调用方算好传进来（同一 uid + contentType 下
    /// 的公开/悄悄两个书架），**不从状态表反查** —— 用户关掉某个书架的镜像后状态行就没了，
    /// 反查会静默漏删，留下一堆没有主行的孤儿标签。
    @discardableResult
    func deleteTargetTags(shelfKeys: [String], targetId: Int64) throws -> Int {
        if shelfKeys.isEmpty { return 0 }
        let placeholders = Array(repeating: "?", count: shelfKeys.count).joined(separator: ",")
        try run(
            "DELETE FROM bookmark_mirror_tag_table WHERE targetId = ? AND shelfKey IN (\(placeholders))",
            [.int(targetId)] + shelfKeys.map { SQLValue.text($0) }
        )
        return changes()
    }

    /// 整架清空（换号、用户手动重建镜像）。
    func clearShelf(shelfKey: String) throws {
        try transaction {
            try run("DELETE FROM bookmark_mirror_table WHERE shelfKey = ?", [.text(shelfKey)])
            try run("DELETE FROM bookmark_mirror_tag_table WHERE shelfKey = ?", [.text(shelfKey)])
        }
    }

    // MARK: 状态

    func upsertState(_ s: BookmarkMirrorStateEntity) throws {
        try run(
            """
            INSERT OR REPLACE INTO bookmark_mirror_state_table (
                shelfKey, ownerUid, contentType, restrictCode, phase, nextUrl, generation, nextBackfillSeq,
                headSeqCursor, headBlockCeiling, pagesThisRun, itemsThisRun, firstCompletedAt, lastSyncedAt,
                lastFullSweepAt, lastErrorAt, lastError, consecutiveFailures, cooldownUntil, updatedAt
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [
                .text(s.shelfKey), .int(s.ownerUid), .int(Int64(s.contentType)), .int(Int64(s.restrictCode)),
                .int(Int64(s.phase)), s.nextUrl.map { SQLValue.text($0) } ?? .null, .int(Int64(s.generation)),
                .int(s.nextBackfillSeq), .int(s.headSeqCursor), .int(s.headBlockCeiling),
                .int(Int64(s.pagesThisRun)), .int(Int64(s.itemsThisRun)), .int(s.firstCompletedAt),
                .int(s.lastSyncedAt), .int(s.lastFullSweepAt), .int(s.lastErrorAt),
                s.lastError.map { SQLValue.text($0) } ?? .null, .int(Int64(s.consecutiveFailures)),
                .int(s.cooldownUntil), .int(s.updatedAt),
            ]
        )
    }

    func findState(shelfKey: String) throws -> BookmarkMirrorStateEntity? {
        try query("SELECT * FROM bookmark_mirror_state_table WHERE shelfKey = ? LIMIT 1", [.text(shelfKey)], Self.readState).first
    }

    func allStates() throws -> [BookmarkMirrorStateEntity] {
        try query("SELECT * FROM bookmark_mirror_state_table", [], Self.readState)
    }

    func states(ownerUid: Int64) throws -> [BookmarkMirrorStateEntity] {
        try query("SELECT * FROM bookmark_mirror_state_table WHERE ownerUid = ?", [.int(ownerUid)], Self.readState)
    }

    func deleteState(shelfKey: String) throws {
        try run("DELETE FROM bookmark_mirror_state_table WHERE shelfKey = ?", [.text(shelfKey)])
    }

    // MARK: 读取

    func countOf(shelfKey: String) throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM bookmark_mirror_table WHERE shelfKey = ?", [.text(shelfKey)])
    }

    /// 按账号（而不是按书架）的行数。页面上可以就地在「公开 / 悄悄」两个书架之间切换，
    /// 按 ownerUid 观察一次就覆盖两边。
    func ownerCount(ownerUid: Int64) throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM bookmark_mirror_table WHERE ownerUid = ?", [.int(ownerUid)])
    }

    func findRow(shelfKey: String, targetId: Int64) throws -> BookmarkMirrorEntity? {
        try query(
            "SELECT * FROM bookmark_mirror_table WHERE shelfKey = ? AND targetId = ? LIMIT 1",
            [.text(shelfKey), .int(targetId)], Self.readRow
        ).first
    }

    /// 这批作品里哪些在该账号的镜像中（公开/悄悄两架都算），走 targetId 索引。
    func mirroredAmong(ownerUid: Int64, contentType: Int, targetIds: [Int64]) throws -> Set<Int64> {
        guard !targetIds.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: targetIds.count).joined(separator: ",")
        let args: [SQLValue] = [.int(ownerUid), .int(Int64(contentType))] + targetIds.map { .int($0) }
        return Set(try query(
            "SELECT DISTINCT targetId FROM bookmark_mirror_table WHERE ownerUid = ? AND contentType = ? AND targetId IN (\(marks))",
            args
        ) { sqlite3_column_int64($0, 0) })
    }

    /// 花式筛选的执行口。查询由 `BookmarkMirrorQuery` 拼出来，这里只负责跑。
    func rawRows(_ q: SQLQuery) throws -> [BookmarkMirrorEntity] {
        try query(q.sql, q.args, Self.readRow)
    }

    func rawCount(_ q: SQLQuery) throws -> Int {
        try scalarInt(q.sql, q.args)
    }

    func rawTagFacets(_ q: SQLQuery) throws -> [BookmarkTagFacet] {
        try query(q.sql, q.args) { stmt in
            BookmarkTagFacet(
                tagName: Self.text(stmt, 0), displayName: Self.text(stmt, 1),
                translatedName: Self.text(stmt, 2), hitCount: Int(sqlite3_column_int64(stmt, 3))
            )
        }
    }

    func rawAuthorFacets(_ q: SQLQuery) throws -> [BookmarkAuthorFacet] {
        try query(q.sql, q.args) { stmt in
            BookmarkAuthorFacet(
                authorId: sqlite3_column_int64(stmt, 0), authorName: Self.text(stmt, 1),
                hitCount: Int(sqlite3_column_int64(stmt, 2))
            )
        }
    }

    func yearFacets(shelfKey: String) throws -> [BookmarkYearFacet] {
        let q = BookmarkMirrorQuery.yearFacets(shelfKey: shelfKey)
        return try query(q.sql, q.args) { stmt in
            BookmarkYearFacet(year: Int(sqlite3_column_int64(stmt, 0)), hitCount: Int(sqlite3_column_int64(stmt, 1)))
        }
    }

    // MARK: 行映射

    /// 主表列序。`SELECT *` 的返回顺序就是建表顺序，读取按这个下标走。
    private static let rowColumns: [String] = [
        "shelfKey", "targetId", "ownerUid", "contentType", "restrictCode", "bookmarkSeq", "payloadJson",
        "title", "authorId", "authorName", "workType", "pageCount", "width", "height", "aspectRatio",
        "orientation", "totalBookmarks", "totalView", "textLength", "createDateMs", "aiType", "xRestrict",
        "sanityLevel", "isVisible", "isMuted", "seriesId", "tagCount", "searchText", "syncedAt", "generation",
    ]

    private static func rowValues(_ r: BookmarkMirrorEntity) -> [SQLValue] {
        [
            .text(r.shelfKey), .int(r.targetId), .int(r.ownerUid), .int(Int64(r.contentType)), .int(Int64(r.restrictCode)),
            .int(r.bookmarkSeq), .text(r.payloadJson), .text(r.title), .int(r.authorId), .text(r.authorName),
            .text(r.workType), .int(Int64(r.pageCount)), .int(Int64(r.width)), .int(Int64(r.height)), .real(r.aspectRatio),
            .int(Int64(r.orientation)), .int(Int64(r.totalBookmarks)), .int(Int64(r.totalView)), .int(Int64(r.textLength)),
            .int(r.createDateMs), .int(Int64(r.aiType)), .int(Int64(r.xRestrict)), .int(Int64(r.sanityLevel)),
            .int(r.isVisible ? 1 : 0), .int(r.isMuted ? 1 : 0), .int(r.seriesId), .int(Int64(r.tagCount)),
            .text(r.searchText), .int(r.syncedAt), .int(Int64(r.generation)),
        ]
    }

    private static func readRow(_ s: OpaquePointer) -> BookmarkMirrorEntity {
        BookmarkMirrorEntity(
            shelfKey: text(s, 0), targetId: sqlite3_column_int64(s, 1), ownerUid: sqlite3_column_int64(s, 2),
            contentType: Int(sqlite3_column_int64(s, 3)), restrictCode: Int(sqlite3_column_int64(s, 4)),
            bookmarkSeq: sqlite3_column_int64(s, 5), payloadJson: text(s, 6), title: text(s, 7),
            authorId: sqlite3_column_int64(s, 8), authorName: text(s, 9), workType: text(s, 10),
            pageCount: Int(sqlite3_column_int64(s, 11)), width: Int(sqlite3_column_int64(s, 12)),
            height: Int(sqlite3_column_int64(s, 13)), aspectRatio: sqlite3_column_double(s, 14),
            orientation: Int(sqlite3_column_int64(s, 15)), totalBookmarks: Int(sqlite3_column_int64(s, 16)),
            totalView: Int(sqlite3_column_int64(s, 17)), textLength: Int(sqlite3_column_int64(s, 18)),
            createDateMs: sqlite3_column_int64(s, 19), aiType: Int(sqlite3_column_int64(s, 20)),
            xRestrict: Int(sqlite3_column_int64(s, 21)), sanityLevel: Int(sqlite3_column_int64(s, 22)),
            isVisible: sqlite3_column_int64(s, 23) != 0, isMuted: sqlite3_column_int64(s, 24) != 0,
            seriesId: sqlite3_column_int64(s, 25), tagCount: Int(sqlite3_column_int64(s, 26)),
            searchText: text(s, 27), syncedAt: sqlite3_column_int64(s, 28), generation: Int(sqlite3_column_int64(s, 29))
        )
    }

    private static func readState(_ s: OpaquePointer) -> BookmarkMirrorStateEntity {
        BookmarkMirrorStateEntity(
            shelfKey: text(s, 0), ownerUid: sqlite3_column_int64(s, 1), contentType: Int(sqlite3_column_int64(s, 2)),
            restrictCode: Int(sqlite3_column_int64(s, 3)), phase: Int(sqlite3_column_int64(s, 4)),
            nextUrl: optionalText(s, 5), generation: Int(sqlite3_column_int64(s, 6)),
            nextBackfillSeq: sqlite3_column_int64(s, 7), headSeqCursor: sqlite3_column_int64(s, 8),
            headBlockCeiling: sqlite3_column_int64(s, 9), pagesThisRun: Int(sqlite3_column_int64(s, 10)),
            itemsThisRun: Int(sqlite3_column_int64(s, 11)), firstCompletedAt: sqlite3_column_int64(s, 12),
            lastSyncedAt: sqlite3_column_int64(s, 13), lastFullSweepAt: sqlite3_column_int64(s, 14),
            lastErrorAt: sqlite3_column_int64(s, 15), lastError: optionalText(s, 16),
            consecutiveFailures: Int(sqlite3_column_int64(s, 17)), cooldownUntil: sqlite3_column_int64(s, 18),
            updatedAt: sqlite3_column_int64(s, 19)
        )
    }

    private static func text(_ s: OpaquePointer, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(s, index) else { return "" }
        return String(cString: c)
    }

    private static func optionalText(_ s: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(s, index) != SQLITE_NULL, let c = sqlite3_column_text(s, index) else { return nil }
        return String(cString: c)
    }

    // MARK: SQLite 零件

    private func exec(_ sql: String) throws {
        try Self.exec(try db(), sql)
    }

    private static func exec(_ d: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(d, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(d))
            sqlite3_free(err)
            throw DatabaseError(message: "\(message) — \(sql.prefix(80))")
        }
    }

    private func prepare(_ sql: String, _ args: [SQLValue] = []) throws -> OpaquePointer {
        let d = try db()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(d, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError(message: "\(String(cString: sqlite3_errmsg(d))) — \(sql.prefix(120))")
        }
        do {
            try bind(stmt, args)
        } catch {
            sqlite3_finalize(stmt)
            throw error
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ args: [SQLValue]) throws {
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            let rc: Int32
            switch arg {
            case .int(let v): rc = sqlite3_bind_int64(stmt, index, v)
            case .real(let v): rc = sqlite3_bind_double(stmt, index, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, index, v, -1, sqliteTransient)
            case .null: rc = sqlite3_bind_null(stmt, index)
            }
            guard rc == SQLITE_OK else { throw DatabaseError(message: "bind #\(index) failed rc=\(rc)") }
        }
    }

    private func stepDone(_ stmt: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DatabaseError(message: "step rc=\(rc): \(String(cString: sqlite3_errmsg(try db())))")
        }
    }

    private func run(_ sql: String, _ args: [SQLValue]) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        try stepDone(stmt)
    }

    private func query<T>(_ sql: String, _ args: [SQLValue], _ map: (OpaquePointer) -> T) throws -> [T] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                out.append(map(stmt))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw DatabaseError(message: "step rc=\(rc): \(String(cString: sqlite3_errmsg(try db())))")
            }
        }
        return out
    }

    private func scalarInt(_ sql: String, _ args: [SQLValue]) throws -> Int {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func changes() -> Int {
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
