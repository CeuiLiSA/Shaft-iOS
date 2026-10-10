import XCTest
@testable import Shaft_iOS

final class OctoberPortTests: XCTestCase {
    func testJustifiedRowsFillWidthAndKeepLastRowSmall() {
        let rows = JustifiedRows.make(aspectRatios: [1, 1, 1, 1, 1], width: 320, targetHeight: 156, spacing: 8)
        XCTAssertEqual(rows.map(\.indices), [[0, 1], [2, 3], [4]])
        for row in rows.dropLast() {
            XCTAssertEqual(row.widths.reduce(0, +) + 8 * Double(row.indices.count - 1), 320, accuracy: 0.001)
        }
        XCTAssertEqual(rows.last?.height, 156)
        XCTAssertEqual(rows.last?.widths, [156])
    }

    func testJustifiedRowsHandleNarrowAndMalformedGeometry() {
        for width in [1.0, 30, 320, 1024] {
            let rows = JustifiedRows.make(aspectRatios: [0, .nan, .infinity, 0.0001, 999, 1], width: width, targetHeight: 0.1, spacing: 8)
            XCTAssertEqual(rows.flatMap(\.indices), Array(0..<6))
            for row in rows {
                XCTAssertTrue(row.height.isFinite && row.height > 0)
                XCTAssertLessThanOrEqual(row.widths.reduce(0, +) + min(width, 8) * Double(row.indices.count - 1), width + 0.001)
            }
        }
        XCTAssertTrue(JustifiedRows.make(aspectRatios: [1], width: .nan, targetHeight: 100, spacing: 8).isEmpty)
    }

    func testJustifiedExtremePortraitsKeepNativeTouchWidth() {
        let rows = JustifiedRows.make(aspectRatios: Array(repeating: 0.2, count: 12) + [5, 0.2], width: 320, targetHeight: 156, spacing: 8)
        XCTAssertEqual(rows.flatMap(\.indices), Array(0..<14))
        XCTAssertTrue(rows.flatMap(\.widths).allSatisfy { $0 >= 44 - 0.001 })
    }

    func testScrollEdgeHapticRearmsOnlyInsideContent() {
        var edge = ScrollEdgeState()
        XCTAssertFalse(edge.crossed(offset: 0, content: 1000, viewport: 300))
        XCTAssertFalse(edge.crossed(offset: -20, content: 1000, viewport: 300))
        XCTAssertFalse(edge.crossed(offset: 100, content: 1000, viewport: 300))
        XCTAssertTrue(edge.crossed(offset: 0, content: 1000, viewport: 300))
        XCTAssertFalse(edge.crossed(offset: -10, content: 1000, viewport: 300))
        XCTAssertFalse(edge.crossed(offset: 650, content: 1000, viewport: 300))
        XCTAssertTrue(edge.crossed(offset: 700, content: 1000, viewport: 300))
        XCTAssertFalse(edge.crossed(offset: 720, content: 1000, viewport: 300))
        XCTAssertFalse(edge.crossed(offset: 0, content: 200, viewport: 300))
    }

    func testAppLockColdLaunchDeadlineAndMonotonicRollback() {
        XCTAssertTrue(AppLockTimeout.fiveMinutes.requiresLock(authenticated: false, backgroundAt: nil, now: 100))
        XCTAssertFalse(AppLockTimeout.immediately.requiresLock(authenticated: true, backgroundAt: nil, now: 100))
        XCTAssertTrue(AppLockTimeout.immediately.requiresLock(authenticated: true, backgroundAt: 100, now: 100))
        XCTAssertFalse(AppLockTimeout.oneMinute.requiresLock(authenticated: true, backgroundAt: 100, now: 159.9))
        XCTAssertTrue(AppLockTimeout.oneMinute.requiresLock(authenticated: true, backgroundAt: 100, now: 160))
        XCTAssertTrue(AppLockTimeout.fifteenMinutes.requiresLock(authenticated: true, backgroundAt: 100, now: 99))
    }

    @MainActor func testCancellingAuthenticationDoesNotPromptAgainOnDialogReturn() async throws {
        let suite = "october-lock-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "applock_enabled")
        var prompts = 0
        let lock = AppLockController(defaults: defaults, authenticationOverride: { _ in prompts += 1; return false })
        await lock.unlockAutomatically(reason: "test")
        lock.update(.inactive); lock.update(.active)
        await lock.unlockAutomatically(reason: "test")
        XCTAssertEqual(prompts, 1)
        XCTAssertTrue(lock.isLocked)
        lock.update(.background); lock.update(.active)
        await lock.unlockAutomatically(reason: "test")
        XCTAssertEqual(prompts, 2)
    }

