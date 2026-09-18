import Foundation
import Observation
import PhotosUI
import SwiftUI

@MainActor @Observable
final class PlazaStore {
    let uid: Int64
    let api: any PlazaServing
    private(set) var posts: [Int64: PlazaPost] = [:]
    private(set) var deleted: Set<Int64> = []
    private(set) var revision = 0
    private(set) var structureRevision = 0
    private(set) var busy = false
    var failure: Error?
    @ObservationIgnored private var fetched: [Int64: Double] = [:]
    @ObservationIgnored let currentUID: @Sendable () -> Int64

    init(api: any PlazaServing = PlazaAPI.shared, currentUID: @escaping @Sendable () -> Int64 = { plazaCurrentUID() }) {
        self.api = api; self.currentUID = currentUID; uid = currentUID()
    }
    func check() throws {
        guard uid > 0, currentUID() == uid else { throw PlazaFailure(key: uid > 0 ? "account_changed" : "login_required") }
    }
    func accept(_ post: PlazaPost) {
        guard !deleted.contains(post.id) else { return }
        posts[post.id] = post
        fetched[post.id] = plazaNow()
    }
    func page(before: Int64?, author: Int64?, replyTo: Int64?) async throws -> PlazaPage {
        // Mutations return complete posts. A read started earlier cannot replace them.
        for _ in 0..<3 {
            try check()
            let epoch = revision
            let result = try await api.feed(uid: uid, before: before, author: author, replyTo: replyTo)
            try check(); try Task.checkCancellation()
            guard epoch == revision else { continue }
            for post in result.items { accept(post) }
            return result
        }
        throw CancellationError()
    }
    @discardableResult
    func fetch(_ id: Int64, force: Bool = false) async throws -> PlazaPost {
        try check()
        if !force, let post = posts[id], !post.needsFreshImages, plazaNow() - (fetched[id] ?? 0) < 240_000 { return post }
        for _ in 0..<3 {
            let epoch = revision
            do {
                let post = try await api.post(uid: uid, id: id)
                try check(); try Task.checkCancellation()
                guard epoch == revision else { continue }
                accept(post)
                return post
            } catch let error as PlazaFailure where error.status == 404 {
                guard epoch == revision else { continue }
                invalidate(id)
                throw error
            }
        }
        throw CancellationError()
    }
    private func invalidate(_ id: Int64) {
        posts[id] = nil; deleted.insert(id); revision += 1; structureRevision += 1
    }
    func mutate(_ action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; revision += 1
        defer { busy = false; revision += 1 }
        do { try check(); try await action(); try check() }
        catch is CancellationError { }
        catch { failure = error }
    }
    func like(_ post: PlazaPost) async {
        await mutate {
            let fresh = try await api.like(uid: uid, id: post.id, selected: !post.liked)
            try check(); accept(fresh)
        }
    }
    func react(_ post: PlazaPost, _ reaction: PlazaReaction) async {
        await mutate {
            let fresh = try await api.react(uid: uid, id: post.id, reaction: reaction)
            try check(); accept(fresh)
        }
    }
    func delete(_ post: PlazaPost) async {
        await mutate {
            try await api.delete(uid: uid, id: post.id)
            try check(); invalidate(post.id)
        }
    }
    func block(_ author: Int64, selected: Bool) async {
        await mutate {
            try await api.block(uid: uid, author: author, selected: selected)
            try check()
            // Drop all cached previews too: they can contain the blocked author's replies.
            posts.removeAll(); fetched.removeAll(); structureRevision += 1
        }
    }
    func publish(_ body: PlazaCreateRequest) async throws -> PlazaPost {
        try check()
        guard !busy else { throw PlazaFailure(key: "publishing_wait") }
        busy = true; revision += 1
        defer { busy = false; revision += 1 }
        let post = try await api.create(uid: uid, body: body)
        try check(); accept(post); structureRevision += 1
        return post
    }
}

@MainActor @Observable
final class PlazaPageModel {
    private(set) var ids: [Int64] = []
    private(set) var next: Int64?
    private(set) var loaded = false
    private(set) var loading = false
    private(set) var error: Error?
    @ObservationIgnored private var generation = 0
    func load(store: PlazaStore, author: Int64? = nil, replyTo: Int64? = nil, reset: Bool) async {
        guard reset || (!loading && next != nil) else { return }
        generation += 1
        let token = generation, cursor = reset ? nil : next
        loading = true; error = nil
        defer { if token == generation { loading = false } }
        do {
            let page = try await store.page(before: cursor, author: author, replyTo: replyTo)
            guard token == generation else { return }
            var seen = Set<Int64>()
            ids = ((reset ? [] : ids) + page.items.map(\.id)).filter { seen.insert($0).inserted }
            next = page.nextBefore == cursor ? nil : page.nextBefore
            loaded = true
        } catch is CancellationError { }
        catch { if token == generation { self.error = error; loaded = true } }
    }
}

struct PlazaDraft: Codable, Sendable {
    var requestId = UUID().uuidString.lowercased()
    var title = ""
    var text = ""
    var images: [PlazaAttachment] = []
    var objectId: Int64?
    var objectType: String?
    var replyTo: Int64?
    var replyName: String?
    var replyPreview: String?
    var isEmpty: Bool { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty && objectId == nil }
    var valid: Bool { !isEmpty && title.unicodeScalars.count <= 120 && text.unicodeScalars.count <= 2000 && images.count <= 9 }
}

