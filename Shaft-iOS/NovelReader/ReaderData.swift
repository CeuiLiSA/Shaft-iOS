import Foundation

// Data layer for the V3 novel reader: WebNovel extraction from the
// `/webview/v2/novel` HTML (upstream `WebNovelParser.parsePixivObject`),
// inline-image URL resolution, the in-process text cache, the reading
// progress store and the local annotation/bookmark store (upstream keeps
// these in Room; we persist Codable JSON).

// MARK: - WebNovel model

/// Subset of the `window.pixiv.novel` blob the reader needs — field names
/// match upstream `WebNovel` exactly (they're the JSON keys).
struct WebNovel: Decodable {
    let id: String?
    let title: String?
    let caption: String?
    let coverUrl: String?
    let text: String?
    let aiType: Int?
    let isOriginal: Bool?
    let seriesId: String?
    let seriesTitle: String?
    let seriesIsWatched: Bool?
    let tags: [String?]?
    let userId: String?
    let illusts: [String: WebIllustHolder]?
    let images: [String: WebNovelImage]?
    let seriesNavigation: WebSeriesNavigation?

    enum CodingKeys: String, CodingKey {
        case id, title, caption, coverUrl, text, aiType, isOriginal
        case seriesId, seriesTitle, seriesIsWatched, tags, userId
        case illusts, images, seriesNavigation
    }

    /// Decode each field independently with `try?` so one quirky field can't
    /// abort the whole novel. pixiv serializes an empty `illusts`/`images` map
    /// as `[]` (a JS empty-map artifact) rather than `{}`, which a strict
    /// `[String: …]` decode rejects with a typeMismatch — that single field then
    /// failed the entire parse and the reader showed "load failed". Per-field
    /// decoding turns that (and any future shape drift) into a nil field instead.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: key) }
        id = v(.id);                    title = v(.title)
        caption = v(.caption);          coverUrl = v(.coverUrl)
        text = v(.text);                aiType = v(.aiType)
        isOriginal = v(.isOriginal);    seriesId = v(.seriesId)
        seriesTitle = v(.seriesTitle);  seriesIsWatched = v(.seriesIsWatched)
        tags = v(.tags);                userId = v(.userId)
        illusts = v(.illusts);          images = v(.images)
        seriesNavigation = v(.seriesNavigation)
    }

    struct WebIllustHolder: Decodable {
        let illust: WebIllust?
    }

    struct WebIllust: Decodable {
        let images: WebIllustImages?
    }

    /// Pixiv inline-illust URL set; upstream priority medium > large >
    /// original > small > url.
    struct WebIllustImages: Decodable {
        let small: String?
        let medium: String?
        let large: String?
        let original: String?
        let url: String?
    }

    struct WebNovelImage: Decodable {
        let novelImageId: Int64?
        let urls: [String: String?]?

        private enum CodingKeys: String, CodingKey { case novelImageId, urls }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // novelImageId arrives as either a number or a string.
            if let n = try? c.decode(Int64.self, forKey: .novelImageId) {
                novelImageId = n
            } else if let s = try? c.decode(String.self, forKey: .novelImageId) {
                novelImageId = Int64(s)
            } else {
                novelImageId = nil
            }
            urls = try? c.decode([String: String?].self, forKey: .urls)
        }
    }

    struct WebSeriesNavigation: Decodable {
        let nextNovel: WebSeriesNeighbor?
        let prevNovel: WebSeriesNeighbor?
    }

    struct WebSeriesNeighbor: Decodable {
        let id: Int64?
        let title: String?
    }
}

enum WebNovelParser {
    private struct Root: Decodable { let novel: WebNovel? }

    /// Extract the `Object.defineProperty(window, 'pixiv', { value: {…} })`
    /// blob from the webview HTML and decode `novel`.
    ///
    /// The blob is a **JavaScript object literal**, not JSON: keys are unquoted
    /// (`sessionUserId: 1`), strings may be single-quoted, objects carry trailing
    /// commas, and values can be `undefined`. Upstream gets away with feeding it
    /// straight to Gson (lenient by default); `JSONDecoder` is strict and
    /// `.json5Allowed` still chokes on the 197 KB payload. So we run a
    /// string-aware scanner that brace-matches the `value:` object (robust where
    /// the old `});`-terminator truncated on any `});` inside the novel text) and
    /// rewrites it into strict JSON before decoding.
    static func parse(html: String) -> WebNovel? {
        guard let markerRange = html.range(of: "Object.defineProperty(window, 'pixiv'") else { return nil }
        let afterMarker = html[markerRange.upperBound...]
        guard let valueRange = afterMarker.range(of: "value:") else { return nil }
        let afterValue = afterMarker[valueRange.upperBound...]
        guard let braceIndex = afterValue.firstIndex(of: "{") else { return nil }

        guard let json = normalizeJSObject(Array(afterValue[braceIndex...])),
              let data = json.data(using: .utf8),
              let root = try? JSONDecoder().decode(Root.self, from: data) else {
            return nil
        }
        return root.novel
    }

