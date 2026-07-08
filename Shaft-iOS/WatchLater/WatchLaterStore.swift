import Foundation
import Observation

/// Local "稍后再看" (Watch Later) store — a 1:1 port of Pixiv-Shaft's watch-later
/// feature, which upstream implements as a purely **local** list (no server API).
///
/// Upstream (`EntityWrapper` + Room `general_table`, `recordType = WATCH_LATER (7)`):
/// stores the full `Illust` JSON per row, keeps an in-memory `Set<Long>` of ids
/// for O(1) menu lookups, and fires an `ACTION_WATCH_LATER_CHANGED` LocalBroadcast
/// so the list page refreshes.
///
/// iOS equivalents:
/// - Room table  → UserDefaults JSON array of full `Illust` values (same shape as
///   `HistoryStore`), ordered most-recently-added first (`updatedTime DESC`).
/// - id `Set`    → `ids`, kept in sync for O(1) `contains`.
/// - LocalBroadcast → this `@Observable` singleton: any view reading `items`
///   re-renders automatically, so there is no NotificationCenter hop to make.
///
/// Watch Later holds illust/manga works only (not novels or users), exactly like
/// upstream (`EntityType.ILLUST`). It is user-curated (manual add/remove), so —
/// like upstream — there is no size cap.
@MainActor
@Observable
final class WatchLaterStore {
    static let shared = WatchLaterStore()

    private let key = "watch_later_v1"
    private let defaults = UserDefaults.standard

    /// Saved works, most-recently-added first (upstream orders by `updatedTime DESC`).
    private(set) var items: [Illust] = []

    /// O(1) membership mirror of `items` — the iOS stand-in for upstream's
    /// `_watchLaterIllustIds`; card long-press menus check this each time they open.
    @ObservationIgnored private var ids: Set<Int64> = []

    private init() {
        items = load()
        ids = Set(items.map(\.id))
    }

    /// Whether a work is already saved — O(1), drives the card long-press menu
    /// label ("加入 / 移出稍后再看").
    func contains(_ id: Int64) -> Bool { ids.contains(id) }

    /// Add a work, or move it to the front if already present. Upstream `insert`
    /// uses `OnConflictStrategy.REPLACE` on the `(id, recordType)` key, refreshing
    /// `updatedTime` so re-adding re-tops the entry and never duplicates it.
    func add(_ illust: Illust) {
        items.removeAll { $0.id == illust.id }
        items.insert(illust, at: 0)
        ids.insert(illust.id)
        save()
    }

    func remove(_ id: Int64) {
        items.removeAll { $0.id == id }
        ids.remove(id)
        save()
    }

    /// Card long-press toggle. Returns the new membership (true = now saved).
    @discardableResult
    func toggle(_ illust: Illust) -> Bool {
        if contains(illust.id) {
            remove(illust.id)
            return false
        }
        add(illust)
        return true
    }

    func clear() {
        items.removeAll()
        ids.removeAll()
        save()
    }

    // MARK: Persistence

    private func load() -> [Illust] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Illust].self, from: data)
        else { return [] }
        return decoded
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Coalesced, off-main persistence — same pattern as `HistoryStore`: adds fire
    /// from a context-menu tap while the menu/navigation animation is running, so
    /// JSON-encoding the array on the main thread there would compete with it. Each
    /// mutation captures its own post-mutation snapshot before the 300ms debounce.
    private func save() {
        saveTask?.cancel()
        let snapshot = items
        let key = key
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
}
