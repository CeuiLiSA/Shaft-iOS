import SwiftUI

// MARK: - View models

@MainActor
@Observable
final class NotificationListVM {
    /// nil = top-level list; non-nil = view-more drill-in for that group head.
    let viewMoreId: Int64?
    var items: [NotificationItem] = []
    var nextUrl: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init(viewMoreId: Int64? = nil) {
        self.viewMoreId = viewMoreId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async { if items.isEmpty { await load() } }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let r: NotificationListResponse
            if let id = viewMoreId {
                r = try await api.notificationViewMore(id)
            } else {
                r = try await api.notificationList()
            }
            items = r.notifications
            nextUrl = r.nextUrl
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let r: NotificationListResponse = try? await api.nextPage(url) {
            items.append(contentsOf: r.notifications)
            nextUrl = r.nextUrl
        }
    }
}

@MainActor
@Observable
final class InfoLatestVM {
    var categories: [CategorizedInfo] = []
    var isLoading = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init() {
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async { if categories.isEmpty { await load() } }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            categories = try await api.infoLatest().categorizedInfos
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
@Observable
final class InfoCategoryVM {
    let categoryId: Int
    var items: [InfoItem] = []
    var nextUrl: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init(categoryId: Int) {
        self.categoryId = categoryId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async { if items.isEmpty { await load() } }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let r = try await api.infoList(categoryId: categoryId)
            items = r.categorizedInfo?.infoList ?? []
            nextUrl = r.nextUrl
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let url = nextUrl, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let r: InfoListResponse = try? await api.nextPage(url) {
            items.append(contentsOf: r.categorizedInfo?.infoList ?? [])
            nextUrl = r.nextUrl
        }
    }
}

// MARK: - Notifications + announcements pager

/// Shaft `NotificationPagerFragment`: two tabs — 通知 (activity notifications)
/// and 公告 (official announcements).
struct NotificationsView: View {
    private enum Tab: Hashable { case notifications, info }
    @State private var tab: Tab = .notifications
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(l10n.t(.notificationsTab)).tag(Tab.notifications)
                Text(l10n.t(.notificationsInfoTab)).tag(Tab.info)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            switch tab {
            case .notifications: NotificationListPage()
            case .info: InfoLatestPage()
            }
        }
        .navigationTitle(l10n.t(.notificationsTitle))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NotificationListPage: View {
    @State private var vm = NotificationListVM()
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        NotificationList(vm: vm)
            .overlay {
                if vm.isLoading && vm.items.isEmpty {
                    ProgressView()
                } else if vm.items.isEmpty, let err = vm.errorMessage {
                    InlineError(message: err) { Task { await vm.load() } }.padding()
                } else if vm.items.isEmpty && !vm.isLoading {
                    ContentUnavailableView(l10n.t(.nothingHere), systemImage: "bell")
                }
            }
            .refreshable { await vm.load() }
            .task { await vm.loadIfNeeded() }
    }
}

/// Drill-in for a grouped notification's full sub-list (`view_more`).
struct NotificationViewMoreView: View {
    let title: String
    @State private var vm: NotificationListVM
    @Environment(OnboardingStore.self) private var l10n

    init(notificationId: Int64, title: String) {
        self.title = title
        _vm = State(wrappedValue: NotificationListVM(viewMoreId: notificationId))
    }

