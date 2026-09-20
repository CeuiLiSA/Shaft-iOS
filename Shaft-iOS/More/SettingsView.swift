import SwiftUI

// MARK: - Two-level settings catalog

/// The ten categories and order used by Pixiv-Shaft's redesigned
/// `FragmentSettingsHub` / `SettingsCatalog`.
private enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case account, network, appearance, browsing, viewing
    case bookmarks, download, ai, data, experimental

    var id: String { rawValue }

    var titleKey: LocalizedKey {
        switch self {
        case .account:      return .stSectionAccount
        case .network:      return .settingsNetwork
        case .appearance:   return .stSectionUI
        case .browsing:     return .settingsCatBrowsing
        case .viewing:      return .settingsCatViewing
        case .bookmarks:    return .settingsCatBookmarks
        case .download:     return .downloadsTitle
        case .ai:           return .settingsCatAI
        case .data:         return .settingsCatData
        case .experimental: return .stSectionExperimental
        }
    }

    var icon: String {
        switch self {
        case .account:      return "person.fill"
        case .network:      return "globe"
        case .appearance:   return "paintpalette.fill"
        case .browsing:     return "magnifyingglass"
        case .viewing:      return "photo.fill"
        case .bookmarks:    return "heart.fill"
        case .download:     return "arrow.down.circle.fill"
        case .ai:           return "sparkles"
        case .data:         return "externaldrive.fill"
        case .experimental: return "flask.fill"
        }
    }
}

private struct SettingsCatalogEntry: Identifiable {
    let id: String
    let category: SettingsCategory
    let title: LocalizedKey
    var description: LocalizedKey? = nil
    var keywords = ""
}