    /// Scan a JS object literal starting at its opening `{` and emit strict JSON
    /// for exactly that object (stops when the matching `}` closes depth 0).
    /// String-aware: never rewrites content inside string literals.
    private static func normalizeJSObject(_ chars: [Character]) -> String? {
        var out = ""
        out.reserveCapacity(chars.count)
        var depth = 0
        var i = 0
        let n = chars.count

        func isIdentStart(_ c: Character) -> Bool { c.isLetter || c == "_" || c == "$" }
        func isIdentPart(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }
        func isWS(_ c: Character) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" }

        while i < n {
            let c = chars[i]

            // String literal — copy verbatim, converting ' → " and escaping
            // bare double quotes / literal control chars JSON forbids.
            if c == "\"" || c == "'" {
                let quote = c
                out.append("\"")
                i += 1
                while i < n {
                    let d = chars[i]
                    if d == "\\" {                       // keep escape pairs intact
                        out.append(d)
                        if i + 1 < n { out.append(chars[i + 1]); i += 2 } else { i += 1 }
                        continue
                    }
                    if d == quote { out.append("\""); i += 1; break }
                    switch d {
                    case "\"": out.append("\\\"")        // bare " inside a '…' string
                    case "\n": out.append("\\n")
                    case "\r": out.append("\\r")
                    case "\t": out.append("\\t")
                    default: out.append(d)
                    }
                    i += 1
                }
                continue
            }

            if c == "{" || c == "[" { depth += 1; out.append(c); i += 1; continue }
            if c == "}" || c == "]" {
                depth -= 1; out.append(c); i += 1
                if depth == 0 { return out }
                continue
            }

            // Identifier: a key (followed by `:`) gets quoted; otherwise it's a
            // bare literal (`true`/`false`/`null`, or `undefined` → `null`).
            if isIdentStart(c) {
                var ident = ""
                while i < n, isIdentPart(chars[i]) { ident.append(chars[i]); i += 1 }
                var k = i
                while k < n, isWS(chars[k]) { k += 1 }
                if k < n, chars[k] == ":" {
                    out.append("\""); out.append(ident); out.append("\"")
                } else {
                    out.append(ident == "undefined" ? "null" : ident)
                }
                continue
            }

            // Trailing comma before `}`/`]` → drop it.
            if c == "," {
                var k = i + 1
                while k < n, isWS(chars[k]) { k += 1 }
                if k < n, chars[k] == "}" || chars[k] == "]" { i += 1; continue }
                out.append(c); i += 1; continue
            }

            out.append(c); i += 1
        }
        return nil   // unbalanced braces
    }
}

// MARK: - Inline image URL resolution (upstream ImageResolver)

enum ReaderImageResolver {
    static func resolve(token: ContentToken, webNovel: WebNovel) -> String? {
        switch token {
        case .pixivImage(_, _, let illustId, let pageIndex):
            let key = pageIndex > 0 ? "\(illustId)-\(pageIndex)" : "\(illustId)"
            let direct = webNovel.illusts?[key]?.illust?.images
            let fallback = direct == nil ? webNovel.illusts?["\(illustId)"]?.illust?.images : nil
            guard let urls = direct ?? fallback else { return nil }
            return urls.medium ?? urls.large ?? urls.original ?? urls.small ?? urls.url
        case .uploadedImage(_, _, let imageId):
            guard let urls = webNovel.images?["\(imageId)"]?.urls else { return nil }
            for key in ["1200x1200", "original", "480mw", "240mw"] {
                if let u = urls[key], let url = u { return url }
            }
            return urls.values.compactMap { $0 }.first
        default:
            return nil
        }
    }
}

// MARK: - NovelTextCache (in-process LRU, 4 entries)

@MainActor
enum NovelTextCache {
    struct Entry {
        let webNovel: WebNovel
        let tokens: [ContentToken]
    }

    private static var cache: [Int64: Entry] = [:]
    private static var order: [Int64] = []
    private static let capacity = 4

    static func get(_ novelId: Int64) -> Entry? {
        guard let e = cache[novelId] else { return nil }
        order.removeAll { $0 == novelId }
        order.append(novelId)
        return e
    }

    static func put(_ novelId: Int64, _ entry: Entry) {
        cache[novelId] = entry
        order.removeAll { $0 == novelId }
        order.append(novelId)
        while order.count > capacity {
            cache.removeValue(forKey: order.removeFirst())
        }
    }
}

// MARK: - ReaderProgressStore

/// Reading progress, keyed like upstream MMKV "novel_reader_v3_progress"
/// (`char_$id` / `page_$id` / `total_$id` / `time_$id`).
enum ReaderProgressStore {
    private static let prefix = "nrv3_progress_"
    private static var d: UserDefaults { .standard }

    static func saveProgress(novelId: Int64, charIndex: Int, pageIndex: Int, totalPages: Int) {
        d.set(charIndex, forKey: "\(prefix)char_\(novelId)")
        d.set(pageIndex, forKey: "\(prefix)page_\(novelId)")
        d.set(totalPages, forKey: "\(prefix)total_\(novelId)")
        d.set(Date().timeIntervalSince1970, forKey: "\(prefix)time_\(novelId)")
    }

