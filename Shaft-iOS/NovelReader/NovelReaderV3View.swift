import SwiftUI
import UIKit

// Root of the V3 novel reader (fragment_novel_reader_v3 parity): full-screen
// stage hosting the paged or scroll reader, 220 ms chrome (top/bottom bars),
// search overlay, settings panel + chapter/bookmark/annotation/search/series
// sheets, note editor, export + share, toasts, and the screen side effects
// (immersive status bar, keep-awake, custom brightness, warm filter).

struct NovelReaderV3View: View {
    @State private var currentNovelId: Int64

    init(novelId: Int64) {
        _currentNovelId = State(initialValue: novelId)
    }

    var body: some View {
        // Series navigation swaps the whole reader for the target novel.
        NovelReaderV3Screen(novelId: currentNovelId) { nextId in
            currentNovelId = nextId
        }
        .id(currentNovelId)
    }
}

private struct NoteEditorContext: Identifiable {
    let id = UUID()
    let annotationId: Int64
    let charStart: Int
    let charEnd: Int
    let excerpt: String
    let initialNote: String
    let colorARGB: UInt32
    let showDelete: Bool
}

private enum ReaderSheet: Identifiable {
    case settings, chapters, bookmarks, annotations, searchHits, series, export
    case note(NoteEditorContext)
    case share(URL)
    case illust(Int64)

    var id: String {
        switch self {
        case .settings: return "settings"
        case .chapters: return "chapters"
        case .bookmarks: return "bookmarks"
        case .annotations: return "annotations"
        case .searchHits: return "searchHits"
        case .series: return "series"
        case .export: return "export"
        case .note(let ctx): return "note-\(ctx.id)"
        case .share(let url): return "share-\(url.lastPathComponent)"
        case .illust(let id): return "illust-\(id)"
        }
    }
}

private struct NovelReaderV3Screen: View {
    let novelId: Int64
    let openNovel: (Int64) -> Void

    @State private var vm: NovelReaderV3ViewModel
    @State private var settings = NovelReaderSettings.shared
    @State private var chromeVisible = false
    @State private var activeSheet: ReaderSheet?
    @State private var showMoreMenu = false
    @State private var savedBrightness: CGFloat?
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(novelId: Int64, openNovel: @escaping (Int64) -> Void) {
        self.novelId = novelId
        self.openNovel = openNovel
        _vm = State(wrappedValue: NovelReaderV3ViewModel(novelId: novelId))
    }

    private var theme: ReaderTheme {
        settings.effectiveTheme(systemIsDark: colorScheme == .dark)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let safe = proxy.safeAreaInsets
            ZStack {
                Color(theme.backgroundColor).ignoresSafeArea()

                stage(size: size, safe: safe)
                    .ignoresSafeArea()

                if settings.warmFilterStrength > 0 {
                    Color(hex: 0xFF9800)
                        .opacity(settings.warmFilterStrength * 0.55)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                loadStateOverlay

                chrome(safe: safe)

                if let toast = vm.toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(.black.opacity(0.75), in: .capsule)
                            .padding(.bottom, 110)
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
            .onChange(of: layoutKey(size: size, safe: safe)) {
                pushLayout(size: size, safe: safe)
            }
            .onChange(of: isLoaded) {
                pushLayout(size: size, safe: safe)
                if settings.readingDirection == .vertical {
                    vm.jumpToCharIndex(vm.desiredCharIndex)
                }
            }
            .onAppear {
                pushLayout(size: size, safe: safe)
            }
        }
        .statusBarHidden(settings.immersive)
        .persistentSystemOverlays(settings.immersive ? .hidden : .automatic)
        .animation(.easeInOut(duration: 0.22), value: chromeVisible)
        .animation(.easeInOut(duration: 0.2), value: vm.searchActive)
        .animation(.easeInOut(duration: 0.2), value: vm.toast != nil)
        .task {
            vm.configureL10n { l10n.t($0) }
            vm.onOpenNovel = { openNovel($0) }
            ReaderJumpButton.labelFormat = { String(format: l10n.t(.nrJumpButtonFmt), $0) }
            await vm.loadIfNeeded()
        }
        .onAppear { applyScreenEffects() }
        .onDisappear { restoreScreenEffects() }
        .onChange(of: settings.keepScreenOn) { applyScreenEffects() }
        .onChange(of: settings.useSystemBrightness) { applyScreenEffects() }
        .onChange(of: settings.customBrightness) { applyScreenEffects() }
        .onChange(of: settings.readingDirection) {
            vm.invalidateLayout()
            vm.jumpToCharIndex(vm.desiredCharIndex)
        }
        .onChange(of: vm.exportedFileURL) {
            if let url = vm.exportedFileURL {
                vm.exportedFileURL = nil
                activeSheet = .share(url)
            }
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
        }
        .confirmationDialog("", isPresented: $showMoreMenu) {
            moreMenuButtons
        }
    }

    private var isLoaded: Bool {
        if case .loaded = vm.loadState { return true }
        return false
    }

    // MARK: Stage

    @ViewBuilder
    private func stage(size: CGSize, safe: EdgeInsets) -> some View {
        if settings.readingDirection == .vertical {
            ScrollReaderHost(
                vm: vm,
                style: currentStyle(),
                settings: settings,
                safeTop: safe.top,
                safeBottom: safe.bottom,
                menuStrings: menuStrings,
                onCenterTap: { chromeVisible.toggle() },
                onSelectionAction: handleSelection,
                onIllustOpen: { activeSheet = .illust($0) }
            )
        } else {
            PagedReaderHost(
                vm: vm,
                settings: settings,
                menuStrings: menuStrings,
                onCenterTap: { chromeVisible.toggle() },
                onSelectionAction: handleSelection,
                onIllustOpen: { activeSheet = .illust($0) }
            )
        }
    }

    @ViewBuilder
    private var loadStateOverlay: some View {
        switch vm.loadState {
        case .loading, .idle:
            ProgressView().tint(Color(theme.secondaryTextColor))
        case .error(let message):
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Color(theme.secondaryTextColor))
                .multilineTextAlignment(.center)
                .padding(32)
                .onTapGesture { Task { await vm.load() } }
        case .loaded:
            EmptyView()
        }
    }

