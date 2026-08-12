import Foundation
import Observation

/// Backing state for the Settings page — a 1:1 port of Pixiv-Shaft's
/// `Settings.java` fields (classic branch). Every key keeps the upstream
/// SharedPreferences field name with an `st_` prefix and the same default,
/// so the page renders exactly like Android. Most values are stored-only for
/// now: the page UI is the port target; feature wiring comes later.
@MainActor
@Observable
final class AppSettingsStore {
    static let shared = AppSettingsStore()

    @ObservationIgnored private let defaults = UserDefaults.standard

    // MARK: Network (网络)
    var directConnect = false { didSet { save(directConnect, "st_directConnect") } }
    var useSecureDns = true { didSet { save(useSecureDns, "st_useSecureDns") } }
    var showLargeThumbnailImage = false { didSet { save(showLargeThumbnailImage, "st_showLargeThumbnailImage") } }
    var showOriginalPreviewImage = false { didSet { save(showOriginalPreviewImage, "st_showOriginalPreviewImage") } }

    // MARK: General (常规)
    var saveViewHistory = true { didSet { save(saveViewHistory, "st_saveViewHistory") } }
    var cloudHistorySync = true { didSet { save(cloudHistorySync, "st_cloudHistorySync") } }
    var deleteStarIllust = false { didSet { save(deleteStarIllust, "st_deleteStarIllust") } }
    var filterRankBookmarked = true { didSet { save(filterRankBookmarked, "st_filterRankBookmarked") } }
    var filterInvalidBookmarks = false { didSet { save(filterInvalidBookmarks, "st_filterInvalidBookmarks") } }
    var deleteAIIllust = false { didSet { save(deleteAIIllust, "st_deleteAIIllust") } }
    var toastDownloadResult = true { didSet { save(toastDownloadResult, "st_toastDownloadResult") } }
    /// 0 = 无限制, 1…9 = 500/1000/2000/5000/7500/10000/20000/50000/100000 人收藏
    var searchFilterIndex = 0 { didSet { save(searchFilterIndex, "st_searchFilter") } }
    /// 0 最新作品 / 1 由旧到新 / 2 热度排序 / 3 机内自带热度排序
    var searchSortIndex = 0 { didSet { save(searchSortIndex, "st_searchDefaultSortType") } }
    /// Permutations of 推荐/发现/动态 — string_343…348
    var bottomBarOrder = 0 { didSet { save(bottomBarOrder, "st_bottomBarOrder") } }
    var filterComment = false { didSet { save(filterComment, "st_filterComment") } }

    // MARK: Interface (界面)
    var mainViewR18 = false { didSet { save(mainViewR18, "st_mainViewR18") } }
    /// 0 上次关闭位置 / 1 推荐 / 2 发现 / 3 动态 / 4 R — upstream default TUIJIAN
    var navigationInitPosition = 1 { didSet { save(navigationInitPosition, "st_navigationInitPosition") } }
    var useFragmentIllust = true { didSet { save(useFragmentIllust, "st_useFragmentIllust") } }
    var useArtworkV3 = false { didSet { save(useArtworkV3, "st_useArtworkV3") } }
    var artworkV3FabDownloadOnLeft = true { didSet { save(artworkV3FabDownloadOnLeft, "st_artworkV3FabDownloadOnLeft") } }
    var artworkV3ShowCommentJumpFab = false { didSet { save(artworkV3ShowCommentJumpFab, "st_artworkV3ShowCommentJumpFab") } }
    /// 0 跟随系统 / 1 浅色 / 2 深色
    var themeType = 0 { didSet { save(themeType, "st_themeType") } }
    var useStaggeredLayout = true { didSet { save(useStaggeredLayout, "st_useStaggeredLayout") } }

