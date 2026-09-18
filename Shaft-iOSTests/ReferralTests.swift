import XCTest
@testable import Shaft_iOS

final class ReferralTests: XCTestCase {
    func testUnknownWireFieldsAndStatesAreSafe() throws {
        let data = Data(#"{"enabled":true,"tasks":[{"key":"invite","status":"future","target":0,"progress":-1},{"key":"future","status":"ready"}],"rewards":[{"id":1,"task":"future"},{"task":"invite"}]}"#.utf8)
        let state = try JSONDecoder().decode(ReferralSnapshot.self, from: data)
        XCTAssertEqual(state.status(.invite), .new)
        XCTAssertEqual(state.target(.invite), 1)
        XCTAssertEqual(state.progress(.invite), 0)
        XCTAssertEqual(state.claimable, 0)
        XCTAssertTrue(state.cards.isEmpty)
        XCTAssertEqual(referralPlanLabel("future"), "PRO")
    }
    func testClosedCampaignKeepsOutstandingRewards() throws {
        let empty = try JSONDecoder().decode(ReferralSnapshot.self, from: Data(#"{"enabled":false}"#.utf8))
        XCTAssertFalse(empty.showsContent)
        let active = try JSONDecoder().decode(ReferralSnapshot.self, from: Data(#"{"enabled":false,"tasks":[{"key":"invite","status":"claimed"}],"rewards":[{"id":1,"task":"invite","plan":"max","days":7,"expiresAt":2000000000000}]}"#.utf8))
        XCTAssertTrue(active.showsContent)
        XCTAssertEqual(active.earnedDays, 7)
        XCTAssertTrue(active.cards[0].usable(at: 1900000000000))
        XCTAssertFalse(active.cards[0].usable(at: 2000000000000))
    }
    func testCodeParserDoesNotGuessAmbiguousCharacters() {
        XCTAssertEqual(parseReferralCode("k7m2-qx4p"), "K7M2QX4P")
        XCTAssertEqual(parseReferralCode("https://pixshaft.com/i/K7M2QX4P?from=share"), "K7M2QX4P")
        for value in ["O7M2QX4P", "I7M2QX4P", "L7M2QX4P", "17M2QX4P", "07M2QX4P", "K7M2QX4", String(repeating: "x", count: 201)] {
            XCTAssertNil(parseReferralCode(value), value)
        }
    }
    func testLocalizedRulesUseServerValues() {
        let copy = ReferralCopy(tag: "zh-Hans")
        let rules = ReferralRules(qualifyWindowDays: 9, qualifyActiveDays: 4, retainWindowDays: 20, retainActiveDays: 5, retainLateFromDay: 10, cardValidDays: 60)
        let text = copy.format("rules_body", rules.arguments)
        XCTAssertTrue(text.contains("60 天内激活"))
        XCTAssertFalse(text.contains("$d"))
        for tag in ["en", "zh-Hans", "zh-Hant", "ja", "ko", "ru", "tr"] {
            XCTAssertNotEqual(ReferralCopy(tag: tag).text("heading"), "heading")
            XCTAssertFalse(ReferralCopy(tag: tag).format("rules_body", rules.arguments).contains("$d"))
        }
    }
    @MainActor func testClaimAndActivateReplaceWholeServerState() async {
        let service = ReferralPreviewService()
        let model = ReferralModel(service: service, currentUID: { 42 })
        await model.refresh()
        XCTAssertEqual(model.snapshot.claimable, 1)
        let failure = await model.mutate(.init(operation: "claim", task: "invite"))
        XCTAssertNil(failure)
        XCTAssertEqual(model.snapshot.status(.invite), .claimed)
        XCTAssertEqual(model.snapshot.cards.count, 1)
        XCTAssertEqual(model.snapshot.claimable, 0)
        let activate = await model.mutate(.init(operation: "activate", id: 100))
        XCTAssertNil(activate)
        XCTAssertTrue(model.snapshot.cards[0].activated)
        XCTAssertGreaterThan(model.snapshot.activeUntil ?? 0, referralNow())
    }
    @MainActor func testFailureKeepsLastKnownRewardsAnd409Refreshes() async {
        let service = ControlledService()
        let model = ReferralModel(service: service, currentUID: { 42 })
        await model.refresh()
        await service.failLoads(true)
        await model.refresh()
        XCTAssertEqual(model.snapshot.earnedDays, 7)
        XCTAssertEqual(model.error?.code, "network")
        await service.failLoads(false)
        let failure = await model.mutate(.init(operation: "activate", id: 100))
        XCTAssertEqual(failure?.code, "higher_tier_active")
        for _ in 0..<100 where model.busy || model.snapshot.cards.first?.expiresAt != 2100000000000 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.snapshot.cards.first?.expiresAt, 2100000000000)
    }
    @MainActor func testAccountChangeDiscardsInFlightResponse() async {
        let service = ControlledService()
        await service.delay(100)
        var uid: Int64 = 42
        let model = ReferralModel(service: service, currentUID: { uid })
        let request = Task { await model.refresh() }
        try? await Task.sleep(for: .milliseconds(20))
        uid = 99
        await request.value
        for _ in 0..<100 where model.snapshot.uid != 99 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.snapshot.uid, 99)
        XCTAssertFalse(model.busy)
    }
    @MainActor func testLoginRequiredDoesNotContactServer() async {
        let service = ControlledService()
        let model = ReferralModel(service: service, currentUID: { 0 })
        await model.refresh()
        XCTAssertEqual(model.error?.code, "login_required")
        let loads = await service.loads
        XCTAssertEqual(loads, 0)
    }

    func testExpiredOrRevokedRefreshCredentialsBootstrapAgain() async throws {
        for code in ["invalid_grant", "token_reuse_detected"] {
            let storage = LockedValue<Data?>(try storedAuthTokens())
            let http = AuthHTTPStub([
                .response(400, Data("{\"error\":\"\(code)\"}".utf8)),
                .response(201, try authTokens(access: "new-access")),
            ])
            let session = authSession(storage: storage, http: http)
            let access = try await session.token(uid: 42, rejected: "old-access")
            XCTAssertEqual(access, "new-access")
            let requests = await http.requests
            XCTAssertEqual(requests.map { $0.url!.lastPathComponent }, ["token", "session"])
            XCTAssertNotNil(requests[1].value(forHTTPHeaderField: "X-Shaft-Sign"))
            let persisted = try JSONSerialization.jsonObject(with: XCTUnwrap(storage.read())) as! [String: Any]
            XCTAssertNil(persisted["refreshAttempt"])
            XCTAssertEqual((persisted["tokens"] as? [String: Any])?["access_token"] as? String, "new-access")
        }
    }

    func testInterruptedRefreshReusesPersistedAttemptAfterRecreation() async throws {
        let storage = LockedValue<Data?>(try storedAuthTokens())
        let http = AuthHTTPStub([
            .failure(.timedOut),
            .response(503, Data(#"{"error":"auth_unavailable"}"#.utf8)),
            .response(200, try authTokens(access: "rotated-access")),
        ])
        for _ in 0..<2 {
            do {
                _ = try await authSession(storage: storage, http: http).token(uid: 42, rejected: "old-access")
                XCTFail("Transient failures must not bootstrap a new session")
            } catch { }
        }
        let access = try await authSession(storage: storage, http: http).token(uid: 42)
        XCTAssertEqual(access, "rotated-access")
        let requests = await http.requests
        XCTAssertEqual(requests.map { $0.url!.lastPathComponent }, ["token", "token", "token"])
        let attempts = requests.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }
        XCTAssertEqual(attempts.count, 3)
        XCTAssertEqual(Set(attempts).count, 1)
        // Every retry must send the same pre-rotation credential as well.
        XCTAssertEqual(Set(requests.compactMap(\.httpBody)).count, 1)
    }

    func testUnrelatedAuth400DoesNotDiscardRefreshCredentials() async throws {
        let storage = LockedValue<Data?>(try storedAuthTokens())
        let http = AuthHTTPStub([.response(400, Data(#"{"error":"bad_idempotency_key"}"#.utf8))])
        do {
            _ = try await authSession(storage: storage, http: http).token(uid: 42, rejected: "old-access")
            XCTFail("Unexpected authentication success")
        } catch let failure as ReferralFailure { XCTAssertEqual(failure.code, "auth_unavailable") }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let persisted = try JSONSerialization.jsonObject(with: XCTUnwrap(storage.read())) as! [String: Any]
        XCTAssertNotNil(persisted["refreshAttempt"])
    }

    func testConcurrentAuthRequestsShareOneRefresh() async throws {
        let storage = LockedValue<Data?>(try storedAuthTokens())
        let http = AuthHTTPStub([.response(200, try authTokens(access: "shared-access"))], delay: .milliseconds(50))
        let session = authSession(storage: storage, http: http)
        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 { group.addTask { try await session.token(uid: 42, rejected: "old-access") } }
            var values: [String] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(values, Array(repeating: "shared-access", count: 10))
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testForegroundActivityDoesNotSwallowBookmarkAndResetsAtShanghaiMidnight() async {
        let date = LockedValue(Date(timeIntervalSince1970: 1_000 * 86400 - 8 * 3600 - 1))
        let sent = LockedValue<[Bool]>([])
        let reporter = ReferralActivityReporter(currentUID: { 42 }, now: { date.read() }, enabled: { _ in true }, send: { _, bookmarked in
            sent.update { $0.append(bookmarked) }
        })
        await reporter.active(uid: 42)
        await reporter.active(uid: 42)
        await reporter.bookmark(uid: 42)
        await reporter.bookmark(uid: 42)
        XCTAssertEqual(sent.read(), [false, true])
        date.update { $0 = $0.addingTimeInterval(2) }
        await reporter.active(uid: 42)
        await reporter.bookmark(uid: 42)
        XCTAssertEqual(sent.read(), [false, true, false, true])
    }

    func testActivityFailureRetriesAndOtherAccountsCannotReport() async {
        let uid = LockedValue<Int64>(42)
        let sent = LockedValue<[Bool]>([])
        let reporter = ReferralActivityReporter(currentUID: { uid.read() }, enabled: { _ in true }, send: { _, bookmarked in
            sent.update { $0.append(bookmarked) }
            if sent.read().count == 1 { throw URLError(.notConnectedToInternet) }
        })
        await reporter.active(uid: 99)
        await reporter.active(uid: 42)
        await reporter.active(uid: 42)
        uid.update { $0 = 99 }
        await reporter.bookmark(uid: 42)
        XCTAssertEqual(sent.read(), [false, false])
    }

    func testClosedCampaignDoesNotSendActivity() async {
        let sent = LockedValue(0)
        let reporter = ReferralActivityReporter(currentUID: { 42 }, enabled: { _ in false }, send: { _, _ in sent.update { $0 += 1 } })
        await reporter.active(uid: 42)
        await reporter.bookmark(uid: 42)
        XCTAssertEqual(sent.read(), 0)
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.withLock { value } }
    func update(_ operation: (inout Value) -> Void) { lock.withLock { operation(&value) } }
}

private func authTokens(access: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["uid": 42, "access_token": access, "refresh_token": "refresh-token", "access_expires_at": referralNow() + 3_600_000])
}
private func storedAuthTokens() throws -> Data {
    try JSONSerialization.data(withJSONObject: ["tokens": JSONSerialization.jsonObject(with: authTokens(access: "old-access"))])
}
private func authSession(storage: LockedValue<Data?>, http: AuthHTTPStub) -> ReferralSession {
    ReferralSession(send: { request in
        // Rotation must be recoverable even if the process dies while sending.
        if request.url?.lastPathComponent == "token" {
            let persisted = try JSONSerialization.jsonObject(with: XCTUnwrap(storage.read())) as! [String: Any]
            XCTAssertEqual(persisted["refreshAttempt"] as? String, request.value(forHTTPHeaderField: "Idempotency-Key"))
        }
        return try await http.send(request)
    }, currentUID: { 42 }, readCredentials: { _ in storage.read() }, writeCredentials: { data, _ in storage.update { $0 = data } })
}

private actor AuthHTTPStub {
    enum Reply { case response(Int, Data), failure(URLError.Code) }
    private var replies: [Reply]
    private var delay: Duration
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply], delay: Duration = .zero) { self.replies = replies; self.delay = delay }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { XCTFail("Unexpected auth request"); throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        if delay > .zero { try await Task.sleep(for: delay) }
        switch reply {
        case let .response(status, data): return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case let .failure(code): throw URLError(code)
        }
    }
}

private actor ControlledService: ReferralServing {
    var loads = 0
    var fail = false
    var latency = 0
    var expiry: Double = 2000000000000
    func failLoads(_ value: Bool) { fail = value }
    func delay(_ value: Int) { latency = value }
    func load(uid: Int64, campaign: String?) async throws -> ReferralSnapshot {
        loads += 1
        if latency > 0 { try await Task.sleep(for: .milliseconds(latency)) }
        if fail { throw ReferralFailure(code: "network") }
        return ReferralSnapshot(uid: uid, enabled: true, tasks: [.init(key: "invite", status: "claimed")],
                                rewards: [.init(id: 100, task: "invite", plan: "pro", days: 7, expiresAt: expiry)])
    }
    func mutate(_ mutation: ReferralMutation, uid: Int64, campaign: String?) async throws -> ReferralSnapshot {
        expiry = 2100000000000
        throw ReferralFailure(code: "higher_tier_active", stale: true)
    }
}
