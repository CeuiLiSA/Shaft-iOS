import Foundation
import Observation

// SSOT for the manga reader — 1:1 with upstream `ComicReaderV3ViewModel`, with
// `ComicPagePrefetcher`, `ComicStatsTracker`, `ComicSeriesNavigator` and
// `ComicSeriesNeighborFinder` folded in (the iOS view layer is thin enough that
// a separate UseCase/Graph tier buys nothing). Holds load state, the page list,
// the current page, prefetch bookkeeping and the reading-session timer.
@MainActor
@Observable
final class ComicReaderViewModel {
    let illustId: Int64

    enum LoadState: Equatable { case idle, loading, loaded, error(String) }

    /// One comic page — `large` is the preview resolution, `original` the
    /// full-res download (upstream `ComicPage.previewUrl` / `.originalUrl`).
    struct ComicPage: Identifiable, Hashable {
        let index: Int
        let large: URL?
        let original: URL?
        var id: Int { index }
    }

    /// Programmatic page move (tap zone / seekbar / thumbnail / bookmark jump).
    /// Swipes never emit one — the container reports those back via
    /// `reportPageSettled`. Coordinators dedupe by `id`.
    struct PageCommand: Equatable { let id: Int; let page: Int; let animated: Bool }

    var loadState: LoadState = .idle
    var illust: Illust?
    var title: String = ""
    var pages: [ComicPage] = []
    var currentPage = 0
    var command: PageCommand?
    var toast: String?

    // Series list (shared by the series sheet and neighbor jump).
    var seriesIllusts: [Illust] = []
    var seriesLoading = false
    var seriesError: String?

    /// Set by the host — series navigation replaces the whole reader (.id swap).
    @ObservationIgnored var onNavigateToReader: ((Int64) -> Void)?

    @ObservationIgnored private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    @ObservationIgnored private let store = ComicReaderLocalStore.shared
    @ObservationIgnored private var l10n: (LocalizedKey) -> String = { $0.rawValue }
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var commandSeq = 0
    @ObservationIgnored private var prefetchFingerprint = -1
    @ObservationIgnored private var sessionStart: Date?
    @ObservationIgnored private var sessionFlips = 0
    @ObservationIgnored private let initialIllust: Illust?

    private var settings: ComicReaderSettings { .shared }

    init(illustId: Int64, illust: Illust? = nil) {
        self.illustId = illustId
        self.initialIllust = (illust?.id == illustId) ? illust : nil
    }

    func configureL10n(_ t: @escaping (LocalizedKey) -> String) { l10n = t }

    // MARK: Load

    func loadIfNeeded() async {
        if case .idle = loadState { await load() }
    }

    /// Retry after a failed load (the error overlay taps into this).
    func reload() async {
        loadState = .idle
        await load()
    }

    func load() async {
        guard loadState != .loading else { return }
        loadState = .loading
        // The detail screen already holds the full Illust (meta_pages included);
        // reuse it instead of a refetch. Series navigation passes nil → fetch.
        if let cached = initialIllust, (cached.pageCount ?? 1) > 0 {
            applyIllust(cached)
            return
        }
        do {
            let resp = try await api.illustDetail(illustId)
            applyIllust(resp.illust)
        } catch {
            loadState = .error(error.localizedDescription)
        }
    }

    private func applyIllust(_ illust: Illust) {
        self.illust = illust
        self.title = illust.title ?? ""
        self.pages = IllustPages.pages(for: illust).enumerated().map {
            ComicPage(index: $0.offset, large: $0.element.large, original: $0.element.original)
        }
        let resume = ComicReaderProgressStore.lastPage(illustId: illustId)
            .clamped(0, max(pages.count - 1, 0))
        currentPage = resume
        loadState = .loaded
        prefetchFingerprint = -1
        prefetchAround(resume)
    }

    // MARK: URL resolution (ComicPageUrlResolver parity)

    /// Page URL honoring the "load original" setting, with sensible fallbacks.
    func url(for page: ComicPage) -> URL? {
        settings.loadOriginal ? (page.original ?? page.large) : (page.large ?? page.original)
    }

    /// Preview (large) URL — used for thumbnails and bookmark snapshots.
    func previewUrl(for page: ComicPage) -> URL? { page.large ?? page.original }

    // MARK: Page navigation

    /// Container reports a settled swipe here (counts as a flip for stats).
    func reportPageSettled(_ index: Int) { goToPage(index, countFlip: true) }

    /// Programmatic jump — updates the cursor and tells the container to move.
    func jumpTo(_ page: Int, animated: Bool = false) {
        let p = page.clamped(0, max(pages.count - 1, 0))
        goToPage(p, countFlip: false)
        commandSeq += 1
        command = PageCommand(id: commandSeq, page: p, animated: animated)
    }

