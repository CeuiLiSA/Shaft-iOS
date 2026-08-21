import SwiftUI

// MARK: - 跳转到插画/漫画… (UserIllustJumpHelper)

/// What the overflow entry hands the sheet: which list, and how long it is.
struct UserJumpRequest: Identifiable, Hashable {
    let userId: Int64
    /// "illust" / "manga" / "novel".
    let type: String
    let total: Int
    var id: String { "\(userId):\(type)" }

    static let pageSize = 30
    var totalPages: Int { (total + Self.pageSize - 1) / Self.pageSize }
}

/// Where the sheet decided to land.
struct UserJumpTarget: Identifiable, Hashable {
    let userId: Int64
    let type: String
    let offset: Int
    /// ISO date the reader asked for, carried through for context.
    let targetDate: String?
    var id: String { "\(userId):\(type):\(offset):\(targetDate ?? "")" }
}

/// 跳到最早作品 / 按时间跳转 / 按页码跳转 — the three-way chooser, plus the page
/// prompt and the date search. Novels have no date option upstream (their list
/// endpoint is paged the same way but the helper only offers page jumps).
struct UserJumpSheet: View {
    let request: UserJumpRequest
    var onPick: (UserJumpTarget) -> Void = { _ in }

    private enum Stage { case choose, page, date, locating }

    @State private var stage: Stage = .choose
    @State private var pageText = ""
    @State private var pickedDate = Date()
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n

