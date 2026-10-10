import Foundation
import SwiftUI
import UIKit

// MARK: - Models

/// What kind of work a download represents. Drives the per-row badge and the
/// download strategy (manga = N pages, ugoira = zip → GIF). Mirrors upstream
/// `WorkType` (ILLUST / MANGA / UGOIRA).
enum DownloadKind: String, Codable, Sendable {
    case illust, manga, ugoira

    var label: LocalizedKey {
        switch self {
        case .illust: return .detailTypeIllust
        case .manga:  return .detailTypeManga
        case .ugoira: return .detailTypeUgoira
        }
    }
}

/// Where a queue item sits in its lifecycle. `success` items leave the queue and
/// become `DoneRecord`s; the Queue tab shows everything except success, the
/// Active tab shows only `downloading`. Parity with upstream PENDING /
/// DOWNLOADING / SUCCESS / FAILED.
enum DownloadStatus: String, Codable, Sendable {
    case pending, downloading, success, failed, paused
}

/// Immutable description of a work to download — the minimum needed to render a
/// row and fetch the bytes, snapshotted from `Illust` so the queue survives app
/// relaunch without re-hitting the API.
struct DownloadWorkInfo: Codable, Hashable, Identifiable, Sendable {
    let id: Int64
    let title: String
    let userName: String
    let thumbnailURL: String?
    let kind: DownloadKind
    /// Original-resolution page URLs (ugoira: empty — resolved from metadata at
    /// download time).
    let pageURLs: [String]

    var pageCount: Int { kind == .ugoira ? 1 : max(pageURLs.count, 1) }

    /// `resolution`: the page size to save — callers that don't let the user pick
    /// on the spot pass `ImageResolution.default` (upstream `defaultImageResolution()`).
    init(illust: Illust, resolution: ImageResolution = .original) {
        self.id = illust.id
        self.title = (illust.title?.isEmpty == false ? illust.title! : "illust \(illust.id)")
        self.userName = illust.user?.name ?? ""
        self.thumbnailURL = illust.imageUrls?.squareMedium
            ?? illust.imageUrls?.medium
            ?? illust.imageUrls?.large
        // Upstream `LegacyBatchEnqueue` WorkType: isGif → UGOIRA, type "manga" →
        // MANGA, else ILLUST (classified by type, not page count).
        if illust.type == "ugoira" {
            self.kind = .ugoira
            self.pageURLs = []
        } else if illust.type == "manga" {
            self.kind = .manga
            self.pageURLs = resolution.urls(for: illust).map(\.absoluteString)
        } else {
            self.kind = .illust
            self.pageURLs = resolution.urls(for: illust).map(\.absoluteString)
        }
    }
}

/// A live queue entry. A value type so mutating it inside the manager's `queue`
/// array republishes to SwiftUI; persisted verbatim so a half-drained queue
/// resumes after relaunch.
struct DownloadItem: Identifiable, Codable, Hashable, Sendable {
    enum UgoiraPhase: String, Codable, Sendable {
        case queued, meta, frames, encoding
        var label: LocalizedKey {
            switch self {
            case .queued:   return .dlUgoiraQueued
            case .meta:     return .dlUgoiraMeta
            case .frames:   return .dlUgoiraFrames
            case .encoding: return .dlUgoiraEncode
            }
        }
    }

    let info: DownloadWorkInfo
    /// Monotonic enqueue order, stable across relaunch (so the queue keeps its
    /// FIFO ordering). Set from a persisted counter.
    let seq: Int64
    var status: DownloadStatus = .pending
    var progress: Double = 0           // 0…1 across the whole work
    var currentPage: Int = 0           // 1-based page in flight (illust/manga)
    var pagesDone: Int = 0
    var retryCount: Int = 0
    var error: String? = nil
    var ugoiraPhase: UgoiraPhase? = nil
    var transfer: ImageTransferProgress? = nil
    var userPaused: Bool? = nil

    var id: Int64 { info.id }
}

/// A finished download, shown in the Done tab and persisted as history. Deleting
/// it only forgets the record — the file stays in Photos (we never touch the
/// user's library after writing).
struct DoneRecord: Identifiable, Codable, Hashable, Sendable {
    let id: Int64
    let title: String
    let userName: String
    let thumbnailURL: String?
    let kind: DownloadKind
    let pageCount: Int
    let savedAt: Date
}