    // MARK: Download (下载)
    /// 0 Pictures / 1 Downloads / 2 SAF
    var storageChoice = 0 { didSet { save(storageChoice, "st_storageChoice") } }
    /// 0 跳过 / 1 覆盖 / 2 重命名
    var overwritePolicy = 0 { didSet { save(overwritePolicy, "st_overwritePolicy") } }
    /// 0 每次询问 / 1 TXT / 2 Markdown / 3 EPUB / 4 PDF
    var defaultNovelFormatIndex = 0 { didSet { save(defaultNovelFormatIndex, "st_defaultNovelExportFormat") } }
    /// 0 原图 / 1 大图 / 2 中图 / 3 小图
    var defaultImageResolutionIndex = 0 { didSet { save(defaultImageResolutionIndex, "st_defaultImageResolution") } }
    var pageIndexFrom1 = false { didSet { save(pageIndexFrom1, "st_pageIndexFrom1") } }
    var illustLongPressDownload = false { didSet { save(illustLongPressDownload, "st_illustLongPressDownload") } }
    /// 0 无限制 / 1 仅 Wi-Fi / 2 不自动下载
    var downloadLimitType = 0 { didSet { save(downloadLimitType, "st_downloadLimitType") } }
    var maxConcurrentDownloads = 1 { didSet { save(maxConcurrentDownloads, "st_maxConcurrentDownloads") } }

    // MARK: Personalization (个性化)
    var privateStar = false { didSet { save(privateStar, "st_privateStar") } }
    var privateFollow = false { didSet { save(privateFollow, "st_privateFollow") } }
    var showNovelCardTags = true { didSet { save(showNovelCardTags, "st_showNovelCardTags") } }
    var collapseNovelCardTags = true { didSet { save(collapseNovelCardTags, "st_collapseNovelCardTags") } }
    var hideStarButtonAtMyCollection = false { didSet { save(hideStarButtonAtMyCollection, "st_hideStarButtonAtMyCollection") } }
    var starWithTagSelectAll = false { didSet { save(starWithTagSelectAll, "st_starWithTagSelectAll") } }
    var keepStatusBarWhenViewImage = false { didSet { save(keepStatusBarWhenViewImage, "st_keepStatusBarWhenViewImage") } }
    var synonymDictEnabled = false { didSet { save(synonymDictEnabled, "st_synonymDictEnabled") } }
    /// Index into `Self.transformerNames` — upstream default 5 (CubeOut, "3D盒子")
    var transformerIndex = 5 { didSet { save(transformerIndex, "st_transformerType") } }
    var showRelatedWhenStar = true { didSet { save(showRelatedWhenStar, "st_showRelatedWhenStar") } }
    var autoPostLikeWhenDownload = false { didSet { save(autoPostLikeWhenDownload, "st_autoPostLikeWhenDownload") } }
    var autoFollowAfterStar = false { didSet { save(autoFollowAfterStar, "st_autoFollowAfterStar") } }
    var autoDownloadAfterStar = false { didSet { save(autoDownloadAfterStar, "st_autoDownloadAfterStar") } }
    var illustDetailKeepScreenOn = false { didSet { save(illustDetailKeepScreenOn, "st_illustDetailKeepScreenOn") } }
    var useCustomDoubleTapZoom = false { didSet { save(useCustomDoubleTapZoom, "st_useCustomDoubleTapZoom") } }
    var customZoomAddScale = 1.8 { didSet { save(customZoomAddScale, "st_customZoomAddScale") } }
    var useThreeLevelZoom = false { didSet { save(useThreeLevelZoom, "st_useThreeLevelZoo") } }
    var useCustomLongPressReset = false { didSet { save(useCustomLongPressReset, "st_useCustomLongPressReset") } }
    var isFirebaseEnable = true { didSet { save(isFirebaseEnable, "st_isFirebaseEnable") } }

    // MARK: Experimental (试验性)
    var showChatRoomEntry = false { didSet { save(showChatRoomEntry, "st_showChatRoomEntry") } }
    var showChatRoomPushBanner = false { didSet { save(showChatRoomPushBanner, "st_showChatRoomPushBanner") } }
    var showPlazaEntry = false { didSet { save(showPlazaEntry, "st_showPlazaEntry") } }

    /// Upstream `PageTransformerHelper` derives these from the transformer
    /// class names — they are shown untranslated on Android too.
    static let transformerNames = [
        "Default", "Accordion", "BackgroundToForeground", "ForegroundToBackground",
        "CubeIn", "CubeOut", "DepthPage", "FlipHorizontal", "FlipVertical",
        "RotateDown", "RotateUp", "ScaleInOut", "ZoomOutSlide", "ZoomIn",
        "ZoomOut", "Stack", "Tablet", "Drawer",
    ]

