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
    /// `empty_list_2` — the feeds empty state on the V3 profile tabs.
    case userV3EmptyList
    case detailExpandRemainingFmt, detailCollapsePages
    case dpArtworkId, dpUserId, dpType, dpResolution, dpPages, dpAI, dpRestriction, dpPublished
    case dpAIYes, dpAINo, dpAllAges
    case detailTypeIllust, detailTypeManga, detailTypeUgoira

    // ArtworkV3 first-level detail page (ArtworkV3Fragment + section_v3_*.xml).
    // All keys here are prefixed `artworkV3` so they can't collide.
    case artworkV3ExpandAllPagesFmt, artworkV3ReaderEnterIllust
    case artworkV3DescLabel, artworkV3DescExpand, artworkV3DescCollapse
    case artworkV3AddCommentHint, artworkV3AuthorBadge, artworkV3NoCommentsYet
    case artworkV3CopyComment, artworkV3ViewUser, artworkV3Translate
    case artworkV3ShareFirstImage, artworkV3MuteSettings, artworkV3MuteThisWork
    case artworkV3CopyWorkLink, artworkV3LoadOriginal, artworkV3FlagPost
    case artworkV3UnmuteWork, artworkV3UnmuteUser, artworkV3LeavePage
    case artworkV3ResOriginal, artworkV3ResLarge, artworkV3ResMedium, artworkV3ResSquareMedium
    case artworkV3EditTags, artworkV3TitleLabel, artworkV3CaptionLabel
    case artworkV3JumpToComments, artworkV3DetailPanelCollapsed

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

    // UserActivityV3 (V3 画师主页) — tab strip, filter bar, overflow menu, jump
    // dialog and the 约稿中 tab. All prefixed `userV3` so they can't collide.
    case userV3TabBookmarks, userV3TabRequest, userV3FollowingPrivate
    case userV3SegIllustBookmarks, userV3SegNovelBookmarks
    case userV3AdvancedSearch, userV3TagSheetHint, userV3TagSheetSectionWorks
    case userV3TagSheetFailed, userV3TagSheetNoTag, userV3TagSheetNoMatch
    case userV3TagCopyOriginal, userV3TagCopyTranslation, userV3TagMute, userV3TagUnmute
    case userV3MenuJumpIllust, userV3MenuJumpManga
    case userV3MenuDownloadAllIllust, userV3MenuDownloadAllManga
    case userV3MenuOpenDownloadManager, userV3UnblockUserWorks
    case userV3JumpLoading, userV3JumpNoWorks, userV3JumpEarliest
    case userV3JumpByDate, userV3JumpByPage, userV3JumpTitleFmt
    case userV3JumpPageTitle, userV3JumpPageHintFmt, userV3JumpRangeErrorFmt
    case userV3JumpLocatingFmt, userV3JumpLocateFailedFmt
    case userV3RequestPriceFmt, userV3RequestBadgeAdult
    case userV3RequestFlagIllust, userV3RequestFlagManga, userV3RequestFlagUgoira
    case userV3RequestFlagNovel, userV3RequestFlagAnonymous, userV3RequestFlagAI
    case userV3RequestPriceLabel, userV3RequestFlagsLabel, userV3RequestTitleLabel
    case userV3RequestDescLabel, userV3RequestMetaLabel, userV3RequestMetaId
    case userV3RequestMetaAI, userV3RequestAINone, userV3RequestAIGenerated
    case userV3RequestAIUnknown, userV3RequestGoCommission, userV3RequestOrigFmt
    case userV3BulkFetchingFmt

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
    // Ranking date picker (past rankings — 1:1 with RankActivity's date dialog)
    case rankDateTitle, rankDateLatest

    // Discover
    case discoverSpotlight
    // Discover tab — 1:1 FragmentCenter / fragment_new_center.xml
    case discoverOtherCategories      // string_76 其他分类
    case discoverViewAll              // string_167 查看全部
    case discoverSeeMore              // see_more 查看更多
    case discoverLatest               // latest_work 最新
    case discoverTypeManga            // type_manga 漫画
    case discoverTypeNovel            // type_novel 小说
    case discoverRecommendManga       // recommend_manga 推荐漫画
    case discoverRecommendNovel       // recommend_novel 推荐小说
    case discoverWalkThrough          // type_walk_through 画廊
    case artistRank, artistAvgRank, viewRank, pixivComic
    case bookmarkRank, aiRank, yearRank, tagRank, wallpaperRank
    case followingNovels              // string_196 关注者的小说
    case followingNovelsPageTitle     // string_197 关注者的最新小说
    case discoveryFeed                // string_discovery 发现
    case webHome                      // street_title Web 首页
    case niceFriendWorks              // nice_friend_works 好P友作品
    case niceFriendWorksPageTitle     // string_274 好P友的插画/漫画作品
    // 动态 tab — 1:1 FragmentRight / fragment_new_right.xml
    case dynRecommendUsers            // string_78 推荐用户
    case dynSeeMore                   // string_79 查看更多
    case dynRestrictAll, dynRestrictPublic, dynRestrictPrivate   // string_390/391/392
    case dynTypeIllustManga           // dynamic_type_illust_manga 插画/漫画
    case dynTypeNovel                 // string_171 小说
    case timeJustNow                  // date_minute_plurals_zero

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
    // Settings hub (two-level redesign)
    case settingsSearchHint, settingsSearchEmpty
    case settingsCatBrowsing, settingsCatViewing, settingsCatBookmarks
    case settingsCatAI, settingsCatData

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
    case bodyUnitCharShort, bodyUnitWordShort, bodyUnitMinute
    case typeIllust, typeUgoira
    case filterSearchConditions, filterSearch, filterOther, filterNone, filterDisabled
    case filterUserUnsupported
    case sortPopularPreview, filterBookmarkCustom, filterCustom
    case filterMinimum, filterMaximum
    case filterConfirm, filterRangeConfirm, filterRangeHint
    case filterDateStart, filterDateEnd, filterDateUnset, filterClearDates
    case filterGroupBySeries, filterGroupBySeriesHint
    case searchSeriesOngoingFmt, searchSeriesConcludedFmt
    case filterAll, filterBookmarkAll, filterToolAll, filterToolLoading, filterGenreAll
    case filterLanguageAll, filterRatioAll, filterResolutionAll, filterWorkLanguage
    case filterDurationAll, filterBodyAll, filterRangeUnlimited
    case filterResolutionAbove, filterResolutionMiddle, filterResolutionBelow
    case filterContentAll, filterContentIllustUgoira
    case filterSummaryNoAI, filterSummaryOnlyAI
    case bodyCharsMicro, bodyCharsShort, bodyCharsMedium, bodyCharsLong
    case bodyWordsBelow, bodyWordsFrom5K, bodyWordsFrom20K, bodyWordsAbove80K
    case bodyTimeUnder10, bodyTime10To59, bodyTime60To179, bodyTimeAbove180
    case bodyCustomCharsFmt, bodyCustomWordsFmt, bodyCustomTimeFmt
    case searchSeriesEmptyHint
    case filterWebLogin
    case borrowQuotaSessionFmt, borrowQuotaWeeklyFmt
    case borrowQuotaDaysHoursFmt, borrowQuotaHoursMinutesFmt, borrowQuotaMinutesFmt

    // Notifications & announcements
    case notificationsTitle, notificationsTab, notificationsInfoTab

    // Watchlist (追更)
    case watchlistTitle, watchlistAdd, watchlistAdded, episodesFmt

    // Watch Later (稍后再看) — 1:1 port of pixiv/ui/watchlater/ (local list)
    case watchLaterTitle, watchLaterAdd, watchLaterRemove
    case watchLaterEmpty, watchLaterClear, watchLaterClearOk, watchLaterClearConfirm
    case watchLaterPlayAll

    // shaft-api-v2 self-hosted feeds (当前最热 / 站长推荐 / 操作记录 + gate)
    case currentHot, siteRecommend, eventHistory
    case recentWindowLive, recentWindowDay, recentWindowWeek, recentWindowMonth
    case sensitiveGateTitle, sensitiveGateMessage, sensitiveGateCancel, sensitiveGateProceed
    case eventHistoryEmpty, eventHistoryCopyClientId, eventHistoryClientIdCopied
    case eventVerbBookmark, eventVerbUnbookmark, eventVerbDownload, eventVerbFollow, eventVerbUnfollow
    case typeUser

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
    case stImageHost, stLargeThumbnail, stShowOriginalPreview, stOriginalHint
    // Normal
    case stSaveViewHistory, stCloudHistorySync, stClearCloudHistory
    case stFilterStarSearch, stFilterRankBookmarked, stFilterInvalidBookmarks
    case stDeleteAIIllust, stToastDownloadResult, stSearchFilter, stSearchSort
    case stBottomBarOrder, stFilterComment, stR18DefaultFilter, stR18DefaultFilterHint
    case stAutoRefreshHome, stAutoRefreshHomeHint
    case stNovelMinLength, stNovelMinLengthHint, stNovelMaxLength, stNovelMaxLengthHint
    case stNovelMaxTagLength, stNovelMaxTagLengthHint, stSearchExitConfirm, stSearchExitConfirmHint
    case stOptNoLimit, stOptBookmarksOverFmt
    case stOptSortNewest, stOptSortOldest, stOptSortPopular, stOptSortPopularBuiltin
    // UI
    case stMainViewR18, stNavInitPosition, stOptNavLastClosed
    case stIllustDetailNew, stIllustDetailV3, stFabOrder
    case stOptFabDownloadLeft, stOptFabBookmarkLeft
    case stThemeMode, stOptThemeSystem, stOptThemeLight, stOptThemeDark
    case stThemeColor, stLayoutMode, stOptStaggered, stOptLinear
    case stLineCount, stOptColumnsFmt
    case stWidgetRefreshInterval, stCollapseNovelTags
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
    case stWriteExif, stWriteExifHint, stSilentDownload, stSilentDownloadHint
    // Personalization
    case stPrivateStar, stPrivateFollow, stShowNovelTags, stHideStarButton, stSelectAllTags
    case stKeepStatusBar, stSynonymEnable, stSynonymDict, stTransformMode
    case stShowRelatedWhenStar, stAutoLikeWhenDownload, stAutoFollowAfterStar
    case stAutoDownloadAfterStar, stKeepScreenOn
    case stCustomDoubleTapZoom, stZoomScale, stZoomScaleHint
    case stThreeLevelZoom, stThreeLevelZoomHint, stLongPressReset, stLongPressResetHint
    case stNovelDirectReader, stNovelDirectReaderHint, stCommentJumpButton
    case stUgoiraRife, stUgoiraRifeHint, stUgoiraAutoPlay
    case stFirebase, stUpscaleModel, stRembgModel, stRifeModel, stNotSet, stBubbleModel, stOcrModel
    case stAITranslate, stAITranslateHint
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

    // Slideshow (1:1 port of pixiv/ui/slideshow/)
    case slideshowPlay

    // Prime / featured tags (1:1 port of pixiv/ui/prime/)
    case primeTagsTitle

    // Report / flag illust (1:1 port of loxia/flag/)
    case actionReport
    case reportReasonTitle, reportDescTitle
    case reportReasonSexual, reportReasonGrotesque, reportReasonCopyright, reportReasonOther
    case reportHint, reportSubmit, reportSuccess

    // Pinned tags (1:1 port of pixiv/ui/pinned/)
    case pinnedTagsTitle, actionPinTag, actionUnpinTag, pinnedClearMessage

    // View-history backup — local JSON export/import (pixiv/ui/history/BrowseHistoryBackup)
    case actionExport, actionImport
    case historyExportEmpty, historyImportedFmt, historyImportFailed

    // MARK: 聊天室 (chat) — 1:1 with Android `chat_*` in values*/strings.xml
    case chatDrawerEntry, chatRoomGlobalTitle, chatPreviewYouPrefix, chatRoomCount
    case chatNewMessages, chatSelfLabel, chatInputHint, chatGlobalClosedHint
    case chatPeerTyping, chatPeerTypingAnon, chatActionBack, chatActionMore
    case chatActionCopy, chatActionDelete, chatActionForward, chatActionReply
    case chatStateLoadingDefault, chatStateErrorDefault, chatStateEmptyDefault, chatStateRetry
    case chatListLoadingMore, chatListLoadError, chatErrorNetworkUnavailable, chatErrorRequestTimeout
    case chatErrorSecurity, chatErrorUnauthorized, chatErrorForbidden, chatErrorNotFound
    case chatErrorGone, chatErrorRateLimited, chatErrorRateLimitedWithDelay, chatErrorServiceUnavailable
    case chatErrorSerialization, chatErrorUnknown, chatWithHim
}
