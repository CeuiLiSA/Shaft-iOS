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

    init(illust: Illust) {
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
            self.pageURLs = IllustPages.urls(for: illust).map(\.absoluteString)
        } else {
            self.kind = .illust
            self.pageURLs = IllustPages.urls(for: illust).map(\.absoluteString)
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
    var isPaused = false { didSet { guard !isLoading else { return }; if !isPaused { pump() }; persistFlags() } }
    var doneLayout: DoneLayoutMode = .list { didSet { guard !isLoading else { return }; persistFlags() } }

    @ObservationIgnored private var runningTasks: [Int64: Task<Void, Never>] = [:]
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

    private init() {
        load()
        // Anything caught mid-flight by a kill resumes from PENDING.
        for i in queue.indices where queue[i].status == .downloading {
            queue[i].status = .pending
            queue[i].progress = 0
            queue[i].currentPage = 0
            queue[i].pagesDone = 0
            queue[i].ugoiraPhase = nil
        }
        pump()
    }

    // MARK: Enqueue

    /// Add works to the queue (skipping ones already queued). Returns how many
    /// were newly added. Resumes draining unless the user paused.
    @discardableResult
    func enqueue(_ illusts: [Illust]) -> Int {
        let existing = Set(queue.map(\.id))
        var added = 0
        for illust in illusts where !existing.contains(illust.id) {
            seqCounter += 1
            queue.append(DownloadItem(info: DownloadWorkInfo(illust: illust), seq: seqCounter))
            added += 1
        }
        if added > 0 { persist(); pump() }
        return added
    }

    // MARK: Queue controls

    func togglePause() { isPaused.toggle() }

    func retryFailed() {
        for i in queue.indices where queue[i].status == .failed {
            queue[i].status = .pending
            queue[i].error = nil
        }
        persist()
        pump()
    }

    func retry(_ id: Int64) {
        guard let i = queue.firstIndex(where: { $0.id == id }), queue[i].status == .failed else { return }
        queue[i].status = .pending
        queue[i].error = nil
        persist()
        pump()
    }

    /// Cancel and drop one item from the queue.
    func remove(_ id: Int64) {
        runningTasks[id]?.cancel()
        runningTasks[id] = nil
        queue.removeAll { $0.id == id }
        persist()
        pump()
    }

    /// Drop everything: cancel in-flight tasks and empty the queue.
    func clearQueue() {
        for t in runningTasks.values { t.cancel() }
        runningTasks.removeAll()
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

    /// Record a completed download that bypassed the queue (e.g. the detail-page
    /// FAB, which downloads immediately). Keeps the Done tab a complete history.
    func recordCompleted(_ illust: Illust) {
        let info = DownloadWorkInfo(illust: illust)
        appendDone(info: info)
    }

    // MARK: Drain loop

    private func pump() {
        guard !isPaused else { return }
        let limit = max(1, min(AppSettingsStore.shared.maxConcurrentDownloads, 5))
        while runningTasks.count < limit,
              let next = queue.first(where: { $0.status == .pending }) {
            start(next.id)
        }
    }

    private func start(_ id: Int64) {
        guard runningTasks[id] == nil, let i = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[i].status = .downloading
        queue[i].error = nil
        queue[i].ugoiraPhase = queue[i].info.kind == .ugoira ? .queued : nil
        let item = queue[i]
        runningTasks[id] = Task { [weak self] in
            await self?.run(item)
            self?.runningTasks[id] = nil
            self?.pump()
        }
    }

    private func run(_ item: DownloadItem) async {
        guard await PhotoLibrarySaver.requestAuthorization() else {
            fail(item.id, "Photos access denied"); return
        }
        if item.info.kind == .ugoira {
            await runUgoira(item)
        } else {
            await runImages(item)
        }
    }

    private func runImages(_ item: DownloadItem) async {
        let urls = item.info.pageURLs.compactMap(URL.init(string:))
        guard !urls.isEmpty else { fail(item.id, "No image URL"); return }
        let total = urls.count
        for (i, url) in urls.enumerated() {
            await parkWhilePaused()
            if Task.isCancelled { return }
            mutate(item.id) { $0.currentPage = i + 1 }
            let data = await PixivImageCache.shared.loadData(url) { [weak self] p in
                self?.mutate(item.id, throttled: true) {
                    $0.progress = (Double(i) + p) / Double(total)
                }
            }
            if Task.isCancelled { return }
            guard let data else { fail(item.id, "Couldn't load image"); return }
            do { try await PhotoLibrarySaver.save(data: data) }
            catch { fail(item.id, error.localizedDescription); return }
            mutate(item.id) { $0.pagesDone = i + 1; $0.progress = Double(i + 1) / Double(total) }
        }
        complete(item.id, info: item.info)
    }

    private func runUgoira(_ item: DownloadItem) async {
        let id = item.id
        await parkWhilePaused()
        if Task.isCancelled { return }
        do {
            let frames = try await UgoiraGIF.fetchFrames(illustId: id, api: api) { [weak self] phase in
                Task { @MainActor in self?.mutate(id) { $0.ugoiraPhase = phase } }
            }
            if Task.isCancelled { return }
            mutate(id) { $0.ugoiraPhase = .encoding; $0.progress = 0.5 }
            let gif = try await UgoiraGIF.encode(frames)
            if Task.isCancelled { return }
            try await PhotoLibrarySaver.save(data: gif)
            mutate(id) { $0.progress = 1 }
            complete(id, info: item.info)
        } catch {
            fail(id, error.localizedDescription)
        }
    }

    /// Hold an in-flight task between pages while the queue is paused — the iOS
    /// stand-in for upstream `Manager.stopAll()`, which suspends active transfers
    /// (we can't interrupt a page mid-flight, so we gate at page boundaries).
    private func parkWhilePaused() async {
        while isPaused && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
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
        let d = base.appendingPathComponent("Downloads", isDirectory: true)
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
        isPaused = UserDefaults.standard.bool(forKey: "dl_isPaused")
        doneLayout = DoneLayoutMode(rawValue: UserDefaults.standard.integer(forKey: "dl_doneLayout")) ?? .list
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
        UserDefaults.standard.set(isPaused, forKey: "dl_isPaused")
        UserDefaults.standard.set(doneLayout.rawValue, forKey: "dl_doneLayout")
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