    var body: some View {
        NotificationList(vm: vm)
            .overlay {
                if vm.isLoading && vm.items.isEmpty {
                    ProgressView()
                } else if vm.items.isEmpty, let err = vm.errorMessage {
                    InlineError(message: err) { Task { await vm.load() } }.padding()
                }
            }
            .refreshable { await vm.load() }
            .task { await vm.loadIfNeeded() }
            .navigationTitle(title.isEmpty ? l10n.t(.notificationsTitle) : title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NotificationList: View {
    @Bindable var vm: NotificationListVM

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(vm.items) { item in
                    NotificationCell(item: item)
                    Divider().padding(.leading, 64)
                }
                if vm.nextUrl != nil, !vm.items.isEmpty {
                    Color.clear
                        .frame(height: 40)
                        .onAppear { Task { await vm.loadMore() } }
                }
            }
        }
    }
}

private struct NotificationCell: View {
    let item: NotificationItem
    @Environment(\.openURL) private var openExternal
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row
            // Group heads carry a server-titled chip (e.g. "有新粉丝") that
            // expands to the full sub-list.
            if let more = item.viewMore, let title = more.title, item.id > 0 {
                NavigationLink(value: AppRoute.notificationViewMore(notificationId: item.id, title: title)) {
                    HStack(spacing: 4) {
                        Text(title)
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color(.secondarySystemBackground), in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(.leading, 52)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .background(alignment: .leading) {
            if isUnread {
                Rectangle().fill(.tint).frame(width: 3)
            }
        }
    }

    @ViewBuilder
    private var row: some View {
        let content = HStack(alignment: .top, spacing: 12) {
            PixivAsyncImage(url: avatarURL)
                .frame(width: 40, height: 40)
                .clipShape(.circle)
                .background(Color(.secondarySystemBackground), in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.boldHTML(item.content?.text ?? ""))
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                if let ago = timeAgo {
                    Text(ago).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let thumb = thumbURL {
                PixivAsyncImage(url: thumb)
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 6))
            }
        }
        .foregroundStyle(.primary)

        if let route = targetRoute {
            NavigationLink(value: route) { content }.buttonStyle(.plain)
        } else if let url = httpTarget {
            Button { openExternal(url) } label: { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private var isUnread: Bool {
        item.isRead == false || item.viewMore?.unreadExists == true
    }

    /// Prefer the work thumbnail, fall back to the avatar icon — mirrors
    /// Shaft `NotificationViewHolder`.
    private var avatarURL: URL? {
        (item.content?.leftImage ?? item.content?.leftIcon).flatMap(URL.init(string:))
    }

    private var thumbURL: URL? {
        (item.content?.rightImage ?? item.content?.rightIcon).flatMap(URL.init(string:))
    }

    /// `target_url` is always a `pixiv://` scheme — reuse the search link
    /// parser for illusts/users/novels.
    private var targetRoute: AppRoute? {
        guard let t = item.targetUrl, t.lowercased().hasPrefix("pixiv://") else { return nil }
        return PixivLinkParser.shortcuts(for: t).first?.route
    }

    private var httpTarget: URL? {
        guard let t = item.targetUrl, t.lowercased().hasPrefix("http") else { return nil }
        return URL(string: t)
    }

    private var timeAgo: String? {
        guard let raw = item.createdDatetime,
              let date = ISO8601DateFormatter().date(from: raw) else { return nil }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    /// Server text is HTML with the user name in `<b>` — convert just that to
    /// markdown bold, strip any other tags, and render as AttributedString.
    static func boldHTML(_ html: String) -> AttributedString {
        var s = html
            .replacingOccurrences(of: "<b>", with: "**")
            .replacingOccurrences(of: "</b>", with: "**")
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<.+?>", with: "", options: .regularExpression)
        s = s
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
        return (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s.replacingOccurrences(of: "**", with: ""))
    }
}

// MARK: - Announcements (公告)

private struct InfoLatestPage: View {
    @State private var vm = InfoLatestVM()
    @State private var openItem: InfoItem?
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        List {
            ForEach(vm.categories) { category in
                Section {
                    ForEach(category.infoList) { item in
                        InfoRow(item: item) { openItem = item }
                    }
                    NavigationLink(value: AppRoute.infoCategory(
                        categoryId: category.categoryId,
                        title: category.categoryTitle ?? ""
                    )) {
                        Text(l10n.t(.detailSeeMore))
                            .font(.footnote)
                            .foregroundStyle(.tint)
                    }
                } header: {
                    Text(category.categoryTitle ?? "")
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if vm.isLoading && vm.categories.isEmpty {
                ProgressView()
            } else if vm.categories.isEmpty, let err = vm.errorMessage {
                InlineError(message: err) { Task { await vm.load() } }.padding()
            } else if vm.categories.isEmpty && !vm.isLoading {
                ContentUnavailableView(l10n.t(.nothingHere), systemImage: "megaphone")
            }
        }
        .refreshable { await vm.load() }
        .task { await vm.loadIfNeeded() }
        .navigationDestination(isPresented: Binding(
            get: { openItem != nil },
            set: { if !$0 { openItem = nil } }
        )) {
            if let url = openItem?.url.flatMap(URL.init(string:)) {
                WebArticleView(url: url)
            }
        }
    }
}

/// Paginated single-category announcement list (`/v1/info/list?cid=N`).
struct InfoCategoryView: View {
    let title: String
    @State private var vm: InfoCategoryVM
    @State private var openItem: InfoItem?
    @Environment(OnboardingStore.self) private var l10n

    init(categoryId: Int, title: String) {
        self.title = title
        _vm = State(wrappedValue: InfoCategoryVM(categoryId: categoryId))
    }

    var body: some View {
        List {
            ForEach(vm.items) { item in
                InfoRow(item: item) { openItem = item }
            }
            if vm.nextUrl != nil, !vm.items.isEmpty {
                Color.clear
                    .frame(height: 40)
                    .listRowSeparator(.hidden)
                    .onAppear { Task { await vm.loadMore() } }
            }
        }
        .listStyle(.plain)
        .overlay {
            if vm.isLoading && vm.items.isEmpty {
                ProgressView()
            } else if vm.items.isEmpty, let err = vm.errorMessage {
                InlineError(message: err) { Task { await vm.load() } }.padding()
            }
        }
        .refreshable { await vm.load() }
        .task { await vm.loadIfNeeded() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: Binding(
            get: { openItem != nil },
            set: { if !$0 { openItem = nil } }
        )) {
            if let url = openItem?.url.flatMap(URL.init(string:)) {
                WebArticleView(url: url)
            }
        }
    }
}

private struct InfoRow: View {
    let item: InfoItem
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if item.isRecent == true {
                        Circle().fill(.tint).frame(width: 6, height: 6)
                    }
                    Text(item.title ?? "")
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                }
                if let date = item.date {
                    Text(date).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}
