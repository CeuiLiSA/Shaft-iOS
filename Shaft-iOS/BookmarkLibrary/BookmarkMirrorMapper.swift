import Foundation
import os

/// 收藏镜像的统一日志口（Android 侧是 `Timber.tag("BookmarkMirror")`）。
///   xcrun simctl spawn booted log stream --predicate \
///     'subsystem == "com.shaft.ShaftiOS" AND category == "BookmarkMirror"' --style compact
let mirrorLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Shaft-iOS", category: "BookmarkMirror")

/// 网络模型（`Illust` / `Novel`）→ 镜像行 + 标签行。
///
/// 1:1 移植自 `ceui.pixiv.db.mirror.BookmarkMirrorMapper`。这里是**唯一**决定「哪些字段被摊平成
/// 可筛选列」的地方。加一个筛选维度 = 在 `BookmarkMirrorEntity` 加一列 + 在这里填上 +
/// 在 `BookmarkMirrorQuery` 加一个条件，三处对齐，别处不用动。
///
/// 纯函数、无 UI 依赖，可以单测。
enum BookmarkMirrorMapper {

    enum Orientation {
        static let unknown = 0
        static let landscape = 1
        static let portrait = 2
        static let square = 3
    }

    /// 画幅取向。方图的判定给 5% 容差，不然几乎没有作品算「方」。
    private static let squareTolerance = 0.05

    static func fromIllust(
        shelf: BookmarkShelf,
        illust: Illust,
        bookmarkSeq: Int64,
        generation: Int,
        now: Int64
    ) -> MirrorRow {
        let tags = illust.tags ?? []
        let tagRows = tagRows(shelf: shelf, targetId: illust.id, tags: tags)
        let authorName = illust.user?.name ?? ""
        let title = illust.title ?? ""
        let width = illust.width ?? 0
        let height = illust.height ?? 0
        let row = BookmarkMirrorEntity(
            shelfKey: shelf.key,
            targetId: illust.id,
            ownerUid: shelf.ownerUid,
            contentType: shelf.contentType.code,
            restrictCode: shelf.restrict.code,
            bookmarkSeq: bookmarkSeq,
            payloadJson: encode(illust),
            title: title,
            authorId: illust.user?.id ?? 0,
            authorName: authorName,
            workType: illust.type ?? "illust",
            pageCount: illust.pageCount ?? 1,
            width: width,
            height: height,
            aspectRatio: aspectRatioOf(width: width, height: height),
            orientation: orientationOf(width: width, height: height),
            totalBookmarks: illust.totalBookmarks ?? 0,
            totalView: illust.totalView ?? 0,
            textLength: 0,
            createDateMs: parseCreateDate(illust.createDate),
            aiType: illust.illustAIType ?? 0,
            xRestrict: illust.xRestrict ?? 0,
            sanityLevel: illust.sanityLevel ?? 0,
            // pixiv 对已删除 / 仅限好P友的作品回 visible=false 且字段几乎全空。
            // 照样入库（用户自己收藏过的东西不该凭空消失），由界面上的
            // 「失效作品」筛选决定看不看。
            isVisible: illust.visible != false,
            isMuted: illust.isMuted == true,
            seriesId: illust.series?.id ?? 0,
            // 用**真正入库的**行数，不是 tags.count：重名标签（pixiv 偶发下发）
            // 在 tagRows 里被去重了，用原始条数会和标签表对不上。
            tagCount: tagRows.count,
            searchText: buildSearchText(title: title, authorName: authorName, tags: tags),
            syncedAt: now,
            generation: generation
        )
        return MirrorRow(row: row, tags: tagRows)
    }