/// Search index kept separate from the view hierarchy, matching Android's
/// catalog: the hub preview, search ordering and category destinations all
/// derive from this one ordered list.
private enum SettingsCatalog {
    static let entries: [SettingsCatalogEntry] = [
        // Account
        .init(id: "accountManage", category: .account, title: .stAccountManage, keywords: "account switch 多账号 切换账号"),
        .init(id: "editAccount", category: .account, title: .stEditAccount, keywords: "email password 邮箱 密码"),
        .init(id: "emailBackup", category: .account, title: .stEmailBackup, keywords: "email backup restore 邮箱 备份 恢复"),
        .init(id: "editProfile", category: .account, title: .stEditProfile, keywords: "profile avatar 资料 头像 昵称"),
        .init(id: "workspace", category: .account, title: .stWorkspace, keywords: "workspace 作业环境 电脑 手绘板"),
        .init(id: "r18Setting", category: .account, title: .stR18Setting, keywords: "adult r18 r18g 成人 限制级"),
        .init(id: "premium", category: .account, title: .stPremiumSetting, keywords: "premium member 会员 订阅"),
        .init(id: "logout", category: .account, title: .actionLogOut, keywords: "logout sign out 退出 登出"),

        // Network
        .init(id: "directConnect", category: .network, title: .stDirectConnect, description: .stSeePixEz, keywords: "direct proxy vpn 直连 代理 梯子"),
        .init(id: "secureDNS", category: .network, title: .stSecureDns, description: .stSecureDnsHint, keywords: "dns doh cloudflare 域名 解析"),
        .init(id: "imageHost", category: .network, title: .stImageHost, keywords: "image host proxy domain 图片 图床 代理 域名"),
        .init(id: "largeThumbnail", category: .network, title: .stLargeThumbnail, description: .stOriginalHint, keywords: "thumbnail image quality 缩略图 大图 画质"),
        .init(id: "originalPreview", category: .network, title: .stShowOriginalPreview, description: .stOriginalHint, keywords: "original detail image 原图 高清 详情"),

        // Appearance
        .init(id: "themeMode", category: .appearance, title: .stThemeMode, keywords: "theme dark light system 主题 深色 浅色"),
        .init(id: "themeColor", category: .appearance, title: .stThemeColor, keywords: "accent palette color 主题色 配色"),
        .init(id: "language", category: .appearance, title: .settingsLanguage, keywords: "language 中文 english 日本語 한국어 语言"),
        .init(id: "startPage", category: .appearance, title: .stNavInitPosition, keywords: "start home initial 启动页 默认页 首页"),
        .init(id: "tabOrder", category: .appearance, title: .stBottomBarOrder, keywords: "bottom bar tab order 底部 导航 顺序"),
        .init(id: "homeR18", category: .appearance, title: .stMainViewR18, keywords: "home r18 首页"),
        .init(id: "columns", category: .appearance, title: .stLineCount, keywords: "columns grid 列数 网格 瀑布流"),
        .init(id: "layoutMode", category: .appearance, title: .stLayoutMode, keywords: "layout staggered linear 布局 瀑布流 列表"),
        .init(id: "novelTags", category: .appearance, title: .stShowNovelTags, keywords: "novel tags 小说 标签 卡片"),
        .init(id: "widgetRefresh", category: .appearance, title: .stWidgetRefreshInterval, keywords: "widget refresh interval 小组件 刷新 间隔"),

        // Browsing & search
        .init(id: "autoRefreshHome", category: .browsing, title: .stAutoRefreshHome, description: .stAutoRefreshHomeHint, keywords: "home recommendation refresh launch 首页 推荐 自动刷新 启动"),
        .init(id: "saveHistory", category: .browsing, title: .stSaveViewHistory, keywords: "history 浏览历史 足迹"),
        .init(id: "cloudHistory", category: .browsing, title: .stCloudHistorySync, keywords: "cloud history sync 云同步 历史"),
        .init(id: "clearCloudHistory", category: .browsing, title: .stClearCloudHistory, keywords: "clear delete cloud history 清除 云端 历史"),
        .init(id: "filterComments", category: .browsing, title: .stFilterComment, keywords: "spam comments 垃圾 评论 广告"),
        .init(id: "filterR18", category: .browsing, title: .stR18DefaultFilter, description: .stR18DefaultFilterHint, keywords: "r18 safe filter 成人 屏蔽"),
        .init(id: "hideAI", category: .browsing, title: .stDeleteAIIllust, keywords: "ai aigc filter 屏蔽 生成"),
        .init(id: "rankBookmarked", category: .browsing, title: .stFilterRankBookmarked, keywords: "ranking bookmark 排行榜 已收藏"),
        .init(id: "novelMinLength", category: .browsing, title: .stNovelMinLength, description: .stNovelMinLengthHint, keywords: "novel minimum length filter 小说 最小 字数 过滤"),
        .init(id: "novelMaxLength", category: .browsing, title: .stNovelMaxLength, description: .stNovelMaxLengthHint, keywords: "novel maximum length filter 小说 最大 字数 过滤"),
        .init(id: "novelMaxTagLength", category: .browsing, title: .stNovelMaxTagLength, description: .stNovelMaxTagLengthHint, keywords: "novel tag maximum length filter 小说 标签 长度 过滤"),
        .init(id: "searchFilter", category: .browsing, title: .stSearchFilter, keywords: "search bookmarks filter 搜索 收藏量 筛选"),
        .init(id: "searchSort", category: .browsing, title: .stSearchSort, keywords: "search sort popular date 搜索 排序 热门 时间"),
        .init(id: "searchExitConfirm", category: .browsing, title: .stSearchExitConfirm, description: .stSearchExitConfirmHint, keywords: "search exit back confirm 搜索 退出 返回 确认"),
        .init(id: "searchBookmarked", category: .browsing, title: .stFilterStarSearch, keywords: "search bookmarked hide 搜索 已收藏 去重"),
        .init(id: "synonymEnable", category: .browsing, title: .stSynonymEnable, keywords: "synonym dictionary 同义词 词典 别名"),
        .init(id: "synonymDictionary", category: .browsing, title: .stSynonymDict, keywords: "synonym dictionary import export 同义词 词典 管理"),

        // Viewer & details
        .init(id: "detailV3", category: .viewing, title: .stIllustDetailV3, keywords: "v3 immersive detail 新版 沉浸 详情"),
        .init(id: "fabOrder", category: .viewing, title: .stFabOrder, keywords: "fab download bookmark order 按钮 下载 收藏 顺序"),
        .init(id: "novelDirectReader", category: .viewing, title: .stNovelDirectReader, description: .stNovelDirectReaderHint, keywords: "novel direct reader detail 小说 直接 阅读器 详情"),
        .init(id: "transition", category: .viewing, title: .stTransformMode, keywords: "page transition animation 翻页 动画 过渡"),
        .init(id: "ugoiraRife", category: .viewing, title: .stUgoiraRife, description: .stUgoiraRifeHint, keywords: "ugoira rife ai frame interpolation 动图 插帧 补帧"),
        .init(id: "ugoiraAutoPlay", category: .viewing, title: .stUgoiraAutoPlay, keywords: "ugoira autoplay animated 动图 自动播放"),
        .init(id: "statusBar", category: .viewing, title: .stKeepStatusBar, keywords: "status bar fullscreen 状态栏 全屏 沉浸"),
        .init(id: "keepScreenOn", category: .viewing, title: .stKeepScreenOn, keywords: "screen awake 常亮 息屏"),
        .init(id: "customZoom", category: .viewing, title: .stCustomDoubleTapZoom, keywords: "double tap zoom 双击 放大 缩放"),
        .init(id: "zoomScale", category: .viewing, title: .stZoomScale, description: .stZoomScaleHint, keywords: "zoom scale 倍率 缩放 增量"),
        .init(id: "threeZoom", category: .viewing, title: .stThreeLevelZoom, description: .stThreeLevelZoomHint, keywords: "three level zoom 三级 缩放"),
        .init(id: "longPressReset", category: .viewing, title: .stLongPressReset, description: .stLongPressResetHint, keywords: "long press reset zoom 长按 复位 缩放"),

        // Bookmarks & actions
        .init(id: "privateBookmark", category: .bookmarks, title: .stPrivateStar, keywords: "private bookmark 私密 收藏 非公开"),
        .init(id: "privateFollow", category: .bookmarks, title: .stPrivateFollow, keywords: "private follow 私密 关注 悄悄关注"),
        .init(id: "hideBookmarkButton", category: .bookmarks, title: .stHideStarButton, keywords: "hide bookmark button 隐藏 收藏 按钮"),
        .init(id: "invalidBookmarks", category: .bookmarks, title: .stFilterInvalidBookmarks, keywords: "invalid deleted bookmark 失效 无效 收藏"),
        .init(id: "bookmarkMirror", category: .bookmarks, title: .settingsBookmarkMirror, keywords: "bookmark mirror library local offline 收藏库 镜像 本地 筛选"),
        .init(id: "selectAllTags", category: .bookmarks, title: .stSelectAllTags, keywords: "select all tags 全选 标签 收藏"),
        .init(id: "relatedAfterBookmark", category: .bookmarks, title: .stShowRelatedWhenStar, keywords: "related recommendation 相关 推荐 收藏"),
        .init(id: "followAfterBookmark", category: .bookmarks, title: .stAutoFollowAfterStar, keywords: "auto follow bookmark 自动关注 收藏"),
        .init(id: "downloadAfterBookmark", category: .bookmarks, title: .stAutoDownloadAfterStar, keywords: "auto download bookmark 自动下载 收藏"),
        .init(id: "bookmarkAfterDownload", category: .bookmarks, title: .stAutoLikeWhenDownload, keywords: "auto bookmark download 自动收藏 下载"),

        // Download
        .init(id: "storage", category: .download, title: .stStorageChoice, keywords: "storage folder pictures downloads 存储 保存 目录"),
        .init(id: "filename", category: .download, title: .stCustomFileName, description: .stTapToSet, keywords: "filename path template 文件名 路径 模板"),
        .init(id: "overwrite", category: .download, title: .stOverwritePolicy, keywords: "duplicate overwrite rename 同名 覆盖 重命名"),
        .init(id: "pageIndex", category: .download, title: .stPageIndex, keywords: "page index p0 p1 页码 序号"),
        .init(id: "imageResolution", category: .download, title: .stImageResolution, keywords: "resolution original image 清晰度 原图 画质"),
        .init(id: "writeExif", category: .download, title: .stWriteExif, description: .stWriteExifHint, keywords: "exif xmp jpeg tag metadata 图片 标签 元数据"),
        .init(id: "novelFormat", category: .download, title: .stNovelFormat, keywords: "novel txt markdown epub pdf 小说 格式 导出"),
        .init(id: "novelHeader", category: .download, title: .stNovelHeader, description: .stNovelHeaderDesc, keywords: "novel metadata header 小说 信息头 作者"),
        .init(id: "downloadLimit", category: .download, title: .stDownloadLimitType, keywords: "wifi cellular network limit 流量 网络 限制"),
        .init(id: "concurrency", category: .download, title: .stMaxConcurrent, keywords: "concurrent parallel download 并发 同时 下载"),
        .init(id: "longPressDownload", category: .download, title: .stLongPressDownload, keywords: "long press download 长按 下载"),
        .init(id: "downloadNotice", category: .download, title: .stToastDownloadResult, keywords: "download complete notice 下载 完成 提示"),
        .init(id: "silentDownload", category: .download, title: .stSilentDownload, description: .stSilentDownloadHint, keywords: "silent download photo date gallery 静默 下载 相册 日期"),
        .init(id: "aria2", category: .download, title: .stAria2Title, description: .stAria2Desc, keywords: "aria2 rpc nas remote 远程 下载"),

        // AI
        .init(id: "upscale", category: .ai, title: .stUpscaleModel, keywords: "upscale waifu2x esrgan 超分 放大 修复"),
        .init(id: "removeBackground", category: .ai, title: .stRembgModel, keywords: "remove background rembg 抠图 去背景"),
        .init(id: "rifeModel", category: .ai, title: .stRifeModel, keywords: "rife model frame interpolation 插帧 模型"),
        .init(id: "bubbleDetector", category: .ai, title: .stBubbleModel, keywords: "bubble detector manga 气泡 检测 漫画"),
        .init(id: "ocr", category: .ai, title: .stOcrModel, keywords: "ocr text recognition 文字 识别 漫画"),
        .init(id: "aiTranslate", category: .ai, title: .stAITranslate, description: .stAITranslateHint, keywords: "openai translation api comment manga AI 翻译 评论 漫画"),

        // Data
        .init(id: "backup", category: .data, title: .stBackup, keywords: "backup export 备份 导出"),
        .init(id: "restore", category: .data, title: .stRestore, keywords: "restore import 恢复 还原 导入"),
        .init(id: "cloudUpload", category: .data, title: .stMoonUpload, keywords: "cloud upload sync 云端 上传 同步"),
        .init(id: "cloudSync", category: .data, title: .stMoonSync, keywords: "cloud download sync 云端 下载 同步"),
        .init(id: "imageCache", category: .data, title: .stClearImageCache, keywords: "image cache storage 图片 缓存 清理"),
        .init(id: "gifCache", category: .data, title: .stClearGifCache, keywords: "gif ugoira cache 动图 缓存 清理"),
        .init(id: "bulkCache", category: .data, title: .stClearBulkData, keywords: "bulk download cache 批量 下载 缓存"),

        // Experimental
        .init(id: "chatBanner", category: .experimental, title: .stChatRoomPushBanner, keywords: "chat push banner 聊天 消息 横幅"),
        .init(id: "analytics", category: .experimental, title: .stFirebase, keywords: "firebase analytics telemetry privacy 分析 统计 隐私"),
    ]

