import SwiftUI

// 官网发现 (#1121) — 1:1 port of upstream `ui/discovery/WebDiscovery*`: pixiv's
// own /discovery recommendations as a native waterfall with three rating
// pages (全部 / 全年龄 / R-18). Independent of the local candidate-pool
// `DiscoveryFeedView` and of app-api's home recommendations.
//
// With a web session for the same account the personalised
// `/ajax/discovery/artworks` batch is used; without one, the anonymous legacy
// `/ajax/illust/discovery` (all-ages only — R-18 asks for a web login rather
// than passing all-ages works off as R-18).

enum WebDiscoveryMode: String, CaseIterable, Identifiable, Sendable {
    case all, safe, r18

    var id: String { rawValue }

    func accepts(_ xRestrict: Int) -> Bool {
        switch self {
        case .all: return true
        case .safe: return xRestrict == 0
        case .r18: return xRestrict > 0
        }
    }

    var labelKey: LocalizedKey {
        switch self {
        case .all: return .webDiscoveryModeAll
        case .safe: return .webDiscoveryModeSafe
        case .r18: return .webDiscoveryModeR18
        }
    }

    static func initial(filterR18: Bool) -> WebDiscoveryMode { filterR18 ? .safe : .all }
}

// MARK: - Session

/// Upstream `WebDiscoverySession`: the web cookie counts only when its
/// PHPSESSID (`<uid>_…`) belongs to the account signed in to the app.
enum WebDiscoverySession {
    private static let pixivURL = URL(string: "https://www.pixiv.net/ajax/discovery/artworks")!

    @MainActor
    static func cookieHeader() async -> String? {
        await PixivWebCookieBridge.header(for: pixivURL)
    }

    static func matchesAccount(cookie: String?, appUid: Int64) -> Bool {
        guard appUid > 0, let cookie else { return false }
        let session = cookie.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("PHPSESSID=") }?
            .dropFirst("PHPSESSID=".count)
        guard let session, let underscore = session.firstIndex(of: "_"),
              let webUid = Int64(session[session.startIndex..<underscore]) else { return false }
        return webUid == appUid
    }

    @MainActor
    static func isCurrentAccount() async -> Bool {
        let uid = KeychainTokenStore.shared.load()?.user?.id ?? 0
        return matchesAccount(cookie: await cookieHeader(), appUid: uid)
    }

    /// Has any web cookie at all — then re-login must open the real login form.
    @MainActor
    static func hasWebCookie() async -> Bool {
        (await cookieHeader())?.contains("PHPSESSID=") == true
    }
}

// MARK: - API

private struct WebDiscoveryResponse<Body: Decodable>: Decodable {
    let error: Bool?
    let message: String?
    let body: Body?
}

private struct WebDiscoveryBody: Decodable {
    struct Thumbnails: Decodable { let illust: [WebDiscoveryArtwork]? }
    let thumbnails: Thumbnails?
}

private struct WebLegacyDiscoveryBody: Decodable {
    let illusts: [WebDiscoveryArtwork]?
}