@MainActor @Observable
final class PlazaComposerModel {
    private(set) var draft: PlazaDraft
    private(set) var sending = false
    private(set) var importing = false
    private(set) var progress: [UUID: Double] = [:]
    var error: Error?
    let owner: Int64
    let directory: URL
    @ObservationIgnored private let rootReply: Int64?
    @ObservationIgnored private let uploader: PlazaMediaUploader
    @ObservationIgnored private let persistent: Bool
    @ObservationIgnored private var avatarURL: String?

    init(uid: Int64, replyTo: Int64? = nil, uploader: PlazaMediaUploader = .init(), persistent: Bool = true, draftKey: String? = nil) {
        owner = uid; rootReply = replyTo; self.uploader = uploader; self.persistent = persistent
        directory = PlazaPhotoFiles.directory(uid: uid, draft: draftKey ?? replyTo.map { "reply-\($0)" } ?? "post")
        let saved = persistent ? (try? Data(contentsOf: directory.appendingPathComponent("draft.json"))) : nil
        draft = saved.flatMap { try? JSONDecoder().decode(PlazaDraft.self, from: $0) } ?? PlazaDraft(replyTo: replyTo)
    }
    var canSend: Bool { draft.valid && !sending && !importing }
    func loadAvatar() async {
        guard persistent, plazaCurrentUID() == owner, owner > 0 else { return }
        let user = try? await PixivAPI.make(tokenProvider: AuthTokenProvider.shared).userDetail(owner).user
        if plazaCurrentUID() == owner { avatarURL = user?.profileImageUrls?.medium }
    }
    func edit(_ change: (inout PlazaDraft) -> Void) {
        guard !sending else { return }
        change(&draft)
        draft.requestId = UUID().uuidString.lowercased()
        save()
    }
    private func persist() throws {
        guard persistent else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: directory.appendingPathComponent("draft.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func save() { do { try persist() } catch { self.error = error } }
    func remove(_ image: PlazaAttachment) {
        guard !sending else { return }
        edit { $0.images.removeAll { $0.id == image.id } }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(image.fileName))
    }
    func importPhotos(_ items: [PhotosPickerItem], limit: Int = 9) async {
        guard !sending, !importing else { return }
        importing = true; error = nil
        defer { importing = false }
        for item in items.prefix(max(0, limit - draft.images.count)) {
            do {
                try plazaCheckAccount(owner)
                guard let imported = try await item.loadTransferable(type: PlazaImportedFile.self) else { throw PlazaFailure(key: "media_read_error") }
                defer { try? FileManager.default.removeItem(at: imported.url) }
                let dir = directory
                let image = try await Task.detached(priority: .userInitiated) { try PlazaPhotoFiles.importFile(imported.url, directory: dir) }.value
                try plazaCheckAccount(owner)
                edit { $0.images.append(image) }
            } catch is CancellationError { return }
            catch { self.error = error }
        }
    }
    func discard() {
        guard !sending else { return }
        draft = PlazaDraft(replyTo: rootReply)
        if persistent { try? FileManager.default.removeItem(at: directory) }
    }
    func reportMedia(store: PlazaStore) async throws -> [String] {
        guard !sending, !importing else { throw PlazaFailure(key: "publishing_wait") }
        sending = true
        defer { sending = false }
        try await uploadImages(store: store)
        return draft.images.compactMap(\.mediaId)
    }
    private func uploadImages(store: PlazaStore) async throws {
        try store.check()
        guard owner == store.uid else { throw PlazaFailure(key: "account_changed") }
        for image in draft.images where image.mediaId == nil {
            let media = try await uploader.upload(image, directory: directory, uid: owner, saveTicket: { [weak self] ticket in
                try await self?.save(ticket: ticket, imageID: image.id)
            }, progress: { [weak self] fraction in
                Task { @MainActor in self?.progress[image.id] = fraction }
            })
            try store.check()
            if let index = draft.images.firstIndex(where: { $0.id == image.id }) {
                draft.images[index].mediaId = media.mediaId
                draft.images[index].ticket = nil
                try persist()
            }
        }
    }
    func send(store: PlazaStore) async -> PlazaPost? {
        guard canSend else { return nil }
        sending = true; error = nil
        defer { sending = false }
        do {
            try store.check()
            guard owner == store.uid else { throw PlazaFailure(key: "account_changed") }
            try persist()
            try await uploadImages(store: store)
            var extensions: PlazaObjectExtensions?
            if let id = draft.objectId, ["illust", "manga"].contains(draft.objectType ?? "") {
                let work = try? await PixivAPI.make(tokenProvider: AuthTokenProvider.shared).illustDetail(id).illust
                if let work, work.imageUrls?.medium != nil { extensions = PlazaObjectExtensions(illust: work) }
            }
            try store.check()
            let body = PlazaCreateRequest(requestId: draft.requestId, text: draft.text.trimmingCharacters(in: .whitespacesAndNewlines),
                displayName: KeychainTokenStore.shared.load()?.user?.name ?? String(owner), mediaIds: draft.images.compactMap(\.mediaId),
                objectId: draft.objectId, objectType: draft.objectType, replyTo: draft.replyTo,
                title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines), avatarUrl: avatarURL, objectExtensions: extensions)
            let post = try await store.publish(body)
            draft = PlazaDraft(replyTo: rootReply)
            if persistent { try? FileManager.default.removeItem(at: directory) }
            return post
        } catch is CancellationError { return nil }
        catch { self.error = error; return nil }
    }
    private func save(ticket: PlazaUploadTicket, imageID: UUID) throws {
        try plazaCheckAccount(owner)
        if let index = draft.images.firstIndex(where: { $0.id == imageID }) {
            draft.images[index].ticket = ticket
            try persist()
        }
    }
}