    /// Tap-zone / boundary step. Returns whether a flip actually happened.
    @discardableResult
    func stepPage(forward: Bool) -> Bool {
        guard !pages.isEmpty else { return false }
        let target = forward ? currentPage + 1 : currentPage - 1
        guard target >= 0, target < pages.count else { return false }
        jumpTo(target, animated: true)
        return true
    }

    private func goToPage(_ index: Int, countFlip: Bool) {
        let changed = index != currentPage
        currentPage = index
        guard !pages.isEmpty else { return }
        ComicReaderProgressStore.savePage(illustId: illustId, pageIndex: index, totalPages: pages.count)
        if changed && countFlip { sessionFlips += 1 }
        prefetchAround(index)
    }

    // MARK: Prefetch (ComicPagePrefetcher parity)

    func onImageSettingsChanged() {
        prefetchFingerprint = -1
        prefetchAround(currentPage)
    }

    private func prefetchAround(_ index: Int) {
        guard !pages.isEmpty else { return }
        let ahead = settings.preloadAhead
        guard ahead > 0 else { return }
        let end = min(index + ahead, pages.count - 1)
        let original = settings.loadOriginal
        // (index, end, original) fingerprint — any change triggers a fresh round.
        let fp = (index << 20) | (end << 4) | (original ? 1 : 0)
        guard fp != prefetchFingerprint else { return }
        prefetchFingerprint = fp
        guard index + 1 <= end else { return }
        // Paged cells decode from raw bytes (`loadData` → TileImageSource);
        // webtoon cells consume decoded images (`load`). Warm the layer each
        // mode actually reads, otherwise prefetch is a no-op for that mode.
        let webtoon = settings.readingMode == .webtoon
        for i in (index + 1)...end {
            let u = original ? (pages[i].original ?? pages[i].large)
                             : (pages[i].large ?? pages[i].original)
            guard let url = u else { continue }
            if webtoon {
                Task { _ = await PixivImageCache.shared.load(url) }
            } else {
                Task { _ = await PixivImageCache.shared.loadData(url) }
            }
        }
    }

    // MARK: Reading-session stats (ComicStatsTracker parity)

    func onSessionStart() { sessionStart = Date() }

    func onSessionFlush() {
        guard let start = sessionStart else { return }
        let duration = max(Date().timeIntervalSince(start), 0)
        let flips = sessionFlips
        sessionFlips = 0
        sessionStart = Date()
        guard duration > 0 || flips > 0 else { return }
        store.flushSession(illustId: illustId, lastIndex: currentPage,
                           totalPages: pages.count, durationSec: duration, flips: flips)
    }

    // MARK: Bookmarks

    func addBookmark(at pageIndex: Int) {
        guard pages.indices.contains(pageIndex) else { return }
        let preview = previewUrl(for: pages[pageIndex])?.absoluteString ?? ""
        store.addBookmark(illustId: illustId, pageIndex: pageIndex,
                          totalPages: pages.count, previewUrl: preview)
        showToast(String(format: l10n(.crBookmarksAdded), "\(pageIndex + 1)"))
    }

    // MARK: Series

    func loadSeriesIfNeeded() async {
        guard seriesIllusts.isEmpty, !seriesLoading, let seriesId = illust?.series?.id else { return }
        seriesLoading = true
        seriesError = nil
        defer { seriesLoading = false }
        do {
            var resp = try await api.illustSeries(seriesId)
            var all = resp.illusts
            var fetched = 1
            // Upstream cap: 10 pages ≈ 300 works.
            while let next = resp.nextUrl, fetched < 10, all.count < 300 {
                let r: IllustSeriesResponse = try await api.nextPage(next)
                all += r.illusts
                resp = r
                fetched += 1
            }
            seriesIllusts = all
        } catch {
            seriesError = error.localizedDescription
        }
    }

    func jumpSeriesNeighbor(forward: Bool) async {
        guard illust?.series?.id != nil else { showToast(l10n(.crNoSeries)); return }
        showToast(l10n(.crSeriesLoading))
        await loadSeriesIfNeeded()
        guard let idx = seriesIllusts.firstIndex(where: { $0.id == illustId }) else {
            showToast(l10n(.crNoSeries)); return
        }
        let target = forward ? idx + 1 : idx - 1
        guard seriesIllusts.indices.contains(target) else {
            showToast(l10n(forward ? .crSeriesLast : .crSeriesFirst)); return
        }
        onNavigateToReader?(seriesIllusts[target].id)
    }

    // MARK: Toast

    func showToast(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.0))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}

private extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}
