import Foundation
import Observation

/// Most-recently-used search terms, persisted to UserDefaults. Mirrors the
/// search-history surface in Pixiv-Shaft's FragmentSearch.
@MainActor
@Observable
final class SearchHistoryStore {
    static let shared = SearchHistoryStore()

    private let key = "search_history_v1"
    private let cap = 30
    private let defaults = UserDefaults.standard

    var entries: [String] = []

    init() {
        if let arr = defaults.stringArray(forKey: key) {
            entries = arr
        }
    }

    func record(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        entries.removeAll { $0.caseInsensitiveCompare(t) == .orderedSame }
        entries.insert(t, at: 0)
        if entries.count > cap { entries.removeLast(entries.count - cap) }
        save()
    }

    func remove(_ term: String) {
        entries.removeAll { $0 == term }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        defaults.set(entries, forKey: key)
    }
}
