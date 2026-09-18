import XCTest
@testable import Shaft_iOS

private actor StickerReactionWire {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) -> (Data, URLResponse) {
        requests.append(request)
        let body = #"{"id":1,"uid":42,"displayName":"Test","text":"Post","createdAt":1,"likeCount":0,"replyCount":0,"liked":false,"images":[],"reactions":[{"emoji":"sticker:1123418376571372434","count":1,"selected":true,"stickerId":"1123418376571372434"}]}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

enum StickerFixtures {
    static var directory: URL { Bundle(for: StickerTests.self).resourceURL!.appendingPathComponent("StickerFixtures") }
    static func catalog(at directory: URL = directory) throws -> StickerCatalog {
        try JSONDecoder().decode(StickerCatalog.self, from: Data(contentsOf: directory.appendingPathComponent("catalog.json")))
    }
    static func install(root: URL, source: URL = directory) throws -> StickerReady {
        let catalog = try catalog(at: source), store = StickerStore(root: root)
        try catalog.validate(); try store.begin()
        for pkg in catalog.packages {
            try store.installArchive(source.appendingPathComponent(pkg.sha256 + ".zip"), package: pkg)
            try store.extract(pkg)
        }
        return try store.finish(catalog)
    }
}

final class StickerTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sticker-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testExact64BitIDsAcrossCatalogWebSocketHistoryAndPersistence() throws {
        let id = "1123418376571372434"
        let sticker = try JSONDecoder().decode(Sticker.self, from: Data("{\"stickerId\":\(id),\"name\":\"test\",\"media\":{\"resourceList\":[]}}".utf8))
        XCTAssertEqual(sticker.id, id)
        for raw in [ChatFrameEncoder.msgGlobal(clientMsgId: "test", text: "[贴纸]", stickerId: id),
                    ChatFrameEncoder.msg1v1(toUid: 99, clientMsgId: "test", text: "[贴纸]", stickerId: id)] {
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            XCTAssertEqual(object["sticker_id"] as? String, id)
        }
        let frame = ChatFrameDecoder.decode("{\"kind\":\"msg\",\"room\":\"global\",\"uid\":42,\"client_msg_id\":\"test\",\"sticker_id\":\"\(id)\",\"text\":\"[贴纸]\",\"ts\":1}")
        guard case .msg(let payload) = frame else { return XCTFail("Missing message") }
        let message = try XCTUnwrap(ChatMessage.fromBroadcast(payload))
        XCTAssertEqual(message.stickerId, id)
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message)).stickerId, id)
        let history = try JSONDecoder().decode(ChatHistoryItem.self, from: Data("{\"id\":1,\"uid\":42,\"sticker_id\":\"\(id)\",\"ts\":1}".utf8))
        XCTAssertEqual(ChatMessage.fromHistory(history, room: "global").stickerId, id)
    }

    func testOldMessagesStillDecodeWithoutStickerColumn() throws {
        let raw = #"{"localKey":"old","uid":42,"room":"global","text":"hello","ts":1,"state":"delivered"}"#
        XCTAssertNil(try JSONDecoder().decode(ChatMessage.self, from: Data(raw.utf8)).stickerId)
        let history = #"{"id":1,"uid":42,"text":"hello","ts":1}"#
        XCTAssertNil(try JSONDecoder().decode(ChatHistoryItem.self, from: Data(history.utf8)).sticker_id)
    }

    func testPostStickerAddsAndRemovesReactionUsingExactID() async throws {
        let wire = StickerReactionWire()
        let api = PlazaAPI(send: { await wire.send($0) }, token: { _, _ in "tokyo-test" }, currentUID: { 42 })
        let id = "1123418376571372434"
        let reaction = PlazaReaction(emoji: "sticker:\(id)", count: 0, selected: false, stickerId: id)
        let post = try await api.react(uid: 42, id: 1, reaction: reaction)
        XCTAssertEqual(post.reactions?.first?.stickerId, id)
        _ = try await api.react(uid: 42, id: 1, reaction: PlazaReaction(emoji: reaction.emoji, count: 1, selected: true, stickerId: id))
        let requests = await wire.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["PUT", "DELETE"])
        XCTAssertEqual(requests.map { $0.url?.absoluteString }, Array(repeating: "https://api.pixshaft.com/v1/plaza/posts/1/reactions/stickers/\(id)", count: 2))
        XCTAssertTrue(requests.allSatisfy { $0.httpBody == nil })
    }

    func testCatalogDeduplicatesSharedPackagesAndAnimationEntries() throws {
        let catalog = try StickerFixtures.catalog()
        try catalog.validate()
        XCTAssertEqual(catalog.packages.count, 4)
        let sticker = catalog.packs["animation"]!.stickers[0]
        let pack = StickerPack(pkgList: [], groupList: [.init(name: "a", stickerList: [sticker])], stickerList: [sticker])
        XCTAssertEqual(pack.stickers.count, 1)
    }

    func testRejectsUntrustedArchiveURLsAndIncompleteResolutions() throws {
        let data = try Data(contentsOf: StickerFixtures.directory.appendingPathComponent("catalog.json"))
        let raw = String(decoding: data, as: UTF8.self)
        for replacement in ["evil.example", "shaft-1300933917.cos.ap-osaka.myqcloud.com.evil.example"] {
            let changed = raw.replacingOccurrences(of: "shaft-1300933917.cos.ap-osaka.myqcloud.com", with: replacement)
            let catalog = try JSONDecoder().decode(StickerCatalog.self, from: Data(changed.utf8))
            XCTAssertThrowsError(try catalog.validate())
        }
        let changed = raw.replacingOccurrences(of: "https://shaft-", with: "http://shaft-")
        XCTAssertThrowsError(try JSONDecoder().decode(StickerCatalog.self, from: Data(changed.utf8)).validate())
    }

    func testRejectsTraversalAbsoluteBackslashAndBadCRCArchives() throws {
        for name in ["traversal", "absolute", "backslash", "bad-crc"] {
            let data = try Data(contentsOf: StickerFixtures.directory.appendingPathComponent(name + ".zip"))
            XCTAssertThrowsError(try StickerArchive.extract(data, to: root), name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape.png").path))
    }

    func testTruncatedArchiveNeverWritesReadyMarker() throws {
        let catalog = try StickerFixtures.catalog(), store = StickerStore(root: root)
        try store.begin()
        let pkg = catalog.packages[0]
        var data = try Data(contentsOf: StickerFixtures.directory.appendingPathComponent(pkg.sha256 + ".zip"))
        data.removeLast(24)
        let partial = root.appendingPathComponent("broken.zip"); try data.write(to: partial)
        XCTAssertThrowsError(try store.installArchive(partial, package: pkg))
        XCTAssertNil(store.reopen())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ready.json").path))
    }

    func testPartialInstallationCannotCommitGlobalReadyMarker() throws {
        let catalog = try StickerFixtures.catalog(), store = StickerStore(root: root)
        try store.begin()
        let pkg = catalog.packages[0]
        try store.installArchive(StickerFixtures.directory.appendingPathComponent(pkg.sha256 + ".zip"), package: pkg)
        try store.extract(pkg)
        XCTAssertThrowsError(try store.finish(catalog))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ready.json").path))
    }

    func testInstallReopenAndResourceSizeSelectionAreEntirelyLocal() throws {
        let ready = try StickerFixtures.install(root: root), store = StickerStore(root: root)
        XCTAssertNotNil(store.reopen()); XCTAssertTrue(store.unchanged(ready))
        for category in ready.items { for sticker in category {
            let small = try XCTUnwrap(ready.file(id: sticker.id, size: 64))
            let large = try XCTUnwrap(ready.file(id: sticker.id, size: 128))
            XCTAssertTrue(small.path.contains("/64/")); XCTAssertTrue(large.path.contains("/128/"))
            XCTAssertEqual(ready.file(id: sticker.id, size: 256), large)
            XCTAssertTrue(small.isFileURL)
        } }
        for pkg in ready.catalog.packages {
            XCTAssertTrue(store.validArchive(pkg))
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.packageDirectory(pkg).appendingPathComponent("downloaded.json").path))
        }
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testMissingFileClosesGateAndRepairReusesVerifiedArchive() throws {
        let ready = try StickerFixtures.install(root: root), store = StickerStore(root: root)
        let file = try XCTUnwrap(ready.file(id: ready.items[0][0].id, size: 64))
        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(store.unchanged(ready)); XCTAssertNil(store.reopen())
        try store.begin()
        for pkg in ready.catalog.packages { XCTAssertTrue(store.validArchive(pkg)); try store.extract(pkg) }
        let repaired = try store.finish(ready.catalog)
        XCTAssertEqual(repaired.generation, ready.generation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testSameLengthCorruptionIsDetectedAndRepairedWithCRC() throws {
        let ready = try StickerFixtures.install(root: root), store = StickerStore(root: root)
        let file = try XCTUnwrap(ready.file(id: ready.items[0][0].id, size: 64))
        let original = try Data(contentsOf: file)
        var corrupt = original; corrupt[0] ^= 1; try corrupt.write(to: file)
        XCTAssertFalse(store.unchanged(ready))
        try store.begin()
        for pkg in ready.catalog.packages { try store.extract(pkg) }
        _ = try store.finish(ready.catalog)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testRealAnimatedWebPFramesAndTiming() async throws {
        let ready = try StickerFixtures.install(root: root)
        let sticker = ready.items[2][0], file = try XCTUnwrap(ready.file(id: ready.items[2][0].id, size: 64))
        let decoder = StickerDecoder()
        let first = try await decoder.frame(file: file, key: sticker.id, index: 0)
        XCTAssertGreaterThan(first.count, 1)
        XCTAssertGreaterThanOrEqual(first.duration, 0.02)
        XCTAssertLessThan(first.duration, 0.2)
        let last = try await decoder.frame(file: file, key: sticker.id, index: first.count - 1)
        XCTAssertEqual(last.count, first.count)
        XCTAssertEqual(first.image.size.width, 64)
    }

    @MainActor func testStaleImageFailureCannotInvalidateNewGeneration() throws {
        let ready = try StickerFixtures.install(root: root), repository = StickerRepository(ready: ready)
        repository.localFailure(StickerFailure.missingFile, generation: "stale")
        XCTAssertEqual(repository.state.ready?.generation, ready.generation)
        repository.localFailure(StickerFailure.missingFile, generation: ready.generation)
        XCTAssertNil(repository.state.ready)
    }

    func testSevenLanguagesHaveCompletePickerCopy() {
        for tag in ["zh-Hans", "zh-Hant", "en", "ja", "ko", "ru", "tr"] {
            let copy = StickerCopy(tag: tag)
            for key in ["customized", "static", "animation", "close", "retry", "checking", "extracting", "message"] {
                XCTAssertNotEqual(copy.text(key), key)
            }
            XCTAssertTrue(copy.format("downloading", "42").contains("42%"))
        }
    }
}
