import Foundation
import Observation

/// Local mute lists for users and tags. Pixiv's API doesn't expose a server
/// mute primitive in the public app endpoints — Shaft keeps these client-side
/// in MMKV. We do the same in UserDefaults.
@MainActor
@Observable
final class MuteStore {
    static let shared = MuteStore()

    private let mutedUserKey = "muted_user_ids_v1"
    private let mutedTagKey = "muted_tags_v1"
    /// Upstream keeps a Room row per muted work (`IllustMuteEntity`); the V3
    /// detail page's full-page mask reads it (see `attachMuteObserver`).
    private let mutedIllustKey = "muted_illust_ids_v1"
    /// Upstream `NovelMuteStore` — the novel-card "屏蔽此作品" row (issue #974).
    private let mutedNovelKey = "muted_novel_ids_v1"
    private let hideR18Key = "content_hide_r18_v1"
    private let waterfallColumnsKey = "ui_waterfall_columns_v1"
    private let defaults = UserDefaults.standard

    /// Tags that mark a work as R-18/R-18G. Pixiv tags are stable strings.
    private static let r18Tags: Set<String> = ["R-18", "R-18G"]

    var mutedUserIDs: Set<Int64> = []
    var mutedTags: Set<String> = []
    var mutedIllustIDs: Set<Int64> = []
    var mutedNovelIDs: Set<Int64> = []
    var hideR18: Bool = true
    var waterfallColumns: Int = 2

    init() {
        if let arr = defaults.array(forKey: mutedUserKey) as? [Int] {
            mutedUserIDs = Set(arr.map { Int64($0) })
        } else if let arr = defaults.array(forKey: mutedUserKey) as? [Int64] {
            mutedUserIDs = Set(arr)
        }
        if let tags = defaults.stringArray(forKey: mutedTagKey) {
            mutedTags = Set(tags)
        }
        if let arr = defaults.array(forKey: mutedIllustKey) as? [Int] {
            mutedIllustIDs = Set(arr.map { Int64($0) })
        }
        if let arr = defaults.array(forKey: mutedNovelKey) as? [Int] {
            mutedNovelIDs = Set(arr.map { Int64($0) })
        }
        if defaults.object(forKey: hideR18Key) != nil {
            hideR18 = defaults.bool(forKey: hideR18Key)
        }
        let storedCols = defaults.integer(forKey: waterfallColumnsKey)
        if storedCols >= 1 && storedCols <= 4 {
            waterfallColumns = storedCols
        }
    }

    func setHideR18(_ value: Bool) {
        hideR18 = value
        defaults.set(value, forKey: hideR18Key)
    }

    func setWaterfallColumns(_ value: Int) {
        let clamped = max(1, min(value, 4))
        waterfallColumns = clamped
        defaults.set(clamped, forKey: waterfallColumnsKey)
    }

    func isUserMuted(_ id: Int64) -> Bool { mutedUserIDs.contains(id) }
    func isIllustMuted(_ id: Int64) -> Bool { mutedIllustIDs.contains(id) }

    /// `IllustMuteStore.setMuted` — the detail page's mask and the "mute this
    /// work" menu row both go through here so they can never disagree.
    func setIllustMuted(_ id: Int64, _ muted: Bool) {
        if muted { mutedIllustIDs.insert(id) } else { mutedIllustIDs.remove(id) }
        defaults.set(Array(mutedIllustIDs).map { Int($0) }, forKey: mutedIllustKey)
    }
    func isNovelMuted(_ id: Int64) -> Bool { mutedNovelIDs.contains(id) }

    /// `NovelMuteStore.setMuted` — novel-card spoiler mask + its menu row.
    func setNovelMuted(_ id: Int64, _ muted: Bool) {
        if muted { mutedNovelIDs.insert(id) } else { mutedNovelIDs.remove(id) }
        defaults.set(Array(mutedNovelIDs).map { Int($0) }, forKey: mutedNovelKey)
    }
    func isTagMuted(_ tag: String) -> Bool { mutedTags.contains(tag) }

    func toggleUser(_ id: Int64) {
        if mutedUserIDs.contains(id) { mutedUserIDs.remove(id) }
        else { mutedUserIDs.insert(id) }
        defaults.set(Array(mutedUserIDs).map { Int($0) }, forKey: mutedUserKey)
    }

    func toggleTag(_ tag: String) {
        if mutedTags.contains(tag) { mutedTags.remove(tag) }
        else { mutedTags.insert(tag) }
        defaults.set(Array(mutedTags), forKey: mutedTagKey)
    }

    /// Filter helper used by feeds to drop muted users, muted tags, and
    /// (optionally) R-18/R-18G content before display.
    ///
    /// Search passes `applyR18: false` because its per-search R-18 mode governs
    /// age visibility (by real `x_restrict`, not the tag hack) — the global
    /// `hideR18` toggle must not double-filter those results.
    func filter<T: HasMuteAttributes>(_ items: [T], applyR18: Bool = true) -> [T] {
        items.filter { item in
            if let uid = item.muteUserID, mutedUserIDs.contains(uid) { return false }
            if let tags = item.muteTags, !tags.isEmpty {
                if !mutedTags.isDisjoint(with: tags) { return false }
                if applyR18, hideR18, !Self.r18Tags.isDisjoint(with: tags) { return false }
            }
            return true
        }
    }
}

protocol HasMuteAttributes {
    var muteUserID: Int64? { get }
    var muteTags: Set<String>? { get }
}

extension Illust: HasMuteAttributes {
    var muteUserID: Int64? { user?.id }
    var muteTags: Set<String>? {
        guard let tags else { return nil }
        return Set(tags.compactMap { $0.name })
    }
}

extension Novel: HasMuteAttributes {
    var muteUserID: Int64? { user?.id }
    var muteTags: Set<String>? {
        guard let tags else { return nil }
        return Set(tags.compactMap { $0.name })
    }
}
