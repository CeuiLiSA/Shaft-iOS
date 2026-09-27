import Foundation
import Observation

/// 本地库页面的读侧门面：把 `BookmarkMirrorQuery` 拼出来的 SQL 跑掉，并把行还原成
/// `Illust` / `Novel` / `UserPreview`。
///
/// 1:1 移植自 `ceui.pixiv.ui.library.BookmarkLibraryRepo`。全部方法 main-safe（内部走 DB actor）。
enum BookmarkLibraryRepo {

    /// 标签云一次最多给这么多；再多用户也扫不过来，还会把 sheet 撑成长列表。
    static let tagFacetLimit = 120
    static let authorFacetLimit = 80

    private static var db: BookmarkMirrorDatabase { BookmarkMirrorDatabase.shared }

    static func page(_ filter: BookmarkFilter, limit: Int, offset: Int, afterSeq: Int64? = nil) async throws -> [BookmarkMirrorEntity] {
        let startedAt = Date()
        let query = afterSeq.map { BookmarkMirrorQuery.rowsAfter(shelfKey: filter.shelfKey, afterSeq: $0, limit: limit) }
            ?? BookmarkMirrorQuery.rows(filter, limit: limit, offset: offset)
        let rows = try await db.rawRows(query)
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        mirrorLog.debug("查询 offset=\(offset) limit=\(limit) sort=\(String(describing: filter.sort), privacy: .public) → \(rows.count) 行，耗时 \(ms)ms")
        return rows
    }

    static func count(_ filter: BookmarkFilter) async throws -> Int {
        try await db.rawCount(BookmarkMirrorQuery.count(filter))
    }