    static func entries(in category: SettingsCategory) -> [SettingsCatalogEntry] {
        entries.filter { $0.category == category }
    }

    static func search(
        _ query: String,
        localized: (LocalizedKey) -> String
    ) -> [SettingsCatalogEntry] {
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        return entries.enumerated().compactMap { index, entry -> (SettingsCatalogEntry, Int, Int)? in
            let title = localized(entry.title)
            let description = entry.description.map(localized) ?? ""
            let category = localized(entry.category.titleKey)
            let haystack = "\(title) \(description) \(category) \(entry.keywords)"
            guard tokens.allSatisfy({ haystack.localizedCaseInsensitiveContains($0) }) else { return nil }
            let rank: Int
            if tokens.allSatisfy({ title.localizedCaseInsensitiveContains($0) }) {
                rank = 0
            } else if tokens.allSatisfy({
                title.localizedCaseInsensitiveContains($0) || description.localizedCaseInsensitiveContains($0)
            }) {
                rank = 1
            } else {
                rank = 2
            }
            return (entry, rank, index)
        }
        .sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.2 < rhs.2 : lhs.1 < rhs.1 }
        .prefix(30)
        .map(\.0)
    }
}

// MARK: - Settings hub

/// Port of Android's redesigned settings hub: ten category cards, item
/// previews and full-catalog search. Search results open the right category,
/// scroll to the matched row and briefly tint it.
struct SettingsView: View {
    let auth: AuthViewModel
    @Environment(OnboardingStore.self) private var l10n
    @State private var query = ""

    var body: some View {
        // Cache the search once per render. Referencing a computed result from
        // every row would otherwise rescan/localize all 92 entries repeatedly.
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchResults: [SettingsCatalogEntry] = trimmedQuery.isEmpty
            ? []
            : SettingsCatalog.search(trimmedQuery) { l10n.t($0) }

        ScrollView {
            LazyVStack(spacing: 2) {
                SettingsSearchField(text: $query, placeholder: l10n.t(.settingsSearchHint))
                    .padding(.bottom, 10)

                if trimmedQuery.isEmpty {
                    LazyVStack(spacing: 0) {
                        ForEach(SettingsCategory.allCases) { category in
                            NavigationLink {
                                SettingsCategoryView(category: category, auth: auth)
                            } label: {
                                SettingsCategoryRow(
                                    icon: category.icon,
                                    title: l10n.t(category.titleKey),
                                    subtitle: subtitle(for: category),
                                    showsDivider: category != SettingsCategory.allCases.last
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(Theme.v3Surface, in: .rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.v3Border, lineWidth: 0.5))
                } else if searchResults.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(Theme.v3Text3)
                        Text(l10n.t(.settingsSearchEmpty))
                            .font(.subheadline)
                            .foregroundStyle(Theme.v3Text2)
                    }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(searchResults.enumerated()), id: \.element.id) { index, entry in
                            NavigationLink {
                                SettingsCategoryView(category: entry.category, auth: auth, highlightID: entry.id)
                            } label: {
                                SettingsSearchResultRow(
                                    title: l10n.t(entry.title),
                                    path: searchPath(for: entry),
                                    showsDivider: index < searchResults.count - 1
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(Theme.v3Surface, in: .rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.v3Border, lineWidth: 0.5))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(Theme.v3Bg)
        .navigationTitle(l10n.t(.settingsTitle))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func subtitle(for category: SettingsCategory) -> String {
        let separator = ["zh", "ja"].contains { l10n.activeTag.hasPrefix($0) } ? "、" : ", "
        return SettingsCatalog.entries(in: category)
            .prefix(4)
            .map { l10n.t($0.title) }
            .joined(separator: separator)
    }

    private func searchPath(for entry: SettingsCatalogEntry) -> String {
        var path = l10n.t(entry.category.titleKey)
        if let description = entry.description {
            path += " · \(l10n.t(description))"
        }
        return path
    }
}

private struct SettingsSearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.v3Text3)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.v3Text3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Theme.v3Surface, in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.v3Border, lineWidth: 0.5))
    }
}

private struct SettingsCategoryRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let showsDivider: Bool

    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 42, height: 42)
                .background(Theme.brand.opacity(0.14), in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.v3Text1)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.v3Text2)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.v3Text3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(minHeight: 72)
        .contentShape(.rect)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle().fill(Theme.v3Border).frame(height: 0.5).padding(.leading, 70)
            }
        }
    }
}

