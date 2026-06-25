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

    // MARK: Backup (local JSON export / import)

    /// JSON snapshot of every entry — the backup file the export flow writes.
    /// 1:1 in spirit with upstream `BrowseHistoryBackup.exportToJson`; ours is
    /// purely local (iOS history has no cloud-sync tier to push to).
    func exportJSON() -> Data? {
        try? JSONEncoder().encode(entries)
    }

    /// Merge a previously-exported snapshot into the store: dedupe by
    /// `compositeID`, keep whichever copy was viewed more recently, re-sort by
    /// recency, and apply the same cap. Returns the count of brand-new entries
    /// (mirrors `importFromJson`'s imported tally). Restores cleanly even when
    /// the current store is empty.
    @discardableResult
    func merge(_ imported: [Entry]) -> Int {
        var byID: [String: Entry] = [:]
        for e in entries { byID[e.compositeID] = e }
        var added = 0
        for e in imported {
            if let existing = byID[e.compositeID] {
                if e.viewedAt > existing.viewedAt { byID[e.compositeID] = e }
            } else {
                byID[e.compositeID] = e
                added += 1
            }
        }
        entries = byID.values.sorted { $0.viewedAt > $1.viewedAt }
        if entries.count > cap { entries.removeLast(entries.count - cap) }
        save()
        return added
    }

    /// Decode a backup file's bytes into entries. Throws on malformed JSON so
    /// the caller can surface the "couldn't read that file" message.
    static func decodeBackup(_ data: Data) throws -> [Entry] {
        try JSONDecoder().decode([Entry].self, from: data)
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

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Coalesced, off-main persistence. `record()` fires exactly when a detail
    /// page is being pushed — JSON-encoding up to 500 entries on the main
    /// thread there competes with the navigation transition. The 300ms window
    /// also collapses bursts (e.g. multi-row swipe deletes) into one write.
    private func save() {
        saveTask?.cancel()
        let snapshot = entries
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

extension HistoryStore.Entry: Equatable {
    static func == (l: HistoryStore.Entry, r: HistoryStore.Entry) -> Bool {
        l.compositeID == r.compositeID
    }
}