    static func tagFacets(_ filter: BookmarkFilter) async throws -> [BookmarkTagFacet] {
        let startedAt = Date()
        let facets = try await db.rawTagFacets(BookmarkMirrorQuery.tagFacets(filter, limit: tagFacetLimit))
        mirrorLog.debug("标签云 \(facets.count) 项，耗时 \(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
        return facets
    }

    static func authorFacets(_ filter: BookmarkFilter) async throws -> [BookmarkAuthorFacet] {
        try await db.rawAuthorFacets(BookmarkMirrorQuery.authorFacets(filter, limit: authorFacetLimit))
    }

    static func yearFacets(shelfKey: String) async throws -> [BookmarkYearFacet] {
        try await db.yearFacets(shelfKey: shelfKey)
    }

    static func totalRows(shelfKey: String) async throws -> Int {
        try await db.countOf(shelfKey: shelfKey)
    }

    /// 行 → `Illust`。
    ///
    /// 坏行（旧版本写的 JSON、被截断的 payload）只丢这一条并留一条日志，不让整页炸掉：
    /// 镜像表是后台攒了几万行的东西，一条坏行毁掉整个页面完全不成比例。
    nonisolated static func toIllust(_ row: BookmarkMirrorEntity) -> Illust? { deserialize(row) }

    /// 行 → `Novel`。容错策略同 `toIllust`。
    nonisolated static func toNovel(_ row: BookmarkMirrorEntity) -> Novel? { deserialize(row) }

    /// 关注书架的行 → `UserPreview`。容错策略同 `toIllust`。
    nonisolated static func toUserPreview(_ row: BookmarkMirrorEntity) -> UserPreview? { deserialize(row) }

    private nonisolated static func deserialize<T: Decodable>(_ row: BookmarkMirrorEntity) -> T? {
        do {
            return try JSONDecoder().decode(T.self, from: Data(row.payloadJson.utf8))
        } catch {
            mirrorLog.warning("镜像行反序列化失败 shelf=\(row.shelfKey, privacy: .public) id=\(row.targetId): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// 收藏库页的状态中枢。
///
/// 1:1 移植自 `BookmarkLibraryViewModel` + `BookmarkLibraryFeedSource`：**筛选条件归 VM**，
/// 列表本体也在这里（本地 offset 分页），sheet 与页面共用同一个实例。
///
/// 计数与 facet 是**独立于列表**的查询：它们要回答的是「这套条件一共命中多少件」
/// 和「还能往下钻哪些标签」，而列表只加载看得见的那几十条。分开跑，列表才不会
/// 为了显示一个总数去把三万行全捞出来。
@MainActor
@Observable
final class BookmarkLibraryViewModel {

    let contentType: MirrorContentType

    /// 已经绑定过书架没有。
    private(set) var bound = false

    private(set) var shelf: BookmarkShelf

    private(set) var filter: BookmarkFilter

    /// 当前筛选命中的件数；nil = 还在算。
    private(set) var resultCount: Int?

    /// 这个书架本地一共镜像了多少件（不受筛选影响）。
    private(set) var totalCount: Int?

    /// 后台镜像的同步状态（进度条 / 「还在补齐」提示）。
    private(set) var mirrorState: BookmarkMirrorStateEntity?

    private(set) var tagFacets: [BookmarkTagFacet] = []
    private(set) var authorFacets: [BookmarkAuthorFacet] = []
    private(set) var yearFacets: [BookmarkYearFacet] = []

    // MARK: 列表（BookmarkLibraryFeedSource 的本地分页）

    private(set) var illusts: [Illust] = []
    private(set) var novels: [Novel] = []
    private(set) var users: [UserPreview] = []
    private(set) var isLoading = false
    private(set) var hasMore = false
    private(set) var errorMessage: String?
    /// 每次「换条件重出列表」+1。页面用它判断新一代是否真的落地了（见 `committedGeneration`）。
    private(set) var refreshGeneration = 0
    /// 最近一次提交上屏的列表所属的代号。
    private(set) var committedGeneration = 0
    /// 连着甩满 `burstPageBudget` 页后停下来等用户点 footer（见 `pagingPolicy` 的说明）。
    private(set) var needsManualLoad = false

    /// 屏幕上有多少条目（`itemCount`）。
    var itemCount: Int {
        switch contentType {
        case .illust: return illusts.count
        case .novel: return novels.count
        case .user: return users.count
        }
    }

    @ObservationIgnored private var loadedRows = 0
    /// 上一页最后一条**原始 SQL 行**的收藏序号（不是过滤后的卡片）——默认顺序按它续页。
    @ObservationIgnored private var loadedTailSeq: Int64?

    /// 书架补齐过一次了吗：没补齐前只有最新一段收藏，只按默认顺序浏览，筛选稍后可用。
    var isShelfComplete: Bool { mirrorState?.isFirstSyncDone == true }

    /// 默认顺序 + 无条件：这一种才带稳定的收藏序号游标（其他排序 / 筛选仍用 offset）。
    private var isStableOrder: Bool { filter.sort == .bookmarkNewest && !filter.hasAnyCondition }
    @ObservationIgnored private var burstPages = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// 单飞：筛选条件连着改（用户在 sheet 里一路点）时只留最后一次的查询。
    @ObservationIgnored private var countTask: Task<Void, Never>?
    @ObservationIgnored private var facetTask: Task<Void, Never>?
    @ObservationIgnored private var yearTask: Task<Void, Never>?

    /// ownerUid 在 `bind` 时才从钥匙串解析：view 的 init 会随父视图每次重算而反复执行，
    /// 不该把一次 SecItemCopyMatching 挂在那条路径上。
    init(contentType: MirrorContentType, restrict: MirrorRestrict) {
        self.contentType = contentType
        self.shelf = BookmarkShelf(ownerUid: 0, contentType: contentType, restrict: restrict)
        self.filter = BookmarkFilter(shelfKey: "")
    }

    /// 幂等绑定。
    func bind() {
        if bound { return }
        bound = true
        shelf = shelf.with(ownerUid: BookmarkMirrorService.loggedInUid())
        filter = BookmarkFilter(shelfKey: shelf.key)
        mirrorLog.debug("绑定书架 \(self.shelf.label, privacy: .public)")
        refreshCounts()
        refreshFacets()
        refreshYearFacets()
    }

    /// 就地换一个书架（公开 ↔ 悄悄收藏）。返回 true 表示真的换了。
    ///
    /// **排序保留、筛选条件清空**：排序是「我想怎么看」，换个书架依然成立；而标签 / 作者 /
    /// 年份都是从**这个书架**的内容里统计出来的，带到另一个书架上多半是一条都命中不了的死条件
    /// ——用户会看见一个空列表却不知道为什么。关键词同理（多半是刚才那批内容里的词），一并清掉。
    @discardableResult
    func switchShelf(_ next: BookmarkShelf) -> Bool {
        if bound, shelf == next { return false }
        bound = true
        shelf = next
        var fresh = BookmarkFilter(shelfKey: next.key)
        fresh.sort = filter.sort
        fresh.randomSeed = filter.randomSeed
        filter = fresh
        mirrorLog.debug("切换到书架 \(next.label, privacy: .public)")
        resultCount = nil
        totalCount = nil
        tagFacets = []
        authorFacets = []
        yearFacets = []
        refreshCounts()
        refreshFacets()
        refreshYearFacets()
        return true
    }

    /// 改筛选条件。返回 true 表示真的变了（调用方据此决定要不要重刷列表）——
    /// sheet 里点一下又点回来是很常见的，白刷一次列表会让滚动位置无谓地跳回顶部。
    @discardableResult
    func updateFilter(_ transform: (inout BookmarkFilter) -> Void) -> Bool {
        var next = filter
        // 补齐前只有最新一段收藏，不能让筛选或倒序把它伪装成完整结果（#1109）。
        if isShelfComplete {
            transform(&next)
        } else {
            next = BookmarkFilter(shelfKey: filter.shelfKey)
        }
        if next == filter { return false }
        filter = next
        mirrorLog.debug("筛选变更 sort=\(String(describing: next.sort), privacy: .public) kw='\(next.keyword, privacy: .public)' tags=\(next.tagNames.count) 排除=\(next.excludedTagNames.count) 作者=\(next.authorIds.count) 类型=\(next.workTypes, privacy: .public)")
        refreshCounts()
        refreshFacets()
        return true
    }

    /// 清空全部条件，只留书架与排序（排序是「我想怎么看」，不是「我要看哪些」）。
    @discardableResult
    func clearConditions() -> Bool {
        updateFilter { current in
            var fresh = BookmarkFilter(shelfKey: current.shelfKey)
            fresh.sort = current.sort
            fresh.randomSeed = current.randomSeed
            current = fresh
        }
    }

    /// 返回是否因未补齐而复位了条件；调用方据此重查列表。
    @discardableResult
    func setMirrorState(_ state: BookmarkMirrorStateEntity?) -> Bool {
        let wasComplete = isShelfComplete
        if mirrorState != state { mirrorState = state }
        // 刚补齐：标签 / 作者这些筛选选项现在才完整，重算一次。
        if !wasComplete && isShelfComplete { refreshFacets() }
        return !isShelfComplete && updateFilter { _ in }
    }

    /// 回填只向尾部增长：默认顺序下列表已经读到（暂时的）底、而库里又多出了行，
    /// 就重开游标让 footer 接着读，不整表刷新、不跳回顶部。
    func resumeGrowingTail() {
        guard isStableOrder, !hasMore, !isLoading, loadTask == nil, committedGeneration > 0,
              let stored = totalCount, stored > loadedRows else { return }
        hasMore = true
    }

    /// 后台又镜像进来一批：命中数、总数、年份分布都得跟着变。
    /// 这是**唯一**该重算年份分布的时机（见 `refreshYearFacets`）。
    func onMirrorChanged() {
        refreshCounts()
        refreshYearFacets()
    }

    /// 只重算「当前条件命中多少 / 库里一共多少」。筛选变更走这条，年份分布不掺进来。
    func refreshCounts() {
        let current = filter
        if current.shelfKey.isEmpty { return }
        countTask?.cancel()
        countTask = Task {
            do {
                let hits = try await BookmarkLibraryRepo.count(current)
                let total = try await BookmarkLibraryRepo.totalRows(shelfKey: current.shelfKey)
                guard !Task.isCancelled else { return }
                resultCount = hits
                totalCount = total
            } catch is CancellationError {
            } catch {
                // 计数只服务标题栏上的一个数字，失败了显示「—」就够，不该把页面搞崩
                mirrorLog.warning("计数失败: \(String(describing: error), privacy: .public)")
                resultCount = nil
            }
        }
    }

    /// 年份分布。**刻意不放进 `refreshCounts`**：它是 `strftime` + GROUP BY 的全书架扫描，
    /// 却只跟「库里有哪些年份的作品」有关，跟当前筛选条件毫无关系 —— 挂在筛选路径上的话，
    /// 用户在面板里每点一下 chip 都要白扫一遍全表。只在绑定时和镜像行数变化时跑。
    private func refreshYearFacets() {
        let shelfKey = filter.shelfKey
        if shelfKey.isEmpty { return }
        yearTask?.cancel()
        yearTask = Task {
            do {
                let years = try await BookmarkLibraryRepo.yearFacets(shelfKey: shelfKey)
                guard !Task.isCancelled else { return }
                if yearFacets != years { yearFacets = years }
            } catch is CancellationError {
            } catch {
                mirrorLog.warning("年份分布统计失败: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func refreshFacets() {
        let current = filter
        if current.shelfKey.isEmpty { return }
        facetTask?.cancel()
        facetTask = Task {
            do {
                let tags = try await BookmarkLibraryRepo.tagFacets(current)
                let authors = try await BookmarkLibraryRepo.authorFacets(current)
                guard !Task.isCancelled else { return }
                tagFacets = tags
                authorFacets = authors
            } catch is CancellationError {
            } catch {
                mirrorLog.warning("facet 统计失败: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: 列表

    /// 换筛选 / 排序 / 书架之后重新出列表：整代替换，从 offset 0 重查。
    func refresh() {
        loadTask?.cancel()
        refreshGeneration += 1
        burstPages = 0
        thinFillHops = 0
        needsManualLoad = false
        errorMessage = nil
        let generation = refreshGeneration
        loadedTailSeq = nil
        loadTask = Task { await load(offset: 0, afterSeq: nil, generation: generation) }
    }

    /// 首次进入（列表还是空的）才拉，旋转/返回不重拉。
    func loadIfNeeded() {
        if committedGeneration == 0, loadTask == nil { refresh() }
    }

    /// 滑到底自动追加。连着甩满 `burstPageBudget` 页就停下来等用户点 footer。
    func loadMore() {
        guard hasMore, !isLoading, !needsManualLoad else { return }
        if burstPages >= Self.burstPageBudget {
            needsManualLoad = true
            return
        }
        burstPages += 1
        let generation = refreshGeneration
        let offset = loadedRows
        let afterSeq = isStableOrder ? loadedTailSeq : nil
        loadTask = Task { await load(offset: offset, afterSeq: afterSeq, generation: generation) }
    }

    /// 用户点了 footer：预算归零，接着翻。
    func loadMoreManually() {
        burstPages = 0
        needsManualLoad = false
        loadMore()
    }

    /// 本地一页 60 条：查询是索引扫描，反序列化才是大头，60 条约几毫秒。
    private static let pageSize = 60

    /// 一串连着翻最多累积多少页（× pageSize ≈ 1800 件）。
    ///
    /// 本地翻页没有网络代价，所以间隔闸门可以整个去掉；但**页数预算必须留着**：预算是唯一
    /// 约束「列表能长到多大」的东西。翻过的页是**累加**在内存里的，而收藏几万件的用户在这里
    /// 一路甩下去是零成本的 —— 3 万条 `Illust`（每条带 tags / user / image_urls）能吃掉上百 MB。
    private static let burstPageBudget = 30

    private func load(offset: Int, afterSeq: Int64?, generation: Int) async {
        isLoading = true
        defer { if generation == refreshGeneration { isLoading = false } }
        let filter = self.filter
        guard !filter.shelfKey.isEmpty else {
            // VM 还没 bind（理论上不会：页面 onAppear 里先 bind）。与其抛，不如给一页空的。
            mirrorLog.warning("VM 尚未绑定书架，返回空页")
            commit(illusts: [], novels: [], users: [], rows: 0, offset: offset, generation: generation)
            return
        }
        do {
            let rows = try await BookmarkLibraryRepo.page(filter, limit: Self.pageSize, offset: offset, afterSeq: afterSeq)
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            // 锚点取原始 SQL 行，不能取被全局屏蔽规则过滤后的卡片。
            if let last = rows.last?.bookmarkSeq { loadedTailSeq = last }
            // 内容过滤跟着「它替代的那个页面」走：屏蔽标签 / 屏蔽画师 / R18 / AI 屏蔽照常生效
            // —— 那几条是用户对特定对象或类别的显式表态，换个入口就绕过去，等于这个新页面偷偷
            // 把用户明确说过不想看的东西放了进来。两处让步：用户在筛选面板里**显式选了分级**
            // → 跳过全局 R18 过滤，否则那个控件会变成一个永远筛出 0 条的死按钮；显式选了 AI 档同理。
            // 「作品状态」那一维交给 SQL：它还要能反过来只看失效的，所以这里不做二次挡。
            let applyR18 = filter.age == .any
            let dropAI = filter.ai == .any && AppSettingsStore.shared.deleteAIIllust
            let mute = MuteStore.shared
            // ⚠️ 反序列化切线程：一页 60 条完整 JSON 落在滚动路径上就是肉眼可见的掉帧。
            switch contentType {
            case .illust:
                let decoded = await Task.detached(priority: .userInitiated) {
                    rows.compactMap(BookmarkLibraryRepo.toIllust)
                }.value
                guard !Task.isCancelled, generation == refreshGeneration else { return }
                let visible = mute.filter(decoded, applyR18: applyR18).filter { !dropAI || $0.illustAIType != 2 }
                commit(illusts: visible, novels: [], users: [], rows: rows.count, offset: offset, generation: generation)
            case .novel:
                let decoded = await Task.detached(priority: .userInitiated) {
                    rows.compactMap(BookmarkLibraryRepo.toNovel)
                }.value
                guard !Task.isCancelled, generation == refreshGeneration else { return }
                // 对齐小说收藏页：字数/超长 tag 那套反刷屏阈值是冲着发现面上的广告去的，
                // 不该把用户自己收藏过的短文从藏书里抹掉；这里只走屏蔽 + R18 + AI。
                let visible = mute.filter(decoded, applyR18: applyR18).filter { !dropAI || $0.novelAIType != 2 }
                commit(illusts: [], novels: visible, users: [], rows: rows.count, offset: offset, generation: generation)
            case .user:
                let decoded = await Task.detached(priority: .userInitiated) {
                    rows.compactMap(BookmarkLibraryRepo.toUserPreview)
                }.value
                guard !Task.isCancelled, generation == refreshGeneration else { return }
                // 对齐原关注列表：不套作品屏蔽规则，只丢没有身份的坏行
                commit(illusts: [], novels: [], users: decoded.filter { $0.user.id > 0 }, rows: rows.count, offset: offset, generation: generation)
            }
        } catch is CancellationError {
        } catch {
            guard generation == refreshGeneration else { return }
            mirrorLog.warning("列表查询失败: \(String(describing: error), privacy: .public)")
            errorMessage = error.localizedDescription
            // 否则 resumeGrowingTail / loadIfNeeded 会一直以为还有一次查询在路上
            loadTask = nil
        }
    }

    private func commit(illusts: [Illust], novels: [Novel], users: [UserPreview], rows: Int, offset: Int, generation: Int) {
        if offset == 0 {
            self.illusts = illusts
            self.novels = novels
            self.users = users
        } else {
            let seenUser = Set(self.users.map(\.id))
            self.users.append(contentsOf: users.filter { !seenUser.contains($0.id) })
            // 去重：后台镜像在两次查询之间插了新行时，offset 会漂移一两条
            let seenIllust = Set(self.illusts.map(\.id))
            self.illusts.append(contentsOf: illusts.filter { !seenIllust.contains($0.id) })
            let seenNovel = Set(self.novels.map(\.id))
            self.novels.append(contentsOf: novels.filter { !seenNovel.contains($0.id) })
        }
        // 不足一页 = 到底了。注意判据是**查回来的行数**而不是映射后的条目数：
        // 中间夹着几条反序列化失败的坏行时，用条目数会提前判定到底，把后面的收藏全吞掉。
        hasMore = rows >= Self.pageSize
        loadedRows = offset + rows
        committedGeneration = generation
        loadTask = nil
        fillIfThin(generation: generation)
    }

    /// 一页可能被屏蔽 / R18 / AI 过滤到 0 条（全局隐藏 R-18 的用户，最近 60 件恰好全是 R-18 并不稀奇）。
    /// 这时空态和 footer 都不会出现，用户永远翻不到第二页。这里最多追 `thinFillHops` 页把首屏填起来，
    /// 预算照走 `burstPages`，不会退化成把整个书架捞进内存。
    private func fillIfThin(generation: Int) {
        guard itemCount < Self.thinFillThreshold, hasMore, thinFillHops < Self.thinFillMaxHops else {
            thinFillHops = 0
            return
        }
        thinFillHops += 1
        // 此刻还在 load() 里（isLoading 仍为 true），下一拍再翻。
        Task { @MainActor [weak self] in
            guard let self, generation == self.refreshGeneration else { return }
            self.loadMore()
        }
    }

    @ObservationIgnored private var thinFillHops = 0
    private static let thinFillThreshold = 10
    private static let thinFillMaxHops = 5
}
