import Foundation

/// Novel → TXT sink — 1:1 with upstream `BatchDownloadNovelsTask` +
/// `NovelHeaderRenderer`: each novel is fetched through `/webview/v2/novel`,
/// prefixed with a metadata block (title / author / id / link / caption /
/// tags / series), and written to `Documents/Novels/<title>_<id>.txt`. The
/// Documents folder is exposed to the Files app (`UIFileSharingEnabled`), the
/// iOS stand-in for upstream's public Downloads directory.
///
/// Failures are collected per novel so one bad parse never aborts the batch.
enum NovelDownloader {
    struct Failure: Sendable {
        let novel: Novel
        let reason: String
    }

    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Novels", isDirectory: true)
    }

    /// Download `novels` sequentially. Returns the failures (empty == all OK).
    @MainActor
    static func download(_ novels: [Novel], onProgress: ((Int, Int) -> Void)? = nil) async -> [Failure] {
        var failures: [Failure] = []
        let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
        for (i, novel) in novels.enumerated() {
            do {
                let data = try await api.novelText(novel.id)
                guard let html = String(data: data, encoding: .utf8),
                      let web = WebNovelParser.parse(html: html) else {
                    failures.append(Failure(novel: novel, reason: "parse"))
                    continue
                }
                let body = header(for: novel) + (web.text ?? "")
                try await Task.detached(priority: .utility) {
                    try write(body, for: novel)
                }.value
            } catch {
                failures.append(Failure(novel: novel, reason: error.localizedDescription))
            }
            onProgress?(i + 1, novels.count)
        }
        return failures
    }

    /// `NovelHeaderRenderer.render` with the default preset.
    static func header(for novel: Novel) -> String {
        var lines: [String] = []
        lines.append("标题：\(novel.title ?? "")")
        lines.append("作者：\(novel.user?.name ?? "")")
        lines.append("作者ID：\(novel.user.map { "\($0.id)" } ?? "")")
        lines.append("作品ID：\(novel.id)")
        lines.append("作品链接：https://www.pixiv.net/novel/show.php?id=\(novel.id)")
        let caption = (novel.caption ?? "")
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !caption.isEmpty { lines.append("简介：\n\(caption)") }
        if let date = novel.createDate, !date.isEmpty { lines.append("发布时间：\(date)") }
        lines.append("字数：\(novel.textLength ?? 0)")
        let tags = (novel.tags ?? []).compactMap { $0.name }.filter { !$0.isEmpty }
        if !tags.isEmpty { lines.append("标签：\(tags.joined(separator: ", "))") }
        if let series = novel.series?.title, !series.isEmpty { lines.append("系列：\(series)") }
        return lines.joined(separator: "\n\n") + "\n\n—————————————\n"
    }

    private static func write(_ text: String, for novel: Novel) throws {
        let dir = directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeTitle = (novel.title ?? "novel")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r"))
            .joined(separator: "_")
            .prefix(80)
        let url = dir.appendingPathComponent("\(safeTitle)_\(novel.id).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