    @MainActor func testAuthenticationSuccessWhileDialogIsInactiveUnmasksOnlyWhenActive() async throws {
        let suite = "october-lock-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "applock_enabled")
        var lock: AppLockController!
        lock = AppLockController(defaults: defaults, authenticationOverride: { _ in lock.update(.inactive); return true })
        await lock.unlockAutomatically(reason: "test")
        XCTAssertFalse(lock.isLocked)
        XCTAssertTrue(lock.privacyShield)
        lock.update(.active)
        XCTAssertFalse(lock.privacyShield)
        XCTAssertFalse(lock.isLocked)
    }

    @MainActor func testBackgroundTransitionInvalidatesEvenALateSuccessfulAuthentication() async throws {
        let suite = "october-lock-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "applock_enabled")
        var lock: AppLockController!
        lock = AppLockController(defaults: defaults, authenticationOverride: { _ in lock.update(.background); lock.update(.active); return true })
        await lock.unlock(reason: "test")
        XCTAssertTrue(lock.isLocked)
    }

    func testImageIdlePolicyLimitsAndOneRetry() {
        XCTAssertEqual(ImageTransferPolicy(seconds: 0, directConnect: false).idleSeconds, 10)
        XCTAssertEqual(ImageTransferPolicy(seconds: 99, directConnect: true).idleSeconds, 30)
        XCTAssertEqual(ImageTransferPolicy(seconds: 3, directConnect: false).idleSeconds, 3)
        XCTAssertFalse(ImageTransferPolicy(seconds: 10, directConnect: false).customized)
        XCTAssertTrue(ImageTransferPolicy(seconds: 3, directConnect: false).customized)
        XCTAssertTrue(ImageTransferPolicy.shouldRetry(error: URLError(.timedOut), received: 1, attempts: 0, enabled: true))
        XCTAssertFalse(ImageTransferPolicy.shouldRetry(error: URLError(.timedOut), received: 0, attempts: 0, enabled: true))
        XCTAssertFalse(ImageTransferPolicy.shouldRetry(error: URLError(.timedOut), received: 1, attempts: 1, enabled: true))
        XCTAssertFalse(ImageTransferPolicy.shouldRetry(error: URLError(.cancelled), received: 1, attempts: 0, enabled: true))
        XCTAssertFalse(ImageTransferPolicy.shouldRetry(error: URLError(.cannotConnectToHost), received: 1, attempts: 0, enabled: true))
    }

    func testUnknownLengthAndEOFDoNotShowFalseProgressOrStall() {
        var progress = ImageTransferProgress(received: 123, lastByteUptime: 100)
        XCTAssertNil(progress.fraction)
        XCTAssertNil(progress.stalledSeconds(now: 102, threshold: 3))
        XCTAssertEqual(progress.stalledSeconds(now: 104, threshold: 3), 4)
        progress.complete = true
        XCTAssertEqual(progress.fraction, 1)
        XCTAssertNil(progress.stalledSeconds(now: 999, threshold: 3))
    }

    func testHTTP3ProgressCountsOnlyDataAcrossFragmentedFrames() throws {
        let headers = QPACK.encodeFieldSection([(":status", "200"), ("content-length", "6")])
        let frames = Data(QPACK.encodeVarint(1) + QPACK.encodeVarint(UInt64(headers.count)) + headers
            + [0, 3] + Array("abc".utf8) + [0, 3] + Array("def".utf8))
        var parser = HTTP3TransferProgress()
        for byte in frames { try parser.append(Data([byte]), now: 100) }
        XCTAssertEqual(parser.value.received, 6)
        XCTAssertEqual(parser.value.expected, 6)
        XCTAssertTrue(parser.complete)
        try parser.append(Data([0, 5, 65]), now: 101)
        XCTAssertEqual(parser.value.received, 7)
        XCTAssertFalse(parser.complete)
    }

    func testDownloadPolicyAndMutedNoticeKeys() {
        XCTAssertTrue(DownloadStartPolicy.allows(mode: 0, wifi: false, manuallyAllowed: false, globallyPaused: false))
        XCTAssertFalse(DownloadStartPolicy.allows(mode: 1, wifi: false, manuallyAllowed: false, globallyPaused: false))
        XCTAssertTrue(DownloadStartPolicy.allows(mode: 1, wifi: true, manuallyAllowed: false, globallyPaused: false))
        XCTAssertFalse(DownloadStartPolicy.allows(mode: 2, wifi: true, manuallyAllowed: false, globallyPaused: false))
        XCTAssertTrue(DownloadStartPolicy.allows(mode: 2, wifi: false, manuallyAllowed: true, globallyPaused: true))
        XCTAssertFalse(DownloadNoticeKind.allows(.done, muted: ["DOWNLOAD_DONE", "FUTURE_KIND"]))
        XCTAssertTrue(DownloadNoticeKind.allows(.failed, muted: ["FUTURE_KIND"]))
    }

