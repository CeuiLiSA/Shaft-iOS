import Foundation

enum LocalizedKey: String, CaseIterable, Sendable {
    // Login
    case loginTitle, loginSubtitle, loginAction, loginProvisional
    // Landing page (1:1 page_login port)
    case loginNow, signNow, loginRestoreEmail, loginRestoreUnavailable
    case loginProxyTitle, loginProxyMessage, loginProxyConfirm
    case landingTermsBase, termsOfService, privacyPolicy, readAgreement

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

    // Settings — 1:1 port of Pixiv-Shaft fragment_settings.xml
    // Sections
    case stSectionNormal, stSectionUI, stSectionPersonalize, stSectionCache
    case stSectionExperimental, stSectionBackup
    // Account
    case stAccountManage, stEditAccount, stEmailBackup, stEditProfile, stWorkspace
    case stR18Setting, stPremiumSetting, stLogoutConfirmTitle, stDeleteAccountInfo
    // Network
    case stDirectConnect, stSeePixEz, stSecureDns, stSecureDnsHint
    case stLargeThumbnail, stShowOriginalPreview, stOriginalHint
    // Normal
    case stSaveViewHistory, stCloudHistorySync, stClearCloudHistory
    case stFilterStarSearch, stFilterRankBookmarked, stFilterInvalidBookmarks
    case stDeleteAIIllust, stToastDownloadResult, stSearchFilter, stSearchSort
    case stBottomBarOrder, stFilterComment, stR18DefaultFilter, stR18DefaultFilterHint
    case stOptNoLimit, stOptBookmarksOverFmt
    case stOptSortNewest, stOptSortOldest, stOptSortPopular, stOptSortPopularBuiltin
    // UI
    case stMainViewR18, stNavInitPosition, stOptNavLastClosed
    case stIllustDetailNew, stIllustDetailV3, stFabOrder
    case stOptFabDownloadLeft, stOptFabBookmarkLeft
    case stThemeMode, stOptThemeSystem, stOptThemeLight, stOptThemeDark
    case stThemeColor, stLayoutMode, stOptStaggered, stOptLinear
    case stLineCount, stOptColumnsFmt
    // Download
    case stStorageChoice, stOptStoragePictures, stOptStorageDownloads, stOptStorageSaf
    case stOverwritePolicy, stOptPolicySkip, stOptPolicyReplace, stOptPolicyRename
    case stCustomFileName, stTapToSet, stAria2Title, stAria2Desc
    case stNovelHeader, stNovelHeaderDesc
    case stNovelFormat, stOptAlwaysAsk, stOptFormatTxt, stOptFormatEpub
    case stImageResolution, stOptResOriginal, stOptResLarge, stOptResMedium, stOptResSquareMedium
    case stPageIndex, stOptPageFrom0, stOptPageFrom1
    case stLongPressDownload, stDownloadLimitType, stOptWifiOnly, stOptNoAutoDownload
    case stMaxConcurrent, stOptSerialOne, stOptConcurrentFmt
    // Personalization
    case stPrivateStar, stShowNovelTags, stHideStarButton, stSelectAllTags
    case stKeepStatusBar, stSynonymEnable, stSynonymDict, stTransformMode
    case stShowRelatedWhenStar, stAutoLikeWhenDownload, stAutoFollowAfterStar
    case stAutoDownloadAfterStar, stKeepScreenOn
    case stCustomDoubleTapZoom, stZoomScale, stZoomScaleHint
    case stThreeLevelZoom, stThreeLevelZoomHint, stLongPressReset, stLongPressResetHint
    case stFirebase, stUpscaleModel, stRembgModel, stNotSet, stBubbleModel, stOcrModel
    // Cache
    case stClearImageCache, stClearGifCache, stClearBulkData
    // Experimental
    case stChatRoomEntry, stChatRoomWarning, stChatRoomPushBanner, stPlazaEntry
    // Backup & restore
    case stBackup, stRestore, stBackupHistoryToo, stMoonUpload, stMoonSync
    // Misc
    case stNotAvailable, stDone, stSure
    case stSectionAccount, stOptFollowSystem, stModelNotReadyFmt

