import SwiftUI

@MainActor
@Observable
final class UserProfileViewModel {
    let userId: Int64
    var user: PixivUser?
    var profile: UserProfile?
    var illusts: [Illust] = []
    var manga: [Illust] = []
    var novels: [Novel] = []
    var bookmarks: [Illust] = []
    var illustNext: String?
    var mangaNext: String?
    var novelNext: String?
    var bookmarkNext: String?
    var bookmarkRestrict: String = "public"
    var bookmarkTags: [BookmarkTag] = []
    var bookmarkTagFilter: String? = nil
    var isLoading = false
    var errorMessage: String?
    var isFollowing = false

    @ObservationIgnored private let api: PixivAPI

    init(userId: Int64) {
        self.userId = userId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async {
        if user == nil { await load() }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in await self?.loadDetail() }
            group.addTask { @MainActor [weak self] in await self?.loadIllusts() }
            group.addTask { @MainActor [weak self] in await self?.loadManga() }
            group.addTask { @MainActor [weak self] in await self?.loadNovels() }
            group.addTask { @MainActor [weak self] in await self?.loadBookmarks() }
        }
    }

    private func loadDetail() async {
        do {
            let r = try await api.userDetail(userId)
            user = r.user
            profile = r.profile
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    func loadIllusts() async {
        let r = try? await api.userIllusts(userId, type: "illust")
        illusts = r?.illusts ?? []
        illustNext = r?.nextUrl
    }
    func loadManga() async {
        let r = try? await api.userIllusts(userId, type: "manga")
        manga = r?.illusts ?? []
        mangaNext = r?.nextUrl
    }
    func loadNovels() async {
        let r = try? await api.userNovels(userId)
        novels = r?.novels ?? []
        novelNext = r?.nextUrl
    }
    func loadBookmarks() async {
        let r = try? await api.userBookmarkedIllusts(
            userId, restrict: bookmarkRestrict, tag: bookmarkTagFilter
        )
        bookmarks = r?.illusts ?? []
        bookmarkNext = r?.nextUrl
    }

    func loadBookmarkTags() async {
        let r = try? await api.userBookmarkTags(userId, restrict: bookmarkRestrict)
        bookmarkTags = r?.bookmarkTags ?? []
    }

    func setBookmarkRestrict(_ r: String) async {
        guard r != bookmarkRestrict else { return }
        bookmarkRestrict = r
        bookmarks = []
        bookmarkNext = nil
        bookmarkTagFilter = nil
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in await self?.loadBookmarks() }
            group.addTask { @MainActor [weak self] in await self?.loadBookmarkTags() }
        }
    }

    func setBookmarkTagFilter(_ tag: String?) async {
        bookmarkTagFilter = tag
        bookmarks = []
        bookmarkNext = nil
        await loadBookmarks()
    }

    func loadMoreIllusts() async {
        guard let url = illustNext else { return }
        if let r: IllustResponse = try? await api.nextPage(url) {
            illusts.append(contentsOf: r.illusts)
            illustNext = r.nextUrl
        }
    }
    func loadMoreManga() async {
        guard let url = mangaNext else { return }
        if let r: IllustResponse = try? await api.nextPage(url) {
            manga.append(contentsOf: r.illusts)
            mangaNext = r.nextUrl
        }
    }
    func loadMoreNovels() async {
        guard let url = novelNext else { return }
        if let r: NovelResponse = try? await api.nextPage(url) {
            novels.append(contentsOf: r.novels)
            novelNext = r.nextUrl
        }
    }
    func loadMoreBookmarks() async {
        guard let url = bookmarkNext else { return }
        if let r: IllustResponse = try? await api.nextPage(url) {
            bookmarks.append(contentsOf: r.illusts)
            bookmarkNext = r.nextUrl
        }
    }

    func toggleFollow() async {
        guard let u = user else { return }
        isFollowing = true
        defer { isFollowing = false }
        do {
            if u.isFollowed == true {
                _ = try await api.unfollowUser(userId)
                user = PixivUser(id: u.id, name: u.name, account: u.account,
                                 profileImageUrls: u.profileImageUrls, isFollowed: false)
            } else {
                _ = try await api.followUser(userId)
                user = PixivUser(id: u.id, name: u.name, account: u.account,
                                 profileImageUrls: u.profileImageUrls, isFollowed: true)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct UserProfileView: View {
    let userId: Int64
    @State private var vm: UserProfileViewModel
    @State private var section: ProfileSection = .illusts
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.openURL) private var openURL

    enum ProfileSection: Hashable, CaseIterable { case illusts, manga, novels, bookmarks }

    private var pixivURL: URL {
        URL(string: "https://www.pixiv.net/users/\(userId)")!
    }

    private var isOwnProfile: Bool {
        KeychainTokenStore.shared.load()?.user?.id == userId
    }

    init(userId: Int64) {
        self.userId = userId
        _vm = State(wrappedValue: UserProfileViewModel(userId: userId))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let user = vm.user {
                header(user: user)
                entriesRow
            } else if vm.isLoading {
                ProgressView().padding(.vertical, 40)
            } else if let err = vm.errorMessage {
                InlineError(message: err) { Task { await vm.load() } }.padding()
            }

            PagerTabBar(
                titles: ProfileSection.allCases.map { ($0, label(for: $0)) },
                selection: $section
            )
            TabView(selection: $section) {
                IllustWaterfallList(
                    illusts: vm.illusts, isLoading: false, errorMessage: nil,
                    onRefresh: { await vm.loadIllusts() },
                    onLoadMore: { await vm.loadMoreIllusts() },
                    hasMore: vm.illustNext != nil
                ).tag(ProfileSection.illusts)
                IllustWaterfallList(
                    illusts: vm.manga, isLoading: false, errorMessage: nil,
                    onRefresh: { await vm.loadManga() },
                    onLoadMore: { await vm.loadMoreManga() },
                    hasMore: vm.mangaNext != nil
                ).tag(ProfileSection.manga)
                NovelList(
                    novels: vm.novels,
                    onLoadMore: { await vm.loadMoreNovels() },
                    hasMore: vm.novelNext != nil
                )
                .tag(ProfileSection.novels)
                bookmarksTab.tag(ProfileSection.bookmarks)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: pixivURL) {
                        Label(l10n.t(.actionShare), systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = pixivURL.absoluteString
                    } label: {
                        Label(l10n.t(.actionCopyLink), systemImage: "doc.on.doc")
                    }
                    Button {
                        openURL(pixivURL)
                    } label: {
                        Label(l10n.t(.actionOpenInBrowser), systemImage: "safari")
                    }
                    Divider()
                    Button(role: .destructive) {
                        MuteStore.shared.toggleUser(userId)
                    } label: {
                        let muted = MuteStore.shared.isUserMuted(userId)
                        Label(muted ? l10n.t(.actionUnmuteUser) : l10n.t(.actionMuteUser),
                              systemImage: "speaker.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            await vm.loadIfNeeded()
            if let u = vm.user { HistoryStore.shared.record(user: u) }
        }
    }

    /// Secondary destinations Shaft surfaces on a profile: the user's own
    /// series, mutual friends (MyPixiv), and related artists.
    @ViewBuilder
    private var entriesRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if (vm.profile?.totalIllustSeries ?? 1) > 0 {
                    entryChip(.userIllustSeriesList(userId: userId),
                              label: l10n.t(.userIllustSeriesTitle), systemImage: "rectangle.stack")
                }
                if (vm.profile?.totalNovelSeries ?? 1) > 0 {
                    entryChip(.userNovelSeriesList(userId: userId),
                              label: l10n.t(.userNovelSeriesTitle), systemImage: "books.vertical")
                }
                entryChip(.userMyPixiv(userId: userId),
                          label: l10n.t(.followingMyPixiv), systemImage: "person.2")
                entryChip(.userRelated(userId: userId),
                          label: l10n.t(.userRelatedTitle), systemImage: "person.3")
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func entryChip(_ route: AppRoute, label: String, systemImage: String) -> some View {
        NavigationLink(value: route) {
            Label(label, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(.secondarySystemBackground), in: .capsule)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var bookmarksTab: some View {
        VStack(spacing: 0) {
            if isOwnProfile {
                HStack(spacing: 8) {
                    restrictChip("public", label: l10n.t(.followingPublic))
                    restrictChip("private", label: l10n.t(.followingPrivate))
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)

                if !vm.bookmarkTags.isEmpty {
                    bookmarkTagStrip
                }
            }
            IllustWaterfallList(
                illusts: vm.bookmarks, isLoading: false, errorMessage: nil,
                onRefresh: { await vm.loadBookmarks() },
                onLoadMore: { await vm.loadMoreBookmarks() },
                hasMore: vm.bookmarkNext != nil
            )
        }
        .task(id: isOwnProfile) {
            if isOwnProfile, vm.bookmarkTags.isEmpty {
                await vm.loadBookmarkTags()
            }
        }
    }

    @ViewBuilder
    private var bookmarkTagStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                bookmarkTagChip(name: nil, label: l10n.t(.bookmarkTagAll))
                ForEach(vm.bookmarkTags) { tag in
                    bookmarkTagChip(name: tag.name, label: tag.name ?? "")
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func bookmarkTagChip(name: String?, label: String) -> some View {
        let active = vm.bookmarkTagFilter == name
        Button {
            Task { await vm.setBookmarkTagFilter(name) }
        } label: {
            Text(label)
                .font(.caption.weight(active ? .bold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(active ? Color.accentColor : Color(.secondarySystemBackground),
                            in: .capsule)
                .foregroundStyle(active ? Color.white : .primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func restrictChip(_ r: String, label: String) -> some View {
        Button {
            Task { await vm.setBookmarkRestrict(r) }
        } label: {
            Text(label)
                .font(.caption.weight(vm.bookmarkRestrict == r ? .bold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(vm.bookmarkRestrict == r ? Color.accentColor : Color(.secondarySystemBackground),
                            in: .capsule)
                .foregroundStyle(vm.bookmarkRestrict == r ? Color.white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func label(for s: ProfileSection) -> String {
        switch s {
        case .illusts:   return l10n.t(.profileIllusts)
        case .manga:     return l10n.t(.profileManga)
        case .novels:    return l10n.t(.profileNovels)
        case .bookmarks: return l10n.t(.profileBookmarks)
        }
    }

    @ViewBuilder
    private func header(user: PixivUser) -> some View {
        VStack(spacing: 10) {
            PixivAsyncImage(url: avatarURL(for: user))
                .frame(width: 88, height: 88)
                .clipShape(.circle)
            Text(user.name ?? "")
                .font(.title3.bold())
            Text("@\(user.account ?? "")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await vm.toggleFollow() }
            } label: {
                Text(user.isFollowed == true ? l10n.t(.profileFollowing) : l10n.t(.profileFollow))
                    .font(.subheadline.bold())
                    .padding(.horizontal, 24).padding(.vertical, 8)
                    .background(user.isFollowed == true
                                ? AnyShapeStyle(Color(.secondarySystemBackground))
                                : AnyShapeStyle(Theme.brandGradient),
                                in: .capsule)
                    .foregroundStyle(user.isFollowed == true ? Color.primary : .white)
            }
            .disabled(vm.isFollowing)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func avatarURL(for user: PixivUser) -> URL? {
        (user.profileImageUrls?.medium ?? user.profileImageUrls?.px170x170)
            .flatMap(URL.init(string:))
    }
}

struct NovelList: View {
    let novels: [Novel]
    let onLoadMore: (() async -> Void)?
    let hasMore: Bool

    init(
        novels: [Novel],
        onLoadMore: (() async -> Void)? = nil,
        hasMore: Bool = false
    ) {
        self.novels = novels
        self.onLoadMore = onLoadMore
        self.hasMore = hasMore
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(novels) { novel in
                    NavigationLink(value: AppRoute.novelDetail(novel.id)) {
                        NovelRow(novel: novel)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
                if hasMore, !novels.isEmpty {
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

struct NovelRow: View {
    let novel: Novel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PixivAsyncImage(url: cover)
                .frame(width: 60, height: 80)
                .clipShape(.rect(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 4) {
                Text(novel.title ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let author = novel.user?.name {
                    Text(author).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if let v = novel.totalView { Label("\(v)", systemImage: "eye") }
                    if let b = novel.totalBookmarks { Label("\(b)", systemImage: "heart") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var cover: URL? {
        let s = novel.imageUrls?.medium ?? novel.imageUrls?.squareMedium
        return s.flatMap(URL.init(string:))
    }
}
