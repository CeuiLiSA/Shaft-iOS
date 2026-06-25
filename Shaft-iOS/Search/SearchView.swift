import SwiftUI

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
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.vertical, 40)
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

    /// Displayed (post client-side filter) results; raw pages kept separately so
    /// re-filtering on a filter change doesn't need a re-fetch.
    var illusts: [Illust] = []
    var novels: [Novel] = []
    var users: [UserPreview] = []
    @ObservationIgnored private var rawIllusts: [Illust] = []
    @ObservationIgnored private var rawNovels: [Novel] = []
    @ObservationIgnored private var rawUsers: [UserPreview] = []

    var illustNext: String?
    var novelNext: String?
    var userNext: String?

    /// The full V3 search filter — single source of truth for both tabs.
    var filter: SearchFilter
    /// Dynamic tool / genre / language options, loaded once.
    var options: SearchOptionsResponse?
    /// Premium gates the male/female popular sorts and the popular-preview routing.
    var isPremium = false
    @ObservationIgnored private var accountLoaded = false

    var isLoading = false
    var isLoadingMoreIllusts = false
    var isLoadingMoreNovels = false
    var isLoadingMoreUsers = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init(word: String) {
        self.word = word
        self.filter = SearchFilter.makeDefault(hideR18: MuteStore.shared.hideR18)
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async {
        if rawIllusts.isEmpty && rawNovels.isEmpty && rawUsers.isEmpty { await load() }
    }

    func loadOptionsIfNeeded() async {
        guard options == nil else { return }
        options = try? await api.searchOptions()
    }

    /// Resolves premium status (self id → user detail) so popular sorts route
    /// correctly. Best-effort; defaults to non-premium until known.
    func loadAccountIfNeeded() async {
        guard !accountLoaded else { return }
        guard let uid = try? await api.selfProfile().profile.userId else { return }
        if let detail = try? await api.userDetail(uid) {
            isPremium = detail.profile?.isPremium ?? false
            accountLoaded = true
        }
    }

    /// Apply an edited filter: reset pages and reload both tabs.
    func apply(_ newFilter: SearchFilter) async {
        filter = newFilter
        rawIllusts = []; rawNovels = []; rawUsers = []
        illusts = []; novels = []; users = []
        illustNext = nil; novelNext = nil; userNext = nil
        await load()
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let f = filter
        // Non-premium popular sorts must hit the popular-preview endpoint instead.
        let usePreview = SortType.usesPopularPreview(f.sort, isPremium: isPremium)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                let r = usePreview
                    ? try? await self.api.searchPopularPreviewIllust(word: self.word, filter: f)
                    : try? await self.api.searchIllust(word: self.word, filter: f)
                self.rawIllusts = r?.illusts ?? []
                self.illustNext = r?.nextUrl
                self.recomputeIllusts()
            }
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                let r = usePreview
                    ? try? await self.api.searchPopularPreviewNovel(word: self.word, filter: f)
                    : try? await self.api.searchNovel(word: self.word, filter: f)
                self.rawNovels = r?.novels ?? []
                self.novelNext = r?.nextUrl
                self.recomputeNovels()
            }
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                let r = try? await self.api.searchUser(word: self.word)
                self.rawUsers = r?.userPreviews ?? []
                self.userNext = r?.nextUrl
                self.recomputeUsers()
            }
        }
    }

    func loadMoreIllusts() async {
        guard let url = illustNext, !isLoadingMoreIllusts else { return }
        isLoadingMoreIllusts = true
        defer { isLoadingMoreIllusts = false }
        if let r: IllustResponse = try? await api.nextPage(url) {
            rawIllusts.append(contentsOf: r.illusts)
            illustNext = r.nextUrl
            recomputeIllusts()
        }
    }

    func loadMoreNovels() async {
        guard let url = novelNext, !isLoadingMoreNovels else { return }
        isLoadingMoreNovels = true
        defer { isLoadingMoreNovels = false }
        if let r: NovelResponse = try? await api.nextPage(url) {
            rawNovels.append(contentsOf: r.novels)
            novelNext = r.nextUrl
            recomputeNovels()
        }
    }

    func loadMoreUsers() async {
        guard let url = userNext, !isLoadingMoreUsers else { return }
        isLoadingMoreUsers = true
        defer { isLoadingMoreUsers = false }
        if let r: UserPreviewResponse = try? await api.nextPage(url) {
            rawUsers.append(contentsOf: r.userPreviews)
            userNext = r.nextUrl
            recomputeUsers()
        }
    }

    // MARK: Client-side filtering
    //
    // Muted users/tags still apply, but global R-18 hiding is skipped (applyR18:
    // false) so the per-search R-18 mode — which filters by the real `x_restrict`
    // field, plus the AI "only AI" mode — fully governs visibility.

    private func recomputeIllusts() {
        illusts = MuteStore.shared.filter(rawIllusts, applyR18: false).filter { filter.accepts($0) }
    }

    private func recomputeNovels() {
        novels = MuteStore.shared.filter(rawNovels, applyR18: false).filter { filter.accepts($0) }
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
    @Environment(OnboardingStore.self) private var l10n

    enum Section: Hashable, CaseIterable { case illust, novel, user }

    init(word: String) {
        self.word = word
        _vm = State(wrappedValue: SearchResultsViewModel(word: word))
    }

    /// Active dimensions on the tab currently in view, for the toolbar badge.
    private var activeCount: Int {
        vm.filter.activeCount(isNovel: section == .novel)
    }

    var body: some View {
        VStack(spacing: 0) {
            PagerTabBar(
                titles: Section.allCases.map { ($0, label(for: $0)) },
                selection: $section
            )
            TabView(selection: $section) {
                IllustWaterfallList(
                    illusts: vm.illusts, isLoading: vm.isLoading,
                    errorMessage: vm.errorMessage,
                    onRefresh: { await vm.load() },
                    onLoadMore: { await vm.loadMoreIllusts() },
                    hasMore: vm.illustNext != nil,
                    prefiltered: true
                ).tag(Section.illust)
                NovelList(
                    novels: vm.novels,
                    onLoadMore: { await vm.loadMoreNovels() },
                    hasMore: vm.novelNext != nil
                ).tag(Section.novel)
                UserPreviewList(
                    items: vm.users,
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
                Button { showFilter = true } label: {
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
        .sheet(isPresented: $showFilter) {
            SearchFilterSheet(
                filter: vm.filter,
                options: vm.options,
                isNovelTab: section == .novel,
                isPremium: vm.isPremium
            ) { newFilter in
                await vm.apply(newFilter)
            }
        }
        .task { await vm.loadIfNeeded() }
        .task { await vm.loadOptionsIfNeeded() }
        .task { await vm.loadAccountIfNeeded() }
    }

    private func label(for s: Section) -> String {
        switch s {
        case .illust: return l10n.t(.searchTabIllust)
        case .novel:  return l10n.t(.searchTabNovel)
        case .user:   return l10n.t(.searchTabUser)
        }
    }
}

struct UserPreviewList: View {
    let items: [UserPreview]
    let onLoadMore: (() async -> Void)?
    let hasMore: Bool

    init(
        items: [UserPreview],
        onLoadMore: (() async -> Void)? = nil,
        hasMore: Bool = false
    ) {
        self.items = items
        self.onLoadMore = onLoadMore
        self.hasMore = hasMore
    }

    var body: some View {
        ScrollView {
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