    static func fromNovel(
        shelf: BookmarkShelf,
        novel: Novel,
        bookmarkSeq: Int64,
        generation: Int,
        now: Int64
    ) -> MirrorRow {
        let tags = novel.tags ?? []
        let tagRows = tagRows(shelf: shelf, targetId: novel.id, tags: tags)
        let authorName = novel.user?.name ?? ""
        let title = novel.title ?? ""
        let row = BookmarkMirrorEntity(
            shelfKey: shelf.key,
            targetId: novel.id,
            ownerUid: shelf.ownerUid,
            contentType: shelf.contentType.code,
            restrictCode: shelf.restrict.code,
            bookmarkSeq: bookmarkSeq,
            payloadJson: encode(novel),
            title: title,
            authorId: novel.user?.id ?? 0,
            authorName: authorName,
            workType: "novel",
            pageCount: novel.pageCount ?? 1,
            width: 0,
            height: 0,
            aspectRatio: 0,
            orientation: Orientation.unknown,
            totalBookmarks: novel.totalBookmarks ?? 0,
            totalView: novel.totalView ?? 0,
            textLength: novel.textLength ?? 0,
            createDateMs: parseCreateDate(novel.createDate),
            aiType: novel.novelAIType ?? 0,
            xRestrict: novel.xRestrict ?? 0,
            sanityLevel: 0,
            isVisible: novel.visible != false,
            isMuted: novel.isMuted == true,
            seriesId: novel.series?.id ?? 0,
            tagCount: tagRows.count,
            searchText: buildSearchText(title: title, authorName: authorName, tags: tags),
            syncedAt: now,
            generation: generation
        )
        return MirrorRow(row: row, tags: tagRows)
    }

    private static func tagRows(shelf: BookmarkShelf, targetId: Int64, tags: [Tag]) -> [BookmarkMirrorTagEntity] {
        if tags.isEmpty { return [] }
        // 去重：主键含 tagName，同一作品重名标签（pixiv 偶发）会在一次 insert 里撞主键。
        // REPLACE 能兜住，但白白多一次删+插，不如在内存里先去掉。
        var seen = Set<String>()
        var rows: [BookmarkMirrorTagEntity] = []
        rows.reserveCapacity(tags.count)
        for tag in tags {
            guard let display = tag.name, !display.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let normalized = display.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            rows.append(
                BookmarkMirrorTagEntity(
                    shelfKey: shelf.key,
                    targetId: targetId,
                    tagName: normalized,
                    displayName: display,
                    translatedName: tag.translatedName ?? ""
                )
            )
        }
        return rows
    }

    /// 检索列：标题 + 作者 + 标签原名 + 标签译名，全部小写、空格分隔。
    ///
    /// 译名一起进去，是为了让中文用户搜「原创」也能命中 `オリジナル`。
    private static func buildSearchText(title: String, authorName: String, tags: [Tag]) -> String {
        var builder = title
        builder.append(" ")
        builder.append(authorName)
        for tag in tags {
            if let name = tag.name { builder.append(" "); builder.append(name) }
            if let translated = tag.translatedName { builder.append(" "); builder.append(translated) }
        }
        return builder.lowercased()
    }

    private static func aspectRatioOf(width: Int, height: Int) -> Double {
        (width > 0 && height > 0) ? Double(width) / Double(height) : 0
    }

    private static func orientationOf(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return Orientation.unknown }
        let ratio = Double(width) / Double(height)
        if ratio > 1 + squareTolerance { return Orientation.landscape }
        if ratio < 1 - squareTolerance { return Orientation.portrait }
        return Orientation.square
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// `2023-06-14T21:03:11+09:00` → epoch ms。解析不了给 0（= 未知，年份筛选自然落空）。
    static func parseCreateDate(_ raw: String?) -> Int64 {
        guard let raw, !raw.isEmpty else { return 0 }
        guard let date = isoFormatter.date(from: raw) else {
            mirrorLog.debug("create_date 解析失败，按未知处理: \(raw, privacy: .public)")
            return 0
        }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: JSON

    private static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// `Illust.withBookmarked(true)` 的 iOS 版：模型字段是 `let`，走一次 JSON 往返改
    /// `is_bookmarked`。镜像行里存的是完整 JSON，将来直接渲染卡片，所以入库前必须带上真值。
    static func withBookmarked<T: Codable>(_ value: T, _ bookmarked: Bool) -> T {
        guard let data = try? JSONEncoder().encode(value),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return value }
        object["is_bookmarked"] = bookmarked
        guard let patched = try? JSONSerialization.data(withJSONObject: object),
              let decoded = try? JSONDecoder().decode(T.self, from: patched) else { return value }
        return decoded
    }
}
