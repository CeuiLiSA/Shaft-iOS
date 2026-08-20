import SwiftUI
import WebKit

struct SearchView: View {
    @State private var word: String = ""
    @State private var suggestions: [AutoCompleteTag] = []
    @State private var trending: [TrendingTag] = []
    @State private var loadingTrending = false
    @State private var history = SearchHistoryStore.shared
    @State private var pinned = PinnedTagsStore.shared
    @Environment(OnboardingStore.self) private var l10n

    @ObservationIgnored private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)

    private let gridColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            content
        }
        .navigationTitle(l10n.t(.searchTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadTrendingIfNeeded() }
        .task(id: word) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !word.isEmpty else { suggestions = []; return }
            suggestions = (try? await api.autocompleteTags(prefix: word))?.tags ?? []
        }
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(l10n.t(.searchPlaceholder), text: $word)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !word.isEmpty {
                Button { word = ""; suggestions = [] } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
        .padding(.horizontal, 12).padding(.top, 8)
    }

    // MARK: Content — empty (history + trending) vs typing (autocomplete)

    @ViewBuilder private var content: some View {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            emptyState
        } else {
            suggestionList(trimmed: trimmed)
        }
    }

    /// The landing surface: recent-search chips plus the trending-tags grid.
    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !history.entries.isEmpty {
                    historySection
                }
                trendingSection
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(l10n.t(.searchRecent)).font(.headline)
                Spacer()
                Button(l10n.t(.actionClear)) { history.clear() }
                    .font(.subheadline)
            }
            FlowLayout(spacing: 8) {
                ForEach(history.entries, id: \.self) { term in
                    historyChip(term)
                }
            }
        }
    }

    private func historyChip(_ term: String) -> some View {
        NavigationLink(value: AppRoute.searchResults(word: term)) {
            HStack(spacing: 5) {
                Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
                Text(term).font(.subheadline).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color(.secondarySystemBackground), in: .capsule)
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { history.record(term) })
        .contextMenu {
            Button(role: .destructive) { history.remove(term) } label: {
                Label(l10n.t(.actionDelete), systemImage: "trash")
            }
        }
    }

    @ViewBuilder private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.t(.subPopularTags)).font(.headline)
            if trending.isEmpty && loadingTrending {
                TagGridSkeleton(columns: 2, rows: 3, corner: 8)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 8) {
                    ForEach(trending) { tag in
                        NavigationLink(value: AppRoute.tagResults(tag: tag.tag ?? "")) {
                            TagGridCell(tag: tag)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            if let t = tag.tag { history.record(t) }
                        })
                        .contextMenu { pinButton(name: tag.tag,
                                                 translatedName: tag.translatedName,
                                                 previewURL: tag.illust?.imageUrls?.squareMedium) }
                    }
                }
            }
        }
    }

    /// Typing surface: link shortcuts, the literal-search row, then keyword
    /// suggestions (关键词联想) from `/v2/search/autocomplete`.
    private func suggestionList(trimmed: String) -> some View {
        List {
            let shortcuts = PixivLinkParser.shortcuts(for: trimmed)
            if !shortcuts.isEmpty {
                Section(l10n.t(.searchOpenLink)) {
                    ForEach(Array(shortcuts.enumerated()), id: \.offset) { _, s in
                        NavigationLink(value: s.route) {
                            Label(s.title, systemImage: s.systemImage)
                        }
                    }
                }
            }
            NavigationLink(value: AppRoute.searchResults(word: trimmed)) {
                Label(trimmed, systemImage: "magnifyingglass")
            }
            .simultaneousGesture(TapGesture().onEnded { history.record(trimmed) })
            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions) { tag in
                        NavigationLink(value: AppRoute.tagResults(tag: tag.name ?? "")) {
                            HStack {
                                Text(tag.name ?? "")
                                if let t = tag.translatedName, !t.isEmpty {
                                    Spacer()
                                    Text(t).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            if let n = tag.name { history.record(n) }
                        })
                        .contextMenu { pinButton(name: tag.name,
                                                 translatedName: tag.translatedName,
                                                 previewURL: nil) }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    /// Pin / unpin a tag from any search-surface long-press (1:1 with the
    /// FragmentSearch pin path). Re-reads `pinned.isPinned` so the label flips.
    @ViewBuilder
    private func pinButton(name: String?, translatedName: String?, previewURL: String?) -> some View {
        let isPinned = pinned.isPinned(name)
        Button {
            pinned.toggle(name: name, translatedName: translatedName, previewURL: previewURL)
        } label: {
            Label(isPinned ? l10n.t(.actionUnpinTag) : l10n.t(.actionPinTag),
                  systemImage: isPinned ? "pin.slash" : "pin")
        }
    }

    // MARK: Loading

    private func loadTrendingIfNeeded() async {
        guard trending.isEmpty, !loadingTrending else { return }
        loadingTrending = true
        defer { loadingTrending = false }
        trending = (try? await api.trendingTags())?.trendTags ?? []
    }
}

/// Parses Pixiv URLs and bare numeric IDs into navigation shortcuts that
/// surface above tag suggestions in the search box.
enum PixivLinkParser {
    struct Shortcut {
        let title: String
        let systemImage: String
        let route: AppRoute
    }

    static func shortcuts(for input: String) -> [Shortcut] {
        guard !input.isEmpty else { return [] }

        // Pixiv app scheme: pixiv://artworks/123, pixiv://users/123
        if let url = URL(string: input), url.scheme?.lowercased() == "pixiv" {
            if let id = numericID(in: url.path) ?? numericID(in: url.host ?? "") {
                let host = (url.host ?? "").lowercased()
                if host.contains("user") {
                    return [Shortcut(title: "User \(id)", systemImage: "person.crop.circle", route: .userProfile(id))]
                }
                if host.contains("novel") {
                    return [Shortcut(title: "Novel \(id)", systemImage: "book", route: .novelDetail(id))]
                }
                return [Shortcut(title: "Illust \(id)", systemImage: "photo", route: .illustDetail(id))]
            }
        }

        // Web URLs.
        let lower = input.lowercased()
        if lower.contains("pixiv.net") {
            if let r = match(input, "/artworks/(\\d+)") { return [.init(title: "Illust \(r)", systemImage: "photo", route: .illustDetail(r))] }
            if let r = match(input, "/i/(\\d+)")        { return [.init(title: "Illust \(r)", systemImage: "photo", route: .illustDetail(r))] }
            if let r = match(input, "/users/(\\d+)")    { return [.init(title: "User \(r)", systemImage: "person.crop.circle", route: .userProfile(r))] }
            if let r = match(input, "/member.php\\?id=(\\d+)") { return [.init(title: "User \(r)", systemImage: "person.crop.circle", route: .userProfile(r))] }
            if let r = match(input, "/novel/show.php\\?id=(\\d+)") { return [.init(title: "Novel \(r)", systemImage: "book", route: .novelDetail(r))] }
            if let r = match(input, "/n/(\\d+)")        { return [.init(title: "Novel \(r)", systemImage: "book", route: .novelDetail(r))] }
        }

        // Bare numeric ID — type ambiguous, offer all three.
        if let id = Int64(input), id > 0 {
            return [
                .init(title: "Illust \(id)", systemImage: "photo",            route: .illustDetail(id)),
                .init(title: "User \(id)",   systemImage: "person.crop.circle", route: .userProfile(id)),
                .init(title: "Novel \(id)",  systemImage: "book",            route: .novelDetail(id)),
            ]
        }
        return []
    }

    /// Compiled once — `shortcuts(for:)` runs in the search List's body on
    /// every keystroke, and NSRegularExpression compilation isn't free.
    private static let compiledPatterns: [String: NSRegularExpression] = {
        let patterns = [
            "/artworks/(\\d+)", "/i/(\\d+)", "/users/(\\d+)",
            "/member.php\\?id=(\\d+)", "/novel/show.php\\?id=(\\d+)", "/n/(\\d+)",
        ]
        return Dictionary(uniqueKeysWithValues: patterns.compactMap { p in
            (try? NSRegularExpression(pattern: p)).map { (p, $0) }
        })
    }()

    private static func match(_ input: String, _ pattern: String) -> Int64? {
        guard let regex = compiledPatterns[pattern] else { return nil }
        let range = NSRange(input.startIndex..., in: input)
        guard let m = regex.firstMatch(in: input, range: range), m.numberOfRanges >= 2 else { return nil }
        guard let r = Range(m.range(at: 1), in: input) else { return nil }
        return Int64(input[r])
    }

    private static func numericID(in s: String) -> Int64? {
        let digits = s.split(whereSeparator: { !$0.isNumber }).last.map(String.init) ?? ""
        return Int64(digits)
    }
}

@MainActor
@Observable
final class SearchResultsViewModel {
    let word: String

    /// Displayed (post client-side filter) results. Raw pages are retained so
    /// pagination and client-only filters always use the frozen generation.
    var illusts: [Illust] = []
    var novelItems: [SearchNovelItem] = []
    var users: [UserPreview] = []
    @ObservationIgnored private var rawIllusts: [Illust] = []
    @ObservationIgnored private var rawNovelItems: [SearchNovelItem] = []
    @ObservationIgnored private var rawUsers: [UserPreview] = []
    @ObservationIgnored private var illustGeneration = 0
    @ObservationIgnored private var novelGeneration = 0
    @ObservationIgnored private var userGeneration = 0
    @ObservationIgnored private var illustHasLoaded = false
    @ObservationIgnored private var novelHasLoaded = false
    @ObservationIgnored private var userHasLoaded = false
    @ObservationIgnored private var illustLoadTask: Task<Void, Never>?
    @ObservationIgnored private var novelLoadTask: Task<Void, Never>?
    @ObservationIgnored private var userLoadTask: Task<Void, Never>?
    /// Filters backing the currently displayed generation. The sheet's live
    /// state can change without a refresh when its parent Cancel is tapped.
    @ObservationIgnored private var illustResultsFilter: SearchFilter
    @ObservationIgnored private var novelResultsFilter: SearchFilter
    /// `gs=1` pagination must keep the first page's frozen parameters.
    @ObservationIgnored private var groupedNovelFilter: SearchFilter?

    var illustNext: String?
    var novelNext: String?
    var userNext: String?

    /// Shaft keeps independent live filters for illustration and novel tabs.
    /// Changing one tab must not silently mutate the other tab's query.
    var illustFilter: SearchFilter
    var novelFilter: SearchFilter
    /// Dynamic tool / genre / language options, loaded once.
    var options: SearchOptionsResponse?
    /// Refreshed from the authoritative self profile before every generation.
    var isPremium = false
    var novelResultsGrouped = false
    var novelWebAuthenticated = false

    var isLoadingIllust = false
    var isLoadingNovel = false
    var isLoadingUsers = false
    var isLoadingMoreIllusts = false
    var isLoadingMoreNovels = false
    var isLoadingMoreUsers = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI
    @ObservationIgnored private let requests: SearchRequestCoordinator

    init(word: String) {
        self.word = word
        let illustDefault = SearchFilter.makeDefault()
        let novelDefault = SearchFilter.makeDefault(forNovel: true)
        self.illustFilter = illustDefault
        self.novelFilter = novelDefault
        self.illustResultsFilter = illustDefault
        self.novelResultsFilter = novelDefault
        self.groupedNovelFilter = nil
        self.isPremium = KeychainTokenStore.shared.load()?.user?.isPremium ?? false
        let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
        self.api = api
        self.requests = SearchRequestCoordinator(api: api)
    }

    /// Upstream's off-screen ViewPager pages do not search until they are first
    /// resumed. That distinction matters for borrowed popularity searches: an
    /// initial illustration page must not silently consume a second novel slot.
    func loadIllustIfNeeded() async {
        guard !illustHasLoaded else { return }
        await reloadIllust()
    }

    func loadNovelIfNeeded() async {
        guard !novelHasLoaded else { return }
        await reloadNovel()
    }

    func loadUsersIfNeeded() async {
        guard !userHasLoaded else { return }
        await reloadUsers()
    }

    func loadOptionsIfNeeded() async {
        guard options == nil else { return }
        // The response is word-independent but pixiv requires a non-empty word.
        // Upstream uses this harmless placeholder when a query should not be
        // leaked merely by opening the filter sheet.
        options = try? await api.searchOptions(word: "art")
    }

    /// Resolves premium status (self id → user detail) so popular sorts route
    /// correctly. Best-effort; defaults to non-premium until known.
    func refreshAccount() async {
        guard let uid = try? await api.selfProfile().profile.userId else {
            return
        }
        if let detail = try? await api.userDetail(uid) {
            if let premium = detail.profile?.isPremium { isPremium = premium }
        }
    }

    /// Apply only to the tab that opened the sheet, matching the two LiveData
    /// stores and two refresh events in Pixiv-Shaft's SearchViewModel.
    func apply(_ newFilter: SearchFilter, isNovel: Bool) async {
        if isNovel {
            novelFilter = newFilter
            await startNovelGeneration(filter: newFilter, clearCurrent: true)
        } else {
            illustFilter = newFilter
            await startIllustGeneration(filter: newFilter, clearCurrent: true)
        }
    }

    /// Child pickers commit into shared filter state immediately, while the
    /// displayed generation remains untouched until Search is pressed.
    func stage(_ newFilter: SearchFilter, isNovel: Bool) {
        if isNovel { novelFilter = newFilter }
        else { illustFilter = newFilter }
    }

    func reloadIllust() async {
        await startIllustGeneration(filter: illustFilter, clearCurrent: false)
    }

    func reloadNovel() async {
        await startNovelGeneration(filter: novelFilter, clearCurrent: false)
    }

    func reloadUsers() async {
        userHasLoaded = true
        userGeneration += 1
        let generation = userGeneration
        userLoadTask?.cancel()
        isLoadingUsers = true
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performUserGeneration(generation: generation)
        }
        userLoadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performUserGeneration(generation: Int) async {
        defer {
            if userGeneration == generation { isLoadingUsers = false }
        }
        do {
            let response = try await api.searchUser(word: word)
            guard userGeneration == generation else { return }
            rawUsers = response.userPreviews
            userNext = response.nextUrl
            recomputeUsers()
        } catch {
            if userGeneration == generation { errorMessage = error.localizedDescription }
        }
    }

    private func startIllustGeneration(filter: SearchFilter, clearCurrent: Bool) async {
        illustHasLoaded = true
        illustGeneration += 1
        let generation = illustGeneration
        illustLoadTask?.cancel()
        illustResultsFilter = filter
        if clearCurrent {
            rawIllusts = []; illusts = []; illustNext = nil
        }
        isLoadingIllust = true
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performIllustGeneration(filter: filter, generation: generation)
        }
        illustLoadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performIllustGeneration(filter: SearchFilter, generation: Int) async {
        defer {
            if illustGeneration == generation { isLoadingIllust = false }
        }
        // Membership is deliberately re-read at the start of every result
        // generation. A stale login snapshot must never decide whether to use
        // the signed-in token or a borrowed Premium account.
        await refreshAccount()
        guard illustGeneration == generation else { return }
        await requests.startIllustGeneration()
        guard illustGeneration == generation else { return }
        let requesterUID = KeychainTokenStore.shared.load()?.user?.id ?? 0
        do {
            let response = try await requests.firstIllust(
                word: word, filter: filter,
                requesterUID: requesterUID, isPremium: isPremium
            )
            guard illustGeneration == generation else { return }
            rawIllusts = response.illusts
            illustNext = response.nextUrl
            recomputeIllusts()
        } catch {
            if illustGeneration == generation { errorMessage = error.localizedDescription }
        }
    }

    private func startNovelGeneration(filter: SearchFilter, clearCurrent: Bool) async {
        novelHasLoaded = true
        novelGeneration += 1
        let generation = novelGeneration
        novelLoadTask?.cancel()
        novelResultsFilter = filter
        groupedNovelFilter = filter.groupBySeries ? filter : nil
        novelResultsGrouped = filter.groupBySeries
        if !filter.groupBySeries { novelWebAuthenticated = false }
        if clearCurrent {
            rawNovelItems = []; novelItems = []; novelNext = nil
        }
        isLoadingNovel = true
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performNovelGeneration(filter: filter, generation: generation)
        }
        novelLoadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performNovelGeneration(filter: SearchFilter, generation: Int) async {
        defer {
            if novelGeneration == generation { isLoadingNovel = false }
        }
        if !filter.groupBySeries {
            // Grouped mode is a web-cookie request. App OAuth membership and
            // the borrowed-session coordinator do not participate in it.
            await refreshAccount()
            guard novelGeneration == generation else { return }
            await requests.startNovelGeneration()
            guard novelGeneration == generation else { return }
        }
        let requesterUID = KeychainTokenStore.shared.load()?.user?.id ?? 0
        do {
            if filter.groupBySeries {
                let page = try await GroupedNovelSearchClient.shared.search(
                    word: word, filter: filter, page: 1
                )
                guard novelGeneration == generation else { return }
                rawNovelItems = page.items
                novelNext = page.nextPage.map { "grouped:\($0)" }
                novelWebAuthenticated = page.webAuthenticated
            } else {
                let response = try await requests.firstNovel(
                    word: word, filter: filter,
                    requesterUID: requesterUID, isPremium: isPremium
                )
                guard novelGeneration == generation else { return }
                rawNovelItems = response.novels.map(SearchNovelItem.novel)
                novelNext = response.nextUrl
            }
            recomputeNovels()
        } catch {
            if novelGeneration == generation { errorMessage = error.localizedDescription }
        }
    }

    func loadMoreIllusts() async {
        guard let url = illustNext, !isLoadingMoreIllusts else { return }
        let generation = illustGeneration
        isLoadingMoreIllusts = true
        defer { isLoadingMoreIllusts = false }
        if let r = try? await requests.nextIllust(url) {
            guard illustGeneration == generation else { return }
            rawIllusts.append(contentsOf: r.illusts)
            illustNext = r.nextUrl
            recomputeIllusts()
        }
    }

    func loadMoreNovels() async {
        guard let url = novelNext, !isLoadingMoreNovels else { return }
        let generation = novelGeneration
        isLoadingMoreNovels = true
        defer { isLoadingMoreNovels = false }
        if let groupedFilter = groupedNovelFilter,
           url.hasPrefix("grouped:"),
           let pageNumber = Int(url.dropFirst("grouped:".count)) {
            if let page = try? await GroupedNovelSearchClient.shared.search(
                word: word, filter: groupedFilter, page: pageNumber
            ) {
                guard novelGeneration == generation else { return }
                rawNovelItems.append(contentsOf: page.items)
                novelNext = page.nextPage.map { "grouped:\($0)" }
                novelWebAuthenticated = page.webAuthenticated
                recomputeNovels()
            }
        } else if let r = try? await requests.nextNovel(url) {
            guard novelGeneration == generation else { return }
            rawNovelItems.append(contentsOf: r.novels.map(SearchNovelItem.novel))
            novelNext = r.nextUrl
            recomputeNovels()
        }
    }

    func loadMoreUsers() async {
        guard let url = userNext, !isLoadingMoreUsers else { return }
        let generation = userGeneration
        isLoadingMoreUsers = true
        defer { isLoadingMoreUsers = false }
        if let r: UserPreviewResponse = try? await api.nextPage(url) {
            guard userGeneration == generation else { return }
            rawUsers.append(contentsOf: r.userPreviews)
            userNext = r.nextUrl
            recomputeUsers()
        }
    }

    // MARK: Client-side filtering
    //
    // The normal mute/global-R18 chain remains active, then search's real
    // `x_restrict` and AI modes narrow it further. This deliberately means a
    // global R-18 block still wins over search's “R-18 only” choice, as in Mapper.

    private func recomputeIllusts() {
        illusts = MuteStore.shared.filter(rawIllusts, applyR18: true)
            .filter { illustResultsFilter.accepts($0) }
    }

    private func recomputeNovels() {
        novelItems = rawNovelItems.filter { item in
            !MuteStore.shared.filter([item.novel], applyR18: true).isEmpty &&
                novelResultsFilter.accepts(item.novel)
        }
    }

    private func recomputeUsers() {
        users = rawUsers.filter { !MuteStore.shared.isUserMuted($0.user.id) }
    }
}

struct SearchResultsView: View {
    let word: String
    @State private var vm: SearchResultsViewModel
    @State private var section: Section = .illust
    @State private var showFilter = false
    @State private var showWebLogin = false
    @State private var showUserFilterHint = false
    @State private var quotaNotices = BorrowedQuotaNoticeStore.shared
    @Environment(OnboardingStore.self) private var l10n

    enum Section: Hashable, CaseIterable { case illust, novel, user }

    init(word: String) {
        self.word = word
        _vm = State(wrappedValue: SearchResultsViewModel(word: word))
    }

    /// Active dimensions on the tab currently in view, for the toolbar badge.
    private var activeCount: Int {
        switch section {
        case .novel: return vm.novelFilter.activeCount(isNovel: true)
        case .illust: return vm.illustFilter.activeCount(isNovel: false)
        case .user: return 0
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PagerTabBar(
                titles: Section.allCases.map { ($0, label(for: $0)) },
                selection: $section
            )
            TabView(selection: $section) {
                IllustWaterfallList(
                    illusts: vm.illusts, isLoading: vm.isLoadingIllust,
                    errorMessage: vm.errorMessage,
                    onRefresh: { await vm.reloadIllust() },
                    onLoadMore: { await vm.loadMoreIllusts() },
                    hasMore: vm.illustNext != nil,
                    prefiltered: true
                ).tag(Section.illust)
                SearchNovelList(
                    items: vm.novelItems,
                    isLoading: vm.isLoadingNovel,
                    grouped: vm.novelResultsGrouped,
                    webAuthenticated: vm.novelWebAuthenticated,
                    onWebLogin: { showWebLogin = true },
                    onLoadMore: { await vm.loadMoreNovels() },
                    hasMore: vm.novelNext != nil
                ).tag(Section.novel)
                UserPreviewList(
                    items: vm.users,
                    isLoading: vm.isLoadingUsers,
                    onLoadMore: { await vm.loadMoreUsers() },
                    hasMore: vm.userNext != nil
                ).tag(Section.user)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle("\u{201C}\(word)\u{201D}")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // Upstream keeps the icon on the author tab and emits a
                    // short toast instead of opening an illustration filter.
                    guard section != .user else {
                        withAnimation { showUserFilterHint = true }
                        Task { @MainActor in
                            do { try await Task.sleep(for: .seconds(2)) }
                            catch { return }
                            withAnimation { showUserFilterHint = false }
                        }
                        return
                    }
                    Task { await vm.loadOptionsIfNeeded() }
                    showFilter = true
                } label: {
                    Image(systemName: activeCount > 0
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                        .overlay(alignment: .topTrailing) {
                            if activeCount > 0 {
                                Text("\(activeCount)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(3)
                                    .background(Theme.brand, in: .circle)
                                    .offset(x: 8, y: -8)
                            }
                        }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = quotaNotices.notice {
                HStack(spacing: 12) {
                    Text(quotaMessage(notice))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        withAnimation { quotaNotices.consume(id: notice.id) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: .rect(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Theme.v3CardHairline, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: notice.id) {
                    do { try await Task.sleep(for: .seconds(12)) }
                    catch { return }
                    withAnimation { quotaNotices.consume(id: notice.id) }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showUserFilterHint {
                Text(l10n.t(.filterUserUnsupported))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: .capsule)
                    .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
                    .padding(.bottom, quotaNotices.notice == nil ? 12 : 82)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showFilter) {
            let isNovel = section == .novel
            SearchFilterSheet(
                filter: isNovel ? vm.novelFilter : vm.illustFilter,
                options: vm.options,
                isNovelTab: isNovel,
                onChange: { vm.stage($0, isNovel: isNovel) },
                onReloadOptions: { Task { await vm.loadOptionsIfNeeded() } }
            ) { newFilter in
                await vm.apply(newFilter, isNovel: isNovel)
            }
        }
        .sheet(isPresented: $showWebLogin, onDismiss: {
            guard section == .novel, vm.novelResultsGrouped else { return }
            Task { await vm.reloadNovel() }
        }) {
            PixivWebLoginSheet()
        }
        .task { await vm.loadIllustIfNeeded() }
        .onChange(of: section) { _, value in
            Task { @MainActor in
                switch value {
                case .illust: await vm.loadIllustIfNeeded()
                case .novel: await vm.loadNovelIfNeeded()
                case .user: await vm.loadUsersIfNeeded()
                }
            }
        }
    }

    private func label(for s: Section) -> String {
        switch s {
        case .illust: return l10n.t(.searchTabIllust)
        case .novel:  return l10n.t(.searchTabNovel)
        case .user:   return l10n.t(.searchTabUser)
        }
    }

    private func quotaMessage(_ notice: BorrowedQuotaNotice) -> String {
        let totalMinutes = (notice.resetInMS + 59_999) / 60_000
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        let duration: String
        if days > 0 {
            duration = l10n.t(.borrowQuotaDaysHoursFmt, "\(days)", "\(hours)")
        } else if hours > 0 {
            duration = l10n.t(.borrowQuotaHoursMinutesFmt, "\(hours)", "\(minutes)")
        } else {
            duration = l10n.t(.borrowQuotaMinutesFmt, "\(minutes)")
        }
        return l10n.t(
            notice.scope == "uid_weekly" ? .borrowQuotaWeeklyFmt : .borrowQuotaSessionFmt,
            duration
        )
    }
}

/// Search uses a destination-bearing wrapper because the grouped web endpoint
/// returns a mixed list: a row can be either one novel or one whole series.
/// Feeding a series id into the novel-detail route would produce a 404.
private struct SearchNovelList: View {
    let items: [SearchNovelItem]
    let isLoading: Bool
    let grouped: Bool
    let webAuthenticated: Bool
    let onWebLogin: () -> Void
    let onLoadMore: (() async -> Void)?
    let hasMore: Bool
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        ScrollView {
            if items.isEmpty, isLoading {
                NovelListSkeleton()
            } else if items.isEmpty, grouped {
                ContentUnavailableView {
                    Label(l10n.t(.filterGroupBySeries), systemImage: "books.vertical")
                } description: {
                    Text(webAuthenticated ? l10n.t(.nothingHere) : l10n.t(.searchSeriesEmptyHint))
                } actions: {
                    if !webAuthenticated {
                        Button(l10n.t(.filterWebLogin), action: onWebLogin)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(items) { item in
                        NavigationLink(value: item.destination) {
                            VStack(alignment: .leading, spacing: 2) {
                                NovelRow(novel: item.novel)
                                if let count = item.episodeCount {
                                    Text(l10n.t(
                                        item.isConcluded == true
                                            ? .searchSeriesConcludedFmt
                                            : .searchSeriesOngoingFmt,
                                        "\(count)"
                                    ))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 70)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                    if hasMore, !items.isEmpty {
                        Color.clear
                            .frame(height: 40)
                            .onAppear { Task { await onLoadMore?() } }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
}

private struct PixivWebLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        NavigationStack {
            PixivWebLoginView(url: URL(string: "https://www.pixiv.net/")!)
                .navigationTitle(l10n.t(.filterWebLogin))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(l10n.t(.actionDone)) { dismiss() }
                    }
                }
        }
    }
}

private struct PixivWebLoginView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct UserPreviewList: View {
    let items: [UserPreview]
    let isLoading: Bool
    let onLoadMore: (() async -> Void)?
    let hasMore: Bool

    init(
        items: [UserPreview],
        isLoading: Bool = false,
        onLoadMore: (() async -> Void)? = nil,
        hasMore: Bool = false
    ) {
        self.items = items
        self.isLoading = isLoading
        self.onLoadMore = onLoadMore
        self.hasMore = hasMore
    }

    var body: some View {
        ScrollView {
            if items.isEmpty, isLoading {
                UserListSkeleton()
            } else {
            LazyVStack(spacing: 12) {
                ForEach(items) { preview in
                    NavigationLink(value: AppRoute.userProfile(preview.user.id)) {
                        UserPreviewRow(preview: preview)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
                if hasMore, !items.isEmpty {
                    Color.clear
                        .frame(height: 40)
                        .onAppear { Task { await onLoadMore?() } }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }
}

struct UserPreviewRow: View {
    let preview: UserPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                PixivAsyncImage(url: avatar)
                    .frame(width: 48, height: 48)
                    .clipShape(.circle)
                VStack(alignment: .leading) {
                    Text(preview.user.name ?? "").font(.subheadline.bold())
                    Text("@\(preview.user.account ?? "")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let illusts = preview.illusts, !illusts.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(illusts.prefix(3).enumerated()), id: \.offset) { _, i in
                        PixivAsyncImage(url: thumb(i))
                            .aspectRatio(1, contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .frame(height: 100)
                            .clipShape(.rect(cornerRadius: 4))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var avatar: URL? {
        (preview.user.profileImageUrls?.medium ?? preview.user.profileImageUrls?.px170x170)
            .flatMap(URL.init(string:))
    }

    private func thumb(_ illust: Illust) -> URL? {
        let s = illust.imageUrls?.squareMedium ?? illust.imageUrls?.medium
        return s.flatMap(URL.init(string:))
    }
}
