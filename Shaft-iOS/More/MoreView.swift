import SwiftUI

/// "More" sheet — what Shaft Android shows in the navigation drawer:
/// downloads, history, mute, settings, about. Plus self-profile shortcut and
/// log-out from `LoggedInView`.
struct MoreView: View {
    @Bindable var auth: AuthViewModel
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        List {
            if let me = auth.token?.user {
                NavigationLink(value: AppRoute.userProfile(me.id)) {
                    HStack(spacing: 12) {
                        MyAvatarView(userId: me.id, size: 44)
                        VStack(alignment: .leading) {
                            Text(me.name).font(.headline)
                            Text("@\(me.account)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                NavigationLink(value: AppRoute.referral()) {
                    Label(ReferralCopy(tag: l10n.activeTag).text("entry"), systemImage: "ticket")
                }
                NavigationLink(value: AppRoute.notifications) {
                    Label(l10n.t(.notificationsTitle), systemImage: "bell")
                }
                NavigationLink(value: AppRoute.history) {
                    Label(l10n.t(.historyTitle), systemImage: "clock.arrow.circlepath")
                }
                NavigationLink(value: AppRoute.watchLater) {
                    Label(l10n.t(.watchLaterTitle), systemImage: "clock.badge.checkmark")
                }
                NavigationLink(value: AppRoute.downloads) {
                    Label(l10n.t(.downloadsTitle), systemImage: "arrow.down.circle")
                }
                NavigationLink(value: AppRoute.mute) {
                    Label(l10n.t(.mutedTitle), systemImage: "speaker.slash")
                }
                if let me = auth.token?.user {
                    NavigationLink(value: AppRoute.userBookmarks(userId: me.id)) {
                        Label(l10n.t(.profileBookmarks), systemImage: "heart")
                    }
                    NavigationLink(value: AppRoute.userFollowing(userId: me.id)) {
                        Label(l10n.t(.profileFollowing), systemImage: "person.2")
                    }
                }
                NavigationLink(value: AppRoute.watchlist) {
                    Label(l10n.t(.watchlistTitle), systemImage: "sparkles.tv")
                }
                NavigationLink(value: AppRoute.novelMarkers) {
                    Label(l10n.t(.novelMarkersTitle), systemImage: "bookmark")
                }
                NavigationLink(value: AppRoute.pinnedTags) {
                    Label(l10n.t(.pinnedTagsTitle), systemImage: "pin")
                }
                NavigationLink(value: AppRoute.eventHistory) {
                    Label(l10n.t(.eventHistory), systemImage: "clock.arrow.circlepath")
                }
            }

            Section {
                NavigationLink(value: AppRoute.settings) {
                    Label(l10n.t(.settingsTitle), systemImage: "gear")
                }
                NavigationLink(value: AppRoute.about) {
                    Label(l10n.t(.aboutTitle), systemImage: "info.circle")
                }
            }

            Section {
                Button(role: .destructive) { auth.logout() } label: {
                    Label(l10n.t(.actionLogOut), systemImage: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(l10n.t(.moreTitle))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The logged-in user's avatar. The OAuth token only carries id/name/account,
/// so the image URL comes from `userDetail` — fetched once per user and cached
/// in UserDefaults so it paints instantly on later launches.
@MainActor
@Observable
final class MyAvatarStore {
    static let shared = MyAvatarStore()

    private static let cacheKey = "my_avatar_url_v1"

    private(set) var url: URL?
    @ObservationIgnored private var requestedFor: Int64?
    @ObservationIgnored private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)

    private init() {
        if let cached = UserDefaults.standard.string(forKey: Self.cacheKey) {
            url = URL(string: cached)
        }
    }

    func loadIfNeeded(userId: Int64) {
        guard requestedFor != userId else { return }
        requestedFor = userId
        Task {
            guard let detail = try? await api.userDetail(userId) else {
                requestedFor = nil  // allow a retry on next appearance
                return
            }
            let urls = detail.user.profileImageUrls
            guard let raw = urls?.medium ?? urls?.px170x170 ?? urls?.px50x50,
                  let parsed = URL(string: raw) else { return }
            url = parsed
            UserDefaults.standard.set(raw, forKey: Self.cacheKey)
        }
    }
}

/// Circular self-avatar with a brand-colored border; falls back to the
/// generic person glyph until the real image URL is known.
struct MyAvatarView: View {
    let userId: Int64?
    let size: CGFloat

    @State private var store = MyAvatarStore.shared

    var body: some View {
        Group {
            if let url = store.url {
                PixivAsyncImage(url: url, showsProgress: false)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.brand, lineWidth: size >= 40 ? 2 : 1.5))
        .task {
            if let userId {
                store.loadIfNeeded(userId: userId)
            }
        }
    }
}
