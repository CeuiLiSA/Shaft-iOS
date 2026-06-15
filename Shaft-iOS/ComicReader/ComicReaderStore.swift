import Foundation
import Observation

// Persistence for the V3 manga reader. Upstream keeps comic bookmarks and
// per-work reading stats in Room (`ComicBookmarkEntity` / `ComicReadingStatsEntity`)
// and the last-read page in an MMKV namespace ("comic_reader_v3_progress").
// iOS mirror: one JSON file in Application Support for bookmarks + stats (same
// pattern as `NovelReaderLocalStore`), and UserDefaults for the lightweight
// progress cursor.

/// One saved page position for an illust (`ComicBookmarkEntity` parity).
struct ComicBookmark: Codable, Identifiable, Equatable {
    var id: Int64
    var illustId: Int64
    var pageIndex: Int
    var totalPages: Int
    var previewUrl: String
    var note: String
    var createdTime: Double
}

/// Cumulative reading stats for one illust (`ComicReadingStatsEntity` parity).
struct ComicReadingStats: Codable, Equatable {
    var illustId: Int64
    var lastPageIndex: Int = 0
    var totalPageCount: Int = 0
    var firstReadTime: Double = 0
    var lastReadTime: Double = 0
    var totalDurationSec: Double = 0
    var totalFlips: Int = 0
    var openCount: Int = 0
    var completed: Bool = false
}

@MainActor
@Observable
final class ComicReaderLocalStore {
    static let shared = ComicReaderLocalStore()

    private(set) var bookmarks: [ComicBookmark] = []
    private(set) var stats: [Int64: ComicReadingStats] = [:]

    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var nextId: Int64 = 1

    private struct Snapshot: Codable {
        var bookmarks: [ComicBookmark]
        var stats: [ComicReadingStats]
        var nextId: Int64
    }

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("comic_reader_v3_local.json")
    }()

    private init() { loadIfNeeded() }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        bookmarks = snap.bookmarks
        stats = Dictionary(uniqueKeysWithValues: snap.stats.map { ($0.illustId, $0) })
        nextId = snap.nextId
    }

    private func persist() {
        let snap = Snapshot(bookmarks: bookmarks, stats: Array(stats.values), nextId: nextId)
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    private func takeId() -> Int64 { defer { nextId += 1 }; return nextId }

    // ---- Bookmarks ---------------------------------------------------------

    /// Newest-first, matching upstream `observeForIllust` ORDER BY createdTime DESC.
    func bookmarks(for illustId: Int64) -> [ComicBookmark] {
        bookmarks.filter { $0.illustId == illustId }.sorted { $0.createdTime > $1.createdTime }
    }

    func addBookmark(illustId: Int64, pageIndex: Int, totalPages: Int, previewUrl: String, note: String = "") {
        bookmarks.append(ComicBookmark(
            id: takeId(), illustId: illustId, pageIndex: pageIndex, totalPages: totalPages,
            previewUrl: previewUrl, note: note, createdTime: Date().timeIntervalSince1970
        ))
        persist()
    }

    func deleteBookmark(id: Int64) {
        bookmarks.removeAll { $0.id == id }
        persist()
    }

    // ---- Reading stats -----------------------------------------------------

    /// Read-modify-write one session's accumulation into the illust's stats row
    /// (`ComicStatsRepository.flushSession` parity). No-op for empty sessions.
    func flushSession(illustId: Int64, lastIndex: Int, totalPages: Int, durationSec: Double, flips: Int) {
        guard durationSec > 0 || flips > 0 else { return }
        let now = Date().timeIntervalSince1970
        var s = stats[illustId] ?? ComicReadingStats(illustId: illustId, firstReadTime: now)
        s.lastPageIndex = lastIndex
        if totalPages > 0 { s.totalPageCount = totalPages }
        s.lastReadTime = now
        s.totalDurationSec += durationSec
        s.totalFlips += flips
        s.openCount = max(s.openCount + 1, 1)
        if totalPages > 0 && lastIndex >= totalPages - 1 { s.completed = true }
        stats[illustId] = s
        persist()
    }

    func stats(for illustId: Int64) -> ComicReadingStats? { stats[illustId] }
}

/// Per-illust last-read page cursor (`ComicReaderProgressStore` parity), kept in
/// UserDefaults like the novel reader's progress store.
enum ComicReaderProgressStore {
    private static let prefix = "crv3_progress_"
    private static var d: UserDefaults { .standard }

    static func savePage(illustId: Int64, pageIndex: Int, totalPages: Int) {
        d.set(pageIndex, forKey: "\(prefix)page_\(illustId)")
        d.set(totalPages, forKey: "\(prefix)total_\(illustId)")
        d.set(Date().timeIntervalSince1970, forKey: "\(prefix)time_\(illustId)")
    }

    static func lastPage(illustId: Int64) -> Int {
        d.integer(forKey: "\(prefix)page_\(illustId)")
    }
}
