import SwiftUI

// MARK: - Shared follow pill (recy_user_preview / recy_trending_artist `post_like_user`)

/// 30dp outlined brand pill, 13sp; 关注 / 已关注 resolved through `InteractionStore`
/// so a follow made on the profile page (or anywhere else) is reflected here.
/// Tap toggles (respecting the private-follow setting), long-press = private follow
/// — the same two gestures upstream binds on the artist card.
struct FollowPillButton: View {
    let user: PixivUser
    @State private var store = InteractionStore.shared
    @Environment(OnboardingStore.self) private var l10n

    private var followed: Bool { store.isFollowed(id: user.id, fallback: user.isFollowed) }
    private var busy: Bool { store.followBusy.contains(user.id) }

    var body: some View {
        Text(l10n.t(followed ? .detailUnfollow : .detailFollow))
            .font(.system(size: 13))
            .foregroundStyle(followed ? Theme.v3TextSecondary : Theme.brand)
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(followed ? Theme.brand.opacity(0.20) : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(followed ? Theme.brand.opacity(0.30) : Theme.brand, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(busy ? 0.5 : 1)
            .onTapGesture {
                guard !busy else { return }
                Task { try? await store.setFollowed(!followed, id: user.id, user: user) }
            }
            .onLongPressGesture {
                guard !busy, !followed else { return }
                Task { try? await store.setFollowed(true, id: user.id, restrict: "private", user: user) }
            }
    }
}

// MARK: - 画师榜 / 画师均分榜 (ArtistRankFeedFragment)

@MainActor
@Observable
final class ArtistRankVM {
    /// "total" 画师榜 / "avg" 画师均分榜 — anything else falls back to total (legacy initBundle).
    let sort: String
    var items: [ArtistRankItem] = []
    var nextUrl: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let client = ShaftApiV2Client.shared

    init(mode: String) { sort = mode == "avg" ? "avg" : "total" }

    func loadIfNeeded() async { if items.isEmpty { await load() } }

    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await client.discoverArtists(sort: sort)
            items = dedup(page.items)
            nextUrl = page.nextUrl
        } catch {
            if isCancellation(error) { return }   // tab switch cancelled the task, not a failure
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let page = try? await client.artistsByUrl(url) {
            let seen = Set(items.map(\.id))
            items.append(contentsOf: dedup(page.items).filter { !seen.contains($0.id) })
            nextUrl = page.nextUrl
        }
    }

    /// Upstream drops id==0 rows and collapses duplicate identities (`dedupByIdentity`).
    private func dedup(_ list: [ArtistRankItem]) -> [ArtistRankItem] {
        var seen = Set<Int64>()
        return list.filter { $0.id != 0 && seen.insert($0.id).inserted }
    }
}

struct ArtistRankView: View {
    let mode: String
    @State private var vm: ArtistRankVM
    @Environment(OnboardingStore.self) private var l10n

