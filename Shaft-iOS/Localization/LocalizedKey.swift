import Foundation

enum LocalizedKey: String, CaseIterable, Sendable {
    // Login
    case loginTitle, loginSubtitle, loginAction, loginProvisional

    // Bottom tabs
    case tabRecommend, tabDiscover, tabWhatsNew

    // Recommend tab
    case homeNavTitle, subRecommendedWorks, subPopularTags, rankingTodayTitle

    // Account / actions
    case account, actionDone, actionLogOut, actionRefresh, actionRetry

    // Token sheet
    case tokenTitle, tokenAccess, tokenExpiresFormat

    // Common
    case nothingHere

    // Detail / sections
    case detailRelated, commentsTitle, viewAllComments, commentsEmpty
    case novelRead

    // Profile sections
    case profileIllusts, profileManga, profileNovels, profileBookmarks
    case profileFollow, profileFollowing

    // Search
    case searchTitle, searchPlaceholder
    case searchTabIllust, searchTabNovel, searchTabUser

    // Ranking modes
    case rankingTitle
    case rankModeDay, rankModeWeek, rankModeMonth
    case rankModeDayMale, rankModeDayFemale
    case rankModeWeekRookie, rankModeWeekOriginal, rankModeDayManga

    // Discover
    case discoverSpotlight

    // Comments
    case commentCompose

    // Newly added discover/recommend
    case latestWorksTitle, recommendUsersTitle

    // Mute
    case muteUsers, muteTags, muteAddTag

    // More / settings / about
    case moreTitle
    case historyTitle, downloadsTitle, mutedTitle
    case settingsTitle, aboutTitle
    case settingsLanguage, settingsContent, settingsHideR18, settingsColumns
    case settingsNetwork, settingsDirectConnect
}
