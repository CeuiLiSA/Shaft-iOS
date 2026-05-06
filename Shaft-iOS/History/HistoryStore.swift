import Foundation
import Observation

/// Local view-history. Persists to UserDefaults as a JSON array of entries.
/// Capped at 500 entries (FIFO eviction).
@MainActor
@Observable
final class HistoryStore {
    static let shared = HistoryStore()

    private let key = "view_history_v1"
    private let cap = 500
    private let defaults = UserDefaults.standard

    var entries: [Entry] = []

    init() { entries = load() }

    enum Kind: String, Codable, Sendable, CaseIterable {
        case illust, novel, user
    }

    struct Entry: Codable, Hashable, Sendable, Identifiable {
        let kind: Kind
        let id: Int64
        let title: String
        let subtitle: String
        let imageURL: String?
        let viewedAt: Date

        var compositeID: String { "\(kind.rawValue):\(id)" }
        var idForList: String { compositeID }

        // Identifiable
        var identifier: String { compositeID }
    }

    func record(illust: Illust) {
        let entry = Entry(
            kind: .illust, id: illust.id,
            title: illust.title ?? "",
            subtitle: illust.user?.name ?? "",
            imageURL: illust.imageUrls?.squareMedium ?? illust.imageUrls?.medium,
            viewedAt: Date()
        )
        prepend(entry)
    }

    func record(novel: Novel) {
        let entry = Entry(
            kind: .novel, id: novel.id,
            title: novel.title ?? "",
            subtitle: novel.user?.name ?? "",
            imageURL: novel.imageUrls?.medium ?? novel.imageUrls?.squareMedium,
            viewedAt: Date()
        )
        prepend(entry)
    }

    func record(user: PixivUser) {
        let entry = Entry(
            kind: .user, id: user.id,
            title: user.name ?? "",
            subtitle: "@" + (user.account ?? ""),
            imageURL: user.profileImageUrls?.medium ?? user.profileImageUrls?.px170x170,
            viewedAt: Date()
        )
        prepend(entry)
    }

    func clear() {
        entries.removeAll()
        save()
    }

    /// Persist the current entries array. Useful after callers mutate
    /// `entries` directly (e.g. row deletion in HistoryView).
    func persist() { save() }

    private func prepend(_ e: Entry) {
        // Dedupe by compositeID.
        entries.removeAll { $0.compositeID == e.compositeID }
        entries.insert(e, at: 0)
        if entries.count > cap { entries.removeLast(entries.count - cap) }
        save()
    }

    private func load() -> [Entry] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }
}

extension HistoryStore.Entry: Equatable {
    static func == (l: HistoryStore.Entry, r: HistoryStore.Entry) -> Bool {
        l.compositeID == r.compositeID
    }
}