/// Done-tab layout, cycled by the toolbar button — list / grid / compact, parity
/// with upstream `DoneLayoutMode`.
enum DoneLayoutMode: Int, CaseIterable, Codable, Sendable {
    case list, grid, compact
    var next: DoneLayoutMode { DoneLayoutMode(rawValue: (rawValue + 1) % 3)! }
    var label: LocalizedKey {
        switch self {
        case .list:    return .dlDoneLayoutList
        case .grid:    return .dlDoneLayoutGrid
        case .compact: return .dlDoneLayoutCompact
        }
    }
}

// MARK: - Resolution

/// The four `Params.IMAGE_RESOLUTION_*` buckets. Raw values follow the
/// 设置 · 下载「默认图片清晰度」 picker (0 原图 / 1 大图 / 2 中图 / 3 小图).
enum ImageResolution: Int, Sendable {
    case original = 0, large, medium, squareMedium

    /// Upstream `IllustDownload.defaultImageResolution()`: every download entry
    /// that doesn't let the user pick a size on the spot (main download button,
    /// download-after-bookmark, the bulk queue) uses the setting, not a hard-coded original.
    @MainActor
    static var `default`: ImageResolution {
        ImageResolution(rawValue: AppSettingsStore.shared.defaultImageResolutionIndex) ?? .original
    }

    func url(_ page: IllustPageURLs, illust: Illust, index: Int) -> URL? {
        switch self {
        case .original: return page.original ?? page.large
        case .large: return page.large ?? page.original
        case .medium, .squareMedium:
            // `meta_pages` carries the small variants; single-page works
            // fall back to the work-level `image_urls`.
            let urls = illust.metaPages?.indices.contains(index) == true
                ? illust.metaPages?[index].imageUrls
                : illust.imageUrls
            let s = self == .medium ? urls?.medium : urls?.squareMedium
            return s.flatMap(URL.init(string:)) ?? page.large ?? page.original
        }
    }

    func urls(for illust: Illust) -> [URL] {
        IllustPages.pages(for: illust).enumerated().compactMap { url($1, illust: illust, index: $0) }
    }
}

// MARK: - Storage guard

/// Free-space gate before each download (pixez#1361: downloading onto a full
/// disk only produces empty / truncated images). Instead of letting every page
/// fail on its own — hundreds of 「失败」 rows to retry one by one — the whole
/// queue is paused once, with one notice; after freeing space 「全部继续」
/// picks up exactly where it stopped.
enum StorageSpaceGuard {
    /// Below this, no new download starts: an original is 1–30 MB and the
    /// Photos import copies it once more, the rest is left for the app's own writes.
    static let minFreeBytes: Int64 = 100 * 1024 * 1024

    /// Unknown free space lets downloads through — a failed query must never block everything.
    static func hasRoomForDownload() -> Bool {
        guard let free = freeBytes() else { return true }
        return free >= minFreeBytes
    }

    static func freeBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return capacity
    }

    /// An error chain that says 「no space left」 (POSIX ENOSPC / Cocoa out-of-space).
    static func isOutOfSpace(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let e = current, depth < 8 {
            if (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC))
                || (e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError) {
                return true
            }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }
}

// MARK: - Manager

