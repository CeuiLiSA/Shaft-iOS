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
    private func loadIllusts() async {
        illusts = (try? await api.userIllusts(userId, type: "illust"))?.illusts ?? []
    }
    private func loadManga() async {
        manga = (try? await api.userIllusts(userId, type: "manga"))?.illusts ?? []
    }
    private func loadNovels() async {
        novels = (try? await api.userNovels(userId))?.novels ?? []
    }
    private func loadBookmarks() async {
        bookmarks = (try? await api.userBookmarkedIllusts(userId))?.illusts ?? []
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

    enum ProfileSection: Hashable, CaseIterable { case illusts, manga, novels, bookmarks }

    init(userId: Int64) {
        self.userId = userId
        _vm = State(wrappedValue: UserProfileViewModel(userId: userId))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let user = vm.user {
                header(user: user)
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
                    onRefresh: {}, onTap: { _ in }
                ).tag(ProfileSection.illusts)
                IllustWaterfallList(
                    illusts: vm.manga, isLoading: false, errorMessage: nil,
                    onRefresh: {}, onTap: { _ in }
                ).tag(ProfileSection.manga)
                NovelList(novels: vm.novels)
                    .tag(ProfileSection.novels)
                IllustWaterfallList(
                    illusts: vm.bookmarks, isLoading: false, errorMessage: nil,
                    onRefresh: {}, onTap: { _ in }
                ).tag(ProfileSection.bookmarks)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await vm.loadIfNeeded()
            if let u = vm.user { HistoryStore.shared.record(user: u) }
        }
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
                    .background(user.isFollowed == true ? Color(.secondarySystemBackground) : Color.accentColor,
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
