import SwiftUI

struct SearchView: View {
    @State private var word: String = ""
    @State private var suggestions: [AutoCompleteTag] = []
    @State private var history = SearchHistoryStore.shared
    @Environment(OnboardingStore.self) private var l10n

    @ObservationIgnored private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(l10n.t(.searchPlaceholder), text: $word)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit {
                        // navigation handled via list item — direct submit also navigates
                    }
                if !word.isEmpty {
                    Button { word = ""; suggestions = [] } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
            .padding(.horizontal, 12).padding(.top, 8)

            List {
                let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
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
                if !trimmed.isEmpty {
                    NavigationLink(value: AppRoute.searchResults(word: trimmed)) {
                        Label(trimmed, systemImage: "magnifyingglass")
                    }
                    .simultaneousGesture(TapGesture().onEnded { history.record(trimmed) })
                }
                if trimmed.isEmpty, !history.entries.isEmpty {
                    Section {
                        ForEach(history.entries, id: \.self) { term in
                            NavigationLink(value: AppRoute.searchResults(word: term)) {
                                Label(term, systemImage: "clock")
                            }
                            .simultaneousGesture(TapGesture().onEnded { history.record(term) })
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    history.remove(term)
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(l10n.t(.searchRecent))
                            Spacer()
                            Button(l10n.t(.actionClear)) {
                                history.clear()
                            }
                            .font(.caption)
                            .textCase(nil)
                        }
                    }
                }
                Section {
                    ForEach(suggestions) { tag in
                        NavigationLink(value: AppRoute.tagResults(tag: tag.name ?? "")) {
                            VStack(alignment: .leading) {
                                Text(tag.name ?? "")
                                if let t = tag.translatedName, !t.isEmpty {
                                    Text(t).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            if let n = tag.name { history.record(n) }
                        })
                    }
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle(l10n.t(.searchTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: word) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !word.isEmpty else { suggestions = []; return }
            suggestions = (try? await api.autocompleteTags(prefix: word))?.tags ?? []
        }
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

    private static func match(_ input: String, _ pattern: String) -> Int64? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
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
    var illusts: [Illust] = []
    var novels: [Novel] = []
    var users: [UserPreview] = []
    var illustNext: String?
    var novelNext: String?
    var userNext: String?
    var sort: String = "date_desc"
    var searchTarget: String = "partial_match_for_tags"
    /// nil = any time; otherwise within_last_day/week/month.
    var duration: String? = nil
    var isLoading = false
    var isLoadingMoreIllusts = false
    var isLoadingMoreNovels = false
    var isLoadingMoreUsers = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init(word: String) {
        self.word = word
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async {
        if illusts.isEmpty && novels.isEmpty && users.isEmpty { await load() }
    }

    func setSort(_ s: String) async {
        guard s != sort else { return }
        sort = s
        illusts = []
        novels = []
        illustNext = nil
        novelNext = nil
        await load()
    }

    func setSearchTarget(_ t: String) async {
        guard t != searchTarget else { return }
        searchTarget = t
        illusts = []
        novels = []
        illustNext = nil
        novelNext = nil
        await load()
    }

    func setDuration(_ d: String?) async {
        guard d != duration else { return }
        duration = d
        illusts = []
        novels = []
        illustNext = nil
        novelNext = nil
        await load()
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                let r = try? await self.api.searchIllust(
                    word: self.word, sort: self.sort, searchTarget: self.searchTarget,
                    duration: self.duration
                )
                self.illusts = r?.illusts ?? []
                self.illustNext = r?.nextUrl
            }
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                let r = try? await self.api.searchNovel(
                    word: self.word, sort: self.sort, searchTarget: self.searchTarget,
                    duration: self.duration
                )
                self.novels = r?.novels ?? []
                self.novelNext = r?.nextUrl
            }
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                let r = try? await self.api.searchUser(word: self.word)
                self.users = r?.userPreviews ?? []
                self.userNext = r?.nextUrl
            }
        }
    }

    func loadMoreIllusts() async {
        guard let url = illustNext, !isLoadingMoreIllusts else { return }
        isLoadingMoreIllusts = true
        defer { isLoadingMoreIllusts = false }
        if let r: IllustResponse = try? await api.nextPage(url) {
            illusts.append(contentsOf: r.illusts)
            illustNext = r.nextUrl
        }
    }

    func loadMoreNovels() async {
        guard let url = novelNext, !isLoadingMoreNovels else { return }
        isLoadingMoreNovels = true
        defer { isLoadingMoreNovels = false }
        if let r: NovelResponse = try? await api.nextPage(url) {
            novels.append(contentsOf: r.novels)
            novelNext = r.nextUrl
        }
    }

    func loadMoreUsers() async {
        guard let url = userNext, !isLoadingMoreUsers else { return }
        isLoadingMoreUsers = true
        defer { isLoadingMoreUsers = false }
        if let r: UserPreviewResponse = try? await api.nextPage(url) {
            users.append(contentsOf: r.userPreviews)
            userNext = r.nextUrl
        }
    }
}

struct SearchResultsView: View {
    let word: String
    @State private var vm: SearchResultsViewModel
    @State private var section: Section = .illust
    @Environment(OnboardingStore.self) private var l10n

