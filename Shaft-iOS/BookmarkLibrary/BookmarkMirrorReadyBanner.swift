import SwiftUI
import Observation

/// 「收藏库准备好了」的一次性引导。
///
/// 1:1 移植自 `ceui.pixiv.db.mirror.BookmarkMirrorReadyBanner`（Android 走 InAppBanners，
/// iOS 没有那套宿主，这里自带一个顶部卡片 `BookmarkMirrorReadyBannerHost`）。
///
/// 整个镜像过程是**刻意静默**的：用户从头到尾没被打扰过，也就完全不知道后台攒好了一份
/// 可以倒序、可以按标签/作者/年份筛、可以全文搜的本地副本。补齐的那一刻是唯一值得说一句话
/// 的时点 —— 在此之前说等于催促，在此之后说就永远没有由头了。
///
/// **只弹一次，而且是永久性的一次**：标记落 UserDefaults（按书架），不是内存标志位。
/// 进程重启、重进页面、甚至用户把镜像重建一遍，都不会再弹第二次。
@MainActor
@Observable
final class BookmarkMirrorReadyBanner {
    static let shared = BookmarkMirrorReadyBanner()

    struct Announcement: Identifiable, Equatable {
        let id = UUID()
        let shelf: BookmarkShelf
        let rows: Int
    }

    private(set) var pending: Announcement?

    /// UserDefaults key 前缀。带书架键 = 插画/小说、公开/悄悄各自最多一次。
    private static let keyPrefix = "bookmark_mirror_ready_announced_"

    private init() {}

    func announce(shelf: BookmarkShelf, rows: Int) {
        let key = Self.keyPrefix + shelf.key
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: key) {
            mirrorLog.debug("[\(shelf.label, privacy: .public)] 引导 banner 之前已经弹过，不再弹")
            return
        }
        // **先落标记再弹**：反过来的话，当时没有前台宿主接住这条 banner，标记就没写上，
        // 下次全量完成时又会弹一次。引导宁可漏一次，也不能重复打扰。
        defaults.set(true, forKey: key)
        pending = Announcement(shelf: shelf, rows: rows)
        mirrorLog.info("[\(shelf.label, privacy: .public)] 收藏库就绪引导 banner 已入队（\(rows) 件）")
    }

    func dismiss(_ id: Announcement.ID) {
        if pending?.id == id { pending = nil }
    }
}

/// 顶部引导卡片的宿主。挂在 `HomeView` 的 TabView 上，点「去看看」推收藏库路由。
struct BookmarkMirrorReadyBannerHost: ViewModifier {
    let open: (AppRoute) -> Void

    @State private var banner = BookmarkMirrorReadyBanner.shared
    @Environment(OnboardingStore.self) private var l10n

    /// 比默认 toast 长一点：这是一条要读、要理解、还要决定点不点的引导。
    private static let autoDismiss: Duration = .seconds(7)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let a = banner.pending {
                    card(a)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: a.id) {
                            try? await Task.sleep(for: Self.autoDismiss)
                            guard !Task.isCancelled else { return }
                            banner.dismiss(a.id)
                        }
                }
            }
            .animation(.spring(duration: 0.35), value: banner.pending)
    }

    private func card(_ a: BookmarkMirrorReadyBanner.Announcement) -> some View {
        let route = AppRoute.bookmarkLibrary(contentType: a.shelf.contentType.code, restrict: a.shelf.restrict.apiValue)
        let isUser = a.shelf.contentType == .user
        let caption: String = {
            switch a.shelf.contentType {
            case .illust: return l10n.t(.bookmarkLibraryTitle)
            case .novel: return l10n.t(.bookmarkLibraryNovelTitle)
            case .user: return l10n.t(.followingLibraryTitle)
            }
        }()
        return HStack(alignment: .top, spacing: 12) {
            // 用 app 自己的图标：这条不是某个作品/某个人发来的消息，而是**应用**在跟用户说话。
            Image(.launchLogo)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .clipShape(.rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(l10n.t(isUser ? .followingMirrorReadyTitle : .bookmarkMirrorReadyTitle))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.v3Text1)
                Text(l10n.t(isUser ? .followingMirrorReadyMessage : .bookmarkMirrorReadyMessage, BookmarkLibraryFormat.count(a.rows)))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.v3Text2)
                    .lineLimit(3)
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.v3Text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                banner.dismiss(a.id)
                open(route)
            } label: {
                Text(l10n.t(.bookmarkMirrorReadyAction))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.brand, in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Theme.v3MenuBg, in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.v3Border2, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .contentShape(.rect)
        .onTapGesture {
            banner.dismiss(a.id)
            open(route)
        }
        .gesture(
            DragGesture(minimumDistance: 12).onEnded { value in
                if value.translation.height < -20 { banner.dismiss(a.id) }
            }
        )
    }
}

extension View {
    func bookmarkMirrorReadyBanner(open: @escaping (AppRoute) -> Void) -> some View {
        modifier(BookmarkMirrorReadyBannerHost(open: open))
    }
}

/// 千分位，长列表里的数字扫一眼就能读出量级。
enum BookmarkLibraryFormat {
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()

    static func count(_ value: Int) -> String {
        formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
