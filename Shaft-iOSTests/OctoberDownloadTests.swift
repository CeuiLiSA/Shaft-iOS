import XCTest
import UIKit
@testable import Shaft_iOS

@MainActor final class OctoberDownloadTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var manager: DownloadManager?
    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "october-download-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        manager?.clearQueue(); manager = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }
    private func work(_ id: Int64, pages: Int = 1) throws -> Illust {
        let json: [String: Any] = ["id": id, "title": "Test", "type": "illust", "page_count": pages,
            "meta_single_page": ["original_image_url": "https://download.invalid/\(id)/0.png"],
            "meta_pages": (0..<pages).map { ["image_urls": ["original": "https://download.invalid/\(id)/\($0).png"]] }]
        return try JSONDecoder().decode(Illust.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func make(_ services: DownloadManager.Services, items: [DownloadItem] = []) throws -> DownloadManager {
        try JSONEncoder().encode(items).write(to: directory.appendingPathComponent("queue.json"))
        let result = DownloadManager(directory: directory, defaults: defaults, services: services, autostart: false)
        manager = result
        return result
    }
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Queue did not reach expected state")
    }

    func testQueueOnlyAndDuplicateEnqueueStartExactlyOneSelectedWork() async throws {
        var loaded: [URL] = []
        var services = DownloadManager.Services()
        services.mode = { 2 }; services.authorize = { true }; services.hasRoom = { true }
        services.loadImage = { url, _, _ in loaded.append(url); return Data([1]) }
        services.save = { _ in }
        let manager = try make(services)
        let first = try work(1), second = try work(2)
        XCTAssertEqual(manager.enqueue([first, first, second]), 2)
        XCTAssertEqual(manager.queue.map(\.status), [.paused, .paused])
        XCTAssertTrue(loaded.isEmpty)
        manager.resume(1)
        try await wait { manager.done.count == 1 }
        XCTAssertEqual(manager.done.first?.id, 1)
        XCTAssertEqual(manager.queue.first?.id, 2)
        XCTAssertEqual(manager.queue.first?.status, .paused)
        XCTAssertEqual(loaded.count, 1)
    }

    func testPauseDuringTransferContinuesFromFirstUnsavedPage() async throws {
        var loaded: [String] = [], saved: [Data] = []
        var blockSecond = true
        var services = DownloadManager.Services()
        services.mode = { 0 }; services.authorize = { true }; services.hasRoom = { true }
        services.loadImage = { url, transfer, progress in
            loaded.append(url.lastPathComponent)
            transfer(.init(received: 1, expected: 100))
            progress(0.01)
            if url.lastPathComponent == "1.png", blockSecond {
                do { try await Task.sleep(for: .seconds(30)) } catch { return nil }
            }
            return Data(url.lastPathComponent.utf8)
        }
        services.save = { saved.append($0) }
        let manager = try make(services)
        manager.enqueue([try work(1, pages: 2)])
        try await wait { loaded.count == 2 }
        manager.pause(1)
        XCTAssertEqual(manager.queue.first?.status, .paused)
        XCTAssertEqual(manager.queue.first?.pagesDone, 1)
        blockSecond = false
        manager.resume(1)
        try await wait { manager.done.count == 1 }
        XCTAssertEqual(loaded.filter { $0 == "0.png" }.count, 1)
        XCTAssertEqual(saved.map { String(decoding: $0, as: UTF8.self) }, ["0.png", "1.png"])
    }

    func testResumeAllLeavesFailedRowsForExplicitRetry() async throws {
        var services = DownloadManager.Services()
        services.mode = { 2 }; services.authorize = { true }; services.hasRoom = { true }
        services.loadImage = { _, _, _ in Data([1]) }; services.save = { _ in }
        var failed = DownloadItem(info: DownloadWorkInfo(illust: try work(1)), seq: 1)
        failed.status = .failed; failed.error = "previous"
        var paused = DownloadItem(info: DownloadWorkInfo(illust: try work(2)), seq: 2)
        paused.status = .paused
        let manager = try make(services, items: [failed, paused])
        manager.togglePause()
        try await wait { manager.done.count == 1 }
        XCTAssertEqual(manager.queue.first?.status, .failed)
        XCTAssertEqual(manager.done.first?.id, 2)
        manager.isPaused = true
        manager.retry(1)
        try await wait { manager.done.count == 2 }
        XCTAssertTrue(manager.queue.isEmpty)
    }

    func testOldCancelledJobCannotFinishOrOverwriteReplacement() async throws {
        var calls = 0, saved: [Data] = []
        var old: CheckedContinuation<Data?, Never>?
        var lateProgress: (@MainActor (Double) -> Void)?
        var services = DownloadManager.Services()
        services.mode = { 0 }; services.authorize = { true }; services.hasRoom = { true }
        services.loadImage = { _, _, progress in
            calls += 1
            if calls == 1 {
                lateProgress = progress
                return await withCheckedContinuation { old = $0 }
            }
            return Data([2])
        }
        services.save = { saved.append($0) }
        let manager = try make(services)
        let work = try work(1)
        manager.enqueue([work])
        try await wait { old != nil }
        manager.remove(1)
        manager.enqueue([work])
        try await wait { manager.done.count == 1 }
        lateProgress?(0.1)
        old?.resume(returning: Data([1])); old = nil
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(saved, [Data([2])])
        XCTAssertEqual(manager.done.count, 1)
        XCTAssertTrue(manager.queue.isEmpty)
    }

    func testLowStoragePausesWithoutMarkingRowFailed() async throws {
        var services = DownloadManager.Services()
        services.mode = { 0 }; services.authorize = { true }; services.hasRoom = { false }
        services.loadImage = { _, _, _ in XCTFail("Must not transfer on full disk"); return nil }
        let manager = try make(services)
        manager.enqueue([try work(1)])
        try await wait { manager.isPaused }
        XCTAssertEqual(manager.queue.first?.status, .paused)
        XCTAssertNil(manager.queue.first?.error)
    }

    func testRelaunchPreservesCompletedPagesAndAcceptsOldQueueSchema() throws {
        var item = DownloadItem(info: DownloadWorkInfo(illust: try work(1, pages: 2)), seq: 1)
        item.status = .downloading; item.pagesDone = 1
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        json.removeValue(forKey: "transfer")
        let old = try JSONDecoder().decode(DownloadItem.self, from: JSONSerialization.data(withJSONObject: json))
        let manager = try make(DownloadManager.Services(), items: [old])
        XCTAssertEqual(manager.queue.first?.status, .pending)
        XCTAssertEqual(manager.queue.first?.pagesDone, 1)
        XCTAssertEqual(manager.queue.first?.progress, 0.5)
    }

    func testModeChangeReleasesAutomaticWaitersAndKeepsExplicitPause() async throws {
        var mode = 2
        var services = DownloadManager.Services()
        services.mode = { mode }; services.authorize = { true }; services.hasRoom = { true }
        services.loadImage = { _, _, _ in Data([1]) }; services.save = { _ in }
        let manager = try make(services)
        manager.enqueue([try work(1), try work(2)])
        manager.pause(2)
        mode = 0
        manager.preferencesChanged()
        try await wait { manager.done.count == 1 }
        XCTAssertEqual(manager.done.first?.id, 1)
        XCTAssertEqual(manager.queue.first?.id, 2)
        XCTAssertEqual(manager.queue.first?.status, .paused)
    }

    func testLeavingWifiRetractsManualPermitAndToolbarReflectsRealActivity() async throws {
        var wifi = false
        var services = DownloadManager.Services()
        services.mode = { 1 }; services.wifi = { wifi }; services.authorize = { true }; services.hasRoom = { true }
        services.loadImage = { _, _, _ in do { try await Task.sleep(for: .seconds(30)) } catch {}; return nil }
        let manager = try make(services)
        manager.enqueue([try work(1), try work(2)])
        XCTAssertTrue(manager.shouldResumeAll)
        manager.isPaused = true
        manager.resume(1)
        XCTAssertFalse(manager.shouldResumeAll, "The explicitly running work must be stoppable despite a closed global gate")
        wifi = true; manager.networkChanged()
        wifi = false; manager.networkChanged()
        XCTAssertEqual(manager.queue.first?.status, .pending)
        XCTAssertTrue(manager.shouldResumeAll)
        XCTAssertEqual(manager.queue.last?.status, .paused)
    }

    func testPauseDuringGifPhotoCommitDoesNotSaveOrEncodeItAgain() async throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }.pngData()!
        var fetches = 0, saves = 0
        var commit: CheckedContinuation<Void, Never>?
        defer { commit?.resume() }
        var services = DownloadManager.Services()
        services.mode = { 0 }; services.authorize = { true }; services.hasRoom = { true }
        services.fetchUgoira = { _, _, _, _ in
            fetches += 1
            return [.init(data: png, delaySeconds: 0.1)]
        }
        services.save = { _ in
            saves += 1
            if saves == 1 { await withCheckedContinuation { commit = $0 } }
        }
        let manager = try make(services)
        let gif = try JSONDecoder().decode(Illust.self, from: Data(#"{"id":1,"type":"ugoira"}"#.utf8))
        manager.enqueue([gif])
        try await wait { commit != nil }
        manager.pause(1)
        commit?.resume(); commit = nil
        try await wait { manager.queue.first?.pagesDone == 1 }
        XCTAssertEqual(manager.queue.first?.status, .paused)
        manager.resume(1)
        try await wait { manager.done.count == 1 }
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(saves, 1)
        XCTAssertTrue(manager.queue.isEmpty)
    }

    func testRelaunchedGifWithCommittedPhotoOnlyFinishesItsRecord() async throws {
        var services = DownloadManager.Services()
        services.mode = { 0 }; services.authorize = { true }; services.hasRoom = { true }
        services.fetchUgoira = { _, _, _, _ in XCTFail("Already saved GIF must not be fetched"); return [] }
        services.save = { _ in XCTFail("Already saved GIF must not be saved again") }
        let gif = try JSONDecoder().decode(Illust.self, from: Data(#"{"id":1,"type":"ugoira"}"#.utf8))
        var item = DownloadItem(info: DownloadWorkInfo(illust: gif), seq: 1)
        item.status = .downloading; item.pagesDone = 1
        let manager = try make(services, items: [item])
        manager.resume(1)
        try await wait { manager.done.count == 1 }
        XCTAssertTrue(manager.queue.isEmpty)
    }
}