private struct SettingsSearchResultRow: View {
    let title: String
    let path: String
    let showsDivider: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15)).foregroundStyle(Theme.v3Text1)
                Text(path).font(.system(size: 12.5)).foregroundStyle(Theme.v3Text2).lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.v3Text3)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minHeight: 60)
        .contentShape(.rect)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle().fill(Theme.v3Border).frame(height: 0.5).padding(.leading, 18)
            }
        }
    }
}

// MARK: - Category pages

private struct SettingsCategoryView: View {
    let category: SettingsCategory
    let auth: AuthViewModel
    let requestedHighlightID: String?

    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.openURL) private var openURL
    @State private var st = AppSettingsStore.shared
    @State private var mute = MuteStore.shared
    @State private var showLogoutDialog = false
    @State private var showNotAvailable = false
    @State private var showImageHostPicker = false
    @State private var showCustomImageHost = false
    @State private var showImageHostEmpty = false
    @State private var showImageHostRestart = false
    @State private var customImageHostDraft = ""
    @State private var highlightID: String?

    private static let r18SettingURL = URL(string: "https://www.pixiv.net/settings/viewing")!
    private static let premiumSettingURL = URL(string: "https://www.pixiv.net/premium.php#premium-payment")!
    private static let pixEzURL = URL(string: "https://github.com/Notsfsssf/Pix-EzViewer")!

    init(category: SettingsCategory, auth: AuthViewModel, highlightID: String? = nil) {
        self.category = category
        self.auth = auth
        self.requestedHighlightID = highlightID
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form { categoryContent }
                .scrollContentBackground(.hidden)
                .background(Theme.v3Bg)
                .task(id: requestedHighlightID) {
                    highlightID = nil
                    guard let id = requestedHighlightID, isInitiallyVisible(id) else { return }
                    // Wait for Form/List to materialize and measure its rows. The
                    // structured task is cancelled if the user backs out first.
                    try? await Task.sleep(for: .milliseconds(220))
                    guard !Task.isCancelled else { return }
                    highlightID = id
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                    try? await Task.sleep(for: .seconds(1.4))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.35)) { highlightID = nil }
                }
        }
        .navigationTitle(l10n.t(category.titleKey))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(l10n.t(.stLogoutConfirmTitle), isPresented: $showLogoutDialog, titleVisibility: .visible) {
            // iOS currently has one keychain-backed account, so both upstream
            // choices converge on clearing that account and returning to login.
            Button(l10n.t(.stDeleteAccountInfo), role: .destructive) { auth.logout() }
            Button(l10n.t(.actionLogOut), role: .destructive) { auth.logout() }
            Button(l10n.t(.actionCancel), role: .cancel) {}
        }
        .alert(l10n.t(.stNotAvailable), isPresented: $showNotAvailable) {
            Button(l10n.t(.stSure), role: .cancel) {}
        }
        .confirmationDialog(l10n.t(.stImageHost), isPresented: $showImageHostPicker,
                            titleVisibility: .visible) {
            ForEach(ImageHostMode.allCases, id: \.rawValue) { mode in
                Button(imageHostOptionTitle(mode)) {
                    if mode == .custom {
                        customImageHostDraft = st.customImageHost
                        showCustomImageHost = true
                    } else {
                        applyImageHostMode(mode)
                    }
                }
            }
            Button(l10n.t(.actionCancel), role: .cancel) {}
        }
        .alert(l10n.t(.stImageHostCustom), isPresented: $showCustomImageHost) {
            TextField(l10n.t(.stImageHostCustomHint), text: $customImageHostDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button(l10n.t(.actionCancel), role: .cancel) {}
            Button(l10n.t(.stSure)) { applyCustomImageHost() }
        } message: {
            Text(l10n.t(.stImageHostCustomHint))
        }
        .alert(l10n.t(.stImageHostCustom), isPresented: $showImageHostEmpty) {
            Button(l10n.t(.stSure), role: .cancel) {}
        } message: {
            Text(l10n.t(.stImageHostCustomEmpty))
        }
        .alert(l10n.t(.stImageHost), isPresented: $showImageHostRestart) {
            Button(l10n.t(.stSure), role: .cancel) {}
        } message: {
            Text(l10n.t(.stImageHostRestartHint))
        }
    }

    /// Mirrors Android `maybeHighlight`: a search result whose row is hidden
    /// by a parent switch opens the category normally and is not highlighted.
    /// Consuming this decision once also prevents a later toggle/scroll from
    /// replaying the flash.
    private func isInitiallyVisible(_ id: String) -> Bool {
        switch id {
        case "secureDNS": return st.directConnect
        case "synonymDictionary": return st.synonymDictEnabled
        case "fabOrder": return st.useArtworkV3
        case "zoomScale", "threeZoom", "longPressReset": return st.useCustomDoubleTapZoom
        default: return true
        }
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch category {
        case .account: accountContent
        case .network: networkContent
        case .appearance: appearanceContent
        case .browsing: browsingContent
        case .viewing: viewingContent
        case .bookmarks: bookmarksContent
        case .download: downloadContent
        case .ai: aiContent
        case .data: dataContent
        case .experimental: experimentalContent
        }
    }

    @ViewBuilder private var accountContent: some View {
        Section {
            subPageRow(l10n.t(.stAccountManage)).settingRow("accountManage", highlightID)
            subPageRow(l10n.t(.stEditAccount)).settingRow("editAccount", highlightID)
            subPageRow(l10n.t(.stEmailBackup)).settingRow("emailBackup", highlightID)
            subPageRow(l10n.t(.stEditProfile)).settingRow("editProfile", highlightID)
            subPageRow(l10n.t(.stWorkspace)).settingRow("workspace", highlightID)
            actionRow(l10n.t(.stR18Setting)) { openURL(Self.r18SettingURL) }.settingRow("r18Setting", highlightID)
            actionRow(l10n.t(.stPremiumSetting)) { openURL(Self.premiumSettingURL) }.settingRow("premium", highlightID)
        }
        Section {
            actionRow(l10n.t(.actionLogOut)) { showLogoutDialog = true }.settingRow("logout", highlightID)
        }
    }

    @ViewBuilder private var networkContent: some View {
        Section {
            Toggle(isOn: $st.directConnect) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.t(.stDirectConnect))
                    Button { openURL(Self.pixEzURL) } label: {
                        Text(l10n.t(.stSeePixEz)).font(.caption).foregroundStyle(Theme.brand)
                    }
                    .buttonStyle(.plain)
                }
            }
            .settingRow("directConnect", highlightID)
            if st.directConnect {
                hintToggle(l10n.t(.stSecureDns), l10n.t(.stSecureDnsHint), isOn: $st.useSecureDns)
                    .settingRow("secureDNS", highlightID)
            }
            actionRow(l10n.t(.stImageHost), value: imageHostSummary) { showImageHostPicker = true }
                .settingRow("imageHost", highlightID)
        }
        Section {
            hintToggle(l10n.t(.stLargeThumbnail), l10n.t(.stOriginalHint), isOn: $st.showLargeThumbnailImage)
                .settingRow("largeThumbnail", highlightID)
            hintToggle(l10n.t(.stShowOriginalPreview), l10n.t(.stOriginalHint), isOn: $st.showOriginalPreviewImage)
                .settingRow("originalPreview", highlightID)
        }
    }

    @ViewBuilder private var appearanceContent: some View {
        Section {
            pickerRow(l10n.t(.stThemeMode), selection: $st.themeType, options: [
                l10n.t(.stOptThemeSystem), l10n.t(.stOptThemeLight), l10n.t(.stOptThemeDark),
            ]).settingRow("themeMode", highlightID)
            subPageRow(l10n.t(.stThemeColor)).settingRow("themeColor", highlightID)
            Picker(l10n.t(.settingsLanguage), selection: Binding(
                get: { l10n.chosenTag ?? "system" },
                set: { tag in
                    if tag == "system" {
                        l10n.chosenTag = nil
                    } else {
                        l10n.apply(tag: tag)
                    }
                }
            )) {
                Text(l10n.t(.stOptFollowSystem)).tag("system")
                ForEach(AppLocales.supportedTags, id: \.self) { tag in
                    Text(AppLocales.displayName(tag)).tag(tag)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.brand)
            .settingRow("language", highlightID)
        }
        Section {
            pickerRow(l10n.t(.stNavInitPosition), selection: $st.navigationInitPosition, options: navInitOptions)
                .settingRow("startPage", highlightID)
            pickerRow(l10n.t(.stBottomBarOrder), selection: $st.bottomBarOrder, options: bottomOrderOptions)
                .settingRow("tabOrder", highlightID)
            Toggle(l10n.t(.stMainViewR18), isOn: $st.mainViewR18).settingRow("homeR18", highlightID)
        }
        Section {
            Picker(l10n.t(.stLineCount), selection: Binding(
                get: { mute.waterfallColumns }, set: { mute.setWaterfallColumns($0) }
            )) {
                ForEach(2...4, id: \.self) { n in Text(l10n.t(.stOptColumnsFmt, "\(n)")).tag(n) }
            }
            .pickerStyle(.menu)
            .tint(Theme.brand)
            .settingRow("columns", highlightID)
            pickerRow(l10n.t(.stLayoutMode), selection: Binding(
                get: { st.useStaggeredLayout ? 0 : 1 }, set: { st.useStaggeredLayout = $0 == 0 }
            ), options: [l10n.t(.stOptStaggered), l10n.t(.stOptLinear)])
            .settingRow("layoutMode", highlightID)
            Toggle(l10n.t(.stShowNovelTags), isOn: $st.showNovelCardTags).settingRow("novelTags", highlightID)
            // Present on Android's category page but intentionally absent from
            // its SettingsCatalog, so it is likewise not searchable here.
            Toggle(l10n.t(.stCollapseNovelTags), isOn: $st.collapseNovelCardTags)
                .listRowBackground(Theme.v3Surface)
        }
        Section {
            actionRow(l10n.t(.stWidgetRefreshInterval), value: l10n.t(.stNotAvailable)) { showNotAvailable = true }
                .settingRow("widgetRefresh", highlightID)
        }
    }

    @ViewBuilder private var browsingContent: some View {
        Section {
            actionRow(
                l10n.t(.stAutoRefreshHome),
                hint: l10n.t(.stAutoRefreshHomeHint),
                value: l10n.t(.stNotAvailable)
            ) { showNotAvailable = true }
            .settingRow("autoRefreshHome", highlightID)
        }
        Section {
            Toggle(l10n.t(.stSaveViewHistory), isOn: $st.saveViewHistory).settingRow("saveHistory", highlightID)
            Toggle(l10n.t(.stCloudHistorySync), isOn: $st.cloudHistorySync).settingRow("cloudHistory", highlightID)
            actionRow(l10n.t(.stClearCloudHistory)) { showNotAvailable = true }.settingRow("clearCloudHistory", highlightID)
        }
        Section {
            Toggle(l10n.t(.stFilterComment), isOn: $st.filterComment).settingRow("filterComments", highlightID)
            hintToggle(l10n.t(.stR18DefaultFilter), l10n.t(.stR18DefaultFilterHint), isOn: Binding(
                get: { mute.hideR18 }, set: { mute.setHideR18($0) }
            )).settingRow("filterR18", highlightID)
            Toggle(l10n.t(.stDeleteAIIllust), isOn: $st.deleteAIIllust).settingRow("hideAI", highlightID)
            Toggle(l10n.t(.stFilterRankBookmarked), isOn: $st.filterRankBookmarked).settingRow("rankBookmarked", highlightID)
        }
        Section {
            actionRow(l10n.t(.stNovelMinLength), hint: l10n.t(.stNovelMinLengthHint), value: l10n.t(.stNotAvailable)) { showNotAvailable = true }
                .settingRow("novelMinLength", highlightID)
            actionRow(l10n.t(.stNovelMaxLength), hint: l10n.t(.stNovelMaxLengthHint), value: l10n.t(.stNotAvailable)) { showNotAvailable = true }
                .settingRow("novelMaxLength", highlightID)
            actionRow(l10n.t(.stNovelMaxTagLength), hint: l10n.t(.stNovelMaxTagLengthHint), value: l10n.t(.stNotAvailable)) { showNotAvailable = true }
                .settingRow("novelMaxTagLength", highlightID)
        }
        Section {
            pickerRow(l10n.t(.stSearchFilter), selection: $st.searchFilterIndex, options: searchFilterOptions)
                .settingRow("searchFilter", highlightID)
            pickerRow(l10n.t(.stSearchSort), selection: $st.searchSortIndex, options: searchSortOptions)
                .settingRow("searchSort", highlightID)
            actionRow(l10n.t(.stSearchExitConfirm), hint: l10n.t(.stSearchExitConfirmHint), value: l10n.t(.stNotAvailable)) { showNotAvailable = true }
                .settingRow("searchExitConfirm", highlightID)
            Toggle(l10n.t(.stFilterStarSearch), isOn: $st.deleteStarIllust).settingRow("searchBookmarked", highlightID)
        }
        Section {
            Toggle(l10n.t(.stSynonymEnable), isOn: $st.synonymDictEnabled).settingRow("synonymEnable", highlightID)
            if st.synonymDictEnabled {
                subPageRow(l10n.t(.stSynonymDict)).settingRow("synonymDictionary", highlightID)
            }
        }
    }

    @ViewBuilder private var viewingContent: some View {
        Section {
            Toggle(l10n.t(.stIllustDetailV3), isOn: $st.useArtworkV3).settingRow("detailV3", highlightID)
            if st.useArtworkV3 {
                pickerRow(l10n.t(.stFabOrder), selection: Binding(
                    get: { st.artworkV3FabDownloadOnLeft ? 0 : 1 },
                    set: { st.artworkV3FabDownloadOnLeft = $0 == 0 }
                ), options: [l10n.t(.stOptFabDownloadLeft), l10n.t(.stOptFabBookmarkLeft)])
                .settingRow("fabOrder", highlightID)
                Toggle(l10n.t(.stCommentJumpButton), isOn: $st.artworkV3ShowCommentJumpFab)
                    .listRowBackground(Theme.v3Surface)
                Toggle(l10n.t(.artworkV3DetailPanelCollapsed), isOn: $st.detailPanelCollapsedByDefault)
                    .listRowBackground(Theme.v3Surface)
            }
            actionRow(l10n.t(.stNovelDirectReader), hint: l10n.t(.stNovelDirectReaderHint), value: l10n.t(.stNotAvailable)) { showNotAvailable = true }
                .settingRow("novelDirectReader", highlightID)
            pickerRow(l10n.t(.stTransformMode), selection: $st.transformerIndex, options: AppSettingsStore.transformerNames)
                .settingRow("transition", highlightID)
            actionRow(l10n.t(.stUgoiraRife), hint: l10n.t(.stUgoiraRifeHint), value: l10n.t(.stNotAvailable)) { showNotAvailable = true }
                .settingRow("ugoiraRife", highlightID)
            actionRow(l10n.t(.stUgoiraAutoPlay), value: l10n.t(.stNotAvailable)) { showNotAvailable = true }
                .settingRow("ugoiraAutoPlay", highlightID)
            Toggle(l10n.t(.stKeepStatusBar), isOn: $st.keepStatusBarWhenViewImage).settingRow("statusBar", highlightID)
            Toggle(l10n.t(.stKeepScreenOn), isOn: $st.illustDetailKeepScreenOn).settingRow("keepScreenOn", highlightID)
            Toggle(l10n.t(.stCustomDoubleTapZoom), isOn: $st.useCustomDoubleTapZoom).settingRow("customZoom", highlightID)
        }
        if st.useCustomDoubleTapZoom {
            Section {
                zoomScaleRow.settingRow("zoomScale", highlightID)
                hintToggle(l10n.t(.stThreeLevelZoom), l10n.t(.stThreeLevelZoomHint), isOn: $st.useThreeLevelZoom)
                    .settingRow("threeZoom", highlightID)
                hintToggle(l10n.t(.stLongPressReset), l10n.t(.stLongPressResetHint), isOn: $st.useCustomLongPressReset)
                    .settingRow("longPressReset", highlightID)
            }
        }
    }

    private var bookmarksContent: some View {
        Section {
            Toggle(l10n.t(.stPrivateStar), isOn: $st.privateStar).settingRow("privateBookmark", highlightID)
            Toggle(l10n.t(.stPrivateFollow), isOn: $st.privateFollow).settingRow("privateFollow", highlightID)
            Toggle(l10n.t(.stHideStarButton), isOn: $st.hideStarButtonAtMyCollection).settingRow("hideBookmarkButton", highlightID)
            Toggle(l10n.t(.stFilterInvalidBookmarks), isOn: $st.filterInvalidBookmarks).settingRow("invalidBookmarks", highlightID)
            // 收藏库本地镜像。开回来时主动踢一脚引擎，用户不用等下一个空闲心跳。
            Toggle(l10n.t(.settingsBookmarkMirror), isOn: $st.bookmarkMirrorEnabled)
                .settingRow("bookmarkMirror", highlightID)
                .onChange(of: st.bookmarkMirrorEnabled) { _, enabled in
                    if enabled { BookmarkMirrorService.shared.kick("settings toggled on") }
                }
            Toggle(l10n.t(.stSelectAllTags), isOn: $st.starWithTagSelectAll).settingRow("selectAllTags", highlightID)
            Toggle(l10n.t(.stShowRelatedWhenStar), isOn: $st.showRelatedWhenStar).settingRow("relatedAfterBookmark", highlightID)
            Toggle(l10n.t(.stAutoFollowAfterStar), isOn: $st.autoFollowAfterStar).settingRow("followAfterBookmark", highlightID)
            Toggle(l10n.t(.stAutoDownloadAfterStar), isOn: $st.autoDownloadAfterStar).settingRow("downloadAfterBookmark", highlightID)
            Toggle(l10n.t(.stAutoLikeWhenDownload), isOn: $st.autoPostLikeWhenDownload).settingRow("bookmarkAfterDownload", highlightID)
        }
    }

    @ViewBuilder private var downloadContent: some View {
        Section {
            pickerRow(l10n.t(.stStorageChoice), selection: $st.storageChoice, options: [
                l10n.t(.stOptStoragePictures), l10n.t(.stOptStorageDownloads), l10n.t(.stOptStorageSaf),
            ]).settingRow("storage", highlightID)
            subPageRow(l10n.t(.stCustomFileName), hint: l10n.t(.stTapToSet)).settingRow("filename", highlightID)
            pickerRow(l10n.t(.stOverwritePolicy), selection: $st.overwritePolicy, options: [
                l10n.t(.stOptPolicySkip), l10n.t(.stOptPolicyReplace), l10n.t(.stOptPolicyRename),
            ]).settingRow("overwrite", highlightID)
            pickerRow(l10n.t(.stPageIndex), selection: Binding(
                get: { st.pageIndexFrom1 ? 1 : 0 }, set: { st.pageIndexFrom1 = $0 == 1 }
            ), options: [l10n.t(.stOptPageFrom0), l10n.t(.stOptPageFrom1)])
            .settingRow("pageIndex", highlightID)
        }
        Section {
            pickerRow(l10n.t(.stImageResolution), selection: $st.defaultImageResolutionIndex, options: [
                l10n.t(.stOptResOriginal), l10n.t(.stOptResLarge), l10n.t(.stOptResMedium), l10n.t(.stOptResSquareMedium),
            ]).settingRow("imageResolution", highlightID)
            actionRow(l10n.t(.stWriteExif), hint: l10n.t(.stWriteExifHint), value: l10n.t(.stNotAvailable)) { showNotAvailable = true }
                .settingRow("writeExif", highlightID)
            pickerRow(l10n.t(.stNovelFormat), selection: $st.defaultNovelFormatIndex, options: [
                l10n.t(.stOptAlwaysAsk), l10n.t(.stOptFormatTxt), "Markdown", l10n.t(.stOptFormatEpub), "PDF",
            ]).settingRow("novelFormat", highlightID)
            subPageRow(l10n.t(.stNovelHeader), hint: l10n.t(.stNovelHeaderDesc)).settingRow("novelHeader", highlightID)
        }
        Section {
            pickerRow(l10n.t(.stDownloadLimitType), selection: $st.downloadLimitType, options: [
                l10n.t(.stOptNoLimit), l10n.t(.stOptWifiOnly), l10n.t(.stOptNoAutoDownload),
            ]).settingRow("downloadLimit", highlightID)
            pickerRow(l10n.t(.stMaxConcurrent), selection: Binding(
                get: { st.maxConcurrentDownloads - 1 }, set: { st.maxConcurrentDownloads = $0 + 1 }
            ), options: concurrentOptions).settingRow("concurrency", highlightID)
            Toggle(l10n.t(.stLongPressDownload), isOn: $st.illustLongPressDownload).settingRow("longPressDownload", highlightID)
            Toggle(l10n.t(.stToastDownloadResult), isOn: $st.toastDownloadResult).settingRow("downloadNotice", highlightID)
            actionRow(l10n.t(.stSilentDownload), hint: l10n.t(.stSilentDownloadHint), value: l10n.t(.stNotAvailable)) { showNotAvailable = true }
                .settingRow("silentDownload", highlightID)
        }
        Section {
            subPageRow(l10n.t(.stAria2Title), hint: l10n.t(.stAria2Desc)).settingRow("aria2", highlightID)
        }
    }

    private var aiContent: some View {
        Section {
            actionRow(l10n.t(.stUpscaleModel), value: l10n.t(.stNotSet)) { showNotAvailable = true }
                .settingRow("upscale", highlightID)
            actionRow(l10n.t(.stRembgModel), value: l10n.t(.stNotSet)) { showNotAvailable = true }
                .settingRow("removeBackground", highlightID)
            actionRow(l10n.t(.stRifeModel), value: l10n.t(.stNotAvailable)) { showNotAvailable = true }
                .settingRow("rifeModel", highlightID)
            actionRow(l10n.t(.stBubbleModel), value: l10n.t(.stModelNotReadyFmt, "57MB")) { showNotAvailable = true }
                .settingRow("bubbleDetector", highlightID)
            actionRow(l10n.t(.stOcrModel), value: l10n.t(.stModelNotReadyFmt, "91MB")) { showNotAvailable = true }
                .settingRow("ocr", highlightID)
            actionRow(l10n.t(.stAITranslate), hint: l10n.t(.stAITranslateHint), value: l10n.t(.stNotAvailable)) { showNotAvailable = true }
                .settingRow("aiTranslate", highlightID)
        }
    }

    @ViewBuilder private var dataContent: some View {
        Section {
            actionRow(l10n.t(.stBackup)) { showNotAvailable = true }.settingRow("backup", highlightID)
            actionRow(l10n.t(.stRestore)) { showNotAvailable = true }.settingRow("restore", highlightID)
            actionRow(l10n.t(.stMoonUpload)) { showNotAvailable = true }.settingRow("cloudUpload", highlightID)
            actionRow(l10n.t(.stMoonSync)) { showNotAvailable = true }.settingRow("cloudSync", highlightID)
        }
        Section {
            actionRow(l10n.t(.stClearImageCache), value: "0.00MB") { showNotAvailable = true }
                .settingRow("imageCache", highlightID)
            actionRow(l10n.t(.stClearGifCache), value: "0.00MB") { showNotAvailable = true }
                .settingRow("gifCache", highlightID)
            actionRow(l10n.t(.stClearBulkData), value: "0.00MB") { showNotAvailable = true }
                .settingRow("bulkCache", highlightID)
        }
    }

    @ViewBuilder private var experimentalContent: some View {
        Section {
            Toggle(l10n.t(.stChatRoomPushBanner), isOn: $st.showChatRoomPushBanner)
                .settingRow("chatBanner", highlightID)
        }
        Section {
            Toggle(l10n.t(.stFirebase), isOn: $st.isFirebaseEnable).settingRow("analytics", highlightID)
        }
    }

    private var zoomScaleRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(l10n.t(.stZoomScale))
                Spacer()
                Button { st.customZoomAddScale = max(1.1, (st.customZoomAddScale * 10 - 1).rounded() / 10) } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                Text(String(format: "%.1f", st.customZoomAddScale))
                    .font(.headline).foregroundStyle(Theme.brand).frame(minWidth: 36)
                Button { st.customZoomAddScale = min(3.0, (st.customZoomAddScale * 10 + 1).rounded() / 10) } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
            }
            Text(l10n.t(.stZoomScaleHint)).font(.caption).foregroundStyle(Theme.brand)
        }
    }

    private var searchFilterOptions: [String] {
        [l10n.t(.stOptNoLimit)] + ["500", "1000", "2000", "5000", "7500", "10000", "20000", "50000", "100000"]
            .map { l10n.t(.stOptBookmarksOverFmt, $0) }
    }

    private var searchSortOptions: [String] {
        [
            l10n.t(.sortPopularPreview),
            l10n.t(.searchSortDateDesc),
            l10n.t(.searchSortDateAsc),
            l10n.t(.searchSortPopular),
            l10n.t(.sortPopularMale),
            l10n.t(.sortPopularFemale),
        ]
    }

    private var bottomOrderOptions: [String] {
        let r = l10n.t(.tabRecommend), d = l10n.t(.tabDiscover), w = l10n.t(.tabWhatsNew)
        return ["\(r) - \(d) - \(w)", "\(r) - \(w) - \(d)", "\(d) - \(r) - \(w)",
                "\(d) - \(w) - \(r)", "\(w) - \(r) - \(d)", "\(w) - \(d) - \(r)"]
    }

    private var navInitOptions: [String] {
        [l10n.t(.stOptNavLastClosed), l10n.t(.tabRecommend), l10n.t(.tabDiscover), l10n.t(.tabWhatsNew), "R"]
    }

    private var concurrentOptions: [String] {
        [l10n.t(.stOptSerialOne)] + (2...5).map { l10n.t(.stOptConcurrentFmt, "\($0)") }
    }

    private func pickerRow(_ title: String, selection: Binding<Int>, options: [String]) -> some View {
        Picker(title, selection: selection) {
            ForEach(options.indices, id: \.self) { i in Text(options[i]).tag(i) }
        }
        .pickerStyle(.menu)
        .tint(Theme.brand)
    }

    private func hintToggle(
        _ title: String,
        _ hint: String,
        isOn: Binding<Bool>,
        hintColor: Color = Theme.brand
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(hint).font(.caption).foregroundStyle(hintColor)
            }
        }
    }

    private func subPageRow(_ title: String, hint: String? = nil) -> some View {
        NavigationLink(value: AppRoute.settingsSub(title: title)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let hint { Text(hint).font(.caption).foregroundStyle(Theme.brand) }
            }
        }
    }

    private func actionRow(
        _ title: String,
        hint: String? = nil,
        value: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let hint { Text(hint).font(.caption).foregroundStyle(Theme.brand) }
                }
                Spacer()
                if let value {
                    Text(value)
                        .foregroundStyle(Theme.brand)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var imageHostSummary: String {
        switch ImageHostMode(rawValue: st.imageHostMode) ?? .pixiv {
        case .pixiv: return l10n.t(.stImageHostOfficial)
        case .pixivCat: return l10n.t(.stImageHostPixivCat)
        case .pixivRe: return l10n.t(.stImageHostPixivRe)
        case .pixivNl: return l10n.t(.stImageHostPixivNl)
        case .custom:
            return st.customImageHost.isEmpty ? l10n.t(.stImageHostCustom) : st.customImageHost
        }
    }

    private func imageHostOptionTitle(_ mode: ImageHostMode) -> String {
        let title: String
        switch mode {
        case .pixiv: title = l10n.t(.stImageHostOfficial)
        case .pixivCat: title = l10n.t(.stImageHostPixivCat)
        case .pixivRe: title = l10n.t(.stImageHostPixivRe)
        case .pixivNl: title = l10n.t(.stImageHostPixivNl)
        case .custom: title = l10n.t(.stImageHostCustom)
        }
        return mode.rawValue == st.imageHostMode ? "✓ \(title)" : title
    }

    private func applyImageHostMode(_ mode: ImageHostMode) {
        st.imageHostMode = mode.rawValue
        showImageHostRestart = true
    }

    private func applyCustomImageHost() {
        let host = ImageHostManager.normalizeCustomHost(customImageHostDraft)
        guard !host.isEmpty else {
            showImageHostEmpty = true
            return
        }
        st.customImageHost = host
        st.imageHostMode = ImageHostMode.custom.rawValue
        showImageHostRestart = true
    }
}

// MARK: - Search destination highlight

private struct SettingsRowModifier: ViewModifier {
    let id: String
    let highlightedID: String?

    func body(content: Content) -> some View {
        content
            .id(id)
            .listRowBackground(id == highlightedID ? Theme.brand.opacity(0.20) : Theme.v3Surface)
    }
}

private extension View {
    func settingRow(_ id: String, _ highlightedID: String?) -> some View {
        modifier(SettingsRowModifier(id: id, highlightedID: highlightedID))
    }
}