    // Novel reader V3 (1:1 port of Pixiv-Shaft reader/) — themes
    case nrThemeKraft, nrThemeWhite, nrThemeEye, nrThemeParchment
    case nrThemeButter, nrThemeNight, nrThemeCharcoal
    // Fonts
    case nrFontSystem, nrFontSans, nrFontSansLight, nrFontSansMedium
    case nrFontSerif, nrFontMonospace
    // Highlight colors
    case nrHighlightYellow, nrHighlightGreen, nrHighlightPink, nrHighlightBlue
    // Bottom bar
    case nrBtnChapters, nrBtnSeries, nrBtnSettings, nrBtnSearch, nrBtnMore
    case nrBtnThemeNight, nrBtnThemeDay, nrProgressEmpty
    // Search overlay
    case nrSearchHint, nrSearchRegex, nrSearchNoResult
    // Settings panel
    case nrSettingsTitle, nrSectionTypography, nrSectionTheme, nrSectionFlip
    case nrSectionScreen, nrSectionImage
    case nrFontSize, nrLineSpacing, nrParagraphSpacing, nrHMargin, nrVMargin
    case nrFirstIndent, nrIndentNone, nrIndentFmt, nrLetterSpacing, nrBold, nrFontWeight
    case nrFollowDark, nrSystemBrightness, nrCustomBrightness, nrWarmFilter
    case nrReadingDirection, nrDirectionHorizontal, nrDirectionVertical
    case nrFlipAnimation, nrFlipSimulation, nrFlipCover, nrFlipSlide, nrFlipNone
    case nrTapReversed, nrAutoPageInterval
    case nrImmersive, nrKeepScreenOn, nrTouchLocked, nrEyeBreak
    case nrImagePlacement, nrImageTop, nrImageCenter, nrImageBottom
    case nrImageScale, nrImageFit, nrImageFill, nrImageOriginal, nrPreloadImages
    // Sheets
    case nrChaptersTitle, nrChaptersCountFmt
    case nrBookmarksTitle, nrBookmarksCountFmt, nrBookmarksEmpty
    case nrBookmarkPageFmt, nrBookmarkDeleteConfirm
    case nrAnnotationsTitle, nrAnnotationsEmpty
    case nrSearchHitsTitle, nrSearchHitsCountFmt
    case nrSeriesTitle, nrSeriesCountFmt, nrSeriesLoading, nrSeriesEmpty
    case nrSeriesLoadFailedFmt, nrSeriesCurrent
    // Note editor
    case nrNoteHint, nrNoteAddTitle, nrNoteEditTitle, nrActionSave
    // Selection actions
    case nrActionSearchPixiv, nrActionSearchWeb, nrActionHighlight, nrActionNote
    // More menu
    case nrMenuCopyText, nrMenuSavePosition, nrMenuExport
    case nrWatchlistAdd, nrWatchlistRemove
    // Outline / jump
    case nrPagedSegmentFmt, nrPreface, nrJumpButtonFmt
    // Export
    case nrExportTitle, nrFormatTxt, nrFormatMarkdown, nrFormatEpub, nrFormatPdf
    case nrExportTxtDesc, nrExportMdDesc, nrExportEpubDesc, nrExportPdfDesc
    // Toasts
    case nrMsgCopied, nrMsgTextCopiedFmt, nrMsgBookmarkSaved
    case nrMsgBookmarked, nrMsgUnbookmarked, nrMsgWatchAdded, nrMsgWatchRemoved
    case nrMsgOpFailed, nrMsgJumpInvalid, nrMsgNoChapters
    case nrMsgFirstChapter, nrMsgLastChapter, nrMsgJumpNextFmt, nrMsgJumpPrevFmt
    case nrMsgNoteSaved, nrMsgHighlighted
    case nrMsgExportStartFmt, nrMsgExportFailFmt, nrMsgLoadFail

    // V3 comic (manga) reader
    case crEnter, crSettings
    case crModeLabel, crModePaged, crModeWebtoon
    case crDirectionLabel, crDirLtr, crDirRtl
    case crFitLabel, crFitWidth, crFitScreen, crFitOriginal
    case crAnimLabel, crAnimSlide, crAnimCover, crAnimDepth, crAnimFlipbook
    case crBrightnessSystem, crBrightnessLabel, crWarmLabel, crPreloadLabel
    case crKeepScreenOn, crImmersive, crShowPageNumber, crLoadOriginal, crTapReversed
    case crLoadFailed, crNoPages
    case crBookmarksTitle, crBookmarksButton, crBookmarksAddHere, crBookmarksEmpty, crBookmarksAdded
    case crThumbsTitle
    case crLongPressSave, crLongPressShare, crLongPressBookmark
    case crNoSeries, crSeriesFirst, crSeriesLast, crSeriesLoading
    case crSeriesTitle, crSeriesCountFmt, crSeriesEmpty, crSeriesLoadFailedFmt, crSeriesCurrent
    case crMsgSaved, crMsgOpFailed

    // Download manager (1:1 port of Pixiv-Shaft download/ + bulk/) — Photos sink
    case dlTitle, dlTabQueue, dlTabActive, dlTabDone
    case dlPauseAll, dlResumeAll
    case dlQueuePause, dlQueueResume, dlQueueRetryFailed, dlQueueClearAll
    case dlQueueEmptyTitle, dlQueueEmptyHint
    case dlClearQueueTitle, dlClearQueueMessage
    case dlStatusPending, dlStatusDownloading, dlStatusSuccess, dlStatusFailed
    case dlRetryFmt
    case dlActiveEmptyTitle, dlActiveEmptyHint, dlActivePaused, dlActivePageFmt
    case dlUgoiraQueued, dlUgoiraMeta, dlUgoiraFrames, dlUgoiraEncode
    case dlDoneEmptyTitle, dlDoneEmptyHint
    case dlDoneLayoutList, dlDoneLayoutGrid, dlDoneLayoutCompact
    case dlDoneClearHistory, dlDoneClearTitle, dlDoneClearMessage, dlDoneSearchHint
    case dlBulkEntry, dlBulkTitle, dlBulkSelectAll, dlBulkDeselectAll
    case dlBulkSummaryFmt, dlBulkDownloadSelected, dlBulkExportLinks
    case dlEnqueuedFmt, dlLinksCopiedFmt
}