    func testWebR18RecommendationsFollowPageOrderAndRejectMaskedAndAllAges() throws {
        let data = Data(#"{"body":{"page":{"recommend":{"ids":["2",1,2,3,4]},"recommendByTag":[{"ids":[5,"6"]}]},"thumbnails":{"illust":[{"id":"1","xRestrict":1,"url":"https://i.pximg.net/a.jpg"},{"id":2,"xRestrict":2,"url":"https://i.pximg.net/b.jpg"},{"id":3,"xRestrict":0,"url":"https://i.pximg.net/c.jpg"},{"id":4,"xRestrict":1,"isMasked":true,"url":"https://i.pximg.net/d.jpg"},{"id":6,"xRestrict":1,"url":"https://i.pximg.net/e.jpg"}]}}}"#.utf8)
        XCTAssertEqual(try WebHomeRecommendations.orderedR18(data).map(\.id), [2, 1, 6])
        XCTAssertTrue(try WebHomeRecommendations.orderedR18(Data(#"{"error":true}"#.utf8)).isEmpty)
    }

    @MainActor func testNumericAgeFilteringStillAllowsExplicitAdultSearch() throws {
        let store = MuteStore()
        store.mutedTags = []; store.mutedUserIDs = []; store.hideR18 = true
        let work = try JSONDecoder().decode(Illust.self, from: Data(#"{"id":1,"x_restrict":1}"#.utf8))
        XCTAssertTrue(store.filter([work]).isEmpty)
        XCTAssertEqual(store.filter([work], applyR18: false).count, 1)
    }

    func testAIExemptDisabledSetCountsOnlyEnabledAuthorsAndOldListsNeedNoMigration() {
        XCTAssertEqual(AIExemptAuthors.enabled(ids: [1, 2], disabled: []), [1, 2])
        XCTAssertEqual(AIExemptAuthors.enabled(ids: [1, 2], disabled: [1, 99]), [2])
        XCTAssertTrue(AIExemptAuthors.enabled(ids: [1, 2], disabled: [1, 2]).isEmpty)
        XCTAssertEqual(AIExemptAuthors.normalized([2, 1, 2, 0, -1]), [2, 1])
    }

    func testCancelledSharedHandshakeWaitReturnsWithoutCancellingOtherConsumers() async throws {
        let shared = Task<Int, Error> { try await Task.sleep(for: .seconds(30)); return 42 }
        defer { shared.cancel() }
        let waiter = Task { try await CancellableTaskWaiter<Int>().value(of: shared) }
        try await Task.sleep(for: .milliseconds(20))
        let start = Date()
        waiter.cancel()
        do { _ = try await waiter.value; XCTFail("Cancelled wait should throw") } catch is CancellationError {} catch { XCTFail("Wrong error") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertFalse(shared.isCancelled)
    }

    func testCancelledTokenWaitAlsoLeavesNonThrowingRefreshAlive() async throws {
        let refresh = Task<Int?, Never> { try? await Task.sleep(for: .seconds(30)); return 42 }
        defer { refresh.cancel() }
        let consumer = Task { try await CancellableTaskWaiter<Int?>().value(of: refresh) }
        consumer.cancel()
        do { _ = try await consumer.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Wrong error") }
        XCTAssertFalse(refresh.isCancelled)
    }

    func testLegacyDownloadNoticesMigrateOnceAndKeepUnknownKeys() {
        let migrated = DownloadNoticeKind.migratedMuted(["FUTURE"], legacyEnabled: false, migrated: false)
        XCTAssertTrue(migrated.contains("DOWNLOAD_DONE"))
        XCTAssertTrue(migrated.contains("FUTURE"))
        XCTAssertEqual(DownloadNoticeKind.migratedMuted(["FUTURE"], legacyEnabled: false, migrated: true), ["FUTURE"])
    }

    func testLandscapeTapSettingDoesNotChangePortraitOrReversedZones() {
        XCTAssertEqual(ComicReaderTapPolicy.action(zone: .right, landscape: true, landscapeTapFlip: false, reversed: false), .controls)
        XCTAssertEqual(ComicReaderTapPolicy.action(zone: .left, landscape: false, landscapeTapFlip: false, reversed: false), .previous)
        XCTAssertEqual(ComicReaderTapPolicy.action(zone: .left, landscape: true, landscapeTapFlip: true, reversed: true), .next)
        XCTAssertEqual(ComicReaderTapPolicy.action(zone: .center, landscape: true, landscapeTapFlip: true, reversed: true), .controls)
    }

    func testStoredOAuthWithoutNewAgeFieldRemainsReadable() throws {
        let user = try JSONDecoder().decode(PixivOAuthUser.self, from: Data(#"{"id":42,"name":"Name","account":"name","isPremium":false}"#.utf8))
        XCTAssertNil(user.xRestrict)
        XCTAssertEqual(user.id, 42)
    }
}
