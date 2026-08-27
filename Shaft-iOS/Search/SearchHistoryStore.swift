import Foundation
import Observation

/// What a history row *was* when it was searched — upstream `SearchEntity.searchType`
/// (`SearchTypeUtil.SEARCH_TYPE_DB_*`). Re-tapping a row replays the same kind of
/// jump instead of always running a keyword search. Raw values match the DB ints.
enum SearchHistoryKind: Int, Codable, Hashable, Sendable {
    case keyword = 0
    case illustId = 1
    /// Deprecated upstream (kept for old rows); behaves like `.keyword`.
    case userKeyword = 2
    case userId = 3
    case novelId = 4
    case url = 5
}

/// One `search_table` row. Identity is `keyword + kind` — upstream's primary key
/// is `keyword.hashCode() + searchType`, so the same word searched as a keyword
/// and as an illust ID are two separate rows.
struct SearchHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    let keyword: String
    let kind: SearchHistoryKind
    var searchTime: Date

    var id: String { "\(kind.rawValue):\(keyword)" }
}

/// Recent (unpinned) search rows, persisted to UserDefaults. Mirrors the
/// `getRecentUnpinned(50)` half of Pixiv-Shaft's `FragmentSearch`; the pinned
/// half is `PinnedTagsStore`, and moving a row between the two is `pin` / the
/// store's `unpin` + `record`.
@MainActor
@Observable
final class SearchHistoryStore {
    static let shared = SearchHistoryStore()

    private let key = "search_history_v2"
    private let legacyKey = "search_history_v1"
    /// Upstream shows the 50 most recent unpinned rows.
    private let cap = 50
    private let defaults = UserDefaults.standard

    /// Newest first.
    var entries: [SearchHistoryEntry] = []

    init() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([SearchHistoryEntry].self, from: data) {
            entries = decoded
        } else if let legacy = defaults.stringArray(forKey: legacyKey) {
            // Pre-typed store: plain strings, all keyword searches.
            let now = Date()
            entries = legacy.enumerated().map { i, term in
                SearchHistoryEntry(keyword: term, kind: .keyword,
                                   searchTime: now.addingTimeInterval(-Double(i)))
            }
            save()
            defaults.removeObject(forKey: legacyKey)
        }
    }

    /// Insert-or-refresh (`insertSearchHistory` → `REPLACE` on the id): the row
    /// moves to the front with a fresh timestamp.
    func record(_ term: String, kind: SearchHistoryKind = .keyword) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        entries.removeAll { $0.keyword == t && $0.kind == kind }
        entries.insert(SearchHistoryEntry(keyword: t, kind: kind, searchTime: Date()), at: 0)
        if entries.count > cap { entries.removeLast(entries.count - cap) }
        save()
    }

    func remove(_ entry: SearchHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    /// `deleteAllUnpinned` — pinned tags are untouched.
    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }
}