    private init() {
        directConnect = bool("st_directConnect", false)
        useSecureDns = bool("st_useSecureDns", true)
        showLargeThumbnailImage = bool("st_showLargeThumbnailImage", false)
        showOriginalPreviewImage = bool("st_showOriginalPreviewImage", false)
        saveViewHistory = bool("st_saveViewHistory", true)
        cloudHistorySync = bool("st_cloudHistorySync", true)
        deleteStarIllust = bool("st_deleteStarIllust", false)
        filterRankBookmarked = bool("st_filterRankBookmarked", true)
        filterInvalidBookmarks = bool("st_filterInvalidBookmarks", false)
        deleteAIIllust = bool("st_deleteAIIllust", false)
        toastDownloadResult = bool("st_toastDownloadResult", true)
        searchFilterIndex = int("st_searchFilter", 0)
        searchSortIndex = int("st_searchDefaultSortType", 0)
        bottomBarOrder = int("st_bottomBarOrder", 0)
        filterComment = bool("st_filterComment", false)
        mainViewR18 = bool("st_mainViewR18", false)
        navigationInitPosition = int("st_navigationInitPosition", 1)
        useFragmentIllust = bool("st_useFragmentIllust", true)
        useArtworkV3 = bool("st_useArtworkV3", false)
        artworkV3FabDownloadOnLeft = bool("st_artworkV3FabDownloadOnLeft", true)
        artworkV3ShowCommentJumpFab = bool("st_artworkV3ShowCommentJumpFab", false)
        themeType = int("st_themeType", 0)
        useStaggeredLayout = bool("st_useStaggeredLayout", true)
        storageChoice = int("st_storageChoice", 0)
        overwritePolicy = int("st_overwritePolicy", 0)
        defaultNovelFormatIndex = int("st_defaultNovelExportFormat", 0)
        defaultImageResolutionIndex = int("st_defaultImageResolution", 0)
        pageIndexFrom1 = bool("st_pageIndexFrom1", false)
        illustLongPressDownload = bool("st_illustLongPressDownload", false)
        downloadLimitType = int("st_downloadLimitType", 0)
        maxConcurrentDownloads = int("st_maxConcurrentDownloads", 1)
        privateStar = bool("st_privateStar", false)
        privateFollow = bool("st_privateFollow", false)
        showNovelCardTags = bool("st_showNovelCardTags", true)
        collapseNovelCardTags = bool("st_collapseNovelCardTags", true)
        hideStarButtonAtMyCollection = bool("st_hideStarButtonAtMyCollection", false)
        starWithTagSelectAll = bool("st_starWithTagSelectAll", false)
        keepStatusBarWhenViewImage = bool("st_keepStatusBarWhenViewImage", false)
        synonymDictEnabled = bool("st_synonymDictEnabled", false)
        transformerIndex = int("st_transformerType", 5)
        showRelatedWhenStar = bool("st_showRelatedWhenStar", true)
        autoPostLikeWhenDownload = bool("st_autoPostLikeWhenDownload", false)
        autoFollowAfterStar = bool("st_autoFollowAfterStar", false)
        autoDownloadAfterStar = bool("st_autoDownloadAfterStar", false)
        illustDetailKeepScreenOn = bool("st_illustDetailKeepScreenOn", false)
        useCustomDoubleTapZoom = bool("st_useCustomDoubleTapZoom", false)
        customZoomAddScale = double("st_customZoomAddScale", 1.8)
        useThreeLevelZoom = bool("st_useThreeLevelZoo", false)
        useCustomLongPressReset = bool("st_useCustomLongPressReset", false)
        isFirebaseEnable = bool("st_isFirebaseEnable", true)
        showChatRoomEntry = bool("st_showChatRoomEntry", false)
        showChatRoomPushBanner = bool("st_showChatRoomPushBanner", false)
        showPlazaEntry = bool("st_showPlazaEntry", false)
    }

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private func int(_ key: String, _ fallback: Int) -> Int {
        defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
    }

    private func double(_ key: String, _ fallback: Double) -> Double {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