    private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .choose: chooser
                case .page: pagePrompt
                case .date: datePrompt
                case .locating:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(l10n.t(.userV3JumpLocatingFmt, isoDay(pickedDate)))
                            .font(.footnote)
                            .foregroundStyle(Theme.v3Text3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.v3Bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(l10n.t(.actionCancel)) { dismiss() }
                }
            }
            .alert(error ?? "", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button(l10n.t(.actionDone)) { error = nil }
            }
        }
        .presentationDetents([.medium])
    }

    private var title: String {
        l10n.t(.userV3JumpTitleFmt, "\(request.total)", "\(request.totalPages)")
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.v3Text1)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            row(l10n.t(.userV3JumpEarliest), icon: "backward.end") {
                // Land on the last page, so the oldest works are on screen.
                let offset = ((request.total - 1) / UserJumpRequest.pageSize)
                    * UserJumpRequest.pageSize
                finish(offset: max(0, offset), date: nil)
            }
            if request.type != "novel" {
                row(l10n.t(.userV3JumpByDate), icon: "calendar") { stage = .date }
            }
            row(l10n.t(.userV3JumpByPage), icon: "number") { stage = .page }
            Spacer(minLength: 0)
        }
    }

    private func row(_ text: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.v3TextAccent)
                    .frame(width: 24)
                Text(text)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.v3Text1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var pagePrompt: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.t(.userV3JumpPageTitle))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.v3Text1)
            TextField(
                l10n.t(.userV3JumpPageHintFmt, "\(request.totalPages)"),
                text: $pageText
            )
            .keyboardType(.numberPad)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Theme.v3Surface1, in: .rect(cornerRadius: 12))
            Button {
                guard let page = Int(pageText), page >= 1, page <= request.totalPages else {
                    error = l10n.t(.userV3JumpRangeErrorFmt, "\(request.totalPages)")
                    return
                }
                finish(offset: (page - 1) * UserJumpRequest.pageSize, date: nil)
            } label: {
                Text(l10n.t(.actionDone))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.brand, in: .capsule)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var datePrompt: some View {
        VStack(alignment: .leading, spacing: 14) {
            DatePicker(
                l10n.t(.userV3JumpByDate),
                selection: $pickedDate,
                // pixiv opened in 2007 — the same floor upstream sets.
                in: Self.pixivEpoch...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            Button {
                Task { await locate() }
            } label: {
                Text(l10n.t(.actionDone))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.brand, in: .capsule)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private static let pixivEpoch: Date = {
        var c = DateComponents()
        c.year = 2007; c.month = 1; c.day = 1
        return Calendar(identifier: .gregorian).date(from: c) ?? Date(timeIntervalSince1970: 0)
    }()

    /// Upstream compares `LocalDate.toString()`, which is always ISO-8601
    /// proleptic Gregorian. A plain `DateFormatter` follows `Calendar.current`
    /// instead, so on a Buddhist/Japanese-calendar device `yyyy` yields the era
    /// year (2568…) and every `firstDate <= target` probe below would be true —
    /// the search would collapse to page 0 and the jump would silently no-op.
    /// Pin calendar + locale the way `RankingDetailView.ymd` does.
    private static let isoDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func isoDay(_ date: Date) -> String {
        Self.isoDayFormatter.string(from: date)
    }

    private func finish(offset: Int, date: String?) {
        onPick(UserJumpTarget(
            userId: request.userId, type: request.type, offset: offset, targetDate: date
        ))
        dismiss()
    }

    /// Works come back newest-first, so the page whose newest item is already
    /// older than the target is the first page that can contain it — binary
    /// search over page indices, one request per probe (upstream `binarySearch`).
    private func locate() async {
        let target = isoDay(pickedDate)
        guard request.totalPages > 1 else {
            finish(offset: 0, date: target)
            return
        }
        stage = .locating
        var left = 0
        var right = request.totalPages - 1
        while left < right {
            let mid = (left + right) / 2
            let firstDate = await firstCreateDay(offset: mid * UserJumpRequest.pageSize)
            guard let firstDate else {
                // Empty page — treat as past the end and pull the right edge in.
                right = max(left, mid - 1)
                continue
            }
            if firstDate <= target { right = mid } else { left = mid + 1 }
        }
        // The target sits inside the *previous* page (that page's newest item is
        // still newer than the target), so land one page earlier.
        finish(offset: max(0, left - 1) * UserJumpRequest.pageSize, date: target)
    }

    /// `yyyy-MM-dd` of the newest work on that page, nil when the page is empty
    /// or the request failed.
    private func firstCreateDay(offset: Int) async -> String? {
        let raw: String?
        if request.type == "novel" {
            raw = try? await api.userNovels(request.userId, offset: offset).novels.first?.createDate
        } else {
            raw = try? await api.userIllusts(request.userId, type: request.type, offset: offset)
                .illusts.first?.createDate
        }
        guard let raw, raw.count >= 10 else { return nil }
        return String(raw.prefix(10))
    }
}

// MARK: - The list opened at that offset

/// A user's works starting at `offset`. Upstream additionally scrolls to (and
/// highlights) the exact work matching `targetDate` inside the landed page; the
/// waterfall here has no addressable rows to scroll to, so the page itself is
/// the landing and the date is shown in the title instead.
struct UserWorksJumpListView: View {
    let userId: Int64
    let type: String
    let offset: Int
    let targetDate: String?

    @State private var illusts: [Illust] = []
    @State private var novels: [Novel] = []
    @State private var nextUrl: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @Environment(OnboardingStore.self) private var l10n

    private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)

    var body: some View {
        Group {
            if type == "novel" {
                NovelList(
                    novels: novels, isLoading: isLoading,
                    onLoadMore: { await loadMore() }, hasMore: nextUrl != nil
                )
            } else {
                IllustWaterfallList(
                    illusts: illusts, isLoading: isLoading, errorMessage: errorMessage,
                    onRefresh: { await load() },
                    onLoadMore: { await loadMore() },
                    hasMore: nextUrl != nil
                )
            }
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { if illusts.isEmpty && novels.isEmpty { await load() } }
    }

    private var navTitle: String {
        if let targetDate { return targetDate }
        return type == "manga" ? l10n.t(.navMangaWorks)
            : type == "novel" ? l10n.t(.navNovelWorks) : l10n.t(.navIllustWorks)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            if type == "novel" {
                let r = try await api.userNovels(userId, offset: offset)
                novels = r.novels
                nextUrl = r.nextUrl
            } else {
                let r = try await api.userIllusts(userId, type: type, offset: offset)
                illusts = r.illusts
                nextUrl = r.nextUrl
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadMore() async {
        // The sentinel row's `onAppear` can fire again before the previous page
        // lands (scroll bounce, relayout), and both calls would read the same
        // `nextUrl` and append the same 30 works. Every other feed in the app
        // guards this the same way.
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if type == "novel" {
            if let r: NovelResponse = try? await api.nextPage(url) {
                novels.append(contentsOf: r.novels)
                nextUrl = r.nextUrl
            }
        } else {
            if let r: IllustResponse = try? await api.nextPage(url) {
                illusts.append(contentsOf: r.illusts)
                nextUrl = r.nextUrl
            }
        }
    }
}

// MARK: - 下载全部插画/漫画 (批量入队)

struct UserBulkFetchRequest: Identifiable, Hashable {
    let userId: Int64
    /// "illust" / "manga".
    let type: String
    var id: String { "\(userId):\(type)" }
}

/// Streams every page of the author's works, then hands the whole set to the
/// download queue in one go — the iOS stand-in for `FetchProgressDialog` +
/// `bulkEnqueueIllusts`. Closing the sheet cancels the crawl; anything already
/// fetched is discarded (upstream keeps partial work because its fetcher writes
/// straight into a persistent queue as it goes).
struct UserBulkFetchSheet: View {
    let request: UserBulkFetchRequest

    @State private var fetched = 0
    @State private var enqueued: Int?
    @State private var failed = false
    /// Bumped by Retry so the crawl re-runs through `.task(id:)` — a bare
    /// `Task {}` there would outlive the sheet and keep hitting the API after
    /// the reader dismissed it.
    @State private var attempt = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n

    private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)

    var body: some View {
        VStack(spacing: 16) {
            if let enqueued {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.brand)
                Text(l10n.t(.dlEnqueuedFmt, "\(enqueued)"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.v3Text1)
            } else if failed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.v3Text3)
                Button(l10n.t(.actionRetry)) {
                    failed = false
                    fetched = 0
                    attempt += 1
                }
                .font(.system(size: 15, weight: .semibold))
            } else {
                ProgressView()
                Text(l10n.t(.userV3BulkFetchingFmt, "\(fetched)"))
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.v3Text3)
            }
            Button(enqueued == nil ? l10n.t(.actionCancel) : l10n.t(.actionDone)) {
                dismiss()
            }
            .font(.system(size: 15, weight: .semibold))
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(Theme.v3Bg)
        .presentationDetents([.height(220)])
        .task(id: attempt) { await run() }
    }

    /// Upstream `BulkObjectFetcher` sleeps `RATE_LIMIT_MS` between pages —
    /// "防 pixiv 429，debug / release 都得守". A prolific author is hundreds of
    /// pages, and firing them back to back gets the account rate-limited part
    /// way through, so the same 2 s gap is mandatory here.
    private static let pageRateLimit: Duration = .milliseconds(2000)

    private func run() async {
        var all: [Illust] = []
        do {
            var page = try await api.userIllusts(request.userId, type: request.type)
            while true {
                all.append(contentsOf: page.illusts)
                fetched = all.count
                guard let next = page.nextUrl else { break }
                try await Task.sleep(for: Self.pageRateLimit)
                page = try await api.nextPage(next)
            }
        } catch {
            // `Task.sleep` throws on cancellation, which is the normal exit
            // when the reader closes the sheet mid-crawl.
            if Task.isCancelled || error is CancellationError { return }
            failed = true
            return
        }
        enqueued = DownloadManager.shared.enqueue(all)
    }
}
