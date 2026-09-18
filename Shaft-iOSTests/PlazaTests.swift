import XCTest
import SwiftUI
import CryptoKit
@testable import Shaft_iOS

private func fixturePost(_ id: Int64 = 1, likes: Int = 0) -> PlazaPost {
    PlazaPost(id: id, uid: 42, displayName: "Ayaba Onile-Ire", text: "Route Overview\nTotal Distance: ~1,800 km Recommended Duration: 12–14 days",
              createdAt: 1778371200000, likeCount: likes, replyCount: 8, liked: likes > 0,
              title: "New Zealand South Island Road Trip Itinerary",
              reactions: [.init(emoji: "👀", count: 38, selected: true), .init(emoji: "💪", count: 19, selected: false),
                          .init(emoji: "👌", count: 32, selected: false), .init(emoji: "😂", count: 2, selected: false), .init(emoji: "🤔", count: 6, selected: false)],
              commentsPreview: [.init(id: 2, uid: 50, displayName: "Brian", text: "12 days vibe hits different 🚐 No rush and plenty of stops"),
                                .init(id: 3, uid: 51, displayName: "Bojan", text: "Autumn views are chef's kiss 🍂 Saved this route!")])
}

actor PlazaTestService: PlazaServing {
    var value = fixturePost()
    var attempts: [PlazaCreateRequest] = []
    var failCreate = false
    var holdPage = false
    var pending: CheckedContinuation<Void, Never>?
    var pageStarted = false
    var requestCount = 0
    var paginated = false
    func paginate() { paginated = true; value = compactPost(100) }
    private func compactPost(_ id: Int64) -> PlazaPost {
        PlazaPost(id: id, uid: 42, displayName: "Test", text: "Page \(id)", createdAt: 1778371200000)
    }
    func configure(failCreate: Bool = false, holdPage: Bool = false) { self.failCreate = failCreate; self.holdPage = holdPage }
    func setPost(_ post: PlazaPost) { value = post }
    func resumePage() { pending?.resume(); pending = nil }
    func feed(uid: Int64, before: Int64?, author: Int64?, replyTo: Int64?) async throws -> PlazaPage {
        let captured = value
        requestCount += 1
        if paginated {
            // Keep the loading footer mounted before each response arrives.
            try await Task.sleep(for: .milliseconds(80))
            let id = (before ?? 4) - 1
            return .init(items: [compactPost(id)], nextBefore: id > 1 ? id : nil)
        }
        if holdPage {
            holdPage = false; pageStarted = true
            await withCheckedContinuation { pending = $0 }
        }
        return .init(items: replyTo == nil ? [captured] : [], nextBefore: nil)
    }
    func post(uid: Int64, id: Int64) async throws -> PlazaPost { value }
    func create(uid: Int64, body: PlazaCreateRequest) async throws -> PlazaPost {
        attempts.append(body)
        if failCreate { failCreate = false; throw URLError(.timedOut) }
        return value
    }
    func like(uid: Int64, id: Int64, selected: Bool) async throws -> PlazaPost { value.likeCount = selected ? 1 : 0; value.liked = selected; return value }
    func react(uid: Int64, id: Int64, reaction: PlazaReaction) async throws -> PlazaPost { value.reactions = [reaction]; return value }
    func delete(uid: Int64, id: Int64) async throws {}
    func blocks(uid: Int64) async throws -> PlazaBlocks { .init(items: []) }
    func block(uid: Int64, author: Int64, selected: Bool) async throws {}
    func report(uid: Int64, id: Int64, body: PlazaReportRequest) async throws -> PlazaReportReceipt { .init(id: 4, status: "pending", duplicate: false) }
}

