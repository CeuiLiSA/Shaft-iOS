import SwiftUI
import UIKit

// Root of the V3 manga reader (fragment_comic_reader_v3 parity): a full-screen
// stage hosting the paged or webtoon viewport, the 150 ms top/bottom chrome,
// page indicator, settings + thumbnails + bookmarks + series sheets, the
// long-press page menu, and the screen side effects (immersive status bar,
// keep-awake, custom brightness, warm filter, dark/light background).

struct ComicReaderView: View {
    @State private var currentIllustId: Int64
    private let rootIllust: Illust?

    /// Preferred entry from the detail screen — the full Illust is already loaded.
    init(illust: Illust) {
        rootIllust = illust
        _currentIllustId = State(initialValue: illust.id)
    }

    /// Entry by id (series navigation target) — the reader fetches it.
    init(illustId: Int64) {
        rootIllust = nil
        _currentIllustId = State(initialValue: illustId)
    }

    var body: some View {
        // Series navigation swaps the whole reader for the target work.
        ComicReaderScreen(
            illustId: currentIllustId,
            initialIllust: (rootIllust?.id == currentIllustId) ? rootIllust : nil
        ) { nextId in
            currentIllustId = nextId
        }
        .id(currentIllustId)
    }
}

private enum ComicSheet: Identifiable {
    case settings, thumbs, bookmarks, series, comments
    case share(URL)
    var id: String {
        switch self {
        case .settings: return "settings"
        case .thumbs: return "thumbs"
        case .bookmarks: return "bookmarks"
        case .series: return "series"
        case .comments: return "comments"
        case .share(let u): return "share-\(u.absoluteString)"
        }
    }
}

private struct ComicReaderScreen: View {
    let illustId: Int64
    let initialIllust: Illust?
    let openReader: (Int64) -> Void

    @State private var vm: ComicReaderViewModel
    @State private var settings = ComicReaderSettings.shared
    @State private var chromeVisible = true
    @State private var activeSheet: ComicSheet?
    @State private var showOverflow = false
    @State private var showLongPressMenu = false
    @State private var longPressPage = 0
    @State private var savedBrightness: CGFloat?
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss

    init(illustId: Int64, initialIllust: Illust?, openReader: @escaping (Int64) -> Void) {
        self.illustId = illustId
        self.initialIllust = initialIllust
        self.openReader = openReader
        _vm = State(wrappedValue: ComicReaderViewModel(illustId: illustId, illust: initialIllust))
    }

    private var immersiveHidden: Bool { settings.immersive && !chromeVisible }
    private var pixivURL: URL { URL(string: "https://www.pixiv.net/artworks/\(illustId)")! }

