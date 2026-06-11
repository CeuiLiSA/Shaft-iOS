import Foundation
import Observation

/// App-wide single source of truth for illust bookmark state and user follow
/// state.
///
/// Pixiv models carry `is_bookmarked` / `is_followed` snapshots from whenever
/// their list page was fetched, so the same illust/user can appear in many
/// views with different staleness. Views never trust those snapshots directly:
/// they resolve display state through this store, which layers local toggles
/// (and fresh single-item fetches) over the snapshot. Toggling anywhere —
/// waterfall cell, detail action bar, profile header — updates every view
/// observing the store.
@MainActor
@Observable
final class InteractionStore {
    static let shared = InteractionStore()

    /// Authoritative per-id overrides. Written by local mutations and by fresh
    /// single-item server fetches; reads fall back to the model snapshot.
    private(set) var illustBookmarked: [Int64: Bool] = [:]
    private(set) var userFollowed: [Int64: Bool] = [:]
    /// In-flight guards — one concurrent mutation per id; also drives the
    /// disabled state of bookmark/follow buttons.
    private(set) var bookmarkBusy: Set<Int64> = []
    private(set) var followBusy: Set<Int64> = []

    @ObservationIgnored private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)

    // MARK: Resolution

    func isBookmarked(_ illust: Illust) -> Bool {
        illustBookmarked[illust.id] ?? illust.isBookmarked ?? false
    }

    func isBookmarked(id: Int64, fallback: Bool?) -> Bool {
        illustBookmarked[id] ?? fallback ?? false
    }

    func isFollowed(_ user: PixivUser) -> Bool {
        userFollowed[user.id] ?? user.isFollowed ?? false
    }

    func isFollowed(id: Int64, fallback: Bool?) -> Bool {
        userFollowed[id] ?? fallback ?? false
    }

    /// A fresh single-item fetch (`/illust/detail`, `/user/detail`) is newer
    /// truth than any local override — adopt it, unless a mutation is in
    /// flight for that id. List/feed responses must NOT be ingested: their
    /// pages can be older than a toggle made since.
    func ingest(illust: Illust) {
        if !bookmarkBusy.contains(illust.id), let b = illust.isBookmarked {
            illustBookmarked[illust.id] = b
        }
        if let user = illust.user { ingest(user: user) }
    }

    func ingest(user: PixivUser) {
        if !followBusy.contains(user.id), let f = user.isFollowed {
            userFollowed[user.id] = f
        }
    }

    // MARK: Bookmark mutations (optimistic; revert + rethrow on failure)

    func toggleBookmark(_ illust: Illust, restrict: String = "public") async throws {
        try await setBookmarked(!isBookmarked(illust), id: illust.id, restrict: restrict, tags: [])
    }

    /// Bookmark with explicit restrict + tags (the tag-sheet path). Re-applies
    /// when already bookmarked — Pixiv replaces the bookmark's tag/restrict set.
    func bookmark(illustId: Int64, restrict: String, tags: [String]) async throws {
        try await setBookmarked(true, id: illustId, restrict: restrict, tags: tags)
    }

    private func setBookmarked(_ target: Bool, id: Int64, restrict: String, tags: [String]) async throws {
        guard !bookmarkBusy.contains(id) else { return }
        bookmarkBusy.insert(id)
        defer { bookmarkBusy.remove(id) }
        let previous = illustBookmarked[id]
        illustBookmarked[id] = target
        do {
            if target {
                _ = try await api.bookmarkIllust(id, restrict: restrict, tags: tags)
            } else {
                _ = try await api.unbookmarkIllust(id)
            }
        } catch {
            if let previous {
                illustBookmarked[id] = previous
            } else {
                illustBookmarked.removeValue(forKey: id)
            }
            throw error
        }
    }

    // MARK: Follow mutations (optimistic; revert + rethrow on failure)

    func toggleFollow(_ user: PixivUser, restrict: String = "public") async throws {
        try await setFollowed(!isFollowed(user), id: user.id, restrict: restrict)
    }

    func setFollowed(_ target: Bool, id: Int64, restrict: String = "public") async throws {
        guard !followBusy.contains(id) else { return }
        followBusy.insert(id)
        defer { followBusy.remove(id) }
        let previous = userFollowed[id]
        userFollowed[id] = target
        do {
            if target {
                _ = try await api.followUser(id, restrict: restrict)
            } else {
                _ = try await api.unfollowUser(id)
            }
        } catch {
            if let previous {
                userFollowed[id] = previous
            } else {
                userFollowed.removeValue(forKey: id)
            }
            throw error
        }
    }
}
