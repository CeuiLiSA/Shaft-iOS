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
    case actionShare, actionCopyLink, actionOpenInBrowser, actionMuteArtist
    case actionMuteUser, actionUnmuteUser

    // Token sheet
    case tokenTitle, tokenAccess, tokenExpiresFormat

    // Common
    case nothingHere

    // Detail / sections
    case detailRelated, commentsTitle, viewAllComments, commentsEmpty
    case novelRead

    // V3 illust detail
    case detailArtworkDetails, detailTagsLabel, detailViewsLabel, detailBookmarksLabel
    case detailSeriesLabel, detailFollow, detailUnfollow, detailSeeMore, detailNoRelated
    case detailAuthorWorksFmt, detailPageOne, detailPagesFmt
    case detailExpandRemainingFmt, detailCollapsePages
    case dpArtworkId, dpUserId, dpType, dpResolution, dpPages, dpAI, dpRestriction, dpPublished
    case dpAIYes, dpAINo, dpAllAges
    case detailTypeIllust, detailTypeManga, detailTypeUgoira

    // Profile sections
    case profileIllusts, profileManga, profileNovels, profileBookmarks
    case profileFollow, profileFollowing

    // V3 user profile (UserActivityV3 parity)
    case v3LabelFollowing, v3LabelMyPixiv, v3LabelNavigate, v3LabelIllustTags
    case v3LabelProfileDetails, v3LabelWorkspace, v3LabelSocial
    case v3Official, v3FollowsYou, v3MyPixivBadge, v3BlockUserWorks
    case navIllustWorks, navMangaWorks, navIllustSeries, navNovelWorks
    case navNovelSeries, navIllustBookmarks, navNovelBookmarks, navRelatedUsers
    case chipUserId, chipAccount, chipGender, chipRegion, chipBirthday, chipJob
    case chipPremium, chipPixivUrl, chipPremiumUser, chipStandard
    case genderMale, genderFemale

    // Search
    case searchTitle, searchPlaceholder
    case searchTabIllust, searchTabNovel, searchTabUser
    case searchSortDateDesc, searchSortDateAsc, searchSortPopular, searchSortLabel
    case searchTargetPartial, searchTargetExact, searchTargetTitleCaption
    case searchOpenLink, searchRecent, actionClear, actionDelete

    // Following restrict
    case followingPublic, followingPrivate, followingMyPixiv

    // Series / bookmark restrict
    case seriesTitle, bookmarkPublic, bookmarkPrivate, bookmarkAction, bookmarkRestrictTitle
    case bookmarkTagsTitle, bookmarkTagsPlaceholder, bookmarkTagsSuggested, bookmarkWithTags
    case bookmarkTagAll
    case actionCancel

    // Ranking modes
    case rankingTitle
    case rankModeDay, rankModeWeek, rankModeMonth
    case rankModeDayMale, rankModeDayFemale
    case rankModeWeekRookie, rankModeWeekOriginal, rankModeDayManga

    // Discover
    case discoverSpotlight

    // Comments
    case commentCompose, commentReply, commentShowReplies, commentHideReplies

    // Newly added discover/recommend
    case latestWorksTitle, recommendUsersTitle

    // User profile extras
    case userRelatedTitle, userIllustSeriesTitle, userNovelSeriesTitle

    // Search duration filter
    case searchDurationAll, searchDurationDay, searchDurationWeek, searchDurationMonth

    // Mute
    case muteUsers, muteTags, muteAddTag

    // More / settings / about
    case moreTitle
    case historyTitle, downloadsTitle, mutedTitle
    case historyAll
    case settingsTitle, aboutTitle
    case settingsLanguage, settingsContent, settingsHideR18, settingsColumns
    case settingsNetwork, settingsDirectConnect

    // Search filter (V3)
    case filterTitle, filterReset, filterApply, filterAny
    case filterMatch, filterBookmarks, filterPopularityTag
    case filterDatePosted, filterCustomRange
    case filterAIWorks, filterExcludeAI, filterOnlyAI
    case filterAgeRating, filterSafeOnly, filterR18Only
    case filterWorkType, filterAspectRatio, filterResolution
    case filterTool, filterGenre, filterLengthUnit, filterLength
    case filterOriginalOnly, filterReplaceableOnly
    case sortPopularMale, sortPopularFemale
    case targetText, targetKeyword
    case durationHalfYear, durationYear
    case ratioLandscape, ratioPortrait, ratioSquare
    case bodyUnitChars, bodyUnitWords, bodyUnitReadingTime
    case typeIllust, typeUgoira

    // Notifications & announcements
    case notificationsTitle, notificationsTab, notificationsInfoTab

    // Watchlist (追更)
    case watchlistTitle, watchlistAdd, watchlistAdded, episodesFmt

    // Novel markers (小说书签)
    case novelMarkersTitle, markerPageFmt
}
