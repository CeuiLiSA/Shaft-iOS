import Foundation

// 小说正文全文翻译（issue #864）— port of upstream `TranslationInserter` +
// `NovelBodyTranslator` + the Google gtx call they sit on.

// MARK: - TranslationInserter

/// 把全文翻译的译文以 `.paragraph` 的形态放进展示 token 流：
/// `.interlinear` 插到各自原文段落正下方（双语对照），`.replacement` 顶替原文段落（仅译文）。
///
/// 纯函数、只在展示链路上调用：原始 tokens（导出 / 复制 / 朗读 / 进程缓存）不被污染，
/// anchor 保持单调。复用 paragraph 而不是新造 token 类型，翻页 Paginator / 滚动阅读的
/// 段落渲染链路照旧生效。
enum TranslationInserter {
    /// - Parameters:
    ///   - translations: 原文段落 sourceStart → 译文。没有译文（还没翻到 / 失败 / 译文为空）的段落原样保留。
    ///   - role: 译文的身份，不能是 `.none`。
    static func insert(_ tokens: [ContentToken], translations: [Int: String], role: TranslationRole) -> [ContentToken] {
        precondition(role != .none, "translation role must not be None")
        if tokens.isEmpty || translations.isEmpty { return tokens }
        var result: [ContentToken] = []
        result.reserveCapacity(tokens.count + translations.count)
        for token in tokens {
            guard case .paragraph(let start, let end, _, let textSourceStart, _, .none) = token,
                  let translated = translations[start]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !translated.isEmpty else {
                result.append(token)
                continue
            }
            if role == .replacement {
                result.append(.paragraph(
                    sourceStart: start, sourceEnd: end, text: translated,
                    textSourceStart: textSourceStart, inlineSpans: [], translationRole: role
                ))
            } else {
                result.append(token)
                result.append(.paragraph(
                    sourceStart: end, sourceEnd: end, text: translated,
                    textSourceStart: end, inlineSpans: [], translationRole: role
                ))
            }
        }
        return result
    }
}

// MARK: - NovelBodyTranslator

/// 固定走 Google 免费端点——R-18 正文不拒译、不吞句，一万字三个请求、十秒内翻完。
///
/// 任一片请求失败就整体抛出（不逐段重发：网络不通时每段都要等一次连接超时，一篇小说能卡
/// 十几分钟），已回调出去的译文由调用方保留，下次只补没翻到的段落。
enum NovelBodyTranslator {
    /// gtx 的 q 实际上限约 5000 字符，留余量。
    private static let maxChunkChars = 4000
    private static let joinSep = "\n"

    struct Paragraph: Sendable {
        let sourceStart: Int
        let text: String
    }

    /// 按 `paragraphs` 的顺序分片翻译；每片完成回调一次（原文段落 sourceStart → 译文）。
    static func translate(
        _ paragraphs: [Paragraph],
        targetLang: String,
        onChunk: @MainActor ([Int: String]) throws -> Void
    ) async throws {
        let texts = paragraphs.map { $0.text.replacingOccurrences(of: joinSep, with: " ") }
        for (from, to) in chunkByCharLimit(texts, limit: maxChunkChars) {
            try Task.checkCancellation()
            let slice = Array(texts[from..<to])
            let lines = try await GoogleGtx.translate(slice.joined(separator: joinSep), targetLang: targetLang)
                .components(separatedBy: joinSep)
            // 行数对不上（极少见）就把这一片逐段重翻，避免译文错位到别的段落下面。
            var translated = lines
            if lines.count != slice.count {
                translated = []
                for text in slice {
                    try Task.checkCancellation()
                    translated.append(try await GoogleGtx.translate(text, targetLang: targetLang))
                }
            }
            var chunk: [Int: String] = [:]
            for i in from..<to { chunk[paragraphs[i].sourceStart] = translated[i - from] }
            try await onChunk(chunk)
        }
    }

    /// 按累计字符数把 inputs 切成若干个 [from, to) 区间，每段 join 后不超过 limit；
    /// 单条本身超 limit 也会自己占一段。
    static func chunkByCharLimit(_ inputs: [String], limit: Int) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var start = 0
        var size = 0
        for (i, input) in inputs.enumerated() {
            let len = input.utf16.count + 1
            if size + len > limit, i > start {
                out.append((start, i))
                start = i
                size = 0
            }
            size += len
        }
        if start < inputs.count { out.append((start, inputs.count)) }
        return out
    }
}

// MARK: - Google gtx

/// `translate.googleapis.com/translate_a/single?client=gtx` — upstream
/// `GoogleWebTranslator.callGtx`. POST + form body：日文 URL 编码 1 字符 = 9 字符，
/// 几百字的 q 走 GET 会撞 414。国内需要代理，失败抛 `URLError`（由调用方提示代理）。
enum GoogleGtx {
    private static let endpoint = URL(string: "https://translate.googleapis.com/translate_a/single")!
    private static let sourceLang = "ja"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    struct HTTPError: LocalizedError {
        let status: Int
        var errorDescription: String? { "google translate http \(status)" }
    }

    static func translate(_ text: String, targetLang: String) async throws -> String {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            ("client", "gtx"), ("sl", sourceLang), ("tl", targetLang), ("dt", "t"), ("q", text),
        ]).data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(status: http.statusCode)
        }
        return try parse(data)
    }

    /// 响应是嵌套数组，首层 [0] 是分句翻译数组，每条是 [translated, original, ...]。
    /// 把每条 translated 拼起来，内嵌的 \n 会自然保留。
    static func parse(_ data: Data) throws -> String {
        guard let outer = try JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = outer.first as? [Any] else { return "" }
        return segments.compactMap { ($0 as? [Any])?.first as? String }.joined()
    }

    private static func formBody(_ fields: [(String, String)]) -> String {
        // application/x-www-form-urlencoded：只放行 ASCII unreserved 字符，空格编码为 %20。
        // 不能用 `.alphanumerics`——它含所有 Unicode 字母，日文会原样不编码。
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }
}

/// App 语言 tag → gtx 的 `tl`（upstream `appTranslateTargetLang`）：中文按繁简分流，
/// 其余与 Google 的语言代码一一对得上。
func translateTargetLang(appTag: String) -> String {
    switch appTag {
    case "zh-Hans": return "zh-CN"
    case "zh-Hant": return "zh-TW"
    case "": return "en"
    default: return appTag
    }
}