    var body: some View {
        ZStack {
            (settings.backgroundDark ? Color.black : Color.white).ignoresSafeArea()

            stage.ignoresSafeArea()

            if settings.warmFilterStrength > 0 {
                Color(hex: 0xFFB347)
                    .opacity(settings.warmFilterStrength)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            loadStateOverlay

            pageIndicator

            if chromeVisible { chrome }

            toast
        }
        .statusBarHidden(immersiveHidden)
        .persistentSystemOverlays(immersiveHidden ? .hidden : .automatic)
        .animation(.easeInOut(duration: 0.15), value: chromeVisible)
        .animation(.easeInOut(duration: 0.2), value: vm.toast != nil)
        .task {
            vm.configureL10n { l10n.t($0) }
            vm.onNavigateToReader = { openReader($0) }
            vm.onSessionStart()
            await vm.loadIfNeeded()
        }
        .onAppear { applyScreenEffects() }
        .onDisappear {
            vm.onSessionFlush()
            restoreScreenEffects()
        }
        .onChange(of: settings.keepScreenOn) { applyScreenEffects() }
        .onChange(of: settings.useSystemBrightness) { applyScreenEffects() }
        .onChange(of: settings.customBrightness) { applyScreenEffects() }
        .onChange(of: settings.loadOriginal) { vm.onImageSettingsChanged() }
        .onChange(of: settings.preloadAhead) { vm.onImageSettingsChanged() }
        .sheet(item: $activeSheet, content: sheetContent)
        .confirmationDialog("", isPresented: $showOverflow, titleVisibility: .hidden) {
            Button(l10n.t(.crBookmarksButton)) { activeSheet = .bookmarks }
            Button(l10n.t(.actionShare)) { activeSheet = .share(pixivURL) }
            Button(l10n.t(.viewAllComments)) { activeSheet = .comments }
        }
        .confirmationDialog("", isPresented: $showLongPressMenu, titleVisibility: .hidden) {
            Button(l10n.t(.crLongPressSave)) { Task { await savePage(longPressPage) } }
            Button(l10n.t(.crLongPressShare)) { activeSheet = .share(pixivURL) }
            Button(l10n.t(.crLongPressBookmark)) { vm.addBookmark(at: longPressPage) }
        }
    }

    // MARK: Stage

    @ViewBuilder
    private var stage: some View {
        if case .loaded = vm.loadState, !vm.pages.isEmpty {
            if settings.readingMode == .paged {
                ComicPagedContainer(
                    pages: vm.pages,
                    urlFor: { vm.url(for: $0) },
                    previewFor: { vm.previewUrl(for: $0) },
                    direction: settings.pageDirection,
                    fitMode: settings.fitMode,
                    flipAnim: settings.flipAnim,
                    loadOriginal: settings.loadOriginal,
                    doubleTapZoom: CGFloat(settings.doubleTapZoomLevel),
                    initialPage: vm.currentPage,
                    command: vm.command,
                    onPageSettled: { vm.reportPageSettled($0) },
                    onSingleTap: handleTap,
                    onLongPress: { longPressPage = $0; showLongPressMenu = true }
                )
            } else {
                ComicWebtoonContainer(
                    pages: vm.pages,
                    urlFor: { vm.url(for: $0) },
                    previewFor: { vm.previewUrl(for: $0) },
                    loadOriginal: settings.loadOriginal,
                    initialPage: vm.currentPage,
                    command: vm.command,
                    onVisiblePage: { vm.reportPageSettled($0) },
                    onTap: toggleChrome
                )
            }
        }
    }

    @ViewBuilder
    private var loadStateOverlay: some View {
        switch vm.loadState {
        case .loading, .idle:
            ProgressView().tint(.white).controlSize(.large)
        case .error(let message):
            Button {
                Task { await vm.reload() }
            } label: {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.clockwise")
                        .font(.title2)
                    Text(String(format: l10n.t(.crLoadFailed), message))
                        .font(.system(size: 14))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding(20)
            }
        case .loaded:
            if vm.pages.isEmpty {
                Text(l10n.t(.crNoPages))
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .padding(20)
            }
        }
    }

    @ViewBuilder
    private var pageIndicator: some View {
        if settings.showPageNumber, vm.pages.count > 1, case .loaded = vm.loadState {
            VStack {
                Spacer()
                Text("\(vm.currentPage + 1) / \(vm.pages.count)")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: .rect(cornerRadius: 6))
                    .padding(.bottom, chromeVisible ? 120 : 16)
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let toast = vm.toast {
            VStack {
                Spacer()
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.75), in: .capsule)
                    .padding(.bottom, 150)
            }
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    // MARK: Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            bottomBar
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            barButton("xmark") { dismiss() }
            Text(vm.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
            ShareLink(item: pixivURL) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            barButton("ellipsis") { showOverflow = true }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .padding(.top, topSafeInset)
        .background(Color.black.opacity(0.8))
    }

    private var bottomBar: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Text("\(vm.currentPage + 1)")
                    .font(.system(size: 12)).foregroundStyle(.white)
                    .frame(minWidth: 44)
                Slider(
                    value: Binding(
                        get: { Double(vm.currentPage) },
                        set: { newValue in
                            let target = Int(newValue.rounded())
                            if target != vm.currentPage { vm.jumpTo(target) }
                        }
                    ),
                    in: 0...Double(max(vm.pages.count - 1, 1))
                )
                .tint(.white)
                Text("\(vm.pages.count)")
                    .font(.system(size: 12)).foregroundStyle(.white)
                    .frame(minWidth: 44)
            }
            HStack(spacing: 0) {
                barButton("list.bullet.rectangle", weight: .regular) { openSeriesSheet() }
                barButton("chevron.left.2", weight: .regular) { Task { await vm.jumpSeriesNeighbor(forward: false) } }
                barButton("square.grid.2x2", weight: .regular) { openThumbsSheet() }
                barButton("arrow.left.arrow.right", weight: .regular) { settings.toggleDirection() }
                barButton("slider.horizontal.3", weight: .regular) { activeSheet = .settings }
                barButton("circle.lefthalf.filled", weight: .regular) { settings.backgroundDark.toggle() }
                barButton("chevron.right.2", weight: .regular) { Task { await vm.jumpSeriesNeighbor(forward: true) } }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .padding(.bottom, bottomSafeInset)
        .background(Color.black.opacity(0.8))
    }

    private func barButton(_ systemName: String, weight: Font.Weight = .semibold, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: weight))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .frame(maxWidth: .infinity)
    }

    private var topSafeInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }.max() ?? 0
    }
    private var bottomSafeInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }.max() ?? 0
    }

    // MARK: Tap handling

    private func handleTap(_ zone: ComicTapZone) {
        let reversed = settings.tapZoneReversed
        switch zone {
        case .center: toggleChrome()
        case .left:   vm.stepPage(forward: reversed)
        case .right:  vm.stepPage(forward: !reversed)
        }
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.15)) { chromeVisible.toggle() }
    }

    // MARK: Sheets

    private func openThumbsSheet() {
        guard !vm.pages.isEmpty else { vm.showToast(l10n.t(.crNoPages)); return }
        activeSheet = .thumbs
    }

    private func openSeriesSheet() {
        guard vm.illust?.series?.id != nil else { vm.showToast(l10n.t(.crNoSeries)); return }
        activeSheet = .series
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ComicSheet) -> some View {
        switch sheet {
        case .settings:
            ComicReaderSettingsSheet(settings: settings)
        case .thumbs:
            ComicThumbsSheet(
                pages: vm.pages,
                currentIndex: vm.currentPage,
                title: vm.title,
                previewFor: { vm.previewUrl(for: $0) }
            ) { idx in
                activeSheet = nil
                vm.jumpTo(idx)
            }
        case .bookmarks:
            ComicBookmarksSheet(
                illustId: illustId,
                onJump: { entry in activeSheet = nil; vm.jumpTo(entry.pageIndex) },
                onAddCurrent: { vm.addBookmark(at: vm.currentPage) }
            )
        case .series:
            ComicSeriesListSheet(vm: vm, currentIllustId: illustId) { target in
                activeSheet = nil
                openReader(target)
            }
        case .comments:
            NavigationStack {
                CommentsView(target: .illust(illustId))
            }
        case .share(let url):
            ComicShareSheet(items: [url])
        }
    }

    // MARK: Long-press: save current page to Photos

    private func savePage(_ index: Int) async {
        guard vm.pages.indices.contains(index),
              let url = vm.pages[index].original ?? vm.pages[index].large else { return }
        guard let data = await PixivImageCache.shared.loadData(url) else {
            vm.showToast(l10n.t(.crMsgOpFailed)); return
        }
        guard await PhotoLibrarySaver.requestAuthorization() else {
            vm.showToast(l10n.t(.crMsgOpFailed)); return
        }
        do {
            try await PhotoLibrarySaver.save(data: data)
            vm.showToast(l10n.t(.crMsgSaved))
        } catch {
            vm.showToast(l10n.t(.crMsgOpFailed))
        }
    }

    // MARK: Screen effects (ComicWindowController parity)

    private func applyScreenEffects() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        if settings.useSystemBrightness {
            if let saved = savedBrightness {
                UIScreen.main.brightness = saved
                savedBrightness = nil
            }
        } else {
            if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
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

/// UIActivityViewController wrapper for the share action triggered from menus.
struct ComicShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