    // MARK: Chrome

    @ViewBuilder
    private func chrome(safe: EdgeInsets) -> some View {
        VStack(spacing: 0) {
            if vm.searchActive {
                ReaderSearchOverlayBar(
                    query: Bindable(vm).searchQuery,
                    currentIndex: vm.searchIndex,
                    total: vm.searchHits.count,
                    regexEnabled: Bindable(vm).searchRegex,
                    onSubmit: { vm.performSearch() },
                    onPrev: { vm.prevSearchHit() },
                    onNext: { vm.nextSearchHit() },
                    onList: { activeSheet = .searchHits },
                    onClose: {
                        vm.searchActive = false
                        vm.clearSearch()
                        vm.searchQuery = ""
                    }
                )
                .padding(.top, safe.top)
                .background(Color.black.opacity(0.62))
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if chromeVisible {
                ReaderTopBar(
                    title: vm.title,
                    isBookmarked: vm.isBookmarked,
                    bookmarkBusy: vm.bookmarkBusy,
                    onBack: { dismiss() },
                    onAnnotations: { activeSheet = .annotations },
                    onBookmark: { Task { await vm.toggleBookmark() } },
                    onMore: { showMoreMenu = true }
                )
                .padding(.top, safe.top)
                .background(Color.black.opacity(0.62))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer()

            if chromeVisible {
                ReaderBottomBar(
                    isVertical: settings.readingDirection == .vertical,
                    currentPage: vm.currentPageIndex,
                    totalPages: vm.pagination?.pages.count ?? 0,
                    scrollFraction: vm.scrollFraction,
                    isDarkTheme: theme.isDark,
                    hasSeries: vm.novel?.series?.id != nil,
                    onPrevChapter: { vm.goToChapter(forward: false) },
                    onNextChapter: { vm.goToChapter(forward: true) },
                    onSeekCommit: { vm.seekToPage($0) },
                    onScrollSeekCommit: { vm.seekToScrollFraction($0) },
                    onChapters: {
                        if vm.outline.isEmpty {
                            vm.showToast(l10n.t(.nrMsgNoChapters))
                        } else {
                            activeSheet = .chapters
                        }
                    },
                    onSeries: {
                        activeSheet = .series
                        Task { await vm.loadSeriesIfNeeded() }
                    },
                    onSettings: { activeSheet = .settings },
                    onThemeToggle: { settings.toggleDayNight() },
                    onSearch: {
                        chromeVisible = false
                        vm.searchActive = true
                    },
                    onMore: { showMoreMenu = true }
                )
                .padding(.bottom, safe.bottom)
                .background(Color.black.opacity(0.62))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
    }

    // MARK: More menu (top-bar ⋯ / bottom-bar 更多)

    @ViewBuilder
    private var moreMenuButtons: some View {
        Button(l10n.t(.actionCopyLink)) { vm.copyLink() }
        Button(l10n.t(.nrMenuCopyText)) { vm.copyBodyText() }
        Button(l10n.t(.nrMenuSavePosition)) { vm.addBookmarkAtCurrentPosition() }
        Button(l10n.t(.nrBookmarksTitle)) { activeSheet = .bookmarks }
        Button(l10n.t(.nrAnnotationsTitle)) { activeSheet = .annotations }
        Button(l10n.t(.nrMenuExport)) { activeSheet = .export }
        if vm.novel?.series?.id != nil {
            Button(l10n.t(vm.seriesWatched ? .nrWatchlistRemove : .nrWatchlistAdd)) {
                Task { await vm.toggleWatchlist() }
            }
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: ReaderSheet) -> some View {
        switch sheet {
        case .settings:
            ReaderSettingsPanel(settings: settings)
                .presentationDetents([.fraction(0.7), .large])
        case .chapters:
            ReaderChapterListSheet(
                outline: vm.outline,
                currentCharIndex: vm.currentCharIndex,
                onSelect: { vm.jumpToCharIndex($0.sourceStart) }
            )
        case .bookmarks:
            ReaderBookmarksSheet(
                bookmarks: vm.positionBookmarks,
                onJump: { vm.jumpToCharIndex($0.charIndex) },
                onDelete: { vm.deleteBookmark($0.id) }
            )
        case .annotations:
            ReaderAnnotationsSheet(
                annotations: vm.annotations,
                onJump: { vm.jumpToCharIndex($0.charStart) },
                onEdit: { a in
                    activeSheet = .note(NoteEditorContext(
                        annotationId: a.id, charStart: a.charStart, charEnd: a.charEnd,
                        excerpt: a.excerpt, initialNote: a.note, colorARGB: a.colorARGB,
                        showDelete: true
                    ))
                },
                onDelete: { vm.deleteAnnotation($0.id) }
            )
        case .searchHits:
            ReaderSearchHitsSheet(
                hits: vm.searchHits,
                currentIndex: vm.searchIndex,
                query: vm.searchQuery,
                onSelect: { vm.selectSearchHit($0) }
            )
        case .series:
            ReaderSeriesSheet(
                seriesTitle: vm.novel?.series?.title,
                novels: vm.seriesNovels,
                currentNovelId: novelId,
                isLoading: vm.seriesLoading,
                errorMessage: vm.seriesError,
                onSelect: { openNovel($0.id) }
            )
        case .export:
            ReaderExportSheet { format in
                Task { await vm.export(format: format) }
            }
        case .note(let ctx):
            ReaderNoteEditorSheet(
                annotationId: ctx.annotationId,
                charStart: ctx.charStart,
                charEnd: ctx.charEnd,
                excerpt: ctx.excerpt,
                initialNote: ctx.initialNote,
                colorARGB: ctx.colorARGB,
                showDelete: ctx.showDelete,
                onSave: { id, start, end, excerpt, note, color in
                    vm.saveNote(annotationId: id, charStart: start, charEnd: end,
                                excerpt: excerpt, noteText: note, colorARGB: color)
                },
                onDelete: { vm.deleteAnnotation($0) }
            )
        case .share(let url):
            ActivityShareSheet(items: [url])
                .presentationDetents([.medium, .large])
        case .illust(let illustId):
            NavigationStack {
                IllustDetailView(illustId: illustId)
            }
        }
    }

    // MARK: Selection actions

    private func handleSelection(_ action: ReaderSelectionAction, _ selection: ReaderTextSelection) {
        switch action {
        case .highlight(let color):
            vm.addHighlight(selection, color: color)
        case .note:
            activeSheet = .note(NoteEditorContext(
                annotationId: 0, charStart: selection.absoluteStart, charEnd: selection.absoluteEnd,
                excerpt: selection.text, initialNote: "",
                colorARGB: ReaderHighlightColor.yellow.argb, showDelete: false
            ))
        case .searchPixiv:
            let word = selection.text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "https://www.pixiv.net/tags/\(word)") {
                UIApplication.shared.open(url)
            }
        case .searchWeb:
            let word = selection.text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "https://www.google.com/search?q=\(word)") {
                UIApplication.shared.open(url)
            }
        }
    }

    // MARK: Layout plumbing

    private func currentStyle() -> ReaderTypeStyle {
        ReaderTypeStyle.resolve(settings: settings, theme: theme)
    }

    private func layoutKey(size: CGSize, safe: EdgeInsets) -> String {
        let snap = settings.layoutSnapshot
        return "\(Int(size.width))x\(Int(size.height))|\(Int(safe.top))-\(Int(safe.bottom))|\(snap.fontSizeSp)|\(snap.lineSpacing)|\(snap.paragraphSpacingLines)|\(snap.horizontalMarginDp)|\(snap.verticalMarginDp)|\(snap.firstLineIndent)|\(snap.letterSpacing)|\(snap.boldText)|\(snap.fontId)|\(snap.fontWeight)|\(snap.readingDirection.rawValue)|\(snap.imagePlacement.rawValue)|\(snap.imageScaleMode.rawValue)|\(theme.id)"
    }

    private func pushLayout(size: CGSize, safe: EdgeInsets) {
        guard isLoaded, settings.readingDirection == .horizontal, size.width > 0, size.height > 0 else { return }
        let hMargin = CGFloat(settings.horizontalMarginDp)
        let vMargin = CGFloat(settings.verticalMarginDp)
        let geometry = PageGeometry(
            width: size.width + safe.leading + safe.trailing,
            height: size.height + safe.top + safe.bottom,
            paddingLeft: hMargin + safe.leading,
            paddingTop: vMargin + safe.top,
            paddingRight: hMargin + safe.trailing,
            paddingBottom: vMargin + safe.bottom
        )
        vm.updateLayout(style: currentStyle(), geometry: geometry, layoutKey: layoutKey(size: size, safe: safe))
    }

    private var menuStrings: ReaderMenuStrings {
        ReaderMenuStrings(
            searchPixiv: l10n.t(.nrActionSearchPixiv),
            searchWeb: l10n.t(.nrActionSearchWeb),
            highlight: l10n.t(.nrActionHighlight),
            note: l10n.t(.nrActionNote),
            highlightColorNames: ReaderHighlightColor.allCases.map { l10n.t($0.nameKey) }
        )
    }

    // MARK: Screen side effects

    private func applyScreenEffects() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        if settings.useSystemBrightness {
            if let saved = savedBrightness {
                UIScreen.main.brightness = saved
                savedBrightness = nil
            }
        } else {
            if savedBrightness == nil {
                savedBrightness = UIScreen.main.brightness
            }
            UIScreen.main.brightness = CGFloat(settings.customBrightness)
        }
    }

    private func restoreScreenEffects() {
        UIApplication.shared.isIdleTimerDisabled = false
        if let saved = savedBrightness {
            UIScreen.main.brightness = saved
            savedBrightness = nil
        }
    }
}

// MARK: - Paged host

private struct PagedReaderHost: UIViewRepresentable {
    let vm: NovelReaderV3ViewModel
    let settings: NovelReaderSettings
    let menuStrings: ReaderMenuStrings
    let onCenterTap: () -> Void
    let onSelectionAction: (ReaderSelectionAction, ReaderTextSelection) -> Void
    let onIllustOpen: (Int64) -> Void

    final class Coordinator {
        var boundRevision = -1
        var lastCommandId = -1
        var lastOverlays: [HighlightRange] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> NovelPagedReaderView {
        let view = NovelPagedReaderView()
        view.onTapCenter = onCenterTap
        view.onPageChanged = { [weak vm] index in
            DispatchQueue.main.async { vm?.onPageChanged(index) }
        }
        view.onJumpTap = { [weak vm] target in
            DispatchQueue.main.async { vm?.handleJumpTap(target) }
        }
        view.onImageTap = { element in
            if element.imageType == .pixivImage {
                onIllustOpen(element.resourceId)
            }
        }
        view.onLinkTap = { UIApplication.shared.open($0) }
        view.onSelectionAction = onSelectionAction
        return view
    }

    func updateUIView(_ view: NovelPagedReaderView, context: Context) {
        view.flipMode = settings.flipMode
        view.tapZoneReversed = settings.tapZoneReversed
        view.touchLocked = settings.touchLocked
        view.menuStrings = menuStrings

        let overlays = vm.overlays
        if let pagination = vm.pagination {
            if pagination.revision != context.coordinator.boundRevision {
                context.coordinator.boundRevision = pagination.revision
                context.coordinator.lastOverlays = overlays
                view.bind(
                    pages: pagination.pages,
                    initialIndex: pagination.startPageIndex,
                    style: pagination.style,
                    geometry: pagination.geometry,
                    overlays: overlays
                )
            } else if overlays != context.coordinator.lastOverlays {
                context.coordinator.lastOverlays = overlays
                view.applyOverlays(overlays)
            }
        }

        if let command = vm.command, command.id != context.coordinator.lastCommandId {
            context.coordinator.lastCommandId = command.id
            switch command.kind {
            case .goToPage(let index, let animated):
                DispatchQueue.main.async { view.goTo(index: index, animated: animated) }
            case .scrollToChar, .setScrollFraction:
                break
            }
        }
    }
}

// MARK: - Scroll host

private struct ScrollReaderHost: UIViewRepresentable {
    let vm: NovelReaderV3ViewModel
    let style: ReaderTypeStyle
    let settings: NovelReaderSettings
    let safeTop: CGFloat
    let safeBottom: CGFloat
    let menuStrings: ReaderMenuStrings
    let onCenterTap: () -> Void
    let onSelectionAction: (ReaderSelectionAction, ReaderTextSelection) -> Void
    let onIllustOpen: (Int64) -> Void

    final class Coordinator {
        var boundKey = ""
        var lastCommandId = -1
        var lastOverlays: [HighlightRange] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> NovelScrollReaderView {
        let view = NovelScrollReaderView()
        view.onCenterTap = onCenterTap
        view.onScrollProgressChanged = { [weak vm] fraction, charIndex in
            vm?.onScrollPositionChanged(fraction: fraction, charIndex: charIndex)
        }
        view.onJumpTap = { [weak vm] target in
            DispatchQueue.main.async { vm?.handleJumpTap(target) }
        }
        view.onImageTap = { element in
            if element.imageType == .pixivImage {
                onIllustOpen(element.resourceId)
            }
        }
        view.onLinkTap = { UIApplication.shared.open($0) }
        view.onSelectionAction = onSelectionAction
        return view
    }

    func updateUIView(_ view: NovelScrollReaderView, context: Context) {
        view.touchLocked = settings.touchLocked
        view.menuStrings = menuStrings

        let key = "\(vm.tokens.count)|\(settings.layoutSnapshot.fontSizeSp)|\(settings.layoutSnapshot.lineSpacing)|\(settings.layoutSnapshot.paragraphSpacingLines)|\(settings.layoutSnapshot.horizontalMarginDp)|\(settings.layoutSnapshot.verticalMarginDp)|\(settings.layoutSnapshot.firstLineIndent)|\(settings.layoutSnapshot.letterSpacing)|\(settings.layoutSnapshot.boldText)|\(settings.layoutSnapshot.fontId)|\(settings.layoutSnapshot.fontWeight)|\(style.theme.id)"
        if key != context.coordinator.boundKey, !vm.tokens.isEmpty {
            context.coordinator.boundKey = key
            let webNovel = vm.webNovel
            view.bind(
                tokens: vm.tokens,
                style: style,
                horizontalMargin: CGFloat(settings.horizontalMarginDp),
                verticalMargin: CGFloat(settings.verticalMarginDp),
                safeTop: safeTop,
                safeBottom: safeBottom,
                imageUrlResolver: { token in
                    webNovel.flatMap { ReaderImageResolver.resolve(token: token, webNovel: $0) }
                }
            )
        }

        let overlays = vm.overlays
        if overlays != context.coordinator.lastOverlays {
            context.coordinator.lastOverlays = overlays
            view.applyOverlays(overlays)
        }

        if let command = vm.command, command.id != context.coordinator.lastCommandId {
            context.coordinator.lastCommandId = command.id
            switch command.kind {
            case .scrollToChar(let char, let animated):
                DispatchQueue.main.async { view.scrollToCharIndex(char, animated: animated) }
            case .setScrollFraction(let fraction):
                DispatchQueue.main.async { view.setScrollFraction(fraction) }
            case .goToPage:
                break
            }
        }
    }
}

// MARK: - Share sheet

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
