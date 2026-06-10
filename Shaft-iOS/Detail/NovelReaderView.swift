import SwiftUI

@MainActor
@Observable
final class NovelReaderViewModel {
    let novelId: Int64
    var title: String = ""
    var author: String = ""
    var rawText: String = ""
    var pages: [String] = []
    /// 1-based `[newpage]` chapter each reader page belongs to — parallel to
    /// `pages`. The SERVER marker unit is this chapter index (upstream
    /// `NovelParseHelper` splits on `[newpage]`), not our char-based pages.
    var pageChapters: [Int] = []
    var isLoading = false
    var errorMessage: String?
    /// 1-based chapter the marker sits on; 0 = no marker. Shaft semantics:
    /// one marker per novel — marking another chapter overwrites, marking the
    /// same chapter removes it.
    var markerChapter: Int = 0
    var isTogglingMarker = false

    @ObservationIgnored private let api: PixivAPI

    init(novelId: Int64) {
        self.novelId = novelId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async {
        if rawText.isEmpty { await load() }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // Pixiv `/webview/v2/novel?id=` returns an HTML page that embeds
            // the novel in a JSON blob. Shaft's `WebNovelParser` extracts the
            // `text` field from `pixiv.context = { … }`. We replicate the
            // extraction here.
            let data = try await api.novelText(novelId)
            guard let html = String(data: data, encoding: .utf8) else {
                errorMessage = "Decoding failed"
                return
            }
            let extracted = NovelHTMLExtractor.extract(from: html)
            title = extracted.title
            author = extracted.author
            rawText = extracted.text
            (pages, pageChapters) = Self.paginate(extracted.text)
            markerChapter = extracted.markerPage
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// First reader page of the marked chapter — where "resume from marker"
    /// lands. nil when no marker.
    var resumePageIndex: Int? {
        guard markerChapter > 0 else { return nil }
        return pageChapters.firstIndex(of: markerChapter)
            ?? (pages.isEmpty ? nil : pages.count - 1)
    }

    /// Toggle the marker for the chapter containing the given 0-based reader
    /// page. Same chapter → delete, other chapter → add (server overwrites).
    func toggleMarker(atPageIndex index: Int) async {
        guard !isTogglingMarker, pageChapters.indices.contains(index) else { return }
        isTogglingMarker = true
        defer { isTogglingMarker = false }
        let chapter = pageChapters[index]
        let previous = markerChapter
        do {
            if markerChapter == chapter {
                markerChapter = 0
                _ = try await api.deleteNovelMarker(novelId)
            } else {
                markerChapter = chapter
                _ = try await api.addNovelMarker(novelId, page: chapter)
            }
        } catch {
            markerChapter = previous
        }
    }

    /// Two-level paginator. The text is first split on pixiv's `[newpage]`
    /// chapter token (the unit the server marker API speaks — upstream
    /// `NovelParseHelper` does the same), then each chapter is char-paginated
    /// for our swipe reader. Returns the display pages plus each page's
    /// 1-based chapter index.
    static func paginate(_ text: String, charsPerPage: Int = 1100) -> ([String], [Int]) {
        guard !text.isEmpty else { return ([], []) }
        var pages: [String] = []
        var chapters: [Int] = []
        for (i, chapterText) in text.components(separatedBy: "[newpage]").enumerated() {
            let trimmed = chapterText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            for p in paginateChapter(trimmed, charsPerPage: charsPerPage) {
                pages.append(p)
                chapters.append(i + 1)
            }
        }
        return (pages, chapters)
    }

    /// Greedy by-character paginator. Pixiv novels use `\n\n` for paragraph
    /// breaks; we stop at the last paragraph that fits the page budget.
    private static func paginateChapter(_ text: String, charsPerPage: Int) -> [String] {
        var pages: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            if current.count + paragraph.count + 2 > charsPerPage, !current.isEmpty {
                pages.append(current)
                current = ""
            }
            if !current.isEmpty { current += "\n\n" }
            current += paragraph
        }
        if !current.isEmpty { pages.append(current) }
        return pages
    }
}

enum NovelHTMLExtractor {
    struct Extracted {
        let title: String
        let author: String
        let text: String
        /// Reading-marker page from the embedded `"marker":{"page":N}` blob —
        /// 0 = no marker. Same source Shaft's `WebNovelParser` reads.
        var markerPage: Int = 0
    }

