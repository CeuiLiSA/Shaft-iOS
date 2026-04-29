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
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(me.name).font(.headline)
                            Text("@\(me.account)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                NavigationLink(value: AppRoute.history) {
                    Label(l10n.t(.historyTitle), systemImage: "clock.arrow.circlepath")
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
