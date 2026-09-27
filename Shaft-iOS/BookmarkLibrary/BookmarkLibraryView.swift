import SwiftUI

/// 收藏库 —— 直接看本地镜像表的收藏列表页。
///
/// 1:1 移植自 `BookmarkLibraryFragment` / `NovelBookmarkLibraryFragment` + 共用的 `BookmarkLibraryUi`
/// （SwiftUI 没有「插画列表基类 vs 小说列表基类」的多继承问题，插画版与小说版在这里就是同一个 view，
/// 只在「一行 payload 解析成插画卡还是小说卡」那一步分岔）。
///
/// ## 它和「我的插画收藏」是什么关系
///
/// 「我的插画收藏」是**服务端顺序**的原样列表：只能从新到旧，翻到哪算哪。本页是同一批
/// 收藏的**本地副本**，所以能做服务端做不到的一切：倒序、按标签/作者/年份/画幅/人气筛、
/// 全文搜、随机漫游 —— 而且全在 SQLite 里，一次网络请求都不发。
///
/// 两者不是替代关系：镜像还没补齐的时候，原列表永远是最新最全的那份。所以本页在补齐之前
/// 会挂一条进度条老实说「还在补」，补齐之后那条就永远消失。
struct BookmarkLibraryView: View {
    let contentType: MirrorContentType
    let initialRestrict: MirrorRestrict

    @State private var vm: BookmarkLibraryViewModel
    @State private var observed = BookmarkMirrorObserved.shared
    @State private var network = NetworkState.shared
    @State private var mute = MuteStore.shared

    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var showFilter = false

    /// 触发换条件时列表所处的「代号」。等到提交上来的代号**变了**（= 新一代真的落地了）
    /// 才把列表拨回顶部，见 `applyFilterChange` / `onListCommitted`。
    @State private var resetAfterGeneration: Int?

    /// 上一次看到的库内行数，用来认出「库里多出了东西」。
    ///
    /// 它是**当前这个书架**的行数，所以换书架时必须清零（见 `switchShelf`）：不清的话，
    /// 新书架的第一次计数会被当成「多出来的东西」，刚切完立刻又重查一遍。
    @State private var lastKnownStored: Int?

