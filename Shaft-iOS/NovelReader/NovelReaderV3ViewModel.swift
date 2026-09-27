import SwiftUI

// Orchestration — port of NovelReaderV3Fragment + NovelReaderV3ViewModel:
// load (text cache → /webview/v2/novel + /v2/novel/detail), background
// pagination preserving the reading anchor, progress persistence, full-text
// search, chapter/series navigation, pixiv bookmark + watchlist toggles,
// annotation/bookmark plumbing and export.

@MainActor
@Observable
final class NovelReaderV3ViewModel {
    let novelId: Int64

    enum LoadState {
        case idle, loading, loaded
        case error(String)
    }

    var loadState: LoadState = .idle
    var novel: Novel?
    var webNovel: WebNovel?
    var tokens: [ContentToken] = []
    var outline: [ChapterOutlineEntry] = []
    var sourceText: String = ""

    var title: String { novel?.title ?? webNovel?.title ?? "" }

    // MARK: Pagination

    struct Pagination {
        let pages: [ReaderPage]
        let style: ReaderTypeStyle
        let geometry: PageGeometry
        let revision: Int
        let startPageIndex: Int
    }

    var pagination: Pagination?
    var currentPageIndex = 0
    /// Source-char reading anchor — survives repagination + mode switches.
    var desiredCharIndex = 0
    @ObservationIgnored private var paginationRevision = 0
    @ObservationIgnored private var lastLayoutKey: String = ""
    @ObservationIgnored private var paginationTask: Task<Void, Never>?

    // MARK: Interactions

    var isBookmarked = false
    var bookmarkBusy = false
    var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    // MARK: Search

    var searchQuery = ""
    var searchRegex = false
    var searching = false
    var searchHits: [ReaderSearchHit] = [] { didSet { rebuildOverlays() } }
    var searchIndex = 0 { didSet { rebuildOverlays() } }
    var searchActive = false { didSet { rebuildOverlays() } }
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    // MARK: Series

    var seriesNovels: [Novel] = []
    var seriesLoading = false
    var seriesError: String?
    var seriesWatched = false
    var watchlistBusy = false

    // MARK: View commands (consumed by the representables)

    struct Command {
        let id: Int
        let kind: Kind
        enum Kind {
            case goToPage(Int, animated: Bool)
            case scrollToChar(Int, animated: Bool)
            case setScrollFraction(Double)
            /// TTS auto-follow (#1139): paged turns to the page holding the
            /// char, scroll brings its line into view; both skip while the
            /// user is touching the reader.
            case ttsFollow(Int)
        }
    }

    private(set) var command: Command?
    @ObservationIgnored private var commandSeq = 0

    private func send(_ kind: Command.Kind) {
        commandSeq += 1
        command = Command(id: commandSeq, kind: kind)
    }

    /// Set by the host — series navigation replaces the whole reader.
    @ObservationIgnored var onOpenNovel: ((Int64) -> Void)?

    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    @ObservationIgnored private let store = NovelReaderLocalStore.shared
    @ObservationIgnored private var l10n: (LocalizedKey) -> String = { $0.rawValue }

    init(novelId: Int64) {
        self.novelId = novelId
    }

    func configureL10n(_ t: @escaping (LocalizedKey) -> String) {
        l10n = t
    }

    // MARK: Load

    func loadIfNeeded() async {
        if case .idle = loadState { await load() }
    }

    func load() async {
        loadState = .loading
        // Novel metadata (bookmark state, series, author) — independent fetch.
        // Stored so interactions (e.g. bookmark) can await the real state.
        detailTask = Task { [weak self] in
            guard let self else { return }
            if let resp = try? await self.api.novelDetail(self.novelId) {
                self.novel = resp.novel
                self.isBookmarked = resp.novel.isBookmarked ?? false
            }
        }
        if let cached = NovelTextCache.get(novelId) {
            apply(webNovel: cached.webNovel, tokens: cached.tokens)
            return
        }
        do {
            let data = try await api.novelText(novelId)
            guard let html = String(data: data, encoding: .utf8),
                  let web = WebNovelParser.parse(html: html) else {
                loadState = .error(l10n(.nrMsgLoadFail))
                return
            }
            let text = web.text ?? ""
            let parsed = await Task.detached(priority: .userInitiated) {
                ReaderContentParser.tokenize(text)
            }.value
            NovelTextCache.put(novelId, .init(webNovel: web, tokens: parsed))
            apply(webNovel: web, tokens: parsed)
        } catch {
            loadState = .error(error.localizedDescription)
        }
    }

