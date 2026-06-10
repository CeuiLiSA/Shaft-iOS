import SwiftUI

struct HomeView: View {
    @Bindable var auth: AuthViewModel
    @Environment(OnboardingStore.self) private var l10n
    @State private var selection: HomeTab = .recommend
    @State private var recommendPath = NavigationPath()
    @State private var discoverPath = NavigationPath()
    @State private var whatsNewPath = NavigationPath()

    var body: some View {
        TabView(selection: $selection) {
            tabStack(.recommend, path: $recommendPath) { RecommendView() }
            tabStack(.discover, path: $discoverPath) { DiscoverView() }
            tabStack(.whatsNew, path: $whatsNewPath) { WhatsNewView() }
        }
    }

    @ViewBuilder
    private func tabStack<Content: View>(
        _ tab: HomeTab,
        path: Binding<NavigationPath>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        NavigationStack(path: path) {
            content()
                .navigationTitle(navTitle(for: tab))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink(value: AppRoute.more) {
                            Image(systemName: "person.crop.circle")
                        }
                        .accessibilityLabel(l10n.t(.moreTitle))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: AppRoute.search) {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel(l10n.t(.searchTitle))
                    }
                }
                .registerRoutes(auth: auth)
        }
        .tabItem {
            Label(title(for: tab), systemImage: tab.systemImage)
        }
        .tag(tab)
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
