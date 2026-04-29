import SwiftUI

struct HomeView: View {
    @Bindable var auth: AuthViewModel
    @Environment(OnboardingStore.self) private var l10n
    @State private var selection: HomeTab = .recommend
    @State private var showProfile = false

    var body: some View {
        TabView(selection: $selection) {
            ForEach(HomeTab.allCases) { tab in
                NavigationStack {
                    Group {
                        switch tab {
                        case .recommend:
                            RecommendView()
                        default:
                            PlaceholderView(
                                title: title(for: tab),
                                systemImage: tab.systemImage,
                                subtitle: l10n.t(.nothingHere)
                            )
                        }
                    }
                    .navigationTitle(navTitle(for: tab))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                showProfile = true
                            } label: {
                                Image(systemName: "person.crop.circle")
                            }
                            .accessibilityLabel(l10n.t(.account))
                        }
                    }
                }
                .tabItem {
                    Label(title(for: tab), systemImage: tab.systemImage)
                }
                .tag(tab)
            }
        }
        .sheet(isPresented: $showProfile) {
            NavigationStack {
                LoggedInView(auth: auth)
                    .navigationTitle(l10n.t(.account))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(l10n.t(.actionDone)) { showProfile = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func title(for tab: HomeTab) -> String {
        switch tab {
        case .recommend: return l10n.t(.tabRecommend)
        case .discover:  return l10n.t(.tabDiscover)
        case .whatsNew:  return l10n.t(.tabWhatsNew)
        }
    }

    private func navTitle(for tab: HomeTab) -> String {
        // Recommend tab toolbar shows "Home" (Shaft string_207); other tabs
        // reuse their bottom-bar label.
        tab == .recommend ? l10n.t(.homeNavTitle) : title(for: tab)
    }
}

enum HomeTab: String, CaseIterable, Identifiable {
    case recommend, discover, whatsNew

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .recommend: return "sparkles"
        case .discover:  return "safari"
        case .whatsNew:  return "bell"
        }
    }
}