    enum Section: Hashable, CaseIterable { case illust, novel, user }

    private static let sortOptions = ["date_desc", "date_asc", "popular_desc"]
    private static let targetOptions = ["partial_match_for_tags", "exact_match_for_tags", "title_and_caption"]
    /// nil sentinel uses empty string as the "any time" tag in the menu.
    private static let durationOptions: [String?] = [nil, "within_last_day", "within_last_week", "within_last_month"]

    init(word: String) {
        self.word = word
        _vm = State(wrappedValue: SearchResultsViewModel(word: word))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Self.sortOptions, id: \.self) { s in
                    Button {
                        Task { await vm.setSort(s) }
                    } label: {
                        Text(sortLabel(s))
                            .font(.caption.weight(vm.sort == s ? .bold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(vm.sort == s ? Color.accentColor : Color(.secondarySystemBackground),
                                        in: .capsule)
                            .foregroundStyle(vm.sort == s ? Color.white : .primary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Menu {
                    ForEach(Array(Self.durationOptions.enumerated()), id: \.offset) { _, d in
                        Button {
                            Task { await vm.setDuration(d) }
                        } label: {
                            HStack {
                                Text(durationLabel(d))
                                if vm.duration == d { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "calendar")
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(vm.duration == nil ? Color(.secondarySystemBackground) : Color.accentColor,
                                    in: .capsule)
                        .foregroundStyle(vm.duration == nil ? .primary : Color.white)
                }
                Menu {
                    ForEach(Self.targetOptions, id: \.self) { t in
                        Button {
                            Task { await vm.setSearchTarget(t) }
                        } label: {
                            HStack {
                                Text(targetLabel(t))
                                if vm.searchTarget == t {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label(targetLabel(vm.searchTarget), systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(.secondarySystemBackground), in: .capsule)
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)

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
                    hasMore: vm.illustNext != nil
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
        .task { await vm.loadIfNeeded() }
    }

    private func label(for s: Section) -> String {
        switch s {
        case .illust: return l10n.t(.searchTabIllust)
        case .novel:  return l10n.t(.searchTabNovel)
        case .user:   return l10n.t(.searchTabUser)
        }
    }

    private func sortLabel(_ s: String) -> String {
        switch s {
        case "date_desc":    return l10n.t(.searchSortDateDesc)
        case "date_asc":     return l10n.t(.searchSortDateAsc)
        case "popular_desc": return l10n.t(.searchSortPopular)
        default: return s
        }
    }

    private func targetLabel(_ t: String) -> String {
        switch t {
        case "partial_match_for_tags": return l10n.t(.searchTargetPartial)
        case "exact_match_for_tags":   return l10n.t(.searchTargetExact)
        case "title_and_caption":      return l10n.t(.searchTargetTitleCaption)
        default: return t
        }
    }

    private func durationLabel(_ d: String?) -> String {
        switch d {
        case "within_last_day":   return l10n.t(.searchDurationDay)
        case "within_last_week":  return l10n.t(.searchDurationWeek)
        case "within_last_month": return l10n.t(.searchDurationMonth)
        default:                  return l10n.t(.searchDurationAll)
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