/// The web thumbnail is a trimmed work (no original, no full follow state) —
/// never written anywhere as a detail payload.
private struct WebDiscoveryArtwork: Decodable {
    let id: Int64
    let title: String?
    let illustType: Int
    let xRestrict: Int
    let aiType: Int
    let url: String?
    let tags: [String]?
    let userId: Int64
    let userName: String?
    let width: Int
    let height: Int
    let pageCount: Int
    let createDate: String?
    let profileImageUrl: String?
    let isBookmarked: Bool
    let isMasked: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, illustType, xRestrict, aiType, url, tags, userId, userName
        case width, height, pageCount, createDate, profileImageUrl, bookmarkData, isMasked
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // pixiv sends ids as strings here; tolerate numbers too.
        func int64(_ key: CodingKeys) -> Int64 {
            if let s = try? c.decode(String.self, forKey: key) { return Int64(s) ?? 0 }
            return (try? c.decode(Int64.self, forKey: key)) ?? 0
        }
        func int(_ key: CodingKeys) -> Int { (try? c.decode(Int.self, forKey: key)) ?? 0 }
        id = int64(.id)
        userId = int64(.userId)
        title = try? c.decode(String.self, forKey: .title)
        illustType = int(.illustType)
        xRestrict = int(.xRestrict)
        aiType = int(.aiType)
        url = try? c.decode(String.self, forKey: .url)
        tags = try? c.decode([String].self, forKey: .tags)
        userName = try? c.decode(String.self, forKey: .userName)
        width = int(.width)
        height = int(.height)
        pageCount = int(.pageCount)
        createDate = try? c.decode(String.self, forKey: .createDate)
        profileImageUrl = try? c.decode(String.self, forKey: .profileImageUrl)
        isBookmarked = c.contains(.bookmarkData) && (try? c.decodeNil(forKey: .bookmarkData)) == false
        isMasked = (try? c.decode(Bool.self, forKey: .isMasked)) ?? false
    }

    private static let imagePath = try! NSRegularExpression(pattern: #"/img/(.+?)_(?:square|custom|master)1200\.\w+"#)

    func toIllust() -> Illust {
        let thumbnail = url ?? ""
        let ns = thumbnail as NSString
        let path = Self.imagePath.firstMatch(in: thumbnail, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
        let medium = path.map { "https://i.pximg.net/c/540x540_70/img-master/img/\($0)_master1200.jpg" } ?? thumbnail
        let large = path.map { "https://i.pximg.net/c/600x1200_90_webp/img-master/img/\($0)_master1200.jpg" } ?? thumbnail
        let avatar = profileImageUrl.map {
            ImageUrls(url: nil, large: nil, medium: $0, original: nil, small: nil,
                      squareMedium: nil, px170x170: $0, px50x50: nil)
        }
        return Illust(
            id: id, title: title ?? "", caption: nil,
            type: illustType == 1 ? "manga" : illustType == 2 ? "ugoira" : "illust",
            imageUrls: ImageUrls(url: nil, large: large, medium: medium, original: nil, small: nil,
                                 squareMedium: thumbnail, px170x170: nil, px50x50: nil),
            user: PixivUser(id: userId, name: userName ?? "", account: nil, profileImageUrls: avatar, isFollowed: nil),
            tags: (tags ?? []).map { Tag(name: $0, translatedName: nil) },
            pageCount: max(pageCount, 1), width: width, height: height,
            totalBookmarks: nil, totalView: nil, isBookmarked: isBookmarked,
            createDate: createDate, metaSinglePage: nil, metaPages: nil, series: nil,
            xRestrict: xRestrict, illustAIType: aiType, visible: !isMasked
        )
    }
}

enum WebDiscoveryError: LocalizedError {
    case http(Int)
    case business(String)
    case missing

    var errorDescription: String? {
        switch self {
        case .http(let code): return "HTTP \(code)"
        case .business(let message): return message
        case .missing: return "Missing discovery artworks"
        }
    }
}

/// Upstream `WebDiscoverySource.load`: one call = one fresh batch (the web
/// endpoint has no page / offset / next_url).
private enum WebDiscoveryAPI {
    @MainActor
    static func fetch(mode: WebDiscoveryMode) async throws -> (works: [WebDiscoveryArtwork], hasSession: Bool) {
        let cookie = await WebDiscoverySession.cookieHeader()
        let uid = KeychainTokenStore.shared.load()?.user?.id ?? 0
        let hasSession = WebDiscoverySession.matchesAccount(cookie: cookie, appUid: uid)
        // The legacy endpoint has no anonymous R-18: never pass all-ages works off as R-18.
        if !hasSession && mode == .r18 { return ([], false) }
        var components = URLComponents(string: hasSession
            ? "https://www.pixiv.net/ajax/discovery/artworks"
            : "https://www.pixiv.net/ajax/illust/discovery")!
        components.queryItems = hasSession
            ? [URLQueryItem(name: "mode", value: mode.rawValue), URLQueryItem(name: "limit", value: "60")]
            : [URLQueryItem(name: "mode", value: mode.rawValue), URLQueryItem(name: "max", value: "18")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        // The authoritative jar is WebKit's; an anonymous request must carry no
        // cookie at all, or a signed-out / switched account leaks old picks in.
        request.httpShouldHandleCookies = false
        request.setValue(PixivClientIdentity.acceptLanguage(), forHTTPHeaderField: "accept-language")
        request.setValue("https://www.pixiv.net/", forHTTPHeaderField: "referer")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
            forHTTPHeaderField: "user-agent"
        )
        if hasSession, let cookie { request.setValue(cookie, forHTTPHeaderField: "cookie") }
        let (data, response) = try await DirectConnection.data(
            for: request, using: DirectConnection.shared,
            directConnect: DirectConnection.isEnabledAtLaunch
        )
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WebDiscoveryError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let works: [WebDiscoveryArtwork]?
        if hasSession {
            let decoded = try JSONDecoder().decode(WebDiscoveryResponse<WebDiscoveryBody>.self, from: data)
            if decoded.error == true {
                throw WebDiscoveryError.business(decoded.message.flatMap { $0.isEmpty ? nil : $0 } ?? "Discovery request failed")
            }
            works = decoded.body?.thumbnails?.illust
        } else {
            let decoded = try JSONDecoder().decode(WebDiscoveryResponse<WebLegacyDiscoveryBody>.self, from: data)
            if decoded.error == true {
                throw WebDiscoveryError.business(decoded.message.flatMap { $0.isEmpty ? nil : $0 } ?? "Discovery request failed")
            }
            works = decoded.body?.illusts
        }
        guard let works else { throw WebDiscoveryError.missing }
        return (works, hasSession)
    }
}

// MARK: - Feed (one rating page)

@MainActor
@Observable
final class WebDiscoveryFeedVM {
    let mode: WebDiscoveryMode
    var illusts: [Illust] = []
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?
    /// The last batch came back empty — nothing more to ask for.
    var exhausted = false
    /// R-18 without a same-account web session: show the login prompt.
    var needsLogin = false
    var hasLoadedOnce = false

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var seen = Set<Int64>()
    /// Batches may filter down to nothing; keep asking a few times before
    /// showing an empty page (upstream FeedViewModel's request budget).
    private static let emptyBatchBudget = 3

    init(mode: WebDiscoveryMode) { self.mode = mode }

    func loadIfNeeded() async { if !hasLoadedOnce, !isLoading { await load() } }

    func load() async {
        generation += 1
        let loadGeneration = generation
        isLoading = true
        errorMessage = nil
        defer { if generation == loadGeneration { isLoading = false } }
        seen = []
        exhausted = false
        do {
            let batch = try await nextVisibleBatch(loadGeneration)
            guard generation == loadGeneration else { return }
            illusts = batch
            hasLoadedOnce = true
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
            hasLoadedOnce = true
        }
    }

    func loadMore() async {
        guard hasLoadedOnce, !exhausted, !isLoading, !isLoadingMore else { return }
        let loadGeneration = generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let batch = try await nextVisibleBatch(loadGeneration)
            guard generation == loadGeneration else { return }
            illusts.append(contentsOf: batch)
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// After a web login: drop the old generation and reload in place.
    func webLoginReturned() async {
        guard hasLoadedOnce || isLoading else { return }
        illusts = []
        await load()
    }

    private func nextVisibleBatch(_ loadGeneration: Int) async throws -> [Illust] {
        for _ in 0..<Self.emptyBatchBudget {
            let (works, hasSession) = try await WebDiscoveryAPI.fetch(mode: mode)
            guard generation == loadGeneration else { return [] }
            needsLogin = mode == .r18 && !hasSession
            if works.isEmpty {
                exhausted = true
                return []
            }
            // Cross-batch dedup: each call is a fresh batch that may repeat works.
            let fresh = works
                .filter { $0.id > 0 && $0.userId > 0 && !$0.isMasked && !($0.url ?? "").isEmpty }
                .filter { mode.accepts($0.xRestrict) }
                .map { $0.toIllust() }
                .filter { seen.insert($0.id).inserted }
            // This page's rating filter overrides the global R-18 filter; muted
            // authors / tags still apply.
            let visible = MuteStore.shared.filter(fresh, applyR18: false)
            if !visible.isEmpty { return visible }
        }
        return []
    }
}

// MARK: - Screen

struct WebDiscoveryView: View {
    @State private var feeds: [WebDiscoveryMode: WebDiscoveryFeedVM] = Dictionary(
        uniqueKeysWithValues: WebDiscoveryMode.allCases.map { ($0, WebDiscoveryFeedVM(mode: $0)) }
    )
    @State private var mode = WebDiscoveryMode.initial(filterR18: MuteStore.shared.hideR18)
    @State private var webLogin: WebLoginTarget?
    @Environment(OnboardingStore.self) private var l10n

    private struct WebLoginTarget: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        VStack(spacing: 0) {
            modeTabs
            TabView(selection: $mode) {
                ForEach(WebDiscoveryMode.allCases) { m in
                    if let vm = feeds[m] {
                        WebDiscoveryFeedPage(vm: vm, isActive: mode == m) { openWebLogin() }
                            .tag(m)
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Theme.v3Bg)
        .navigationTitle(l10n.t(.webDiscovery))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Even a stale-but-present cookie can be replaced from here.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(l10n.t(.webDiscoveryWebLogin)) { openWebLogin() }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .sheet(item: $webLogin, onDismiss: {
            Task { for vm in feeds.values { await vm.webLoginReturned() } }
        }) { target in
            PixivWebLoginSheet(url: target.url, title: l10n.t(.webDiscoveryWebLogin))
        }
    }

    private func openWebLogin() {
        Task {
            // With a stored cookie the web home would just show content; a
            // re-login must open the real login form.
            let url = await WebDiscoverySession.hasWebCookie()
                ? URL(string: "https://accounts.pixiv.net/login")!
                : URL(string: "https://www.pixiv.net/")!
            webLogin = WebLoginTarget(url: url)
        }
    }

    /// `discovery_modes`: scrollable start-aligned tabs (min 96pt) in an 8pt-inset
    /// 14pt-radius `v3_surface_2` track; the selected tab is an 11pt-radius
    /// theme `alpha20` capsule with `textAccent` text, others `v3_text_2`.
    /// Montserrat SemiBold 13, 0.04 tracking.
    private var modeTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(WebDiscoveryMode.allCases) { m in
                    let selected = mode == m
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { mode = m }
                    } label: {
                        Text(l10n.t(m.labelKey))
                            .font(.montserratSemiBold(13))
                            .tracking(13 * 0.04)
                            .foregroundStyle(selected ? Theme.v3TextAccent : Theme.v3Text2)
                            .padding(.horizontal, 12)
                            .frame(minWidth: 96, minHeight: 48)
                            .background {
                                if selected {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .fill(Theme.brand.opacity(0.20))
                                }
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.v3Surface2))
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .padding(8)
    }
}

/// One rating page; keeps its own list, batch cursor and scroll position.
private struct WebDiscoveryFeedPage: View {
    let vm: WebDiscoveryFeedVM
    let isActive: Bool
    let onWebLogin: () -> Void
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        Group {
            if vm.needsLogin && vm.illusts.isEmpty && !vm.isLoading {
                ContentUnavailableView {
                    Label(l10n.t(.webDiscovery), systemImage: "globe.americas")
                } description: {
                    Text(l10n.t(.webDiscoveryLoginNeeded))
                } actions: {
                    Button(l10n.t(.webDiscoveryGoLogin), action: onWebLogin)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.brand)
                }
            } else {
                IllustWaterfallList(
                    illusts: vm.illusts,
                    isLoading: vm.isLoading,
                    errorMessage: vm.errorMessage,
                    onRefresh: { await vm.load() },
                    onLoadMore: { await vm.loadMore() },
                    hasMore: !vm.exhausted,
                    // Rating + mute filtering already applied per page.
                    prefiltered: true
                )
            }
        }
        // Pages load lazily the first time they are shown.
        .task(id: isActive) { if isActive { await vm.loadIfNeeded() } }
    }
}
