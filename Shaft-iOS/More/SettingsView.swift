import SwiftUI

/// 1:1 port of Pixiv-Shaft's settings page (`fragment_settings.xml` +
/// `FragmentSettings.java`, classic branch): same nine sections, same rows in
/// the same order, same option lists and defaults. UI-first port — rows whose
/// backing feature doesn't exist on iOS yet keep their look and store their
/// value, but the action is stubbed (placeholder page or "not available").
struct SettingsView: View {
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.openURL) private var openURL
    @State private var st = AppSettingsStore.shared
    @State private var mute = MuteStore.shared

    @State private var showLogoutDialog = false
    @State private var showBackupDialog = false
    @State private var showNotAvailable = false

    private static let r18SettingURL = URL(string: "https://www.pixiv.net/settings/viewing")!
    private static let premiumSettingURL = URL(string: "https://www.pixiv.net/premium.php#premium-payment")!
    private static let pixEzURL = URL(string: "https://github.com/Notsfsssf/Pix-EzViewer")!

    var body: some View {
        Form {
            accountSection
            networkSection
            normalSection
            uiSection
            downloadSection
            personalizeSection
            cacheSection
            experimentalSection
            backupSection
        }
        .navigationTitle(l10n.t(.settingsTitle))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(l10n.t(.stLogoutConfirmTitle), isPresented: $showLogoutDialog, titleVisibility: .visible) {
            Button(l10n.t(.stDeleteAccountInfo), role: .destructive) {}
            Button(l10n.t(.actionLogOut), role: .destructive) {}
            Button(l10n.t(.actionCancel), role: .cancel) {}
        }
        .confirmationDialog(l10n.t(.stBackupHistoryToo), isPresented: $showBackupDialog, titleVisibility: .visible) {
            Button(l10n.t(.stSure)) {}
            Button(l10n.t(.actionCancel), role: .cancel) {}
        }
        .alert(l10n.t(.stNotAvailable), isPresented: $showNotAvailable) {
            Button(l10n.t(.stSure), role: .cancel) {}
        }
    }

    // MARK: - 账号

    private var accountSection: some View {
        Section(l10n.t(.stSectionAccount)) {
            subPageRow(l10n.t(.stAccountManage))
            subPageRow(l10n.t(.stEditAccount))
            subPageRow(l10n.t(.stEmailBackup))
            subPageRow(l10n.t(.stEditProfile))
            subPageRow(l10n.t(.stWorkspace))
            actionRow(l10n.t(.stR18Setting)) { openURL(Self.r18SettingURL) }
            actionRow(l10n.t(.stPremiumSetting)) { openURL(Self.premiumSettingURL) }
            // Upstream renders 退出登录 as a regular arrow row, not a red
            // destructive button — the red styling lives in its dialog.
            actionRow(l10n.t(.actionLogOut)) { showLogoutDialog = true }
        }
    }

    // MARK: - 网络

    private var networkSection: some View {
        Section(l10n.t(.settingsNetwork)) {
            Toggle(isOn: $st.directConnect) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.t(.stDirectConnect))
                    Button {
                        openURL(Self.pixEzURL)
                    } label: {
                        Text(l10n.t(.stSeePixEz))
                            .font(.caption)
                            .foregroundStyle(Theme.brand)
                    }
                    .buttonStyle(.plain)
                }
            }
            if st.directConnect {
                hintToggle(l10n.t(.stSecureDns), l10n.t(.stSecureDnsHint), isOn: $st.useSecureDns)
            }
            hintToggle(l10n.t(.stLargeThumbnail), l10n.t(.stOriginalHint), isOn: $st.showLargeThumbnailImage)
            hintToggle(l10n.t(.stShowOriginalPreview), l10n.t(.stOriginalHint), isOn: $st.showOriginalPreviewImage)
        }
    }

    // MARK: - 常规

    private var normalSection: some View {
        Section(l10n.t(.stSectionNormal)) {
            Toggle(l10n.t(.stSaveViewHistory), isOn: $st.saveViewHistory)
            Toggle(l10n.t(.stCloudHistorySync), isOn: $st.cloudHistorySync)
            actionRow(l10n.t(.stClearCloudHistory)) { showNotAvailable = true }
            Toggle(l10n.t(.stFilterStarSearch), isOn: $st.deleteStarIllust)
            Toggle(l10n.t(.stFilterRankBookmarked), isOn: $st.filterRankBookmarked)
            Toggle(l10n.t(.stFilterInvalidBookmarks), isOn: $st.filterInvalidBookmarks)
            Toggle(l10n.t(.stDeleteAIIllust), isOn: $st.deleteAIIllust)
            Toggle(l10n.t(.stToastDownloadResult), isOn: $st.toastDownloadResult)
            pickerRow(l10n.t(.stSearchFilter), selection: $st.searchFilterIndex, options: searchFilterOptions)
            pickerRow(l10n.t(.stSearchSort), selection: $st.searchSortIndex, options: searchSortOptions)
            pickerRow(l10n.t(.stBottomBarOrder), selection: $st.bottomBarOrder, options: bottomOrderOptions)
            Toggle(l10n.t(.stFilterComment), isOn: $st.filterComment)
            hintToggle(l10n.t(.stR18DefaultFilter), l10n.t(.stR18DefaultFilterHint), isOn: Binding(
                get: { mute.hideR18 },
                set: { mute.setHideR18($0) }
            ))
        }
    }

    // MARK: - 界面

    private var uiSection: some View {
        Section(l10n.t(.stSectionUI)) {
            Toggle(l10n.t(.stMainViewR18), isOn: $st.mainViewR18)
            pickerRow(l10n.t(.stNavInitPosition), selection: $st.navigationInitPosition, options: navInitOptions)
            Toggle(l10n.t(.stIllustDetailNew), isOn: $st.useFragmentIllust)
            Toggle(l10n.t(.stIllustDetailV3), isOn: $st.useArtworkV3)
            if st.useArtworkV3 {
                pickerRow(l10n.t(.stFabOrder), selection: Binding(
                    get: { st.artworkV3FabDownloadOnLeft ? 0 : 1 },
                    set: { st.artworkV3FabDownloadOnLeft = $0 == 0 }
                ), options: [l10n.t(.stOptFabDownloadLeft), l10n.t(.stOptFabBookmarkLeft)])
            }
            pickerRow(l10n.t(.stThemeMode), selection: $st.themeType, options: [
                l10n.t(.stOptThemeSystem), l10n.t(.stOptThemeLight), l10n.t(.stOptThemeDark),
            ])
            subPageRow(l10n.t(.stThemeColor))
            pickerRow(l10n.t(.stLayoutMode), selection: Binding(
                get: { st.useStaggeredLayout ? 0 : 1 },
                set: { st.useStaggeredLayout = $0 == 0 }
            ), options: [l10n.t(.stOptStaggered), l10n.t(.stOptLinear)])
            Picker(l10n.t(.stLineCount), selection: Binding(
                get: { mute.waterfallColumns },
                set: { mute.setWaterfallColumns($0) }
            )) {
                ForEach(2...4, id: \.self) { n in
                    Text(l10n.t(.stOptColumnsFmt, "\(n)")).tag(n)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.brand)
            // Upstream's language dialog leads with 跟随系统 (tag = null).
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
        }
    }

    // MARK: - 下载

    private var downloadSection: some View {
        Section(l10n.t(.downloadsTitle)) {
            pickerRow(l10n.t(.stStorageChoice), selection: $st.storageChoice, options: [
                l10n.t(.stOptStoragePictures), l10n.t(.stOptStorageDownloads), l10n.t(.stOptStorageSaf),
            ])
            pickerRow(l10n.t(.stOverwritePolicy), selection: $st.overwritePolicy, options: [
                l10n.t(.stOptPolicySkip), l10n.t(.stOptPolicyReplace), l10n.t(.stOptPolicyRename),
            ])
            subPageRow(l10n.t(.stCustomFileName), hint: l10n.t(.stTapToSet))
            subPageRow(l10n.t(.stAria2Title), hint: l10n.t(.stAria2Desc))
            subPageRow(l10n.t(.stNovelHeader), hint: l10n.t(.stNovelHeaderDesc))
            pickerRow(l10n.t(.stNovelFormat), selection: $st.defaultNovelFormatIndex, options: [
                l10n.t(.stOptAlwaysAsk), l10n.t(.stOptFormatTxt), "Markdown", l10n.t(.stOptFormatEpub), "PDF",
            ])
            pickerRow(l10n.t(.stImageResolution), selection: $st.defaultImageResolutionIndex, options: [
                l10n.t(.stOptResOriginal), l10n.t(.stOptResLarge), l10n.t(.stOptResMedium), l10n.t(.stOptResSquareMedium),
            ])
            pickerRow(l10n.t(.stPageIndex), selection: Binding(
                get: { st.pageIndexFrom1 ? 1 : 0 },
                set: { st.pageIndexFrom1 = $0 == 1 }
            ), options: [l10n.t(.stOptPageFrom0), l10n.t(.stOptPageFrom1)])
            Toggle(l10n.t(.stLongPressDownload), isOn: $st.illustLongPressDownload)
            pickerRow(l10n.t(.stDownloadLimitType), selection: $st.downloadLimitType, options: [
                l10n.t(.stOptNoLimit), l10n.t(.stOptWifiOnly), l10n.t(.stOptNoAutoDownload),
            ])
            pickerRow(l10n.t(.stMaxConcurrent), selection: Binding(
                get: { st.maxConcurrentDownloads - 1 },
                set: { st.maxConcurrentDownloads = $0 + 1 }
            ), options: concurrentOptions)
        }
    }

    // MARK: - 个性化

    private var personalizeSection: some View {
        Section(l10n.t(.stSectionPersonalize)) {
            Toggle(l10n.t(.stPrivateStar), isOn: $st.privateStar)
            Toggle(l10n.t(.stShowNovelTags), isOn: $st.showNovelCardTags)
            Toggle(l10n.t(.stHideStarButton), isOn: $st.hideStarButtonAtMyCollection)
            Toggle(l10n.t(.stSelectAllTags), isOn: $st.starWithTagSelectAll)
            Toggle(l10n.t(.stKeepStatusBar), isOn: $st.keepStatusBarWhenViewImage)
            Toggle(l10n.t(.stSynonymEnable), isOn: $st.synonymDictEnabled)
            if st.synonymDictEnabled {
                subPageRow(l10n.t(.stSynonymDict))
            }
            pickerRow(l10n.t(.stTransformMode), selection: $st.transformerIndex, options: AppSettingsStore.transformerNames)
            Toggle(l10n.t(.stShowRelatedWhenStar), isOn: $st.showRelatedWhenStar)
            Toggle(l10n.t(.stAutoLikeWhenDownload), isOn: $st.autoPostLikeWhenDownload)
            Toggle(l10n.t(.stAutoFollowAfterStar), isOn: $st.autoFollowAfterStar)
            Toggle(l10n.t(.stAutoDownloadAfterStar), isOn: $st.autoDownloadAfterStar)
            Toggle(l10n.t(.stKeepScreenOn), isOn: $st.illustDetailKeepScreenOn)
            Toggle(l10n.t(.stCustomDoubleTapZoom), isOn: $st.useCustomDoubleTapZoom)
            if st.useCustomDoubleTapZoom {
                zoomScaleRow
                hintToggle(l10n.t(.stThreeLevelZoom), l10n.t(.stThreeLevelZoomHint), isOn: $st.useThreeLevelZoom)
                hintToggle(l10n.t(.stLongPressReset), l10n.t(.stLongPressResetHint), isOn: $st.useCustomLongPressReset)
            }
            Toggle(l10n.t(.stFirebase), isOn: $st.isFirebaseEnable)
            actionRow(l10n.t(.stUpscaleModel), value: l10n.t(.stNotSet)) { showNotAvailable = true }
            actionRow(l10n.t(.stRembgModel), value: l10n.t(.stNotSet)) { showNotAvailable = true }
            // Upstream shows the model download state, not 未设置 — sizes are
            // the CTD_BASE / MANGA_OCR_BASE size labels.
            actionRow(l10n.t(.stBubbleModel), value: l10n.t(.stModelNotReadyFmt, "57MB")) { showNotAvailable = true }
            actionRow(l10n.t(.stOcrModel), value: l10n.t(.stModelNotReadyFmt, "91MB")) { showNotAvailable = true }
        }
    }

    /// Android's −/value/+ row for the double-tap zoom increment (1.1–3.0, step 0.1).
    private var zoomScaleRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(l10n.t(.stZoomScale))
                Spacer()
                Button {
                    st.customZoomAddScale = max(1.1, (st.customZoomAddScale * 10 - 1).rounded() / 10)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                Text(String(format: "%.1f", st.customZoomAddScale))
                    .font(.headline)
                    .foregroundStyle(Theme.brand)
                    .frame(minWidth: 36)
                Button {
                    st.customZoomAddScale = min(3.0, (st.customZoomAddScale * 10 + 1).rounded() / 10)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
            }
            Text(l10n.t(.stZoomScaleHint))
                .font(.caption)
                .foregroundStyle(Theme.brand)
        }
    }

    // MARK: - 缓存

    private var cacheSection: some View {
        Section(l10n.t(.stSectionCache)) {
            actionRow(l10n.t(.stClearImageCache), value: "0.00MB") { showNotAvailable = true }
            actionRow(l10n.t(.stClearGifCache), value: "0.00MB") { showNotAvailable = true }
            actionRow(l10n.t(.stClearBulkData), value: "0.00MB") { showNotAvailable = true }
        }
    }

    // MARK: - 试验性

    private var experimentalSection: some View {
        Section(l10n.t(.stSectionExperimental)) {
            hintToggle(l10n.t(.stChatRoomEntry), l10n.t(.stChatRoomWarning), isOn: $st.showChatRoomEntry, hintColor: .red)
            if st.showChatRoomEntry {
                Toggle(l10n.t(.stChatRoomPushBanner), isOn: $st.showChatRoomPushBanner)
            }
            Toggle(l10n.t(.stPlazaEntry), isOn: $st.showPlazaEntry)
        }
    }

    // MARK: - 备份与还原

    private var backupSection: some View {
        Section(l10n.t(.stSectionBackup)) {
            actionRow(l10n.t(.stBackup)) { showBackupDialog = true }
            actionRow(l10n.t(.stRestore)) { showNotAvailable = true }
            actionRow(l10n.t(.stMoonUpload)) { showNotAvailable = true }
            actionRow(l10n.t(.stMoonSync)) { showNotAvailable = true }
        }
    }

    // MARK: - Option lists (parity with FragmentSettings.java arrays)

    private var searchFilterOptions: [String] {
        [l10n.t(.stOptNoLimit)] + ["500", "1000", "2000", "5000", "7500", "10000", "20000", "50000", "100000"]
            .map { l10n.t(.stOptBookmarksOverFmt, $0) }
    }

    private var searchSortOptions: [String] {
        [l10n.t(.stOptSortNewest), l10n.t(.stOptSortOldest), l10n.t(.stOptSortPopular), l10n.t(.stOptSortPopularBuiltin)]
    }

    private var bottomOrderOptions: [String] {
        let r = l10n.t(.tabRecommend)
        let d = l10n.t(.tabDiscover)
        let w = l10n.t(.tabWhatsNew)
        return [
            "\(r) - \(d) - \(w)", "\(r) - \(w) - \(d)",
            "\(d) - \(r) - \(w)", "\(d) - \(w) - \(r)",
            "\(w) - \(r) - \(d)", "\(w) - \(d) - \(r)",
        ]
    }

    private var navInitOptions: [String] {
        [l10n.t(.stOptNavLastClosed), l10n.t(.tabRecommend), l10n.t(.tabDiscover), l10n.t(.tabWhatsNew), "R"]
    }

    private var concurrentOptions: [String] {
        [l10n.t(.stOptSerialOne)] + (2...5).map { l10n.t(.stOptConcurrentFmt, "\($0)") }
    }

    // MARK: - Row builders

    private func pickerRow(_ title: String, selection: Binding<Int>, options: [String]) -> some View {
        Picker(title, selection: selection) {
            ForEach(options.indices, id: \.self) { i in
                Text(options[i]).tag(i)
            }
        }
        .pickerStyle(.menu)
        .tint(Theme.brand)
    }

    private func hintToggle(_ title: String, _ hint: String, isOn: Binding<Bool>, hintColor: Color = Theme.brand) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(hintColor)
            }
        }
    }

    private func subPageRow(_ title: String, hint: String? = nil) -> some View {
        NavigationLink(value: AppRoute.settingsSub(title: title)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(Theme.brand)
                }
            }
        }
    }

    private func actionRow(_ title: String, value: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if let value {
                    Text(value)
                        .foregroundStyle(Theme.brand)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