    init(mode: String) {
        self.mode = mode
        _vm = State(wrappedValue: ArtistRankVM(mode: mode))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(vm.items) { item in
                    ArtistRankRow(item: item, isAvg: vm.sort == "avg")
                    Divider()
                }
                if vm.nextUrl != nil, !vm.items.isEmpty {
                    Color.clear.frame(height: 40)
                        .onAppear { Task { await vm.loadMore() } }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .overlay {
            if vm.isLoading && vm.items.isEmpty {
                RowSkeletonList { MediaRowSkeleton(coverWidth: 48, coverHeight: 48) }
            } else if vm.items.isEmpty, let err = vm.errorMessage {
                InlineError(message: err) { Task { await vm.load() } }.padding()
            } else if vm.items.isEmpty && !vm.isLoading {
                ContentUnavailableView(l10n.t(.nothingHere), systemImage: "sparkles.tv")
            }
        }
        .refreshable { await vm.load() }
        .task { await vm.loadIfNeeded() }
        .navigationTitle(l10n.t(vm.sort == "avg" ? .artistAvgRankTitle : .artistRankTitle))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// `UserFeedFragment` card: avatar + name + follow pill, then the artist's three
/// representative works (fewer left blank, never padded). Tap → profile; a
/// thumbnail → that illust. The server's `is_followed` / `is_bookmarked` are the
/// *reporter's* state, already cleared by the client — the store has the truth.
private struct ArtistRankRow: View {
    let item: ArtistRankItem
    let isAvg: Bool
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                NavigationLink(value: AppRoute.userProfile(item.user.id)) {
                    HStack(spacing: 12) {
                        PixivAsyncImage(url: avatar, showsProgress: false)
                            .frame(width: 48, height: 48)
                            .clipShape(.circle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.user.name ?? "")
                                .font(.subheadline.bold())
                                .lineLimit(1)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(Theme.v3Text2)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                FollowPillButton(user: item.user)
            }
            if !item.illusts.isEmpty {
                HStack(spacing: 4) {
                    ForEach(item.illusts.prefix(3)) { illust in
                        NavigationLink(value: illust) {
                            PixivAsyncImage(url: thumb(illust), showsProgress: false)
                                .frame(maxWidth: .infinity)
                                .frame(height: 100)
                                .clipShape(.rect(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var subtitle: String {
        let works = "\(item.workCount)"
        return isAvg
            ? l10n.t(.artistRankAvgWorks, works, RankCountFormat.compact(item.avgBookmarks ?? 0))
            : l10n.t(.artistRankWorks, works, RankCountFormat.compact(item.totalBookmarks))
    }

    private var avatar: URL? {
        (item.user.profileImageUrls?.medium ?? item.user.profileImageUrls?.px170x170)
            .flatMap(URL.init(string:))
    }

    private func thumb(_ illust: Illust) -> URL? {
        (illust.imageUrls?.squareMedium ?? illust.imageUrls?.medium).flatMap(URL.init(string:))
    }
}

// MARK: - 人气画师 (TrendingArtistsFragment)

@MainActor
@Observable
final class TrendingArtistsVM {
    /// Server enum; order = tab order. Default 「本周」 (server default too).
    static let windows = ["day", "week", "month"]

    var window = "week"
    var items: [TrendingUserItem] = []
    var nextUrl: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let client = ShaftApiV2Client.shared
    /// Bumped on window switch; stale in-flight loads discard their result.
    @ObservationIgnored private var generation = 0

    func loadIfNeeded() async { if items.isEmpty { await load() } }

    func setWindow(_ w: String) async {
        guard w != window else { return }
        window = w
        generation += 1
        items = []; nextUrl = nil
        await load()
    }

    func load() async {
        let gen = generation
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await client.trendingUsers(window: window)
            guard gen == generation else { return }
            items = dedup(page.items)
            nextUrl = page.nextUrl
        } catch {
            guard gen == generation, !isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        let gen = generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let page = try? await client.trendingUsersByUrl(url) {
            guard gen == generation else { return }
            let seen = Set(items.map(\.id))
            items.append(contentsOf: dedup(page.items).filter { !seen.contains($0.id) })
            nextUrl = page.nextUrl
        }
    }

    private func dedup(_ list: [TrendingUserItem]) -> [TrendingUserItem] {
        var seen = Set<Int64>()
        return list.filter { $0.id != 0 && seen.insert($0.id).inserted }
    }
}

/// 今日 / 本周 / 本月 segments (default 本周) over a plain artist list:
/// rank + avatar + name + 「本周 N 人关注」 + follow pill. No preview grid —
/// `trending/users` carries no works, so the three-cell card would be blank.
struct TrendingArtistsView: View {
    @State private var vm = TrendingArtistsVM()
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(
                get: { vm.window },
                set: { w in Task { await vm.setWindow(w) } }
            )) {
                Text(l10n.t(.trendingWindowDay)).tag("day")
                Text(l10n.t(.trendingWindowWeek)).tag("week")
                Text(l10n.t(.trendingWindowMonth)).tag("month")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(vm.items) { item in
                        TrendingArtistRow(item: item, window: vm.window)
                    }
                    if vm.nextUrl != nil, !vm.items.isEmpty {
                        Color.clear.frame(height: 40)
                            .onAppear { Task { await vm.loadMore() } }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .overlay {
                if vm.isLoading && vm.items.isEmpty {
                    RowSkeletonList { MediaRowSkeleton(coverWidth: 52, coverHeight: 52) }
                } else if vm.items.isEmpty, let err = vm.errorMessage {
                    InlineError(message: err) { Task { await vm.load() } }.padding()
                } else if vm.items.isEmpty && !vm.isLoading {
                    ContentUnavailableView(l10n.t(.nothingHere), systemImage: "sparkles.tv")
                }
            }
            .refreshable { await vm.load() }
        }
        .task { await vm.loadIfNeeded() }
        .navigationTitle(l10n.t(.trendingArtistsTitle))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// `recy_trending_artist`: r20 card, 12dp padding; rank 28dp-wide brand bold 14,
/// 52dp avatar with a 1dp #DDDDDD ring, name brand bold 15, count v3_text_2 12.
private struct TrendingArtistRow: View {
    let item: TrendingUserItem
    let window: String
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        HStack(spacing: 0) {
            NavigationLink(value: AppRoute.userProfile(item.user.id)) {
                HStack(spacing: 0) {
                    Text("\(item.rank)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.brand)
                        .frame(width: 28)
                    PixivAsyncImage(url: avatar, showsProgress: false, placeholder: Theme.v3Surface2)
                        .frame(width: 52, height: 52)
                        .clipShape(.circle)
                        .overlay(Circle().strokeBorder(Color(hex: 0xDDDDDD), lineWidth: 1))
                        .padding(.leading, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.user.name ?? "")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.brand)
                            .lineLimit(1)
                        Text(l10n.t(followersKey, "\(item.followCount)"))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.v3Text2)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            FollowPillButton(user: item.user)
        }
        .padding(12)
        .background(Theme.v3Surface1, in: .rect(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.v3Border1, lineWidth: 1)
        )
    }

    private var followersKey: LocalizedKey {
        switch window {
        case "day": .trendingFollowersDay
        case "month": .trendingFollowersMonth
        default: .trendingFollowersWeek
        }
    }

    private var avatar: URL? {
        item.user.profileImageUrls?.medium.flatMap(URL.init(string:))
    }
}
