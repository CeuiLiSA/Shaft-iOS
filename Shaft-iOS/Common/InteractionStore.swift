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
    private(set) var novelBookmarked: [Int64: Bool] = [:]
    private(set) var userFollowed: [Int64: Bool] = [:]
    /// *How* a follow is set — "public" / "private". `is_followed` is only a
    /// bool, so the V3 profile pill reads this to say 「悄悄关注中」 instead of
    /// 「已关注」 (upstream `FollowVisibility` + `followedLabelRes`).
    private(set) var followRestrict: [Int64: String] = [:]
    /// Ids whose visibility we set locally — a later server read must not
    /// clobber them (upstream `FollowVisibility.writeRemote` drops the write).
    @ObservationIgnored private var followRestrictLocal: Set<Int64> = []
    /// In-flight guards — one concurrent mutation per id; also drives the
    /// disabled state of bookmark/follow buttons.
    private(set) var bookmarkBusy: Set<Int64> = []
    private(set) var novelBookmarkBusy: Set<Int64> = []
    private(set) var followBusy: Set<Int64> = []

    @ObservationIgnored private let api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)

    // MARK: Resolution

    func isBookmarked(_ illust: Illust) -> Bool {
        illustBookmarked[illust.id] ?? illust.isBookmarked ?? false
    }

    func isBookmarked(id: Int64, fallback: Bool?) -> Bool {
        illustBookmarked[id] ?? fallback ?? false
    }

    func isBookmarked(_ novel: Novel) -> Bool {
        novelBookmarked[novel.id] ?? novel.isBookmarked ?? false
    }

    func isFollowed(_ user: PixivUser) -> Bool {
        userFollowed[user.id] ?? user.isFollowed ?? false
    }

    func isFollowed(id: Int64, fallback: Bool?) -> Bool {
        userFollowed[id] ?? fallback ?? false
    }

    func isPrivateFollow(id: Int64) -> Bool { followRestrict[id] == "private" }

    /// `/v1/user/follow/detail` result. Dropped when the visibility was set
    /// locally (or a mutation is in flight) so a slow read can't rewind it.
    func ingestRemoteFollowRestrict(_ restrict: String?, id: Int64) {
        guard !followRestrictLocal.contains(id), !followBusy.contains(id) else { return }
        if let restrict {
            followRestrict[id] = restrict
        } else {
            followRestrict.removeValue(forKey: id)
        }
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

    /// The novel detail page mutates through its own API path; it reports the
    /// outcome here so list-card hearts (and vice versa) stay in step.
    func noteNovelBookmark(id: Int64, _ bookmarked: Bool) {
        guard !novelBookmarkBusy.contains(id) else { return }
        novelBookmarked[id] = bookmarked
    }

    func ingest(novel: Novel) {
        if !novelBookmarkBusy.contains(novel.id), let b = novel.isBookmarked {
            novelBookmarked[novel.id] = b
        }
        if let user = novel.user { ingest(user: user) }
    }

    func ingest(user: PixivUser) {
        if !followBusy.contains(user.id), let f = user.isFollowed {
            userFollowed[user.id] = f
        }
    }

    // MARK: Bookmark mutations (optimistic; revert + rethrow on failure)

    func toggleBookmark(_ illust: Illust, restrict: String? = nil) async throws {
        try await setBookmarked(!isBookmarked(illust), id: illust.id, restrict: restrict, tags: [], illust: illust)
    }

    /// Bookmark with explicit restrict + tags (the tag-sheet path). Re-applies
    /// when already bookmarked — Pixiv replaces the bookmark's tag/restrict set.
    func bookmark(illustId: Int64, restrict: String, tags: [String], illust: Illust? = nil) async throws {
        try await setBookmarked(true, id: illustId, restrict: restrict, tags: tags, illust: illust)
    }

    /// Returns whether the mutation actually ran (false = skipped because a
    /// concurrent toggle for the same id was already in flight). `illust` (when
    /// known) is forwarded as the event payload.
    @discardableResult
    private func setBookmarked(_ target: Bool, id: Int64, restrict: String?, tags: [String], illust: Illust? = nil) async throws -> Bool {
        guard !bookmarkBusy.contains(id) else { return false }
        bookmarkBusy.insert(id)
        defer { bookmarkBusy.remove(id) }
        let previous = illustBookmarked[id]
        illustBookmarked[id] = target
        let resolvedRestrict = restrict
            ?? (AppSettingsStore.shared.privateStar ? "private" : "public")
        do {
            if target {
                _ = try await api.bookmarkIllust(id, restrict: resolvedRestrict, tags: tags)
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
        // Single reporting choke point: every caller (toggle, tag-sheet, …) lands
        // here, so no path bypasses the report and none double-reports. Fires only
        // on a real, successful mutation (busy-skip returns above; failure throws).
        Task { await ShaftEventReporter.shared.reportIllustBookmark(illust, id: id, added: target) }
        // 把这次已被服务端确认的收藏 / 取消收藏同步进收藏镜像表（upstream
        // `PixivActionQueue.syncBookmarkMirror`）：收藏需要一份带 is_bookmarked=true 的 bean
        // 才能入库（镜像行里存的是完整 JSON）；没有 bean 时放弃这一条 —— 缺的那条会在下一次
        // 增量维护里被表头扫到。取消不需要 bean，按 id 跨公开/悄悄两个书架删。
        syncBookmarkMirror(illust: illust, id: id, added: target, restrict: resolvedRestrict)
        return true
    }

    private func syncBookmarkMirror(illust: Illust?, id: Int64, added: Bool, restrict: String) {
        Task {
            if added {
                guard let illust else { return }
                await BookmarkMirrorService.shared.onIllustBookmarked(
                    BookmarkMirrorMapper.withBookmarked(illust, true), restrict: MirrorRestrict.ofApiValue(restrict)
                )
            } else {
                await BookmarkMirrorService.shared.onUnbookmarked(contentType: .illust, targetId: id)
            }
        }
    }

    // MARK: Novel bookmark mutations (optimistic; revert + rethrow on failure)

    /// Novel-card heart (upstream `NovelFeedFragment.toggleNovelLike`): flips the
    /// color at the tap, reverts on failure.
    func toggleBookmark(novel: Novel, restrict: String? = nil) async throws {
        try await setNovelBookmarked(!isBookmarked(novel), id: novel.id, restrict: restrict, tags: [], novel: novel)
    }

    func bookmark(novelId: Int64, restrict: String, tags: [String], novel: Novel? = nil) async throws {
        try await setNovelBookmarked(true, id: novelId, restrict: restrict, tags: tags, novel: novel)
    }

    @discardableResult
    private func setNovelBookmarked(_ target: Bool, id: Int64, restrict: String?, tags: [String], novel: Novel?) async throws -> Bool {
        guard !novelBookmarkBusy.contains(id) else { return false }
        novelBookmarkBusy.insert(id)
        defer { novelBookmarkBusy.remove(id) }
        let previous = novelBookmarked[id]
        novelBookmarked[id] = target
        let resolvedRestrict = restrict
            ?? (AppSettingsStore.shared.privateStar ? "private" : "public")
        do {
            if target {
                _ = try await api.bookmarkNovel(id, restrict: resolvedRestrict, tags: tags)
            } else {
                _ = try await api.unbookmarkNovel(id)
            }
        } catch {
            if let previous {
                novelBookmarked[id] = previous
            } else {
                novelBookmarked.removeValue(forKey: id)
            }
            throw error
        }
        if let novel {
            Task { await ShaftEventReporter.shared.reportNovelBookmark(novel, added: target) }
        }
        Task {
            if target {
                guard let novel else { return }
                await BookmarkMirrorService.shared.onNovelBookmarked(
                    BookmarkMirrorMapper.withBookmarked(novel, true), restrict: MirrorRestrict.ofApiValue(resolvedRestrict)
                )
            } else {
                await BookmarkMirrorService.shared.onUnbookmarked(contentType: .novel, targetId: id)
            }
        }
        return true
    }

    // MARK: Follow mutations (optimistic; revert + rethrow on failure)

    func toggleFollow(_ user: PixivUser, restrict: String? = nil) async throws {
        try await setFollowed(!isFollowed(user), id: user.id, restrict: restrict, user: user)
    }

    /// Returns whether the mutation actually ran (false = skipped, concurrent toggle
    /// in flight). Pass `user` when available so the reported event carries payload.
    /// Reporting lands here (the success choke point) so profile-page follows —
    /// which call this directly, not `toggleFollow` — are reported too.
    @discardableResult
    func setFollowed(_ target: Bool, id: Int64, restrict: String? = nil, user: PixivUser? = nil) async throws -> Bool {
        guard !followBusy.contains(id) else { return false }
        followBusy.insert(id)
        defer { followBusy.remove(id) }
        let previous = userFollowed[id]
        userFollowed[id] = target
        // Android `PixivActions.defaultFollowRestrict()`: ordinary taps respect
        // the setting; callers can still pass "private" explicitly for the
        // long-press shortcut.
        let resolvedRestrict = restrict
            ?? (AppSettingsStore.shared.privateFollow ? "private" : "public")
        do {
            if target {
                _ = try await api.followUser(id, restrict: resolvedRestrict)
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
        // Visibility follows the mutation and outranks any later server read.
        if target {
            followRestrict[id] = resolvedRestrict
        } else {
            followRestrict.removeValue(forKey: id)
        }
        followRestrictLocal.insert(id)
        Task { await ShaftEventReporter.shared.reportFollow(user, id: id, followed: target) }
        return true
    }
}
