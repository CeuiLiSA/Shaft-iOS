import Foundation
import Observation

/// 收藏镜像引擎：**静默、限速、可续传**地把一个账号的收藏列表整份拉进本地库。
///
/// 1:1 移植自 Pixiv-Shaft `ceui.pixiv.db.mirror.BookmarkMirrorService`。
///
/// ## 它解决什么
///
/// pixiv 的收藏接口只能从新到旧顺着游标翻，既不能倒序也不能筛。唯一的根治办法是把列表整份
/// 镜像到本地，之后所有排序/筛选都在 SQLite 里做。表设计见 `BookmarkMirrorDatabase`，
/// 查询见 `BookmarkMirrorQuery`。
///
/// ## 三条铁律
///
/// 1. **绝不触发 pixiv 频控。** 全局串行（本类是 actor：无论有几个书架在排队，同一时刻只有
///    一个请求在飞），页与页之间恒定 `pageIntervalMs`（默认 5 秒 = 12 次/分，大约是 pixiv
///    读接口配额的十分之一）再叠随机抖动。真撞上 429 时不只是退避——**本次进程内的每页间隔会被
///    永久放大**（`intervalMultiplier`），宁可慢一倍也不再撞第二次。
/// 2. **静默。** 不弹窗、不发通知、不打断任何操作；出错只进日志。用户唯一能察觉它的地方，
///    是收藏库页上那条进度条，以及首次补齐时的一次性引导 banner。
/// 3. **杀进程能续。** 每翻一页就把游标落盘（`BookmarkMirrorStateEntity.nextUrl`），下次启动
///    从那一页接着翻。**绝不从头再来**——从头再来不只是慢，更是白白多打几百次请求去撞第 1 条铁律。
///
/// ## 生命周期：全量一次，之后只维护
///
/// ```
///  用户第一次打开某个收藏页
///      └─ ensureShelf() 注册这个书架（这就是「开启镜像」的唯一动作，也是隐私边界：
///         没打开过「悄悄收藏」，就永远不会去拉悄悄收藏）
///  BACKFILLING  一页一页翻到底 …… 每页落盘游标
///      └─ next_url 为空 → SYNCED，记下 firstCompletedAt
///  SYNCED       从此只做维护：
///      ├─ 增量：只翻表头几页，连撞 knownStreakStop 条已知的就停（几秒钟的事）
///      ├─ 本地：收藏/取消收藏成功后直接改这一行，连请求都不用发
///      └─ 重扫：fullSweepIntervalMs 到期再走一次全量，用代号差删掉
///               「在别处取消了收藏」的行——这是唯一能发现远端删除的机制
/// ```
///
/// ## 为什么是进程内长活 Task 而不是 BGTaskScheduler
///
/// 首次回填是小时级的活（3 万条 ÷ 30 条/页 × 5 秒 ≈ 80 分钟），而 iOS 的后台任务窗口是分钟级、
/// 由系统按电量随意推迟的。既然进度本来就每页落盘、随时可续，跟着进程活着最简单也最可控：
/// 用户用 app 的时候它慢慢往前挪，用户不用了它就停在断点上。
///
/// 做成 actor 与 Android 的 `limitedParallelism(1)` 同义：所有入口在挂起点之间互斥，
/// `activeRun` 这类裸字段因此不需要额外同步。
actor BookmarkMirrorService {

    static let shared = BookmarkMirrorService()

    private let db = BookmarkMirrorDatabase.shared
    private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)

    /// 唤醒信号。conflated：连着 kick 十次和一次等价，醒来后自己会把该做的都做掉。
    private let wakeup = MirrorWakeup()

    private var loopTask: Task<Void, Never>?

    /// 被用户「刚看过」而需要立刻做一次增量维护的书架。
    private var maintenanceRequested = Set<String>()

    /// 正在进行的增量/重扫轮次。
    private var activeRun: MirrorRun?

    /// 撞过 429 之后本进程内的限速放大系数。**只增不减**：这一次会话里既然已经证明
    /// 5 秒还是太快，就没有理由再赌一次。进程重启回到 1.0。
    private var intervalMultiplier: Double = 1.0

    /// 上一次网络请求**完成**的时刻，全局共享（不分书架）。限速的唯一真相来源。
    ///
    /// 改成在**每次发请求之前**对着这个时刻补足间隔，无论从哪条路走到发请求那一步都成立
    /// （四个书架依次收尾时不会连着打出一串请求）。
    private var lastRequestFinishedAt: Int64 = 0

    private init() {}

    // MARK: 对外 API

    /// 登录后由 `HomeView` 调用。幂等。
    func start() async {
        if let loopTask, !loopTask.isCancelled { return }
        mirrorLog.info("引擎启动 interval=\(Self.pageIntervalMs)ms")
        loopTask = Task(priority: .utility) { await self.loop() }
        kick("start")
        await publish()
    }

    /// 注册（并唤醒）一个书架 —— **这是开启镜像的唯一入口**。
    ///
    /// 语义刻意是「用户打开了这个收藏页」而不是「app 决定要镜像什么」：
    /// - 隐私边界天然正确：没点开过「悄悄收藏」，就绝不会有请求去拉悄悄收藏；
    /// - 灵活：插画/小说、公开/悄悄、甚至将来别人的收藏，都只是不同的 `BookmarkShelf`；
    /// - 幂等：已注册的书架只是被标记为「该做一次增量维护了」。
    func ensureShelf(_ shelf: BookmarkShelf, reason: String) async {
        guard await isFeatureEnabled(), shelf.ownerUid > 0 else { return }
        do {
            let existing = try await db.findState(shelfKey: shelf.key)
            let state: BookmarkMirrorStateEntity?
            if let existing {
                mirrorLog.debug("书架 \(shelf.label, privacy: .public) 已注册 phase=\(MirrorPhase.name(existing.phase), privacy: .public)（原因：\(reason, privacy: .public)）")
                state = existing
            } else {
                try await db.upsertState(Self.newState(shelf, now: Self.nowMs()))
                mirrorLog.info("注册书架 \(shelf.label, privacy: .public)（原因：\(reason, privacy: .public)）→ 准备首次全量回填")
                await publish()
                state = try await db.findState(shelfKey: shelf.key)
            }
            // 刚补过就别再补一次。本方法是「用户在看这个书架」的信号，而这个信号是**高频**的：
            // 收藏库顶部的公开/悄悄切换来回点几下就是几次调用，每次都排一轮增量 = 每次都多打
            // 两页请求。收藏不会在这么短的时间里变出新东西，节流掉纯赚。
            if let last = state?.lastSyncedAt, last > 0 {
                let syncedAgo = Self.nowMs() - last
                if syncedAgo < Self.minMaintenanceGapMs {
                    mirrorLog.debug("书架 \(shelf.label, privacy: .public) \(syncedAgo / 1000)s 前刚补过，本次不排增量")
                    return
                }
            }
            maintenanceRequested.insert(shelf.key)
            kick(reason)
        } catch {
            mirrorLog.warning("ensureShelf 失败: \(String(describing: error), privacy: .public)")
        }
    }

    /// 立刻去服务端对一次这个书架的表头，**不受 `ensureShelf` 的节流影响**。
    ///
    /// 给「用户主动下拉刷新」用。那个动作的语义就是「我知道可能有新东西，去看一眼」——
    /// 任何形式的节流在这里都是在跟用户对着干。它也是整套镜像唯一一个**用户可以主动触发**
    /// 的同步入口：网页端 / 别的设备上收藏的东西，如果自动窗口还没到，这就是那条出路。
    func syncNow(_ shelf: BookmarkShelf, reason: String) async {
        guard await isFeatureEnabled(), shelf.ownerUid > 0 else { return }
        do {
            if try await db.findState(shelfKey: shelf.key) == nil {
                try await db.upsertState(Self.newState(shelf, now: Self.nowMs()))
                mirrorLog.info("注册书架 \(shelf.label, privacy: .public)（原因：\(reason, privacy: .public)）")
                await publish()
            }
        } catch {
            mirrorLog.warning("syncNow 失败: \(String(describing: error), privacy: .public)")
        }
        mirrorLog.info("[\(shelf.label, privacy: .public)] 用户主动要求同步（\(reason, privacy: .public)）")
        maintenanceRequested.insert(shelf.key)
        kick(reason)
    }

    /// 唤醒循环（别处发生了值得干活的事）。可从任意线程调用。
    nonisolated func kick(_ reason: String) {
        mirrorLog.debug("kick: \(reason, privacy: .public)")
        wakeup.kick()
    }

    /// 读一份状态快照。
    func readState(_ shelf: BookmarkShelf) async -> BookmarkMirrorStateEntity? {
        try? await db.findState(shelfKey: shelf.key)
    }

    /// 推倒重来：清空这个书架的镜像并重新全量回填。
    ///
    /// 只有用户明确要求（收藏库菜单里的「重建本地镜像」）才该调 —— 它意味着重新打几百次请求。
    func rebuildShelf(_ shelf: BookmarkShelf) async {
        do {
            let rows = (try? await db.countOf(shelfKey: shelf.key)) ?? 0
            mirrorLog.warning("重建书架 \(shelf.label, privacy: .public)：清空 \(rows) 行并重新回填")
            try await db.clearShelf(shelfKey: shelf.key)
            try await db.upsertState(Self.newState(shelf, now: Self.nowMs()))
            // 只丢这个书架自己的那一轮：别的书架正在跑的增量已经消费掉了「该维护」标记，
            // 清掉它的 activeRun 会让那轮只补了一页就被静默放弃。
            if activeRun?.shelf == shelf { activeRun = nil }
            await publish()
            kick("rebuild")
        } catch {
            mirrorLog.error("重建书架失败: \(String(describing: error), privacy: .public)")
        }
    }

    /// 关掉某个书架的镜像并清空它（用户在设置里关闭，或换号清理）。
    func dropShelf(_ shelf: BookmarkShelf) async {
        do {
            mirrorLog.info("移除书架 \(shelf.label, privacy: .public)")
            try await db.clearShelf(shelfKey: shelf.key)
            try await db.deleteState(shelfKey: shelf.key)
            maintenanceRequested.remove(shelf.key)
            if activeRun?.shelf == shelf { activeRun = nil }
            await publish()
        } catch {
            mirrorLog.error("移除书架失败: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: 本地维护（不发请求就能把表改对）

    /// 收藏被服务端确认成功后就地插到表头。
    ///
    /// 这条路径是「同步完成过一次，以后只维护」的一半：用户在 app 里的每一次收藏都
    /// 立刻反映进镜像表，**一次网络请求都不用多打**。另一半（在别的设备/网页端做的收藏）
    /// 才需要靠增量维护去发现。
    func onIllustBookmarked(_ illust: Illust, restrict: MirrorRestrict) async {
        await upsertLocally(contentType: .illust, targetId: illust.id, restrict: restrict) { shelf, seq, generation, now in
            BookmarkMirrorMapper.fromIllust(shelf: shelf, illust: illust, bookmarkSeq: seq, generation: generation, now: now)
        }
    }

    func onNovelBookmarked(_ novel: Novel, restrict: MirrorRestrict) async {
        await upsertLocally(contentType: .novel, targetId: novel.id, restrict: restrict) { shelf, seq, generation, now in
            BookmarkMirrorMapper.fromNovel(shelf: shelf, novel: novel, bookmarkSeq: seq, generation: generation, now: now)
        }
    }

    /// 这批作品里当前账号收藏过的那些（按镜像，公开/悄悄都算）。借号搜索结果校正收藏态用（#1063）。
    ///
    /// 只能回答「是」：回填没跑完、或在别的设备刚收藏还没被维护到时，不在表里 ≠ 没收藏。
    /// 功能关闭 / 未登录 / 读库失败都返回空集，调用方退回原有判断。
    func bookmarkedAmong(contentType: MirrorContentType, targetIds: [Int64]) async -> Set<Int64> {
        guard !targetIds.isEmpty, await isFeatureEnabled() else { return [] }
        let uid = Self.loggedInUid()
        guard uid > 0 else { return [] }
        do {
            return try await db.mirroredAmong(ownerUid: uid, contentType: contentType.code, targetIds: targetIds)
        } catch {
            mirrorLog.warning("读取镜像收藏态失败，搜索结果按未知处理: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// 关注被服务端确认成功后就地插到关注书架表头。
    ///
    /// 手上只有 `PixivUser`、没有 `/v1/user/following` 附带的三张预览作品，所以先以空预览入库
    /// （卡片照常可点、可取关，只是预览格暂时留空）。不必为它补一次请求：下次打开关注库时
    /// 的增量维护会走到表头，按 id 认出这一行、原序号不动地把整份预览刷新进来。
    func onUserFollowed(_ user: PixivUser, restrict: MirrorRestrict) async {
        let preview = UserPreview(user: BookmarkMirrorMapper.withFollowed(user, true), illusts: [], novels: [], isMuted: nil)
        await upsertLocally(contentType: .user, targetId: user.id, restrict: restrict) { shelf, seq, generation, now in
            BookmarkMirrorMapper.fromUserPreview(shelf: shelf, preview: preview, bookmarkSeq: seq, generation: generation, now: now)
        }
    }

    /// 取消收藏 / 取消关注被确认后就地删除。
    ///
    /// 跨公开/悄悄两个书架删：调用点拿到的 restrict 是「本次操作用的默认可见性」，
    /// 未必是当初收藏时用的那个，按它删会漏。作品 id 上有索引，两架一起删也是两次点查。
    ///
    /// **不看功能开关**：删本地行不发请求，而开关关着时留下的行在重新打开后会一直冒充
    /// 「仍在收藏」（收藏库里还在），直到 14 天后的全量重扫才被发现。
    func onUnbookmarked(contentType: MirrorContentType, targetId: Int64) async {
        let uid = Self.loggedInUid()
        guard uid > 0 else { return }
        do {
            let removed = try await db.deleteTarget(ownerUid: uid, contentType: contentType.code, targetId: targetId)
            if removed > 0 {
                try await db.deleteTargetTags(shelfKeys: Self.shelfKeysOf(uid: uid, contentType: contentType), targetId: targetId)
                mirrorLog.debug("本地取消收藏：\(contentType.tag, privacy: .public)#\(targetId) 已从镜像移除(\(removed) 行)")
                await publish()
            }
        } catch {
            mirrorLog.warning("本地取消收藏落库失败: \(String(describing: error), privacy: .public)")
        }
    }

    private func upsertLocally(
        contentType: MirrorContentType,
        targetId: Int64,
        restrict: MirrorRestrict,
        build: (BookmarkShelf, Int64, Int, Int64) -> MirrorRow
    ) async {
        guard await isFeatureEnabled() else { return }
        let uid = Self.loggedInUid()
        guard uid > 0 else { return }
        let shelf = BookmarkShelf(ownerUid: uid, contentType: contentType, restrict: restrict)
        do {
            let shelfKeys = Self.shelfKeysOf(uid: uid, contentType: contentType)
            // 一个书架都没开镜像 = 这个功能对这台设备还没启用，什么都不做。
            var anyRegistered = false
            for key in shelfKeys {
                if try await db.findState(shelfKey: key) != nil { anyRegistered = true }
            }
            guard anyRegistered else { return }

            // 同一件作品可能刚从另一种可见性改过来（公开↔悄悄），先把另一架上的旧行清掉，
            // 否则一件作品会在两个书架里各留一份。
            // **删除必须在「目标书架是否注册」之前无条件做**：只镜像了公开收藏的用户把某张图
            // 改成悄悄收藏时，目标（悄悄）书架没注册，可写的行确实没有——但公开那一行已经
            // 不成立了，早退会把它留在库里，直到 14 天后的全量重扫才发现。
            try await db.deleteTarget(ownerUid: uid, contentType: contentType.code, targetId: targetId)
            try await db.deleteTargetTags(shelfKeys: shelfKeys, targetId: targetId)

            // 目标书架没开镜像：删掉旧行就是全部该做的事。
            guard let state = try await db.findState(shelfKey: shelf.key) else {
                await publish()
                return
            }

            let now = Self.nowMs()
            let opened = try await openHeadBlock(state, now: now)
            // 代号取**现读**的 state.generation，不是构造期的快照：全量扫描一开跑就把代号 +1，
            // 收尾时按 `generation < 当前代号` 删失联行。现读到的就是「这一轮正在用的代号」，
            // 于是「扫描已经走过表头之后才发生的本地收藏」也带着新代号，不会被收尾误删。
            let built = build(shelf, opened, state.generation, now)
            try await db.writePage(rows: [built.row], tags: built.tags)
            let rows = try await db.countOf(shelfKey: shelf.key)
            mirrorLog.debug("本地收藏入镜像：\(shelf.label, privacy: .public) seq=\(opened)（现有 \(rows) 行）")
            await publish()
        } catch {
            mirrorLog.warning("本地收藏落库失败: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: 主循环

    private func loop() async {
        while !Task.isCancelled {
            let outcome: Tick
            do {
                outcome = try await tick()
            } catch is CancellationError {
                return
            } catch {
                // tick() 内部已经把所有可预期的失败翻译成 Tick 了，走到这里说明是
                // 意料之外的（库损坏…）。绝不能让它把循环带走：那样这个进程剩下的
                // 时间里镜像就彻底停了，而且一声不响。
                mirrorLog.error("tick 意外失败，退避后继续: \(String(describing: error), privacy: .public)")
                outcome = .wait(Self.unexpectedErrorBackoffMs)
            }
            switch outcome {
            // 刚翻完一页不在这里 delay：节奏统一由 awaitRateLimitWindow 在**发请求前**补足。
            case .fetched: break
            case .wait(let ms): await awaitWakeup(ms)
            case .idle: await awaitWakeup(Self.idlePollMs)
            }
        }
    }

    /// 睡到超时或被 `kick` 唤醒，谁先到算谁。
    private func awaitWakeup(_ timeoutMs: Int64) async {
        await setActiveShelf(nil)
        await wakeup.wait(timeoutMs: max(timeoutMs, 1_000))
    }

    /// 一次心跳：要么翻一页，要么说明为什么不翻。
    private func tick() async throws -> Tick {
        guard await isFeatureEnabled() else { return .idle }
        let uid = Self.loggedInUid()
        guard uid > 0 else { return .idle }
        guard NetworkReachability.shared.isOnline else {
            mirrorLog.debug("离线，暂停镜像")
            // 不回 idle：网络恢复不写任何表、也没人会 kick，睡满 idlePollMs 就等于断一次网
            // 回填白停一刻钟，收藏库上那句「恢复联网后会自动继续补齐」也不成立。
            // 短间隔自己看一眼网络状态（只读内存里的值，不查库不发请求）。
            return .wait(Self.offlinePollMs)
        }

        let now = Self.nowMs()
        let states = try await db.allStates().filter { $0.ownerUid == uid }
        if states.isEmpty { return .idle }

        // 冷却是**全局**的：429 限的是这个 IP/账号，不是某个书架，换一个书架接着发只会接着撞。
        let cooldownUntil = states.map(\.cooldownUntil).max() ?? 0
        if cooldownUntil > now {
            let wait = min(cooldownUntil - now, Self.maxSingleWaitMs)
            mirrorLog.debug("限流冷却中，还要等 \((cooldownUntil - now) / 1000)s")
            return .wait(wait)
        }

        guard let job = pickJob(states, now: now) else {
            activeRun = nil
            return .idle
        }
        return try await runOnePage(job)
    }

    /// 挑下一件该做的事。顺序即优先级：
    ///
    /// 1. **续上没跑完的全量**（回填 / 重扫）—— 半截的活最该先做完，它决定了「表是不是完整的」；
    /// 2. **没开过头的回填**；
    /// 3. **用户刚看过的书架做增量**（他正盯着这个列表，新收藏应该马上出现）；
    /// 4. **到期的例行增量**；
    /// 5. **到期的全量重扫**（唯一能发现「在别处取消了收藏」的机制，所以放最后：它最贵）。
    private func pickJob(_ states: [BookmarkMirrorStateEntity], now: Int64) -> MirrorJob? {
        // 手上还有没跑完的一轮就接着跑 —— **必须排在所有条件之前**。
        // 增量维护不改 phase（仍是 SYNCED），开跑时又把「该维护了」的标记消费掉了，
        // 所以下面那些「该不该开一轮」的条件对它一条都不成立：少了这一步，维护会在
        // 翻完第一页之后被静默丢掉，只补了表头 30 条就再也不动。
        if let run = activeRun {
            if let state = states.first(where: { $0.shelfKey == run.shelf.key }), state.generation == run.generation {
                return MirrorJob(shelf: run.shelf, state: state, mode: run.mode)
            }
            // 书架被移除（换号 / 用户关掉镜像）或被重建：丢掉这一轮
            activeRun = nil
        }

        func job(_ state: BookmarkMirrorStateEntity, _ mode: MirrorMode) -> MirrorJob? {
            state.shelf.map { MirrorJob(shelf: $0, state: state, mode: mode) }
        }

        if let s = states.first(where: { $0.phase == MirrorPhase.backfilling.rawValue }), let j = job(s, .backfill) { return j }
        if let s = states.first(where: { $0.phase == MirrorPhase.resweeping.rawValue }), let j = job(s, .sweep) { return j }
        if let s = states.first(where: { $0.phase == MirrorPhase.never.rawValue }), let j = job(s, .backfill) { return j }
        if let s = states.first(where: { $0.phase == MirrorPhase.synced.rawValue && maintenanceRequested.contains($0.shelfKey) }),
           let j = job(s, .maintain) { return j }
        if let s = states.first(where: { $0.phase == MirrorPhase.synced.rawValue && now - $0.lastSyncedAt > Self.maintenanceIntervalMs }),
           let j = job(s, .maintain) { return j }
        if let s = states.first(where: { $0.phase == MirrorPhase.synced.rawValue && now - $0.lastFullSweepAt > Self.fullSweepIntervalMs }),
           let j = job(s, .sweep) { return j }
        return nil
    }

    /// 翻一页、写库、落游标。**每一页都是一个完整的、可被中断的单位**——
    /// 写库在一个事务里，游标在写库成功之后才落，所以最坏情况是下次重放这一页（幂等）。
    private func runOnePage(_ job: MirrorJob) async throws -> Tick {
        let shelf = job.shelf
        var state = job.state

        // 进入一轮新的增量/重扫：开一个新号段（见 headSeqCursor 的文档）
        let run: MirrorRun
        if let existing = activeRun, existing.shelf == shelf, existing.mode == job.mode {
            run = existing
        } else {
            let started = try await onRunStart(shelf, state: state, mode: job.mode)
            state = started.state
            run = MirrorRun(
                shelf: shelf, mode: job.mode, generation: started.state.generation,
                cursor: started.cursor, headCursor: started.state.headSeqCursor,
                backfillSeq: started.state.nextBackfillSeq
            )
            // 续传时把页码/条数接上库里的值，日志里的「第 N 页」才是这一轮**累计**的页码。
            run.pagesDone = started.state.pagesThisRun
            run.itemsSeen = started.state.itemsThisRun
            activeRun = run
        }

        await setActiveShelf(shelf.key)
        let pageNo = run.pagesDone + 1
        mirrorLog.debug("[\(shelf.label, privacy: .public)] \(job.mode.rawValue, privacy: .public) 第 \(pageNo) 页 cursor=\(Self.abbreviate(run.cursor), privacy: .public)")

        await awaitRateLimitWindow(shelf)

        let startedAt = Self.nowMs()
        let fetched: Result<FetchedPage, Error>
        do {
            fetched = .success(try await fetcherFor(shelf, api: api).load(nextUrl: run.cursor))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            fetched = .failure(error)
        }
        // 成败都要记账：失败的请求同样占了 pixiv 的配额，尤其撞 429 时更不能立刻重来。
        lastRequestFinishedAt = Self.nowMs()
        let latencyMs = Self.nowMs() - startedAt

        // ⚠️ 请求回来之后（**无论成败**）必须重新确认这一轮还算数。
        // 网络那一步会把 actor 让出去，这几百毫秒里 rebuildShelf / dropShelf 完全可能插进来跑完。
        // 不校验的话：用户点了「重建本地镜像」，这一页会带着**重建前**的 state 快照写回去，
        // 把刚建好的干净状态连游标带 phase 一起覆盖，重建静默失效。
        // 用 generation 作这一轮的身份：正常翻页不会动它，重建会把它清零，移除会让整行消失。
        let latest = try await db.findState(shelfKey: shelf.key)
        guard let latest, latest.generation == state.generation else {
            mirrorLog.warning("[\(shelf.label, privacy: .public)] 这一页取回期间书架被重建/移除（generation \(state.generation) → \(latest.map { String($0.generation) } ?? "已移除", privacy: .public)），丢弃本页")
            activeRun = nil
            await setActiveShelf(nil)
            return .idle
        }
        // 用最新的一份继续：期间可能有本地收藏抬高过号段上限（openHeadBlock）。
        state = latest
        let page: FetchedPage
        switch fetched {
        case .success(let p): page = p
        case .failure(let error): return try await onPageFailed(shelf, state: state, error: error)
        }

        let now = Self.nowMs()
        let written = try await writePage(shelf, state: state, run: run, page: page, now: now)

        run.pagesDone = pageNo
        run.itemsSeen += page.items.count
        run.newItems += written.newCount
        run.knownStreak = written.newCount == 0 ? run.knownStreak + page.items.count : 0
        // 防呆：服务端若把 next_url 原样回来（协议异常 / 中间层缓存），照翻下去就是
        // 每 5 秒一次的永动机。判成到底，让这一轮正常收尾。
        let stuckCursor = page.nextUrl != nil && page.nextUrl == run.cursor
        if stuckCursor {
            mirrorLog.warning("[\(shelf.label, privacy: .public)] next_url 与当前游标相同，判定到底以免空转")
        }
        run.cursor = stuckCursor ? nil : page.nextUrl
        run.headCursor = written.headCursor
        run.backfillSeq = written.backfillSeq

        mirrorLog.info("[\(shelf.label, privacy: .public)] \(job.mode.rawValue, privacy: .public) 第 \(pageNo) 页 ← \(page.items.count) 条(新 \(written.newCount)) \(latencyMs)ms 累计 \(run.itemsSeen) 条 连续已知 \(run.knownStreak) 下一页=\(run.cursor == nil ? "无(到底)" : "有", privacy: .public)")

        state = try await persistProgress(shelf, state: state, run: run, now: now)

        let finished: FinishReason?
        if run.cursor == nil {
            finished = .reachedEnd
        } else if job.mode == .maintain, run.knownStreak >= Self.knownStreakStop {
            // 增量只碰表头：连着撞到足够多条已知的就收工（几秒钟的事，不是几十分钟）
            finished = .knownStreak
        } else if job.mode == .maintain, run.pagesDone >= Self.maintainMaxPages {
            finished = .pageBudget
        } else {
            finished = nil
        }
        if let finished {
            try await onRunFinished(shelf, state: state, mode: job.mode, run: run, reason: finished, now: now)
            activeRun = nil
            await setActiveShelf(nil)
            return .idle
        }
        await publish()
        return .fetched
    }

    /// 一页落库：先算序号（已有的沿用，新的从号段里发），再一个事务写主表 + 标签表。
    private func writePage(
        _ shelf: BookmarkShelf,
        state: BookmarkMirrorStateEntity,
        run: MirrorRun,
        page: FetchedPage,
        now: Int64
    ) async throws -> PageWriteResult {
        if page.items.isEmpty { return PageWriteResult(newCount: 0, headCursor: run.headCursor, backfillSeq: run.backfillSeq) }

        let ids = page.items.map(\.id)
        let existing = try await db.existingSeqs(shelfKey: shelf.key, targetIds: ids)

        var backfillSeq = run.backfillSeq
        var headCursor = run.headCursor
        var newCount = 0
        var rows: [BookmarkMirrorEntity] = []
        rows.reserveCapacity(page.items.count)
        var tags: [BookmarkMirrorTagEntity] = []
        tags.reserveCapacity(page.items.count * 8)

        for item in page.items {
            let seq: Int64
            if let known = existing[item.id] {
                // 已经镜像过：**原样保留序号**。重新编号 = 把用户的收藏顺序打乱。
                seq = known
            } else if run.mode == .backfill {
                // 首次全量：从 0 往下发（0, -1, -2 …），于是 DESC = 官方顺序、ASC = 倒序
                seq = backfillSeq
                backfillSeq -= 1
                newCount += 1
            } else {
                // 增量/重扫里遇到的真·新收藏：从本轮号段顶往下发，先遇到的（更新的）拿更大的号
                seq = headCursor
                headCursor -= 1
                newCount += 1
            }
            let built = item.toRow(seq: seq, generation: state.generation, now: now)
            rows.append(built.row)
            tags.append(contentsOf: built.tags)
        }

        try await db.writePage(rows: rows, tags: tags)
        return PageWriteResult(newCount: newCount, headCursor: headCursor, backfillSeq: backfillSeq)
    }

    private func persistProgress(
        _ shelf: BookmarkShelf,
        state: BookmarkMirrorStateEntity,
        run: MirrorRun,
        now: Int64
    ) async throws -> BookmarkMirrorStateEntity {
        var next = state
        next.nextUrl = run.cursor
        if run.mode == .backfill { next.nextBackfillSeq = run.backfillSeq }
        next.headSeqCursor = run.headCursor
        next.pagesThisRun = run.pagesDone
        next.itemsThisRun = run.itemsSeen
        next.consecutiveFailures = 0
        next.lastError = nil
        next.updatedAt = now
        try await db.upsertState(next)
        return next
    }

    /// 一轮开始：定下起点游标、代号与号段。
    private func onRunStart(
        _ shelf: BookmarkShelf,
        state: BookmarkMirrorStateEntity,
        mode: MirrorMode
    ) async throws -> RunStart {
        let now = Self.nowMs()
        switch mode {
        case .backfill:
            if state.phase == MirrorPhase.backfilling.rawValue {
                // 续上：游标就是上次落盘的那个
                let rows = (try? await db.countOf(shelfKey: shelf.key)) ?? 0
                mirrorLog.info("[\(shelf.label, privacy: .public)] 续上未完成的全量回填：从第 \(state.pagesThisRun) 页之后继续（已镜像 \(rows) 行）")
                return RunStart(state: state, cursor: state.nextUrl)
            }
            var next = state
            next.phase = MirrorPhase.backfilling.rawValue
            next.nextUrl = nil
            next.generation = state.generation + 1
            next.nextBackfillSeq = 0
            next.pagesThisRun = 0
            next.itemsThisRun = 0
            next.updatedAt = now
            try await db.upsertState(next)
            mirrorLog.info("[\(shelf.label, privacy: .public)] 开始首次全量回填 generation=\(next.generation)")
            return RunStart(state: next, cursor: nil)

        case .sweep:
            if state.phase == MirrorPhase.resweeping.rawValue {
                mirrorLog.info("[\(shelf.label, privacy: .public)] 续上未完成的全量重扫 generation=\(state.generation)")
                return RunStart(state: state, cursor: state.nextUrl)
            }
            let block = state.headBlockCeiling + Self.headSeqBlock
            var next = state
            next.phase = MirrorPhase.resweeping.rawValue
            next.nextUrl = nil
            next.generation = state.generation + 1
            next.headBlockCeiling = block
            next.headSeqCursor = block
            next.pagesThisRun = 0
            next.itemsThisRun = 0
            next.updatedAt = now
            try await db.upsertState(next)
            let daysAgo = state.lastFullSweepAt > 0 ? (now - state.lastFullSweepAt) / 86_400_000 : -1
            mirrorLog.info("[\(shelf.label, privacy: .public)] 开始全量重扫 generation=\(next.generation)（上次重扫距今 \(daysAgo) 天）")
            return RunStart(state: next, cursor: nil)

        case .maintain:
            // 增量不改 phase（仍是 SYNCED）：它随时可以被打断重来，表始终是可用的。
            // 但号段必须先落盘抬高，否则被杀之后下一轮会重用同一段号。
            let block = state.headBlockCeiling + Self.headSeqBlock
            var next = state
            next.headBlockCeiling = block
            next.headSeqCursor = block
            next.pagesThisRun = 0
            next.itemsThisRun = 0
            next.updatedAt = now
            try await db.upsertState(next)
            maintenanceRequested.remove(shelf.key)
            mirrorLog.info("[\(shelf.label, privacy: .public)] 开始增量维护（只走表头，最多 \(Self.maintainMaxPages) 页）")
            return RunStart(state: next, cursor: nil)
        }
    }

    private func onRunFinished(
        _ shelf: BookmarkShelf,
        state: BookmarkMirrorStateEntity,
        mode: MirrorMode,
        run: MirrorRun,
        reason: FinishReason,
        now: Int64
    ) async throws {
        var next = state
        next.phase = MirrorPhase.synced.rawValue
        next.nextUrl = nil
        next.lastSyncedAt = now
        next.consecutiveFailures = 0
        next.lastError = nil
        next.updatedAt = now
        let justCompletedFirstSync = state.firstCompletedAt == 0 && mode == .backfill && reason == .reachedEnd
        if justCompletedFirstSync {
            next.firstCompletedAt = now
        }

        // 只有**走到底**的全量才有资格删失联行：半路收工（增量、预算用尽）时
        // 「本轮没见过」根本不代表「服务端没有了」，照删会把镜像削掉一大块。
        let isCompleteSweep = reason == .reachedEnd && (mode == .sweep || mode == .backfill)
        if isCompleteSweep {
            let removed = try await db.deleteStaleRows(shelfKey: shelf.key, generation: state.generation)
            var orphanTags = 0
            if removed > 0 { orphanTags = try await db.deleteOrphanTags(shelfKey: shelf.key) }
            next.lastFullSweepAt = now
            if removed > 0 {
                mirrorLog.info("[\(shelf.label, privacy: .public)] 全量收尾：清掉 \(removed) 行已在别处取消的收藏（连带 \(orphanTags) 条标签）")
            }
        }
        try await db.upsertState(next)
        // 一轮刚走完，表头一定是最新的 —— 把「该做一次增量」的标记消费掉。
        maintenanceRequested.remove(shelf.key)

        let rows = try await db.countOf(shelfKey: shelf.key)
        mirrorLog.info("[\(shelf.label, privacy: .public)] \(mode.rawValue, privacy: .public) 结束（\(reason.rawValue, privacy: .public)）：\(run.pagesDone) 页 / \(run.itemsSeen) 条 / 新增 \(run.newItems) 条，库内共 \(rows) 行\(justCompletedFirstSync ? "，首次全量完成 ✅" : "", privacy: .public)")
        await publish()

        // 翻到最后一页、整份镜像第一次补齐 —— 这一刻起「倒序 / 按标签筛 / 全文搜」才真的可用。
        // 用户此前对这件事是完全无感的（整个过程刻意静默），所以给一次、且**只给一次**引导。
        if justCompletedFirstSync {
            await MainActor.run { BookmarkMirrorReadyBanner.shared.announce(shelf: shelf, rows: rows) }
        }
    }

    /// 一页失败了怎么办。分三类，因为处置完全不同：
    ///
    /// - **429**：唯一确定的频控信号。整个引擎（不只这个书架）进冷却，并且**永久放大**
    ///   本进程的每页间隔——第 1 条铁律要求宁可慢也不能再撞。
    /// - **5xx / 网络 IO**：服务端或链路的临时问题，指数退避重试同一个游标。
    /// - **其它 4xx / 解析失败**：重试也没用，记下错误、把这一轮停掉，等下次唤醒再说。
    private func onPageFailed(
        _ shelf: BookmarkShelf,
        state: BookmarkMirrorStateEntity,
        error: Error
    ) async throws -> Tick {
        let now = Self.nowMs()
        let failures = state.consecutiveFailures + 1
        let classified = Self.classify(error)

        if classified.httpCode == 429 {
            // PixivAPI 的 http 错误不带响应头，拿不到 Retry-After，按阶梯冷却走。
            let backoff = Self.rateLimitCooldownMs(failures, retryAfterMs: nil)
            intervalMultiplier = min(intervalMultiplier * Self.rateLimitSlowdown, Self.maxIntervalMultiplier)
            mirrorLog.warning("⚠️ 撞上 pixiv 频控(429) shelf=\(shelf.label, privacy: .public)：冷却 \(backoff / 1000)s，之后每页间隔放大到 \(String(format: "%.1f", self.intervalMultiplier), privacy: .public)x(\(Int64(Double(Self.pageIntervalMs) * self.intervalMultiplier))ms)")
            var next = state
            next.cooldownUntil = now + backoff
            next.consecutiveFailures = failures
            next.lastError = "429 rate limited"
            next.lastErrorAt = now
            next.updatedAt = now
            try await db.upsertState(next)
            await publish()
            return .wait(min(backoff, Self.maxSingleWaitMs))
        }

        if classified.retryable, failures <= Self.maxConsecutiveFailures {
            let backoff = Self.transientBackoffMs(failures)
            mirrorLog.warning("[\(shelf.label, privacy: .public)] 第 \(failures) 次失败（可重试），\(backoff / 1000)s 后重试同一页: \(Self.describe(error), privacy: .public)")
            var next = state
            next.consecutiveFailures = failures
            next.lastError = Self.describe(error)
            next.lastErrorAt = now
            next.updatedAt = now
            try await db.upsertState(next)
            await publish()
            return .wait(min(backoff, Self.maxSingleWaitMs))
        }

        mirrorLog.error("[\(shelf.label, privacy: .public)] 第 \(failures) 次失败（不再重试本轮），游标保留在断点上等下次唤醒: \(Self.describe(error), privacy: .public)")
        // 增量维护的「该做一次」标记在开跑时就被消费掉了。这一轮失败就把它放回去，
        // 否则一次网络抖动会让这个书架白等到 6 小时后的例行窗口。
        if activeRun?.mode == .maintain { maintenanceRequested.insert(shelf.key) }
        var next = state
        next.consecutiveFailures = failures
        next.lastError = Self.describe(error)
        next.lastErrorAt = now
        next.updatedAt = now
        try await db.upsertState(next)
        // 断点游标已经落盘，下次唤醒（冷启 / 用户再打开收藏页）从这里接着走，不从头。
        activeRun = nil
        await setActiveShelf(nil)
        await publish()
        return .wait(Self.parkedRetryMs)
    }

    // MARK: 工具

    /// 把最新的状态表 + 行数推给界面（Room 的 observeStates / observeOwnerCount 的替身）。
    private func publish() async {
        let uid = Self.loggedInUid()
        let states = (try? await db.states(ownerUid: uid)) ?? []
        let count = (try? await db.ownerCount(ownerUid: uid)) ?? 0
        await MainActor.run {
            BookmarkMirrorObserved.shared.apply(states: states, ownerCount: count)
        }
    }

    private func setActiveShelf(_ key: String?) async {
        await MainActor.run {
            if BookmarkMirrorObserved.shared.activeShelfKey != key {
                BookmarkMirrorObserved.shared.activeShelfKey = key
            }
        }
    }

    /// 同一 uid + 内容类型下的公开/悄悄两个书架键。
    private static func shelfKeysOf(uid: Int64, contentType: MirrorContentType) -> [String] {
        MirrorRestrict.allCases.map { BookmarkShelf(ownerUid: uid, contentType: contentType, restrict: $0).key }
    }

    private static func newState(_ shelf: BookmarkShelf, now: Int64) -> BookmarkMirrorStateEntity {
        BookmarkMirrorStateEntity(
            shelfKey: shelf.key,
            ownerUid: shelf.ownerUid,
            contentType: shelf.contentType.code,
            restrictCode: shelf.restrict.code,
            phase: MirrorPhase.never.rawValue,
            nextUrl: nil,
            generation: 0,
            nextBackfillSeq: 0,
            headSeqCursor: 0,
            headBlockCeiling: 0,
            pagesThisRun: 0,
            itemsThisRun: 0,
            firstCompletedAt: 0,
            lastSyncedAt: 0,
            lastFullSweepAt: 0,
            lastErrorAt: 0,
            lastError: nil,
            consecutiveFailures: 0,
            cooldownUntil: 0,
            updatedAt: now
        )
    }

    /// 给本地新增开一个号段（用它的顶做序号），保证它高于此前的一切。
    private func openHeadBlock(_ state: BookmarkMirrorStateEntity, now: Int64) async throws -> Int64 {
        let top = state.headBlockCeiling + Self.headSeqBlock
        var next = state
        next.headBlockCeiling = top
        next.headSeqCursor = top
        next.updatedAt = now
        try await db.upsertState(next)
        return top
    }

    /// 发请求前把距上一次请求的间隔补满。这是限速**唯一**的执行点：
    /// 首屏、翻页、换书架、冷却结束后的第一发，全都要过这里。
    private func awaitRateLimitWindow(_ shelf: BookmarkShelf) async {
        let gap = Self.nowMs() - lastRequestFinishedAt
        let required = nextPageDelayMs()
        if lastRequestFinishedAt > 0, gap < required {
            let wait = required - gap
            mirrorLog.debug("[\(shelf.label, privacy: .public)] 限速：距上次请求 \(gap)ms，再等 \(wait)ms")
            try? await Task.sleep(for: .milliseconds(wait))
        }
    }

    /// 每页之间的等待：基准 × 频控放大系数 × 随机抖动。
    private func nextPageDelayMs() -> Int64 {
        let base = Double(Self.pageIntervalMs) * intervalMultiplier
        let jitter = base * Self.jitterRatio
        // 抖动：多台设备/多次冷启不要卡在同一个节拍上一起打过去
        return max(Int64(base + Double.random(in: -jitter...jitter)), 1_000)
    }

    private static func rateLimitCooldownMs(_ failures: Int, retryAfterMs: Int64?) -> Int64 {
        let stepped = rateLimitCooldowns[min(failures - 1, rateLimitCooldowns.count - 1)]
        // 服务端说的话优先，但采信有上限：一个离谱的 Retry-After 能把镜像冻到进程结束。
        let serverAsked = min(max(retryAfterMs ?? 0, 0), maxRetryAfterMs)
        return max(stepped, serverAsked)
    }

    private static func transientBackoffMs(_ failures: Int) -> Int64 {
        min(transientBaseBackoffMs << min(failures - 1, 5), maxTransientBackoffMs)
    }

    private func isFeatureEnabled() async -> Bool {
        await MainActor.run { AppSettingsStore.shared.bookmarkMirrorEnabled }
    }

    static func loggedInUid() -> Int64 {
        KeychainTokenStore.shared.load()?.user?.id ?? 0
    }

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func abbreviate(_ url: String?) -> String {
        guard let url else { return "首页" }
        return url.count <= 60 ? url : String(url.suffix(48))
    }

    private static func describe(_ error: Error) -> String {
        "\(type(of: error)): \(String(describing: error).prefix(160))"
    }

    /// 错误分类。`PixivAPI.APIError.http` 带状态码；`URLError` 等价于 Android 的 IOException。
    private static func classify(_ error: Error) -> (httpCode: Int?, retryable: Bool) {
        if let apiError = error as? PixivAPI.APIError {
            switch apiError {
            case .http(let code, _):
                return (code, (500...599).contains(code) || code == 408)
            case .noToken, .nonHTTP, .decoding:
                return (nil, false)
            }
        }
        if error is URLError { return (nil, true) }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain || ns.domain == NSPOSIXErrorDomain { return (nil, true) }
        return (nil, false)
    }

    // MARK: 内部类型

    private enum Tick {
        /// 刚翻完一页，按限速间隔歇一下。
        case fetched
        /// 没活干，睡到被唤醒。
        case idle
        /// 冷却/退避，睡指定时长（也可被唤醒提前打断——冷却会在下一次 tick 里重新判定）。
        case wait(Int64)
    }

    private enum MirrorMode: String { case backfill = "BACKFILL", maintain = "MAINTAIN", sweep = "SWEEP" }

    private enum FinishReason: String { case reachedEnd = "REACHED_END", knownStreak = "KNOWN_STREAK", pageBudget = "PAGE_BUDGET" }

    private struct MirrorJob {
        let shelf: BookmarkShelf
        let state: BookmarkMirrorStateEntity
        let mode: MirrorMode
    }

    private struct RunStart {
        let state: BookmarkMirrorStateEntity
        let cursor: String?
    }

    private struct PageWriteResult {
        let newCount: Int
        let headCursor: Int64
        let backfillSeq: Int64
    }

    /// 一轮（回填/增量/重扫）的进行时状态。只有引擎碰它。
    private final class MirrorRun {
        let shelf: BookmarkShelf
        let mode: MirrorMode
        /// 开跑时那一轮的代号。书架被重建（代号清零）后靠它立刻认出这一轮已经作废。
        let generation: Int
        var cursor: String?
        var headCursor: Int64
        var backfillSeq: Int64
        var pagesDone = 0
        var itemsSeen = 0
        var newItems = 0
        var knownStreak = 0

        init(shelf: BookmarkShelf, mode: MirrorMode, generation: Int, cursor: String?, headCursor: Int64, backfillSeq: Int64) {
            self.shelf = shelf
            self.mode = mode
            self.generation = generation
            self.cursor = cursor
            self.headCursor = headCursor
            self.backfillSeq = backfillSeq
        }
    }

    // MARK: 常量

    /// 每页之间的基准间隔。5 秒 = 12 次/分，约为 pixiv 读接口配额（~120 次/分/IP）的
    /// 十分之一 —— 即使用户同时在正常刷 app，两边加起来也离限流线很远。
    static let pageIntervalMs: Int64 = 5_000

    /// 间隔抖动比例，±15%。
    private static let jitterRatio = 0.15

    /// 撞过 429 之后每次把间隔乘上这个数，最多放大到 `maxIntervalMultiplier`。
    private static let rateLimitSlowdown = 1.6
    private static let maxIntervalMultiplier = 4.0

    /// 429 的阶梯冷却。
    private static let rateLimitCooldowns: [Int64] = [2 * 60_000, 5 * 60_000, 15 * 60_000, 30 * 60_000]
    private static let maxRetryAfterMs: Int64 = 30 * 60_000

    /// 网络/5xx 的指数退避。
    private static let transientBaseBackoffMs: Int64 = 30_000
    private static let maxTransientBackoffMs: Int64 = 15 * 60_000
    private static let maxConsecutiveFailures = 8

    /// 一次睡眠最长睡这么久，睡醒重新判定（免得抱着一个很长的睡眠错过唤醒语义）。
    private static let maxSingleWaitMs: Int64 = 10 * 60_000

    /// 本轮被判定为「不再重试」后，等这么久再自己试一次。
    private static let parkedRetryMs: Int64 = 30 * 60_000

    /// 意料之外的异常后的退避。
    private static let unexpectedErrorBackoffMs: Int64 = 60_000

    /// 空闲时的兜底心跳（正常靠 `kick` 唤醒，这个只防信号丢失）。
    private static let idlePollMs: Int64 = 15 * 60_000

    /// 离线时多久看一次网络恢复了没有。
    private static let offlinePollMs: Int64 = 30_000

    /// 例行增量的最小间隔。
    private static let maintenanceIntervalMs: Int64 = 6 * 60 * 60_000

    /// 「用户在看这个书架」这个信号的节流窗口。
    ///
    /// 它要挡的只有一种东西：**秒级的连点**（页面顶部那个公开/悄悄切换被来回戳）。
    /// 曾经设成 2 分钟，那是错的：用户最典型的动作恰恰是「在网页端收藏几张 → 切回 app
    /// 看看」，这个来回一分钟内就能完成，却会被整整挡掉。宁可多打两次请求，也不能让这条
    /// 主路径失效。
    private static let minMaintenanceGapMs: Int64 = 30_000

    /// 全量重扫的间隔。它是**唯一**能发现「在网页端/别的设备取消了收藏」的机制，
    /// 但也是最贵的（要把整个列表再翻一遍），所以定得很稀。
    private static let fullSweepIntervalMs: Int64 = 14 * 24 * 60 * 60_000

    /// 增量维护：连着见到这么多条已知条目就收工。两页的量，足够穿过一次翻页错位。
    private static let knownStreakStop = 60

    /// 增量维护的页数硬上限，防止它退化成一次全量。
    private static let maintainMaxPages = 20

    /// 新收藏序号的号段大小。一轮（或一次本地收藏）占一段，段内从顶往下发号，
    /// 于是「先遇到的更新 → 号更大」和「后一轮整体高于前一轮」同时成立。
    private static let headSeqBlock: Int64 = 1_000_000
}

// MARK: - 唤醒信号

/// conflated 的唤醒通道：`kick` 在没人等的时候只记一个「有事」标记，下一次 `wait` 立刻返回；
/// 有人在等就直接把他叫醒。超时与唤醒谁先到算谁。
final class MirrorWakeup: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var waiter: CheckedContinuation<Void, Never>?

    func kick() {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume()
        } else {
            pending = true
            lock.unlock()
        }
    }

    func wait(timeoutMs: Int64) async {
        if consumePending() { return }

        let timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(timeoutMs))
            guard !Task.isCancelled else { return }
            self?.fire()
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if pending {
                    pending = false
                    return true
                }
                waiter = c
                return false
            }
            if resumeNow { c.resume() }
        }
        timer.cancel()
    }

    private func consumePending() -> Bool {
        lock.withLock {
            if pending {
                pending = false
                return true
            }
            return false
        }
    }

    /// 超时到点。没人在等（定时器抢在 waiter 登记之前到了）就记成 pending，
    /// 让紧接着的登记立刻返回 —— 否则那次等待要一直挂到下一次 kick。
    private func fire() {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume()
        } else {
            pending = true
            lock.unlock()
        }
    }
}

// MARK: - 界面观察口

/// Room `observeStates(uid)` / `observeOwnerCount(uid)` 的 SwiftUI 替身：引擎每次落库后把
/// 最新的状态表与行数推到这里，界面按 `@Observable` 自动重绘。
///
/// `isShelfReady` 刻意是同步的：路由（`RouteHost`）要用它决定点收藏入口是进本地库还是进
/// 原始列表，view builder 里没法 await。它读的是引擎推过来的缓存，冷启动最初几十毫秒
/// 还没推到时按「没准备好」处理，让入口回落到不依赖镜像的老路径 —— 导航绝不能因为一个
/// 附加功能而崩。
@MainActor
@Observable
final class BookmarkMirrorObserved {
    nonisolated static let shared = BookmarkMirrorObserved()

    /// 当前账号名下全部书架的同步状态。
    private(set) var states: [BookmarkMirrorStateEntity] = []
    /// 当前账号名下**任一**书架的行数（页面可就地切书架，按 uid 订一次就够）。
    private(set) var ownerCount: Int = 0
    /// 已完整同步过至少一次的书架键。
    private(set) var readyShelfKeys: Set<String> = []
    /// 当前正在翻页的书架（nil = 空闲）。界面上的「正在同步…」用它。
    var activeShelfKey: String?

    nonisolated init() {}

    func apply(states: [BookmarkMirrorStateEntity], ownerCount: Int) {
        if self.states != states { self.states = states }
        if self.ownerCount != ownerCount { self.ownerCount = ownerCount }
        let ready = Set(states.filter(\.isFirstSyncDone).map(\.shelfKey))
        if readyShelfKeys != ready { readyShelfKeys = ready }
    }

    func state(of shelf: BookmarkShelf) -> BookmarkMirrorStateEntity? {
        states.first { $0.shelfKey == shelf.key }
    }

    /// 这个书架**完整同步过至少一次**了吗 —— 也就是「本地这份能不能当作全量来用」。
    func isShelfReady(_ shelf: BookmarkShelf) -> Bool {
        AppSettingsStore.shared.bookmarkMirrorEnabled && readyShelfKeys.contains(shelf.key)
    }

    /// 收藏 / 关注入口要不要直接进本地库（#1109）：已注册的书架可直接浏览；首次在线访问也可
    /// 进入，由页面注册并开始回填。全量完成只决定筛选是否开放，不再是进入本地库的门槛。
    func canOpenLibrary(contentType: MirrorContentType) -> Bool {
        let uid = BookmarkMirrorService.loggedInUid()
        guard uid > 0, AppSettingsStore.shared.bookmarkMirrorEnabled else { return false }
        let shelf = BookmarkShelf(ownerUid: uid, contentType: contentType, restrict: .public)
        return state(of: shelf) != nil || NetworkReachability.shared.isOnline
    }

    /// 当前账号在这个内容类型下的「公开收藏」在本地镜像里是不是已经完整了。判据用**公开**
    /// 书架：收藏库默认落在它上面，悄悄收藏那半边进去以后可以就地切。
    func isMirrorReady(contentType: MirrorContentType) -> Bool {
        let uid = BookmarkMirrorService.loggedInUid()
        guard uid > 0 else { return false }
        return isShelfReady(BookmarkShelf(ownerUid: uid, contentType: contentType, restrict: .public))
    }
}

// MARK: - 收藏页 → 镜像系统的唯一接线点

/// 「用户打开了自己的某个收藏页」是**开启镜像的唯一触发条件**，理由见
/// `BookmarkMirrorService.ensureShelf`：它同时是隐私边界（没点开过悄悄收藏就不会去拉它）
/// 和灵活性来源（插画/小说、公开/悄悄，全靠调用方传进来的 contentType 与 restrict 区分）。
///
/// 只对**自己的**收藏生效：别人的收藏页只是随便看看，没有理由为它在本地留一份全量副本。
func trackBookmarkShelfVisit(userId: Int64, restrict: String, contentType: MirrorContentType) {
    guard userId > 0, BookmarkMirrorService.loggedInUid() == userId else { return }
    let shelf = BookmarkShelf(ownerUid: userId, contentType: contentType, restrict: MirrorRestrict.ofApiValue(restrict))
    Task { await BookmarkMirrorService.shared.ensureShelf(shelf, reason: "打开\(contentType.tag)列表") }
}