    private func apply(webNovel: WebNovel, tokens: [ContentToken]) {
        self.webNovel = webNovel
        self.tokens = tokens
        sourceText = webNovel.text ?? ""
        seriesWatched = webNovel.seriesIsWatched ?? false
        outline = ReaderContentParser.buildChapterOutline(
            tokens,
            pagedLabel: { String(format: self.l10n(.nrPagedSegmentFmt), $0) },
            prefaceLabel: l10n(.nrPreface)
        )
        desiredCharIndex = ReaderProgressStore.loadCharIndex(novelId: novelId)
        refreshAnnotationsCache()
        rebuildOverlays()
        loadState = .loaded
    }

    // MARK: Pagination

    func updateLayout(style: ReaderTypeStyle, geometry: PageGeometry, layoutKey: String) {
        guard case .loaded = loadState, !tokens.isEmpty else { return }
        guard layoutKey != lastLayoutKey else { return }
        lastLayoutKey = layoutKey
        paginationTask?.cancel()
        let tokens = self.tokens
        let webNovel = self.webNovel
        let anchor = desiredCharIndex
        paginationRevision += 1
        let revision = paginationRevision
        paginationTask = Task.detached(priority: .userInitiated) { [weak self] in
            let paginator = ReaderPaginator(
                tokens: tokens,
                geometry: geometry,
                style: style,
                imageUrlResolver: { token in
                    webNovel.flatMap { ReaderImageResolver.resolve(token: token, webNovel: $0) }
                }
            )
            let pages = paginator.paginate()
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, revision == self.paginationRevision else { return }
                let start = pages.firstIndex { $0.charEnd >= anchor } ?? max(pages.count - 1, 0)
                self.currentPageIndex = start
                self.pagination = Pagination(
                    pages: pages, style: style, geometry: geometry,
                    revision: revision, startPageIndex: start
                )
                if !self.searchHits.isEmpty {
                    self.searchHits = ReaderSearchEngine.annotatePageIndices(hits: self.searchHits, pages: pages)
                }
            }
        }
    }

    /// Force the next updateLayout to repaginate (mode/theme switches).
    func invalidateLayout() {
        lastLayoutKey = ""
    }

    // MARK: Progress

    func onPageChanged(_ index: Int) {
        guard let pages = pagination?.pages, pages.indices.contains(index) else { return }
        currentPageIndex = index
        desiredCharIndex = pages[index].charStart
        ReaderProgressStore.saveProgress(
            novelId: novelId, charIndex: pages[index].charStart,
            pageIndex: index, totalPages: pages.count
        )
    }

    @ObservationIgnored private var lastScrollSavedChar = -1
    var scrollFraction: Double = 0

    @ObservationIgnored private var progressSaveTask: Task<Void, Never>?

    func onScrollPositionChanged(fraction: Double, charIndex: Int) {
        scrollFraction = fraction
        guard charIndex != lastScrollSavedChar else { return }
        lastScrollSavedChar = charIndex
        desiredCharIndex = charIndex
        scheduleProgressSave(charIndex: charIndex)
    }

    /// Debounce progress persistence — the top-visible char changes many times a
    /// second during a fling, so coalesce to a single UserDefaults write.
    private func scheduleProgressSave(charIndex: Int) {
        progressSaveTask?.cancel()
        progressSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            ReaderProgressStore.saveProgress(novelId: self.novelId, charIndex: charIndex, pageIndex: 0, totalPages: 0)
        }
    }

    /// Flush any pending scroll-progress write immediately (on leave / series nav).
    func flushPendingProgress() {
        progressSaveTask?.cancel()
        progressSaveTask = nil
        guard NovelReaderSettings.shared.readingDirection == .vertical, lastScrollSavedChar >= 0 else { return }
        ReaderProgressStore.saveProgress(novelId: novelId, charIndex: lastScrollSavedChar, pageIndex: 0, totalPages: 0)
    }

    var currentCharIndex: Int {
        if NovelReaderSettings.shared.readingDirection == .vertical {
            return desiredCharIndex
        }
        guard let pages = pagination?.pages, pages.indices.contains(currentPageIndex) else { return desiredCharIndex }
        return pages[currentPageIndex].charStart
    }

    // MARK: Navigation

    func jumpToCharIndex(_ charIndex: Int, animated: Bool = false) {
        desiredCharIndex = charIndex
        if NovelReaderSettings.shared.readingDirection == .vertical {
            send(.scrollToChar(charIndex, animated: animated))
        } else if let pages = pagination?.pages,
                  let target = pages.firstIndex(where: { $0.charEnd >= charIndex }) {
            send(.goToPage(target, animated: animated))
        }
    }

    func seekToPage(_ index: Int) {
        send(.goToPage(index, animated: false))
    }

    func seekToScrollFraction(_ fraction: Double) {
        send(.setScrollFraction(fraction))
    }

    func handleJumpTap(_ target: Int) {
        if let char = ReaderContentParser.resolveJumpTarget(tokens, target: target) {
            jumpToCharIndex(char, animated: false)
        } else {
            showToast(l10n(.nrMsgJumpInvalid))
        }
    }

    /// Bottom-bar prev/next chapter; falls through to series neighbors when
    /// the outline is exhausted (upstream tryJumpSeriesNeighbor).
    func goToChapter(forward: Bool) {
        // No chapter outline: paged mode turns a single page (upstream
        // flipForward/Backward); fall through to a series neighbour only at the
        // first/last page. Scroll mode has no page unit, so go to series.
        guard !outline.isEmpty else {
            if NovelReaderSettings.shared.readingDirection == .horizontal,
               let pages = pagination?.pages, !pages.isEmpty {
                let target = min(max(currentPageIndex + (forward ? 1 : -1), 0), pages.count - 1)
                if target != currentPageIndex {
                    send(.goToPage(target, animated: true))
                    return
                }
            }
            Task { await jumpSeriesNeighbor(forward: forward) }
            return
        }
        let current = currentCharIndex
        if forward {
            if let next = outline.first(where: { $0.sourceStart > current }) {
                jumpToCharIndex(next.sourceStart)
            } else {
                Task { await jumpSeriesNeighbor(forward: true) }
            }
        } else {
            // "Previous chapter" returns to the start of the current chapter when
            // reading mid-chapter, and steps to the prior chapter only when already
            // at a boundary — matches upstream `lastOrNull { start < current }`.
            if let prev = outline.last(where: { $0.sourceStart < current }) {
                jumpToCharIndex(prev.sourceStart)
            } else {
                Task { await jumpSeriesNeighbor(forward: false) }
            }
        }
    }

    private func jumpSeriesNeighbor(forward: Bool) async {
        guard novel?.series?.id != nil else {
            showToast(l10n(forward ? .nrMsgLastChapter : .nrMsgFirstChapter))
            return
        }
        await loadSeriesIfNeeded()
        guard let idx = seriesNovels.firstIndex(where: { $0.id == novelId }) else {
            showToast(l10n(forward ? .nrMsgLastChapter : .nrMsgFirstChapter))
            return
        }
        let targetIdx = forward ? idx + 1 : idx - 1
        guard seriesNovels.indices.contains(targetIdx) else {
            showToast(l10n(forward ? .nrMsgLastChapter : .nrMsgFirstChapter))
            return
        }
        let target = seriesNovels[targetIdx]
        showToast(String(format: l10n(forward ? .nrMsgJumpNextFmt : .nrMsgJumpPrevFmt), target.title ?? ""))
        onOpenNovel?(target.id)
    }

    // MARK: Series

    func loadSeriesIfNeeded() async {
        guard seriesNovels.isEmpty, !seriesLoading, let seriesId = novel?.series?.id else { return }
        seriesLoading = true
        seriesError = nil
        defer { seriesLoading = false }
        do {
            var resp = try await api.novelSeries(seriesId)
            seriesWatched = resp.novelSeriesDetail?.watchlistAdded ?? seriesWatched
            var all = resp.novels
            var pagesFetched = 1
            // Upstream cap: 5 pages ≈ 150 novels.
            while let next = resp.nextUrl, pagesFetched < 5, all.count < 150 {
                let nextResp: NovelSeriesDetailResponse = try await api.nextPage(next)
                all += nextResp.novels
                resp = nextResp
                pagesFetched += 1
            }
            seriesNovels = all
        } catch {
            seriesError = error.localizedDescription
        }
    }

    func toggleWatchlist() async {
        guard let seriesId = novel?.series?.id, !watchlistBusy else { return }
        watchlistBusy = true
        defer { watchlistBusy = false }
        let target = !seriesWatched
        seriesWatched = target
        do {
            if target {
                _ = try await api.addToWatchlist(kind: "novel", seriesId: seriesId)
                showToast(l10n(.nrMsgWatchAdded))
            } else {
                _ = try await api.removeFromWatchlist(kind: "novel", seriesId: seriesId)
                showToast(l10n(.nrMsgWatchRemoved))
            }
        } catch {
            seriesWatched = !target
            showToast(l10n(.nrMsgOpFailed))
        }
    }

    // MARK: Pixiv bookmark

    func toggleBookmark() async {
        guard !bookmarkBusy else { return }
        bookmarkBusy = true
        defer { bookmarkBusy = false }
        // Toggle against the real bookmark state, not the optimistic default:
        // wait for the metadata fetch if the user tapped before it landed.
        await detailTask?.value
        let target = !isBookmarked
        isBookmarked = target
        do {
            if target {
                let restrict = AppSettingsStore.shared.privateStar ? "private" : "public"
                _ = try await api.bookmarkNovel(novelId, restrict: restrict)
                showToast(l10n(.nrMsgBookmarked))
            } else {
                _ = try await api.unbookmarkNovel(novelId)
                showToast(l10n(.nrMsgUnbookmarked))
            }
        } catch {
            isBookmarked = !target
            showToast(l10n(.nrMsgOpFailed))
        }
    }

    // MARK: Search

    func performSearch() {
        let query = searchQuery
        guard !query.isEmpty else {
            clearSearch()
            return
        }
        let regex = searchRegex
        let text = sourceText
        let pages = pagination?.pages
        searchTask?.cancel()
        searching = true
        searchTask = Task { [weak self] in
            // Full-text regex scan can be heavy on long novels — run it off the
            // main thread so the search bar stays responsive.
            let hits = await Task.detached(priority: .userInitiated) { () -> [ReaderSearchHit] in
                var h = ReaderSearchEngine.search(sourceText: text, query: query, regex: regex)
                if let pages { h = ReaderSearchEngine.annotatePageIndices(hits: h, pages: pages) }
                return h
            }.value
            guard !Task.isCancelled, let self else { return }
            self.searching = false
            self.searchHits = hits
            self.searchIndex = 0
            if let first = hits.first {
                self.jumpToCharIndex(first.absoluteStart)
            }
        }
    }

    func nextSearchHit() {
        guard !searchHits.isEmpty else { return }
        searchIndex = (searchIndex + 1) % searchHits.count
        jumpToCharIndex(searchHits[searchIndex].absoluteStart)
    }

    func prevSearchHit() {
        guard !searchHits.isEmpty else { return }
        searchIndex = (searchIndex - 1 + searchHits.count) % searchHits.count
        jumpToCharIndex(searchHits[searchIndex].absoluteStart)
    }

    func selectSearchHit(_ index: Int) {
        guard searchHits.indices.contains(index) else { return }
        searchIndex = index
        jumpToCharIndex(searchHits[index].absoluteStart)
    }

    func clearSearch() {
        searchTask?.cancel()
        searching = false
        searchHits = []
        searchIndex = 0
    }

    // MARK: Overlays (search highlights + annotations)

    /// Overlay highlights are cached and rebuilt only when annotations or search
    /// state change — they're read on every `updateUIView`, so recomputing the
    /// annotation filter+sort each time would burn cycles during scrolling.
    private(set) var overlays: [HighlightRange] = []
    @ObservationIgnored private var cachedNovelAnnotations: [NovelAnnotation] = []

    private func refreshAnnotationsCache() {
        cachedNovelAnnotations = store.annotations(for: novelId)
    }

    // MARK: TTS

    /// The spoken range, drawn on top of annotations / search hits when the
    /// 「高亮正在朗读的文字」 setting is on.
    private(set) var ttsHighlight: HighlightRange?
    /// Start of the spoken range (regardless of highlighting) — the scroll
    /// host reports whether it is on screen for the 「从本页开始朗读」 pill.
    var ttsFocusChar: Int?
    var ttsCharOnScreen = false

    func setTtsHighlight(_ range: HighlightRange?) {
        guard range != ttsHighlight else { return }
        ttsHighlight = range
        rebuildOverlays()
    }

    func followTts(_ charIndex: Int) {
        send(.ttsFollow(charIndex))
    }

    /// Paragraph / chapter start under a double-tapped char (upstream `NovelTtsText.paragraphStart`).
    func ttsParagraphStart(_ charIndex: Int) -> Int? {
        NovelTtsText.paragraphStart(tokens, charIndex: charIndex)
    }

    private func rebuildOverlays() {
        var result: [HighlightRange] = []
        for a in cachedNovelAnnotations {
            result.append(HighlightRange(
                absoluteStart: a.charStart, absoluteEnd: a.charEnd,
                color: UIColor(argb: a.colorARGB)
            ))
        }
        if searchActive {
            for (i, hit) in searchHits.enumerated() {
                result.append(HighlightRange(
                    absoluteStart: hit.absoluteStart, absoluteEnd: hit.absoluteEnd,
                    color: i == searchIndex ? ReaderSearchColors.current : ReaderSearchColors.other,
                    isCurrent: i == searchIndex
                ))
            }
        }
        if let ttsHighlight { result.append(ttsHighlight) }
        overlays = result
    }

    var annotations: [NovelAnnotation] { store.annotations(for: novelId) }
    var positionBookmarks: [NovelPositionBookmark] { store.bookmarks(for: novelId) }

    // MARK: Annotation / bookmark actions

    func addHighlight(_ selection: ReaderTextSelection, color: ReaderHighlightColor) {
        store.addHighlight(
            novelId: novelId, charStart: selection.absoluteStart, charEnd: selection.absoluteEnd,
            excerpt: selection.text, colorARGB: color.argb
        )
        refreshAnnotationsCache()
        rebuildOverlays()
        showToast(l10n(.nrMsgHighlighted))
    }

    func saveNote(annotationId: Int64, charStart: Int, charEnd: Int, excerpt: String, noteText: String, colorARGB: UInt32) {
        store.saveNote(
            annotationId: annotationId, novelId: novelId,
            charStart: charStart, charEnd: charEnd,
            excerpt: excerpt, noteText: noteText, colorARGB: colorARGB
        )
        refreshAnnotationsCache()
        rebuildOverlays()
        showToast(l10n(.nrMsgNoteSaved))
    }

    func deleteAnnotation(_ id: Int64) {
        store.deleteAnnotation(id: id)
        refreshAnnotationsCache()
        rebuildOverlays()
    }

    /// 「保存位置」— bookmark the current reading position.
    func addBookmarkAtCurrentPosition() {
        let char = currentCharIndex
        let ns = sourceText as NSString
        var preview = ""
        if ns.length > 0 {
            let start = min(max(char, 0), ns.length - 1)
            let len = min(80, ns.length - start)
            let r = ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: len))
            preview = ns.substring(with: r)
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        store.addBookmark(
            novelId: novelId, charIndex: char,
            pageIndex: NovelReaderSettings.shared.readingDirection == .vertical ? 0 : currentPageIndex,
            preview: preview
        )
        showToast(l10n(.nrMsgBookmarkSaved))
    }

    func deleteBookmark(_ id: Int64) {
        store.deleteBookmark(id: id)
    }

    // MARK: Clipboard / export

    func copyLink() {
        UIPasteboard.general.string = "https://www.pixiv.net/novel/show.php?id=\(novelId)"
        showToast(l10n(.nrMsgCopied))
    }

    func copyBodyText() {
        var out = ""
        for token in tokens {
            switch token {
            case .chapter(_, _, let title): out += "【\(title)】\n"
            case .paragraph(_, _, let text, _, _): out += text + "\n"
            case .blankLine: out += "\n"
            case .pageBreak: out += "\n"
            default: break
            }
        }
        UIPasteboard.general.string = out
        showToast(String(format: l10n(.nrMsgTextCopiedFmt), out.count))
    }

    var exportedFileURL: URL?

    func export(format: ReaderExportFormat) async {
        guard let webNovel else { return }
        showToast(String(format: l10n(.nrMsgExportStartFmt), format.fileExtension.uppercased()))
        let input = ReaderExportInput(
            novelId: novelId,
            title: title,
            author: novel?.user?.name ?? "",
            caption: webNovel.caption ?? "",
            tags: novel?.tags?.compactMap(\.name) ?? [],
            tokens: tokens,
            webNovel: webNovel
        )
        do {
            let url = try await ReaderExporter.export(input, format: format)
            exportedFileURL = url
        } catch {
            showToast(String(format: l10n(.nrMsgExportFailFmt), error.localizedDescription))
        }
    }

    // MARK: Toast

    func showToast(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
