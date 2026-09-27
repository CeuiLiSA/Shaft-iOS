import SwiftUI

struct HomeView: View {
    @Bindable var auth: AuthViewModel
    @Environment(OnboardingStore.self) private var l10n
    @State private var selection: HomeTab = .recommend
    @State private var recommendPath = NavigationPath()
    @State private var discoverPath = NavigationPath()
    @State private var whatsNewPath = NavigationPath()
    @State private var referralLink = ReferralLinkStore.shared
    @State private var downloads = DownloadManager.shared
    /// Tabs the tablet rail has shown at least once. Stacks are built on first
    /// visit (like TabView / upstream lazyData) and then kept alive for their state.
    @State private var visitedTabs: Set<HomeTab> = []

    var body: some View {
        GeometryReader { geo in
            // 平板（设备最小边 ≥ 600）且窗口可用宽度 ≥ 600：88pt 侧边导航栏代替底栏（#1087）。
            // 分屏 / 台前调度窄窗口时回到手机排版。
            if AdaptiveStaggerColumns.isTablet && geo.size.width >= 600 {
                railShell
            } else {
                TabView(selection: $selection) {
                    tabStack(.recommend, path: $recommendPath) { RecommendView() }
                    tabStack(.discover, path: $discoverPath) { DiscoverView() }
                    tabStack(.whatsNew, path: $whatsNewPath) { WhatsNewView() }
                }
            }
        }
        // 「收藏库已就绪」的一次性引导卡片：点「去看看」推到当前 tab 的栈上。
        .bookmarkMirrorReadyBanner { route in pushOnSelectedTab(route) }
        // 收藏镜像引擎跟着登录态活着：已注册的书架会从上次落盘的断点续上（幂等）。
        .task { await BookmarkMirrorService.shared.start() }
        // 下载因剩余空间不足整体暂停时的一次性提示（pixez#1361），任何页面都能看到。
        .overlay(alignment: .bottom) {
            if let notice = downloads.lowStorageNotice {
                Text(String(format: l10n.t(.downloadPausedLowStorage),
                            ByteCountFormatter.string(fromByteCount: notice.freeBytes, countStyle: .file)))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.80), in: .rect(cornerRadius: 16))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 96)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .task(id: notice.id) {
                        // Toaster.showLong
                        do { try await Task.sleep(for: .seconds(3.5)) } catch { return }
                        withAnimation { downloads.consumeLowStorageNotice(notice.id) }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: downloads.lowStorageNotice)
        .onAppear { openPendingReferral() }
        .onChange(of: referralLink.pendingCode) { _, _ in openPendingReferral() }
    }

    private func pushOnSelectedTab(_ route: AppRoute) {
        switch selection {
        case .recommend: recommendPath.append(route)
        case .discover: discoverPath.append(route)
        case .whatsNew: whatsNewPath.append(route)
        }
    }

    private func openPendingReferral() {
        if let code = referralLink.consume() { pushOnSelectedTab(.referral(code: code)) }
    }

    /// Tablet shell: rail + the three tab stacks kept alive side by side (only the
    /// selected one is visible), so switching tabs keeps each stack's state.
    private var railShell: some View {
        HStack(spacing: 0) {
            // The rail belongs to the home shell only: pushed pages (a work, a
            // profile…) take the whole window, like upstream's separate activities.
            if currentPathIsEmpty {
            HomeNavigationRail(
                selection: selection,
                onMenu: { pushOnSelectedTab(.more) },
                onSelect: { selection = $0 },
                onBookmarks: {
                    let uid = BookmarkMirrorService.loggedInUid()
                    if uid > 0 { pushOnSelectedTab(.userBookmarks(userId: uid)) }
                },
                onDownloads: { pushOnSelectedTab(.downloads) }
            )
            .transition(.move(edge: .leading).combined(with: .opacity))
            }
            ZStack {
                ForEach(HomeTab.allCases.filter { visitedTabs.contains($0) || $0 == selection }) { tab in
                    Group {
                        switch tab {
                        case .recommend: navStack(.recommend, path: $recommendPath, rail: true) { RecommendView() }
                        case .discover: navStack(.discover, path: $discoverPath, rail: true) { DiscoverView() }
                        case .whatsNew: navStack(.whatsNew, path: $whatsNewPath, rail: true) { WhatsNewView() }
                        }
                    }
                    .opacity(selection == tab ? 1 : 0)
                    .allowsHitTesting(selection == tab)
                    .accessibilityHidden(selection != tab)
                }
            }
        }
        .environment(\.homeRailMode, true)
        .animation(.easeInOut(duration: 0.2), value: currentPathIsEmpty)
        .onAppear { visitedTabs.insert(selection) }
        .onChange(of: selection) { _, tab in visitedTabs.insert(tab) }
    }

    private var currentPathIsEmpty: Bool {
        switch selection {
        case .recommend: return recommendPath.isEmpty
        case .discover: return discoverPath.isEmpty
        case .whatsNew: return whatsNewPath.isEmpty
        }
    }

    @ViewBuilder
    private func tabStack<Content: View>(
        _ tab: HomeTab,
        path: Binding<NavigationPath>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        navStack(tab, path: path, rail: false, content: content)
            .tabItem {
                Label(title(for: tab), systemImage: tab.systemImage)
            }
            .tag(tab)
    }

    @ViewBuilder
    private func navStack<Content: View>(
        _ tab: HomeTab,
        path: Binding<NavigationPath>,
        rail: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        NavigationStack(path: path) {
            content()
                .navigationTitle(navTitle(for: tab))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // 宽窗口：菜单入口在侧栏里，标题行不再放它。
                    if !rail {
                        ToolbarItem(placement: .topBarLeading) {
                            NavigationLink(value: AppRoute.more) {
                                Image(systemName: "person.crop.circle")
                            }
                            .accessibilityLabel(l10n.t(.moreTitle))
                        }
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

// MARK: - Tablet rail (HomeNavigationRail, #1087)

private struct HomeRailModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The tablet side rail is showing — tab pages swap their phone chrome for the
    /// wide-window V3 header.
    var homeRailMode: Bool {
        get { self[HomeRailModeKey.self] }
        set { self[HomeRailModeKey.self] = newValue }
    }
}

/// 88pt side rail (upstream `HomeNavigationRail`): menu button on top → the same
/// tabs as the bottom bar → a divider → 「收藏 / 下载」 shortcuts (they jump, never
/// select). Selected: theme `alpha15` fill + `textAccent`, 22pt corners, items
/// 68pt wide with ≥ 64pt hit height; scrolls when taller than the window; a
/// hairline separates it from the content.
private struct HomeNavigationRail: View {
    let selection: HomeTab
    let onMenu: () -> Void
    let onSelect: (HomeTab) -> Void
    let onBookmarks: () -> Void
    let onDownloads: () -> Void
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Button(action: onMenu) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Theme.v3Text1)
                            .frame(width: 48, height: 48)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(l10n.t(.railOpenMenu))
                    .padding(.bottom, 24)

                    VStack(spacing: 8) {
                        ForEach(HomeTab.allCases) { tab in
                            item(title(for: tab), systemImage: tab.systemImage, selected: tab == selection) {
                                onSelect(tab)
                            }
                        }
                    }
                    .frame(width: 68)

                    Theme.v3Border2.frame(width: 44, height: 0.5)
                        .padding(.top, 12)
                        .padding(.bottom, 20)

                    VStack(spacing: 8) {
                        item(l10n.t(.railBookmarks), systemImage: "heart", selected: false, action: onBookmarks)
                        item(l10n.t(.railDownloads), systemImage: "arrow.down.circle", selected: false, action: onDownloads)
                    }
                    .frame(width: 68)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 16)
            }
            Theme.v3Border2.frame(width: 0.5).ignoresSafeArea()
        }
        .background(Theme.v3Bg.ignoresSafeArea())
    }

    private func title(for tab: HomeTab) -> String {
        switch tab {
        case .recommend: return l10n.t(.tabRecommend)
        case .discover: return l10n.t(.tabDiscover)
        case .whatsNew: return l10n.t(.tabWhatsNew)
        }
    }

    private func item(_ title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                    .frame(width: 24, height: 24)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(selected ? Theme.v3TextAccent : Theme.v3Text2)
            .padding(.horizontal, 4)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(selected ? Theme.brand.opacity(0.15) : .clear))
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(RailPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct RailPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