private actor WireScript {
    var steps: [(Int, Data)]
    var requests: [URLRequest] = []
    init(_ steps: [(Int, String)]) { self.steps = steps.map { ($0.0, Data($0.1.utf8)) } }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        let step = steps.removeFirst()
        return (step.1, HTTPURLResponse(url: request.url!, statusCode: step.0, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}
private final class PlazaTestAccount: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 42
    private var data: Data?
    func uid() -> Int64 { lock.lock(); defer { lock.unlock() }; return value }
    func switchTo(_ uid: Int64) { lock.lock(); defer { lock.unlock() }; value = uid }
    func read() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func save(_ bytes: Data) { lock.lock(); defer { lock.unlock() }; data = bytes }
}

final class PlazaTests: XCTestCase {
    func testTokyoBootstrapSignsExactBodyWithoutPixivCredentials() async throws {
        let account = PlazaTestAccount()
        let wire = WireScript([(200, #"{"uid":42,"access_token":"tokyo","refresh_token":"refresh","access_expires_at":9999999999999}"#)])
        let session = PlazaSession(send: { try await wire.send($0) }, currentUID: { account.uid() },
            readCredentials: { _ in account.read() }, writeCredentials: { data, _ in account.save(data) })
        let token = try await session.token(uid: 42)
        XCTAssertEqual(token, "tokyo")
        let requests = await wire.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.pixshaft.com/v1/auth/session")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(request.httpBody)
        let expected = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(ShaftEventsConfig.hmacSecret.utf8)))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Shaft-Sign"), expected)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["uid", "device_id", "grant_type"])
        XCTAssertEqual(json["grant_type"] as? String, "app_hmac")
    }
    func testInterruptedRefreshReusesPersistedAttemptAcrossSessionRestart() async throws {
        let account = PlazaTestAccount()
        account.save(Data(#"{"tokens":{"uid":42,"access_token":"expired","refresh_token":"refresh-old","access_expires_at":0}}"#.utf8))
        let wire = WireScript([(503, "{}"), (200, #"{"uid":42,"access_token":"new","refresh_token":"refresh-new","access_expires_at":9999999999999}"#)])
        func make() -> PlazaSession {
            PlazaSession(send: { try await wire.send($0) }, currentUID: { account.uid() },
                readCredentials: { _ in account.read() }, writeCredentials: { data, _ in account.save(data) })
        }
        do { _ = try await make().token(uid: 42); XCTFail("Expected transport failure") } catch { }
        let saved = try XCTUnwrap(account.read())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertNotNil(json["refreshAttempt"])
        let token = try await make().token(uid: 42)
        XCTAssertEqual(token, "new")
        let requests = await wire.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Idempotency-Key"), requests[1].value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(requests.map { $0.url!.path }, ["/v1/auth/token", "/v1/auth/token"])
    }
    func testConcurrentRejectedTokensShareOneRotation() async throws {
        let account = PlazaTestAccount()
        account.save(Data(#"{"tokens":{"uid":42,"access_token":"rejected","refresh_token":"refresh","access_expires_at":9999999999999}}"#.utf8))
        let wire = WireScript([(200, #"{"uid":42,"access_token":"new","refresh_token":"new-refresh","access_expires_at":9999999999999}"#)])
        let session = PlazaSession(send: { try await wire.send($0) }, currentUID: { account.uid() },
            readCredentials: { _ in account.read() }, writeCredentials: { data, _ in account.save(data) })
        let cached = try await session.token(uid: 42)
        XCTAssertEqual(cached, "rejected")
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 { group.addTask { try await session.token(uid: 42, rejected: "rejected") } }
            var values: [String] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(tokens, Array(repeating: "new", count: 20))
        let count = await wire.requests.count
        XCTAssertEqual(count, 1)
    }
    func testRevokedRefreshBootstrapsTokyoSession() async throws {
        let account = PlazaTestAccount()
        account.save(Data(#"{"tokens":{"uid":42,"access_token":"expired","refresh_token":"revoked","access_expires_at":0}}"#.utf8))
        let wire = WireScript([(400, #"{"error":"invalid_grant"}"#), (200, #"{"uid":42,"access_token":"new","refresh_token":"new-refresh","access_expires_at":9999999999999}"#)])
        let session = PlazaSession(send: { try await wire.send($0) }, currentUID: { account.uid() },
            readCredentials: { _ in account.read() }, writeCredentials: { data, _ in account.save(data) })
        _ = try await session.token(uid: 42)
        let paths = await wire.requests.map { $0.url!.path }
        XCTAssertEqual(paths, ["/v1/auth/token", "/v1/auth/session"])
    }
    func testReactionIDsKeepAll64Bits() throws {
        let value = try JSONDecoder().decode(PlazaReaction.self, from: Data(#"{"emoji":"sticker:650863185465585230","stickerId":"650863185465585230","count":2,"selected":true}"#.utf8))
        XCTAssertEqual(value.stickerId, "650863185465585230")
        let sticker = try JSONDecoder().decode(PlazaSticker.self, from: Data(#"{"stickerId":650863185465585230,"name":"smile","media":{"resourceList":[]}}"#.utf8))
        XCTAssertEqual(sticker.id, "650863185465585230")
    }
    func testWirePostUsesCamelCaseAndPixivNestedSnakeCase() throws {
        let raw = #"{"id":1,"uid":42,"displayName":"Test","text":"Hello","createdAt":1778371200000,"likeCount":0,"replyCount":0,"liked":false,"images":[],"objectId":123,"objectType":"illust","objectExtensions":{"illust":{"id":123,"image_urls":{"medium":"https://i.pximg.net/a.jpg"},"page_count":1}}}"#
        let post = try JSONDecoder().decode(PlazaPost.self, from: Data(raw.utf8))
        XCTAssertEqual(post.linkedPages, ["https://i.pximg.net/a.jpg"])
        XCTAssertEqual(post.date.timeIntervalSince1970, 1778371200)
        XCTAssertNil(post.reactions)
    }
    func testLimitsCountUnicodeScalarsLikeServer() {
        var draft = PlazaDraft()
        draft.text = String(repeating: "👩‍💻", count: 667)
        XCTAssertEqual(draft.text.count, 667)
        XCTAssertFalse(draft.valid)
        draft.text = String(repeating: "a", count: 2000)
        draft.title = String(repeating: "好", count: 120)
        XCTAssertTrue(draft.valid)
        draft.title += "a"
        XCTAssertFalse(draft.valid)
        draft = PlazaDraft(); draft.objectId = 123; draft.objectType = "illust"
        XCTAssertTrue(draft.valid)
    }
    func test401ReplaysIdenticalBodyOnceUsingTokyoToken() async throws {
        let post = String(data: try JSONEncoder().encode(fixturePost()), encoding: .utf8)!
        let wire = WireScript([(401, #"{"error":"unauthorized"}"#), (200, post)])
        let api = PlazaAPI(send: { try await wire.send($0) }, token: { _, rejected in rejected == nil ? "tokyo-old" : "tokyo-new" }, currentUID: { 42 })
        let request = PlazaCreateRequest(requestId: UUID().uuidString, text: "Hello", displayName: "Test")
        _ = try await api.create(uid: 42, body: request)
        let sent = await wire.requests
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0].url?.host, "api.pixshaft.com")
        XCTAssertEqual(sent[0].httpBody, sent[1].httpBody)
        XCTAssertEqual(sent[1].value(forHTTPHeaderField: "Authorization"), "Bearer tokyo-new")
        XCTAssertNil(sent[1].value(forHTTPHeaderField: "X-Shaft-Sign"))
    }
    func testRepeated401StopsAfterSingleReplay() async throws {
        let wire = WireScript([(401, "{}"), (401, "{}")])
        let api = PlazaAPI(send: { try await wire.send($0) }, token: { _, _ in "token" }, currentUID: { 42 })
        do { _ = try await api.post(uid: 42, id: 1); XCTFail("Expected 401") }
        catch let error as PlazaFailure { XCTAssertEqual(error.status, 401) }
        let count = await wire.requests.count
        XCTAssertEqual(count, 2)
    }
    func testAccountSwitchDropsInFlightResponse() async throws {
        let account = PlazaTestAccount()
        let data = try JSONEncoder().encode(fixturePost())
        let api = PlazaAPI(send: { request in
            account.switchTo(99)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, token: { _, _ in "tokyo" }, currentUID: { account.uid() })
        do { _ = try await api.post(uid: 42, id: 1); XCTFail("Old account response escaped") }
        catch let error as PlazaFailure { XCTAssertEqual(error.key, "account_changed") }
    }
    @MainActor func testMutationWinsOverOlderFeedResponse() async throws {
        let api = PlazaTestService()
        await api.configure(holdPage: true)
        let store = PlazaStore(api: api, currentUID: { 42 })
        let read = Task { try await store.page(before: nil, author: nil, replyTo: nil) }
        while !(await api.pageStarted) { await Task.yield() }
        await store.like(fixturePost())
        await api.resumePage()
        _ = try await read.value
        XCTAssertEqual(store.posts[1]?.likeCount, 1)
        let count = await api.requestCount
        XCTAssertEqual(count, 2)
    }
    @MainActor func testSupersededRefreshCannotOverwriteNewerPostCache() async throws {
        let api = PlazaTestService()
        await api.configure(holdPage: true)
        let store = PlazaStore(api: api, currentUID: { 42 })
        let page = PlazaPageModel()
        let old = Task { await page.load(store: store, reset: true) }
        while !(await api.pageStarted) { await Task.yield() }
        await api.setPost(fixturePost(likes: 7))
        await page.load(store: store, reset: true)
        XCTAssertEqual(store.posts[1]?.likeCount, 7)
        await api.resumePage()
        await old.value
        XCTAssertEqual(page.ids, [1])
        XCTAssertEqual(store.posts[1]?.likeCount, 7, "Superseded responses must not rewrite the shared cache")
        XCTAssertFalse(page.loading)
    }

    @MainActor func testDeletedPostCannotBeResurrectedByFeed() async throws {
        let store = PlazaStore(api: PlazaTestService(), currentUID: { 42 })
        store.accept(fixturePost())
        await store.delete(fixturePost())
        _ = try await store.page(before: nil, author: nil, replyTo: nil)
        XCTAssertNil(store.posts[1])
        XCTAssertTrue(store.deleted.contains(1))
    }
    @MainActor func testPublishRetryPreservesRequestIDAndDraftUntilSuccess() async throws {
        let api = PlazaTestService()
        await api.configure(failCreate: true)
        let store = PlazaStore(api: api, currentUID: { 42 })
        let model = PlazaComposerModel(uid: 42, persistent: false)
        model.edit { $0.text = "Draft survives timeout" }
        let id = model.draft.requestId
        let first = await model.send(store: store)
        XCTAssertNil(first)
        XCTAssertEqual(model.draft.text, "Draft survives timeout")
        XCTAssertEqual(model.draft.requestId, id)
        let second = await model.send(store: store)
        XCTAssertNotNil(second)
        XCTAssertTrue(model.draft.isEmpty)
        let attempts = await api.attempts
        XCTAssertEqual(attempts.map(\.requestId), [id, id])
        XCTAssertEqual(attempts[0].policyVersion, "2026-09-16")
    }
    @MainActor func testEditingChangesIdempotencyKey() {
        let model = PlazaComposerModel(uid: 42, persistent: false)
        model.edit { $0.text = "first" }; let first = model.draft.requestId
        model.edit { $0.text = "second" }
        XCTAssertNotEqual(first, model.draft.requestId)
    }
    @MainActor func testDraftRestoresPerAccountIncludingPendingUpload() throws {
        let key = "test-\(UUID())"
        let one = PlazaComposerModel(uid: 42, draftKey: key)
        defer { one.discard() }
        one.edit { $0.text = "Persisted" }
        let image = PlazaAttachment(id: UUID(), fileName: "photo", contentType: "image/png", size: 3, width: 1, height: 1,
            ticket: PlazaUploadTicket(mediaId: "resume", objectKey: "key", method: "PUT", uploadUrl: "https://cos.example/image", expiresAt: 9999999999999, headers: [:]))
        one.edit { $0.images.append(image) }
        let two = PlazaComposerModel(uid: 42, draftKey: key)
        XCTAssertEqual(two.draft.text, "Persisted")
        XCTAssertEqual(two.draft.requestId, one.draft.requestId)
        XCTAssertEqual(two.draft.images.first?.ticket?.mediaId, "resume")
        let other = PlazaComposerModel(uid: 43, draftKey: key)
        XCTAssertTrue(other.draft.isEmpty)
    }
    func testCompletedUploadRetryDoesNotUploadBytesAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1,2,3]).write(to: directory.appendingPathComponent("image"))
        let ticket = PlazaUploadTicket(mediaId: "media", objectKey: "key", method: "PUT", uploadUrl: "https://cos.example/image", expiresAt: plazaNow() + 60_000, headers: [:])
        let image = PlazaAttachment(id: UUID(), fileName: "image", contentType: "image/png", size: 3, width: 10, height: 20, ticket: ticket)
        let wire = WireScript([(200, #"{"mediaId":"media","width":10,"height":20}"#)])
        let api = PlazaAPI(send: { try await wire.send($0) }, token: { _, _ in "tokyo" }, currentUID: { 42 })
        var uploader = PlazaMediaUploader(api: api)
        uploader.put = { _, _, _ in XCTFail("Uploaded an already completed object") }
        let result = try await uploader.upload(image, directory: directory, uid: 42, saveTicket: { _ in XCTFail("Created a second ticket") }, progress: { _ in })
        XCTAssertEqual(result.mediaId, "media")
        let requests = await wire.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/v1/media/upload/complete"])
    }
    func testNeverUploadedObjectReusesSignedPUTAndExactHeaders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1,2,3]).write(to: directory.appendingPathComponent("image"))
        let ticket = PlazaUploadTicket(mediaId: "media", objectKey: "key", method: "PUT", uploadUrl: "https://cos.example/image?sign=storage", expiresAt: plazaNow() + 120_000, headers: ["x-cos-meta-test":"expected"])
        let image = PlazaAttachment(id: UUID(), fileName: "image", contentType: "image/png", size: 3, width: 10, height: 20, ticket: ticket)
        let wire = WireScript([(409, #"{"error":"media_not_uploaded"}"#), (200, #"{"mediaId":"media","width":10,"height":20}"#)])
        let api = PlazaAPI(send: { try await wire.send($0) }, token: { _, _ in "tokyo" }, currentUID: { 42 })
        var uploader = PlazaMediaUploader(api: api)
        uploader.put = { request, file, progress in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-cos-meta-test"), "expected")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(try Data(contentsOf: file), Data([1,2,3])); progress(0.95)
        }
        _ = try await uploader.upload(image, directory: directory, uid: 42, saveTicket: { _ in XCTFail("Unexpected init") }, progress: { _ in })
        let count = await wire.requests.count
        XCTAssertEqual(count, 2)
    }
    func testPhotoValidationReadsActualContentNotExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fake.jpg")
        try Data("not an image".utf8).write(to: url)
        XCTAssertThrowsError(try PlazaPhotoFiles.importFile(url, directory: root))
    }
    func testPhotoImportPreservesOriginalBytesAndDimensions() throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "imgGaleryImg", withExtension: "png", subdirectory: "PlazaFixtures"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = try PlazaPhotoFiles.importFile(source, directory: root)
        // The Android fixture has a .png name but contains original JPEG bytes.
        XCTAssertEqual(photo.contentType, "image/jpeg")
        XCTAssertGreaterThan(photo.width, 0); XCTAssertGreaterThan(photo.height, 0)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: root.appendingPathComponent(photo.fileName)))
        XCTAssertNotNil(PlazaPhotoFiles.thumbnail(root.appendingPathComponent(photo.fileName)))
    }
    func testSevenLanguageCatalogsAndNumberFormatting() {
        for tag in ["zh-Hans", "zh-Hant", "en", "ja", "ko", "ru", "tr"] {
            let copy = PlazaCopy(tag: tag)
            for key in ["title", "compose_title", "policy_body", "body_label", "report_reasons_9", "filter_mine"] {
                XCTAssertNotEqual(copy.text(key), key, "\(tag) \(key)")
            }
            XCTAssertFalse(copy.format("char_count", "8", "2000").contains("$"))
        }
    }
}