    static func loadCharIndex(novelId: Int64) -> Int {
        d.integer(forKey: "\(prefix)char_\(novelId)")
    }
}

// MARK: - Local annotations & position bookmarks

struct NovelAnnotation: Codable, Identifiable, Equatable {
    static let kindHighlight = "highlight"
    static let kindNote = "note"

    var id: Int64
    var novelId: Int64
    var charStart: Int
    var charEnd: Int
    /// Preview excerpt, truncated to 500 chars on insert.
    var excerpt: String
    /// Empty for highlight-only annotations.
    var note: String
    var colorARGB: UInt32
    var kind: String
    var updatedTime: Double
}

struct NovelPositionBookmark: Codable, Identifiable, Equatable {
    var id: Int64
    var novelId: Int64
    var charIndex: Int
    /// Paged-mode page number; 0 in scroll mode.
    var pageIndex: Int
    /// 80-char snippet from the content at charIndex (newlines → spaces).
    var preview: String
    var createdTime: Double
}

/// Local store for highlights/notes/position bookmarks — upstream keeps these
/// in Room; we persist one JSON file in Application Support.
@MainActor
@Observable
final class NovelReaderLocalStore {
    static let shared = NovelReaderLocalStore()

    private(set) var annotations: [NovelAnnotation] = []
    private(set) var bookmarks: [NovelPositionBookmark] = []

    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var nextId: Int64 = 1

    private struct Snapshot: Codable {
        var annotations: [NovelAnnotation]
        var bookmarks: [NovelPositionBookmark]
        var nextId: Int64
    }

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("novel_reader_v3_local.json")
    }()

    private init() {
        loadIfNeeded()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        annotations = snap.annotations
        bookmarks = snap.bookmarks
        nextId = snap.nextId
    }

    private func persist() {
        let snap = Snapshot(annotations: annotations, bookmarks: bookmarks, nextId: nextId)
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    // MARK: Annotations

    func annotations(for novelId: Int64) -> [NovelAnnotation] {
        annotations.filter { $0.novelId == novelId }.sorted { $0.charStart < $1.charStart }
    }

    /// Insert or recolor an exact-range highlight (upstream upsert logic).
    func addHighlight(novelId: Int64, charStart: Int, charEnd: Int, excerpt: String, colorARGB: UInt32) {
        if let idx = annotations.firstIndex(where: {
            $0.novelId == novelId && $0.charStart == charStart && $0.charEnd == charEnd && $0.kind == NovelAnnotation.kindHighlight
        }) {
            annotations[idx].colorARGB = colorARGB
            annotations[idx].updatedTime = Date().timeIntervalSince1970
        } else {
            annotations.append(NovelAnnotation(
                id: takeId(), novelId: novelId, charStart: charStart, charEnd: charEnd,
                excerpt: String(excerpt.prefix(500)), note: "",
                colorARGB: colorARGB, kind: NovelAnnotation.kindHighlight,
                updatedTime: Date().timeIntervalSince1970
            ))
        }
        persist()
    }

    /// Insert a new note (annotationId == 0) or update an existing one.
    func saveNote(annotationId: Int64, novelId: Int64, charStart: Int, charEnd: Int, excerpt: String, noteText: String, colorARGB: UInt32) {
        if annotationId != 0, let idx = annotations.firstIndex(where: { $0.id == annotationId }) {
            annotations[idx].note = noteText
            annotations[idx].colorARGB = colorARGB
            annotations[idx].updatedTime = Date().timeIntervalSince1970
        } else {
            annotations.append(NovelAnnotation(
                id: takeId(), novelId: novelId, charStart: charStart, charEnd: charEnd,
                excerpt: String(excerpt.prefix(500)), note: noteText,
                colorARGB: colorARGB, kind: NovelAnnotation.kindNote,
                updatedTime: Date().timeIntervalSince1970
            ))
        }
        persist()
    }

    func deleteAnnotation(id: Int64) {
        annotations.removeAll { $0.id == id }
        persist()
    }

    // MARK: Position bookmarks

    func bookmarks(for novelId: Int64) -> [NovelPositionBookmark] {
        bookmarks.filter { $0.novelId == novelId }.sorted { $0.createdTime > $1.createdTime }
    }

    func addBookmark(novelId: Int64, charIndex: Int, pageIndex: Int, preview: String) {
        bookmarks.append(NovelPositionBookmark(
            id: takeId(), novelId: novelId, charIndex: charIndex, pageIndex: pageIndex,
            preview: String(preview.prefix(300)),
            createdTime: Date().timeIntervalSince1970
        ))
        persist()
    }

    func deleteBookmark(id: Int64) {
        bookmarks.removeAll { $0.id == id }
        persist()
    }

    private func takeId() -> Int64 {
        defer { nextId += 1 }
        return nextId
    }
}