/// App-wide download queue. A single source of truth for the 3-tab manager:
/// `queue` (pending/downloading/failed), the derived `active` view, and the
/// persisted `done` history. Concurrency is capped by the user's
/// `maxConcurrentDownloads` setting; the heavy byte work runs off-main inside
/// `PixivImageCache` / `UgoiraGIF`, so this stays a thin @MainActor coordinator.
///
/// iOS reinterpretation of Shaft's `QueueDownloadManager` + `Manager`: same
/// queue→active→done flow, but the sink is the Photo library (no SAF/NAS).
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    private(set) var queue: [DownloadItem] = []
    private(set) var done: [DoneRecord] = []
    var isPaused = false {
        didSet {
            guard !isLoading else { return }
            if isPaused { manualStarts.removeAll(); for id in queue.map(\.id) { pause(id, user: false) } }
            else { resumeWaitingItems() }
            persistFlags()
        }
    }
    var doneLayout: DoneLayoutMode = .list { didSet { guard !isLoading else { return }; persistFlags() } }

    /// One-shot 「存储空间不足，已暂停全部下载」 notice, shown app-wide.
    private(set) var lowStorageNotice: LowStorageNotice?

    struct LowStorageNotice: Identifiable, Equatable {
        let id = UUID()
        let freeBytes: Int64
    }

    @ObservationIgnored private var lastLowStorageNoticeAt: Date?
    @ObservationIgnored private var runningTasks: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var jobTokens: [Int64: UUID] = [:]
    @ObservationIgnored private var manualStarts = Set<Int64>()
    @ObservationIgnored private var wasWiFi = NetworkReachability.shared.isWiFi
    @ObservationIgnored private var lastMode = 0
    @ObservationIgnored private var seqCounter: Int64 = 0
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    /// Serial executor for queue/done JSON writes — guarantees FIFO ordering
    /// (so a stale snapshot can't land after a newer one) and keeps disk IO off
    /// the main thread.
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "shaft.download.persist", qos: .utility)

    // MARK: Derived views

    /// Queue tab: everything that isn't finished, FIFO.
    var queueRows: [DownloadItem] { queue.sorted { $0.seq < $1.seq } }
    /// Active tab: only the items currently transferring bytes.
    var activeRows: [DownloadItem] { queue.filter { $0.status == .downloading }.sorted { $0.seq < $1.seq } }

    var pendingCount: Int { queue.filter { $0.status == .pending }.count }
    var downloadingCount: Int { queue.filter { $0.status == .downloading }.count }
    var failedCount: Int { queue.filter { $0.status == .failed }.count }
    /// Done cards are grouped by illust id (one card per work).
    var doneCards: [DoneRecord] { done.sorted { $0.savedAt > $1.savedAt } }

    struct Services {
        var authorize: @MainActor () async -> Bool = { await PhotoLibrarySaver.requestAuthorization() }
        var loadImage: @MainActor (URL, @escaping @MainActor (ImageTransferProgress) -> Void, @escaping @MainActor (Double) -> Void) async -> Data? = {
            await PixivImageCache.shared.loadData($0, forDownload: true, onTransfer: $1, onProgress: $2)
        }
        var save: @MainActor (Data) async throws -> Void = { try await PhotoLibrarySaver.save(data: $0) }
        var fetchUgoira: @MainActor (Int64, PixivAPI, @escaping @Sendable (ImageTransferProgress) -> Void,
                          @escaping @Sendable (DownloadItem.UgoiraPhase) -> Void) async throws -> [UgoiraGIF.Frame] = {
            try await UgoiraGIF.fetchFrames(illustId: $0, api: $1, onTransfer: $2, onPhase: $3)
        }
        var mode: @MainActor () -> Int = { AppSettingsStore.shared.downloadLimitType }
        var wifi: @MainActor () -> Bool = { NetworkReachability.shared.isWiFi }
        var hasRoom: () -> Bool = { StorageSpaceGuard.hasRoomForDownload() }
    }
    @ObservationIgnored private let services: Services
    @ObservationIgnored private let directoryOverride: URL?
    @ObservationIgnored private let defaults: UserDefaults
    init(directory: URL? = nil, defaults: UserDefaults = .standard, services: Services = Services(), autostart: Bool = true) {
        self.directoryOverride = directory
        self.defaults = defaults
        self.services = services
        wasWiFi = services.wifi()
        lastMode = services.mode()
        load()
        // Anything caught mid-flight by a kill resumes from PENDING.
        for i in queue.indices where queue[i].status == .downloading {
            queue[i].status = .pending
            queue[i].progress = Double(queue[i].pagesDone) / Double(queue[i].info.pageCount)
            queue[i].currentPage = 0
            queue[i].transfer = nil
            queue[i].userPaused = false
            queue[i].ugoiraPhase = nil
        }
        if services.mode() == 2 {
            for i in queue.indices where queue[i].status == .pending { queue[i].status = .paused; queue[i].userPaused = false }
        }
        if autostart { pump() }
    }

    // MARK: Enqueue

    /// Add works to the queue (skipping ones already queued). Returns how many
    /// were newly added. Resumes draining unless the user paused.
    @discardableResult
    func enqueue(_ illusts: [Illust], resolution: ImageResolution? = nil) -> Int {
        var existing = Set(queue.map(\.id))
        var added = 0
        let resolution = resolution ?? ImageResolution.default
        for illust in illusts where !existing.contains(illust.id) {
            seqCounter += 1
            var item = DownloadItem(info: DownloadWorkInfo(illust: illust, resolution: resolution), seq: seqCounter)
            item.userPaused = false
            if isPaused || services.mode() == 2 { item.status = .paused }
            queue.append(item)
            existing.insert(illust.id)
            added += 1
        }
        if added > 0 { persist(); pump() }
        return added
    }

    // MARK: Queue controls

    var hasOnlyFailed: Bool { !queue.isEmpty && queue.allSatisfy { $0.status == .failed } }
    var shouldResumeAll: Bool { activeRows.isEmpty && (isPaused || (!queue.isEmpty && queue.allSatisfy {
        $0.status == .paused || $0.status == .failed || ($0.status == .pending && !mayStart($0.id))
    })) }
    func togglePause() {
        if shouldResumeAll {
            if isPaused { isPaused = false } else { resumeWaitingItems() }
        } else { isPaused = true }
    }
    private func resumeWaitingItems() {
        for i in queue.indices where queue[i].status == .paused { queue[i].status = .pending; queue[i].userPaused = false }
        if services.mode() != 0 { manualStarts.formUnion(queue.filter { $0.status == .pending }.map(\.id)) }
        persist(); pump()
    }
    func pause(_ id: Int64, user: Bool = true) {
        guard let i = queue.firstIndex(where: { $0.id == id }), queue[i].status != .failed else { return }
        manualStarts.remove(id)
        queue[i].status = .paused
        queue[i].userPaused = user || queue[i].userPaused == true
        runningTasks[id]?.cancel()
        persist()
    }
    func resume(_ id: Int64) {
        guard let i = queue.firstIndex(where: { $0.id == id }), queue[i].status == .paused || queue[i].status == .pending else { return }
        manualStarts.insert(id)
        queue[i].userPaused = false
        queue[i].status = .pending
        persist(); pump()
    }
    func networkChanged() {
        let wifi = services.wifi()
        if wasWiFi && !wifi && services.mode() == 1 { manualStarts.removeAll() }
        wasWiFi = wifi
        for i in queue.indices where queue[i].status == .downloading && !mayStart(queue[i].id) {
            queue[i].status = .pending
            runningTasks[queue[i].id]?.cancel()
        }
        persist(); pump()
    }
    func preferencesChanged() {
        let mode = services.mode()
        if mode != lastMode {
            lastMode = mode
            manualStarts.removeAll()
            for i in queue.indices where queue[i].status != .failed {
                if mode == 2 {
                    if queue[i].status != .paused { queue[i].userPaused = false }
                    queue[i].status = .paused
                    runningTasks[queue[i].id]?.cancel()
                } else if queue[i].status == .paused && queue[i].userPaused == false && !isPaused {
                    queue[i].status = .pending
                }
            }
        }
        networkChanged()
    }
    private func mayStart(_ id: Int64) -> Bool {
        DownloadStartPolicy.allows(mode: services.mode(),
            wifi: services.wifi(), manuallyAllowed: manualStarts.contains(id), globallyPaused: isPaused)
    }
    private func owns(_ id: Int64, _ token: UUID) -> Bool { jobTokens[id] == token }
    private func transferring(_ id: Int64, _ token: UUID) -> Bool {
        owns(id, token) && queue.first(where: { $0.id == id })?.status == .downloading
    }

    /// Pause the whole queue for low storage and tell the user once
    /// (`StorageSpaceGuard.pauseDownloadsForLowStorage`). Concurrent hits within
    /// 2 s share one notice; a 「全部继续」 without freeing space pauses and
    /// notifies again, so the button never looks dead.
    func pauseForLowStorage() {
        isPaused = true
        let now = Date()
        if let last = lastLowStorageNoticeAt, now.timeIntervalSince(last) < 2 { return }
        lastLowStorageNoticeAt = now
        if DownloadNoticeKind.lowStorage.enabled { lowStorageNotice = LowStorageNotice(freeBytes: max(StorageSpaceGuard.freeBytes() ?? 0, 0)) }
    }

    func consumeLowStorageNotice(_ id: UUID) {
        if lowStorageNotice?.id == id { lowStorageNotice = nil }
    }

    func retryFailed() {
        for i in queue.indices where queue[i].status == .failed {
            queue[i].status = .pending
            queue[i].error = nil
            manualStarts.insert(queue[i].id)
        }
        persist()
        pump()
    }

    func retry(_ id: Int64) {
        guard let i = queue.firstIndex(where: { $0.id == id }), queue[i].status == .failed else { return }
        queue[i].status = .pending
        queue[i].error = nil
        manualStarts.insert(id)
        persist()
        pump()
    }

    /// Cancel and drop one item from the queue.
    func remove(_ id: Int64) {
        runningTasks[id]?.cancel()
        runningTasks[id] = nil
        jobTokens[id] = nil
        manualStarts.remove(id)
        queue.removeAll { $0.id == id }
        persist()
        pump()
    }

    /// Drop everything: cancel in-flight tasks and empty the queue.
    func clearQueue() {
        for t in runningTasks.values { t.cancel() }
        runningTasks.removeAll()
        jobTokens.removeAll()
        manualStarts.removeAll()
        queue.removeAll()
        persist()
    }

    // MARK: Done history

    func deleteDone(_ id: Int64) {
        done.removeAll { $0.id == id }
        persistDone()
    }

    func clearDoneHistory() {
        done.removeAll()
        persistDone()
    }

    /// Record a completed download that bypassed the queue. Keeps Done history complete.
    func recordCompleted(_ illust: Illust) {
        let info = DownloadWorkInfo(illust: illust)
        appendDone(info: info)
    }

    // MARK: Drain loop

    private func pump() {
        let limit = max(1, min(AppSettingsStore.shared.maxConcurrentDownloads, 5))
        while runningTasks.count < limit,
              let next = queue.first(where: { $0.status == .pending && runningTasks[$0.id] == nil && mayStart($0.id) }) {
            start(next.id)
        }
    }

    private func start(_ id: Int64) {
        guard runningTasks[id] == nil, let i = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[i].status = .downloading
        queue[i].transfer = nil
        queue[i].error = nil
        queue[i].ugoiraPhase = queue[i].info.kind == .ugoira ? .queued : nil
        let item = queue[i]
        let token = UUID()
        jobTokens[id] = token
        runningTasks[id] = Task { [weak self] in
            guard let self else { return }
            await self.run(item, token: token)
            guard self.owns(id, token) else { return }
            self.runningTasks[id] = nil
            self.jobTokens[id] = nil
            self.pump()
        }
    }

    private func run(_ item: DownloadItem, token: UUID) async {
        guard await services.authorize() else {
            if transferring(item.id, token) { fail(item.id, "Photos access denied") }; return
        }
        guard !Task.isCancelled, transferring(item.id, token) else { return }
        if item.info.kind == .ugoira { await runUgoira(item, token: token) }
        else { await runImages(item, token: token) }
    }

    private func runImages(_ item: DownloadItem, token: UUID) async {
        let urls = item.info.pageURLs.compactMap(URL.init(string:))
        guard !urls.isEmpty else { fail(item.id, "No image URL"); return }
        let total = urls.count
        var i = min(max(item.pagesDone, 0), urls.count)
        while i < urls.count {
            let url = urls[i]
            if Task.isCancelled || !transferring(item.id, token) { return }
            // Check free space before every page (pixez#1361); the item stays
            // in flight and resumes from this page on 「全部继续」.
            if !services.hasRoom() {
                pauseForLowStorage()
                return
            }
            mutate(item.id) { $0.currentPage = i + 1 }
            let page = i
            let data = await services.loadImage(url, { [weak self] transfer in
                guard let self, self.transferring(item.id, token) else { return }
                self.mutate(item.id) { $0.transfer = transfer; $0.retryCount = transfer.retryCount }
            }, { [weak self] p in
                guard let self, self.transferring(item.id, token) else { return }
                self.mutate(item.id, throttled: true) {
                    $0.progress = (Double(page) + p) / Double(total)
                }
            })
            if Task.isCancelled || !transferring(item.id, token) { return }
            guard let data else { fail(item.id, "Couldn't load image"); return }
            do { try await services.save(data) }
            catch {
                // The disk filled up mid-save: stop everything and retry this
                // page later instead of failing page after page.
                if Task.isCancelled || !transferring(item.id, token) { return }
                if StorageSpaceGuard.isOutOfSpace(error) || !services.hasRoom() {
                    pauseForLowStorage()
                    return
                }
                fail(item.id, error.localizedDescription); return
            }
            guard owns(item.id, token) else { return }
            mutate(item.id) { $0.pagesDone = page + 1; $0.progress = Double(page + 1) / Double(total) }
            persist()
            i += 1
        }
        guard !Task.isCancelled, transferring(item.id, token) else { return }
        complete(item.id, info: item.info)
    }

    private func runUgoira(_ item: DownloadItem, token: UUID) async {
        let id = item.id
        guard !Task.isCancelled, transferring(id, token) else { return }
        // Photos commits cannot be cancelled. A pause may have arrived while
        // the previous job's GIF was being committed, just like a saved page.
        if item.pagesDone >= 1 { complete(id, info: item.info); return }
        if !services.hasRoom() { pauseForLowStorage(); return }
        do {
            let frames = try await services.fetchUgoira(id, api, { [weak self] transfer in
                Task { @MainActor in
                    guard let self, self.transferring(id, token) else { return }
                    self.mutate(id) { $0.transfer = transfer; $0.retryCount = transfer.retryCount; $0.progress = (transfer.fraction ?? 0) * 0.5 }
                }
            }, { [weak self] phase in
                Task { @MainActor in
                    guard let self, self.transferring(id, token) else { return }
                    self.mutate(id) { $0.ugoiraPhase = phase }
                }
            })
            if Task.isCancelled || !transferring(id, token) { return }
            mutate(id) { $0.ugoiraPhase = .encoding; $0.progress = 0.5 }
            let gif = try await UgoiraGIF.encode(frames)
            if Task.isCancelled || !transferring(id, token) { return }
            try await services.save(gif)
            guard owns(id, token) else { return }
            mutate(id) { $0.pagesDone = 1; $0.progress = 1 }
            persist()
            guard !Task.isCancelled, transferring(id, token) else { return }
            complete(id, info: item.info)
        } catch {
            guard !Task.isCancelled, transferring(id, token) else { return }
            fail(id, error.localizedDescription)
        }
    }

    // MARK: Item mutation

    @ObservationIgnored private var lastProgressWrite: [Int64: Double] = [:]

    /// Mutate the queue item in place. `throttled` skips sub-2% progress churn so
    /// a fast byte stream doesn't thrash the list diff.
    private func mutate(_ id: Int64, throttled: Bool = false, _ body: (inout DownloadItem) -> Void) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        if throttled {
            var probe = queue[i]
            body(&probe)
            let last = lastProgressWrite[id] ?? -1
            if abs(probe.progress - last) < 0.02 && probe.progress < 1 { return }
            lastProgressWrite[id] = probe.progress
            queue[i] = probe
        } else {
            body(&queue[i])
        }
    }

    private func complete(_ id: Int64, info: DownloadWorkInfo) {
        lastProgressWrite[id] = nil
        manualStarts.remove(id)
        queue.removeAll { $0.id == id }
        appendDone(info: info)
        persist()
    }

    private func appendDone(info: DownloadWorkInfo) {
        done.removeAll { $0.id == info.id }   // dedupe — newest wins
        done.append(DoneRecord(
            id: info.id, title: info.title, userName: info.userName,
            thumbnailURL: info.thumbnailURL, kind: info.kind,
            pageCount: info.pageCount, savedAt: Date()
        ))
        persistDone()
    }

    private func fail(_ id: Int64, _ message: String) {
        mutate(id) { $0.status = .failed; $0.error = message; $0.ugoiraPhase = nil }
        persist()
    }

    // MARK: Persistence

    @ObservationIgnored private lazy var dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = directoryOverride ?? base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private var queueFile: URL { dir.appendingPathComponent("queue.json") }
    private var doneFile: URL { dir.appendingPathComponent("done.json") }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        if let data = try? Data(contentsOf: queueFile),
           let items = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            queue = items
            seqCounter = items.map(\.seq).max() ?? 0
        }
        if let data = try? Data(contentsOf: doneFile),
           let records = try? JSONDecoder().decode([DoneRecord].self, from: data) {
            done = records
        }
        isPaused = defaults.bool(forKey: "dl_isPaused")
        doneLayout = DoneLayoutMode(rawValue: defaults.integer(forKey: "dl_doneLayout")) ?? .list
    }

    private func persist() {
        let snapshot = queue
        let url = queueFile
        ioQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func persistDone() {
        let snapshot = done
        let url = doneFile
        ioQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func persistFlags() {
        defaults.set(isPaused, forKey: "dl_isPaused")
        defaults.set(doneLayout.rawValue, forKey: "dl_doneLayout")
    }
}

// MARK: - Export links

/// Copies the original-resolution image URLs of a set of works to the clipboard,
/// one per line (multi-page works expand to one line per page). iOS counterpart
/// of upstream `DownloadExportLinks` (which writes a .txt / shares); clipboard is
/// the closest faithful affordance without a file picker.
enum DownloadExportLinks {
    static func links(for illusts: [Illust]) -> [String] {
        illusts.flatMap { IllustPages.urls(for: $0).map(\.absoluteString) }
    }

    @discardableResult
    static func copyToClipboard(_ illusts: [Illust]) -> Int {
        let urls = links(for: illusts)
        UIPasteboard.general.string = urls.joined(separator: "\n")
        return urls.count
    }
}