    static func extract(from html: String) -> Extracted {
        // pixiv.context = {…};   — single-line JSON-ish blob.
        let pattern = #"pixiv\.context\s*=\s*(\{.*?\});"#
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: range),
              let blobRange = Range(match.range(at: 1), in: html) else {
            return Extracted(title: "", author: "", text: stripHTML(html))
        }
        let blob = String(html[blobRange])

        let title = stringField("title", in: blob) ?? ""
        let author = stringField("authorDetails.userName", in: blob)
            ?? stringField("authorName", in: blob) ?? ""
        let text = stringField("text", in: blob)
            .map(unescapeJSON)
            ?? stripHTML(html)

        // Marker lookup scans the WHOLE document, not just the captured blob:
        // upstream `WebNovelParser` reads it from the
        // `Object.defineProperty(window, 'pixiv', …)` script, which is a
        // different blob than `pixiv.context`. Inside JSON string values every
        // quote is escaped (\"), so a bare `"marker":{` can only be real JSON.
        return Extracted(title: title, author: author, text: text, markerPage: markerPage(in: html))
    }

    private static func markerPage(in html: String) -> Int {
        let pattern = #""marker"\s*:\s*\{[^}]*"page"\s*:\s*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
              let r = Range(m.range(at: 1), in: html) else { return 0 }
        return Int(html[r]) ?? 0
    }

    private static func stringField(_ name: String, in blob: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "\"\(escaped)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: blob, range: NSRange(blob.startIndex..<blob.endIndex, in: blob)),
              let r = Range(match.range(at: 1), in: blob) else { return nil }
        return String(blob[r])
    }

    private static func unescapeJSON(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
         .replacingOccurrences(of: "\\r", with: "")
         .replacingOccurrences(of: "\\\"", with: "\"")
         .replacingOccurrences(of: "\\/", with: "/")
         .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<.+?>", with: "", options: .regularExpression)
         .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}

/// V3-style novel reader: paged horizontal swipe, dimmable background, top bar
/// with title, bottom bar with progress.
struct NovelReaderView: View {
    let novelId: Int64
    @State private var vm: NovelReaderViewModel
    @State private var page: Int = 0
    @Environment(\.dismiss) private var dismiss

    init(novelId: Int64) {
        self.novelId = novelId
        _vm = State(wrappedValue: NovelReaderViewModel(novelId: novelId))
    }

    var body: some View {
        ZStack {
            Color(red: 0.99, green: 0.97, blue: 0.93).ignoresSafeArea()

            if vm.pages.isEmpty {
                if vm.isLoading {
                    ProgressView()
                } else if let err = vm.errorMessage {
                    InlineError(message: err) { Task { await vm.load() } }.padding()
                }
            } else {
                TabView(selection: $page) {
                    ForEach(Array(vm.pages.enumerated()), id: \.offset) { i, content in
                        ScrollView {
                            Text(content)
                                .font(.system(size: 18, weight: .regular, design: .serif))
                                .lineSpacing(8)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 60)
                        }
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .background(.thinMaterial, in: .circle)
                    }
                    Spacer()
                    if !vm.title.isEmpty {
                        Text(vm.title).font(.footnote.bold()).lineLimit(1)
                    }
                    Spacer()
                    // Reading marker (Shaft 小说书签): marks the [newpage]
                    // chapter containing the current page; tapping in the
                    // marked chapter removes it, elsewhere moves it. Filled
                    // icon = this novel has a marker.
                    Button {
                        Task { await vm.toggleMarker(atPageIndex: page) }
                    } label: {
                        Image(systemName: vm.markerChapter > 0 ? "bookmark.fill" : "bookmark")
                            .font(.title3)
                            .foregroundStyle(vm.markerChapter > 0 ? Color.accentColor : .primary)
                            .frame(width: 36, height: 36)
                            .background(.thinMaterial, in: .circle)
                    }
                    .disabled(vm.pages.isEmpty || vm.isTogglingMarker)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
                if !vm.pages.isEmpty {
                    HStack {
                        Text("\(page + 1) / \(vm.pages.count)")
                            .font(.caption.bold())
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.thinMaterial, in: .capsule)
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .task {
            await vm.loadIfNeeded()
            // Resume from the reading marker, like Shaft's FragmentNovelHolder.
            if let resume = vm.resumePageIndex {
                page = resume
            }
        }
    }
}
