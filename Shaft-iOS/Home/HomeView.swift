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
        // 「收藏库已就绪」的一次性引导卡片：点「去看看」推到当前 tab 的栈上。
        .bookmarkMirrorReadyBanner { route in pushOnSelectedTab(route) }
        // 收藏镜像引擎跟着登录态活着：已注册的书架会从上次落盘的断点续上（幂等）。
        .task { await BookmarkMirrorService.shared.start() }
    }

    private func pushOnSelectedTab(_ route: AppRoute) {
        switch selection {
        case .recommend: recommendPath.append(route)
        case .discover: discoverPath.append(route)
        case .whatsNew: whatsNewPath.append(route)
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
                .environment(\.pushRoute, RoutePusher { path.wrappedValue.append($0) })
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