    @State private var isAtTop = true

    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.pushRoute) private var pushRoute

    private static let searchDebounce: Duration = .milliseconds(280)

    init(contentType: MirrorContentType, restrict: MirrorRestrict) {
        self.contentType = contentType
        self.initialRestrict = restrict
        _vm = State(wrappedValue: BookmarkLibraryViewModel(contentType: contentType, restrict: restrict))
    }

    private var isIllust: Bool { contentType == .illust }
    /// 文案 / 可选排序 / 面板露出哪几节，全由书架类型的档案决定（`LibraryProfile`）。
    private var profile: LibraryProfile { LibraryProfile.of(contentType) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id("bookmark-library-top")
                    syncBanner
                    searchField
                    chipRow
                    listBody
                    footer
                }
                .padding(.bottom, 12)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y <= geometry.contentInsets.top + 4
            } action: { _, atTop in
                isAtTop = atTop
            }
            // 下拉刷新 = **去服务端对一次表头** + 重查本地。
            //
            // 本地源读的就是镜像表，镜像不动，再查一百次也还是同一批。而「下拉刷新」恰恰是用户
            // 想说「我在别处收藏了东西，去看看」时唯一会做的动作 —— 它必须真的去同步，否则这套
            // 镜像对「网页端/别的设备上的收藏」就是个死胡同。同步是异步的（受全局限速），
            // 新收藏落库后由 refreshIfStale 接手上屏。
            .refreshable {
                await BookmarkMirrorService.shared.syncNow(vm.shelf, reason: "下拉刷新")
                applyFilterChange()
            }
            .onChange(of: vm.committedGeneration) { _, committed in
                onListCommitted(committed, proxy: proxy)
            }
        }
        .background(Theme.v3Bg)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { shelfSwitch }
            ToolbarItem(placement: .topBarTrailing) { overflowMenu }
        }
        // 书架退回未补齐（例如刚重建）时筛选面板没有意义，直接关掉。
        .onChange(of: vm.isShelfComplete) { _, complete in if !complete { showFilter = false } }
        .sheet(isPresented: $showFilter) {
            BookmarkFilterSheet(vm: vm) { applyFilterChange() }
                .presentationDetents([.fraction(0.88)])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(28)
                .presentationBackground(Theme.v3Bg)
        }
        .onAppear {
            vm.bind()
            applyMirrorState()
            vm.loadIfNeeded()
            searchText = vm.filter.keyword
            // 打开收藏库本身就是一次「用户在看这个书架」的信号：让引擎马上补一次增量，
            // 而不是等下一个例行窗口。补的过程静默，页面照常用本地数据。
            // onAppear 在推入与返回时都会触发 —— 对应 Android 的 install + onResumed。
            Task { await BookmarkMirrorService.shared.ensureShelf(vm.shelf, reason: "打开\(contentType.tag)本地库") }
        }
        // 「在网页端收藏几张 → 切回 app 看看」是最典型的动作，而那个来回根本不会重建本页：
        // 回到前台也要再对一次，否则回来看到的还是走之前那份。
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await BookmarkMirrorService.shared.ensureShelf(vm.shelf, reason: "回到收藏库") }
            }
        }
        .onChange(of: observed.states) { _, _ in applyMirrorState() }
        // 按 owner 订阅：页面可以就地切书架，按 shelfKey 订的话每切一次都要重订
        .onChange(of: observed.ownerCount) { _, _ in vm.onMirrorChanged() }
        // 进度条上的「已 N 件」跟着镜像行数走；顺带在这里判「屏幕上的内容是不是已经过期」
        // ——必须挂在 totalCount 上而不是 ownerCount 上，因为后者发射时 refreshCounts 才刚启动。
        .onChange(of: vm.totalCount) { _, _ in refreshIfStale() }
        // 条件被别处清空了（筛选面板里的「清空」），搜索框要跟着空掉。只做「清空」这一个方向：
        // 绝不拿 filter 去覆盖用户正在敲的内容。
        .onChange(of: vm.filter.keyword) { _, keyword in
            if keyword.isEmpty, !searchText.isEmpty { searchText = "" }
        }
        .onChange(of: searchText) { _, text in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: Self.searchDebounce)
                guard !Task.isCancelled else { return }
                if vm.updateFilter({ $0.keyword = text }) { applyFilterChange() }
            }
        }
    }

    // MARK: 顶栏

    /// toolbar 里只放这一个东西：公开 / 悄悄收藏的切换。分段控件本身就把「这是收藏页 /
    /// 现在在看哪一半 / 另一半在哪」三件事一次说清了，不再单独摆一行标题。
    private var shelfSwitch: some View {
        HStack(spacing: 0) {
            shelfOption(.public, title: l10n.t(profile.publicShelf))
            shelfOption(.private, title: l10n.t(profile.privateShelf))
        }
        .padding(3)
        .background(Theme.brand.opacity(0.16), in: .capsule)
    }

    private func shelfOption(_ restrict: MirrorRestrict, title: String) -> some View {
        let active = vm.shelf.restrict == restrict
        return Button {
            switchShelf(restrict)
        } label: {
            Text(title)
                .font(.system(size: 13, weight: active ? .bold : .medium))
                .foregroundStyle(active ? Color.white : Theme.v3TextSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .frame(minWidth: 88)
                .background(active ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.clear), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private var overflowMenu: some View {
        Menu {
            // 「原始收藏列表」是留给「我要看服务端原本的样子」的退路：本页展示的是本地镜像
            //（顺序是本地重排的，内容取的是镜像时冻结的快照）。
            Button {
                openClassicCollection()
            } label: {
                Label(l10n.t(profile.openClassic), systemImage: "list.bullet.rectangle")
            }
            Button(role: .destructive) {
                rebuildMirror()
            } label: {
                Label(l10n.t(.bookmarkLibraryRebuild), systemImage: "arrow.counterclockwise")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    /// 打开原始的双 tab 收藏页。带 `classic` 标记，那边据此**不再**把入口重定向回本页，
    /// 否则用户从本页点进去会被立刻弹回来，两个页面互相踢皮球。
    private func openClassicCollection() {
        let uid = vm.shelf.ownerUid
        switch contentType {
        case .illust: pushRoute(.userBookmarks(userId: uid, classic: true))
        case .novel: pushRoute(.userNovelBookmarks(userId: uid, classic: true))
        case .user: pushRoute(.userFollowing(userId: uid, classic: true))
        }
    }

    private func rebuildMirror() {
        let shelf = vm.shelf
        mirrorLog.info("用户手动重建镜像 \(shelf.label, privacy: .public)")
        // **刻意不在这里刷新**：清空发生在引擎自己的 actor 里，这里立刻刷只会读到清空前的数据。
        // 交给 refreshIfStale —— 清空落库后 totalCount 会掉到 0，它自然会把屏幕对齐，
        // 回填补进来之后再对齐一次。
        Task { await BookmarkMirrorService.shared.rebuildShelf(shelf) }
    }

    /// 公开 / 悄悄收藏切换。点「悄悄收藏」本身就是一次明确的用户意图，所以顺带把那个书架
    /// 注册进镜像（`trackBookmarkShelfVisit` 同款的隐私边界：没主动看过就不会去拉）。
    private func switchShelf(_ restrict: MirrorRestrict) {
        let current = vm.shelf
        if current.restrict == restrict { return }
        let next = current.with(restrict: restrict)
        guard vm.switchShelf(next) else { return }
        // 行数基准跟着书架走：换了书架，上一个书架的行数就不再是比较的参照物
        lastKnownStored = nil
        searchText = ""
        Task { await BookmarkMirrorService.shared.ensureShelf(next, reason: "收藏库切换到\(next.restrict.apiValue)") }
        applyMirrorState()
        applyFilterChange()
    }

    // MARK: 进度条 / 搜索 / chip

    /// 后台镜像进度。**只在还没补齐时出现**：补齐之后它永远消失，不再占一行
    ///（这是「同步完成过一次，以后只维护」在界面上的表达）。
    @ViewBuilder
    private var syncBanner: some View {
        if let state = vm.mirrorState, !state.isFirstSyncDone {
            let now = BookmarkMirrorService.nowMs()
            // 离线时引擎每个 tick 都直接返回 Idle（连库都不查），一页都不会补。
            // 这时候还挂着「正在后台补齐」就是在骗人。
            let offline = !network.isOnline
            let cooling = state.cooldownUntil > now
            let text: String = {
                if offline { return l10n.t(.bookmarkLibrarySyncOffline) }
                if cooling { return l10n.t(.bookmarkLibrarySyncCooldown) }
                if state.phase == MirrorPhase.backfilling.rawValue {
                    return l10n.t(profile.syncing, BookmarkLibraryFormat.count(vm.totalCount ?? 0))
                }
                return l10n.t(profile.syncQueued)
            }()
            HStack(spacing: 10) {
                // 转圈只在真的在补的时候转；离线/冷却时停下来，别让一个永远转着的圈暗示「马上就好」
                ProgressView()
                    .controlSize(.small)
                    .opacity(offline || cooling ? 0 : 1)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.v3Text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .v3Glass(corner: 20)
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    /// 搜索：标题 / 作者 / 标签（含译名）逐词 AND
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.v3Text3)
            TextField(l10n.t(profile.searchHint), text: $searchText)
                .font(.system(size: 14))
                .foregroundStyle(Theme.v3Text1)
                .submitLabel(.search)
                .autocorrectionDisabled()
                // 补齐前只按默认顺序浏览：搜索、排序与筛选在全量完成后开放（#1109）。
                .disabled(!vm.isShelfComplete)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.v3Text3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .v3Glass(corner: 20)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// 筛选 chip 行。横滑而不是折行：条件多了也只占一行高度，且「往右还有更多」这件事
    /// 靠露出半个 chip 自己就说清楚了。
    private var chipRow: some View {
        let filter = vm.filter
        let conditions = filter.conditionCount
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              if !vm.isShelfComplete {
                // 补齐中：排序 / 倒序 / 随机 / 筛选统统收起，只留一枚不可点的说明 chip。
                BookmarkChip(label: l10n.t(.bookmarkChipSyncing), activated: false) {}
                    .allowsHitTesting(false)
              } else {
                // 排序 chip 只在「不是默认排序」时点亮：默认态点亮一片，选中态就不再是信息了
                BookmarkChip(label: l10n.t(profile.sortLabel(filter.sort)), activated: filter.sort != .bookmarkNewest) {
                    showFilter = true
                }
                // 倒序是本页存在的直接理由，必须是一键，不能埋进面板
                BookmarkChip(label: l10n.t(.bookmarkChipOldestFirst), activated: filter.sort == .bookmarkOldest) {
                    let next: BookmarkSort = filter.sort == .bookmarkOldest ? .bookmarkNewest : .bookmarkOldest
                    if vm.updateFilter({ $0.sort = next }) { applyFilterChange() }
                }
                BookmarkChip(label: l10n.t(.bookmarkChipRandom), activated: filter.sort.isRandom) {
                    // 已经在随机态时再点 = 重新洗牌，所以种子每次都换
                    let alreadyRandom = filter.sort.isRandom
                    let changed = vm.updateFilter {
                        if !alreadyRandom { $0.sort = .random }
                        $0.randomSeed = BookmarkMirrorService.nowMs()
                    }
                    if changed { applyFilterChange() }
                }
                BookmarkChip(
                    label: conditions > 0 ? l10n.t(.bookmarkChipFilterCount, "\(conditions)") : l10n.t(.bookmarkChipFilter),
                    activated: conditions > 0
                ) {
                    showFilter = true
                }
                // 「清空」只在真有东西可清时出现：常驻一个永远灰着的按钮只是噪音
                if filter.hasAnyCondition {
                    BookmarkChip(label: l10n.t(.bookmarkChipClear), activated: false) {
                        searchText = ""
                        if vm.clearConditions() { applyFilterChange() }
                    }
                }
              }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 10)
    }

    // MARK: 列表

    @ViewBuilder
    private var listBody: some View {
        if vm.itemCount == 0 {
            if let err = vm.errorMessage {
                InlineError(message: err) { applyFilterChange() }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            } else if vm.isLoading, vm.committedGeneration == 0 {
                Group {
                    switch contentType {
                    case .illust: WaterfallSkeleton(columns: mute.waterfallColumns)
                    case .novel: NovelListSkeleton()
                    case .user: UserListSkeleton()
                    }
                }
                .padding(.top, 8)
            } else if !vm.isLoading {
                emptyState
            }
        } else if isIllust {
            WaterfallGrid(
                items: vm.illusts,
                columns: mute.waterfallColumns,
                spacing: 8,
                estimatedRelativeHeight: { $0.waterfallImageHeightRatio }
            ) { illust in
                NavigationLink(value: illust) {
                    IllustWaterfallCell(illust: illust)
                }
                .buttonStyle(.plain)
                .contextMenu { IllustCardMenuItems(illust: illust) { vm.illusts } }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            // 与 V3InlineIllustGrid 同款：长按菜单的宿主只套在瀑布流上；小说分支的
            // NovelListContent 自带宿主，整页再套一层会把同一批 sheet / destination 注册两遍。
            .cardMenuHost()
        } else if contentType == .novel {
            NovelListContent(novels: vm.novels, hasMore: false, onLoadMore: nil)
                .padding(.top, 8)
        } else {
            // 关注库：与原关注列表同一张用户卡（点进画师页）
            LazyVStack(spacing: 12) {
                ForEach(vm.users) { preview in
                    NavigationLink(value: AppRoute.userProfile(preview.user.id)) {
                        UserPreviewRow(preview: preview)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
    }

    /// 空态要分清三种「空」，不然用户没法知道该等还是该改条件：
    /// 条件筛没了 / 镜像还没补到这个书架 / 是真的一件都没收藏。
    private var emptyState: some View {
        let text: String = {
            if vm.filter.hasAnyCondition { return l10n.t(profile.emptyFiltered) }
            if let state = vm.mirrorState, !state.isFirstSyncDone { return l10n.t(.bookmarkLibraryEmptySyncing) }
            return l10n.t(profile.empty)
        }()
        return VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 34))
                .foregroundStyle(Theme.v3Text3)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.v3Text3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private var footer: some View {
        if vm.isLoading, vm.itemCount > 0 {
            ProgressView().frame(maxWidth: .infinity).padding()
        } else if vm.hasMore, vm.itemCount > 0 {
            if vm.needsManualLoad {
                Button {
                    vm.loadMoreManually()
                } label: {
                    Label(l10n.t(.discoverSeeMore), systemImage: "arrow.down.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.v3TextAccent)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear
                    .frame(height: 40)
                    .onAppear { vm.loadMore() }
            }
        }
    }

    // MARK: 接线

    /// 换筛选 / 排序 / 书架之后重新出列表。记下当前代号，等新一代真正提交完再确定性地复位到顶部。
    private func applyFilterChange() {
        resetAfterGeneration = vm.committedGeneration
        vm.refresh()
    }

    /// 认代号而不是认一个布尔标记：每次提交都会来，**包括往下滑追加的页**。
    /// 代号变了才动手，追加页的代号不变，绝不会误伤。
    private func onListCommitted(_ committed: Int, proxy: ScrollViewProxy) {
        guard let target = resetAfterGeneration else { return }
        if committed == target { return }
        resetAfterGeneration = nil
        proxy.scrollTo("bookmark-library-top", anchor: .top)
    }

    /// 屏幕上这份列表和库里对不上了 → 自动重查一次。
    ///
    /// 判据刻意只是**两边条数的对账**，不掺「镜像同步到哪一步了」：
    ///
    /// - `库里被清空而屏幕上还有东西`：刚点了「重建本地镜像」。**不能放宽成「库里 < 屏幕」**：
    ///   取消收藏会即时删掉镜像行而卡片留在屏幕上（与原收藏页一致，只翻空那颗心）。
    /// - `屏幕为空而库里有货`：本地源查到 0 行时判定「到底了」，从此不再问数据源要任何东西。
    ///   所以镜像补进第一批之后，得有人推它一把。
    /// - `库里多出了东西，而用户正停在列表顶部`：默认排序下新收藏就排在最上面，用户正看着那儿，
    ///   插进去是他期待的；滚到下面时一律不动。且只在已经补齐过一次之后：首次回填期新行是
    ///   从新往旧一路往**末尾**加的，顶部根本不会变。
    ///
    /// **不要**拿 `isFirstSyncDone` 当条件：它恰好在最后一页落库的同一时刻翻成 true，
    /// 「补齐中且空」这条判据会在最需要它的那一瞬间失效。条数对账没有这个时序缝隙。
    private func refreshIfStale() {
        // 已经有一次刷新在路上：此刻屏幕上本来就是旧的，而且正在被修。
        if resetAfterGeneration != nil { return }
        if vm.filter.hasAnyCondition { return }
        // 回填只向尾部增长，优先续接，避免最后一页同步完成时整表刷新并跳回顶部。
        vm.resumeGrowingTail()
        let shown = vm.itemCount
        guard let stored = vm.totalCount else { return }
        let previous = lastKnownStored
        lastKnownStored = stored

        let clearedWhileShown = stored == 0 && shown > 0
        let emptyButStored = shown == 0 && stored > 0 && !vm.isLoading
        let grewWhileAtTop = previous != nil &&
            stored > previous! &&
            vm.mirrorState?.isFirstSyncDone == true &&
            isAtTop

        guard clearedWhileShown || emptyButStored || grewWhileAtTop else { return }
        mirrorLog.debug("列表与库对不上，自动重查（库内 \(stored) 行 / 屏幕 \(shown) 条，新增上屏=\(grewWhileAtTop)）")
        applyFilterChange()
    }

    /// 从最近一份状态列表里挑出**当前**书架那条，喂给 VM。
    private func applyMirrorState() {
        let reset = vm.setMirrorState(observed.state(of: vm.shelf))
        if reset { applyFilterChange() }
        // 没补齐：搜索框不可用，里面还在防抖的输入一并丢掉。
        if !vm.isShelfComplete, !searchText.isEmpty { searchText = "" }
    }
}

// MARK: - 零件

/// `bg_bookmark_chip` 的 SwiftUI 版：14dp 圆角胶囊，选中用主题色实底表达；排除态用危险色。
struct BookmarkChip: View {
    let label: String
    var activated: Bool = false
    var excluded: Bool = false
    var onTap: () -> Void
    var onLongPress: (() -> Void)? = nil

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: activated || excluded ? .semibold : .regular))
            .lineLimit(1)
            .foregroundStyle(excluded || activated ? Color.white : Theme.v3Text2)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                excluded ? AnyShapeStyle(Theme.v3Danger)
                    : activated ? AnyShapeStyle(Theme.brand)
                    : AnyShapeStyle(Theme.v3Surface2),
                in: .rect(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(activated || excluded ? Color.clear : Theme.v3Border1, lineWidth: 1)
            )
            .contentShape(.rect)
            .onTapGesture { onTap() }
            .onLongPressGesture(minimumDuration: 0.4) {
                if let onLongPress { onLongPress() }
            }
    }
}

enum BookmarkSortLabels {
    static func key(_ sort: BookmarkSort) -> LocalizedKey {
        switch sort {
        case .bookmarkNewest: return .bookmarkSortBookmarkNewest
        case .bookmarkOldest: return .bookmarkSortBookmarkOldest
        case .createdNewest: return .bookmarkSortCreatedNewest
        case .createdOldest: return .bookmarkSortCreatedOldest
        case .popularDesc: return .bookmarkSortPopularDesc
        case .popularAsc: return .bookmarkSortPopularAsc
        case .viewsDesc: return .bookmarkSortViewsDesc
        case .pagesDesc: return .bookmarkSortPagesDesc
        case .lengthDesc: return .bookmarkSortLengthDesc
        case .lengthAsc: return .bookmarkSortLengthAsc
        case .titleAsc: return .bookmarkSortTitleAsc
        case .random: return .bookmarkSortRandom
        }
    }
}
