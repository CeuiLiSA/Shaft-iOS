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
    private let defaults = UserDefaults.standard

    var mutedUserIDs: Set<Int64> = []
    var mutedTags: Set<String> = []

    init() {
        if let arr = defaults.array(forKey: mutedUserKey) as? [Int] {
            mutedUserIDs = Set(arr.map { Int64($0) })
        } else if let arr = defaults.array(forKey: mutedUserKey) as? [Int64] {
            mutedUserIDs = Set(arr)
        }
        if let tags = defaults.stringArray(forKey: mutedTagKey) {
            mutedTags = Set(tags)
        }
    }

    func isUserMuted(_ id: Int64) -> Bool { mutedUserIDs.contains(id) }
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

    /// Filter helper used by feeds to drop muted illusts before display.
    func filter<T: HasMuteAttributes>(_ items: [T]) -> [T] {
        items.filter { item in
            if let uid = item.muteUserID, mutedUserIDs.contains(uid) { return false }
            if let tags = item.muteTags, !tags.isEmpty,
               !mutedTags.isDisjoint(with: tags) { return false }
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
