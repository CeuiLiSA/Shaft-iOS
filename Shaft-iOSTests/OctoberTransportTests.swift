import XCTest
import Network
import UIKit
@testable import Shaft_iOS

/// Loopback HTTP exercises the actual URLSession download delegate and resume path.
final class OctoberHTTPServer: @unchecked Sendable {
    struct Request { let method: String; let path: String; let headers: [String: String]; let body: Data }
    struct Response {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var delayAfterFirstChunk: TimeInterval? = nil
        var knownLength = true
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "october.http-fixture")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var recorded: [Request] = []
    private let handler: @Sendable (Request, Int) -> Response
    var requests: [Request] { lock.withLock { recorded } }
    var baseURL: String { "http://127.0.0.1:\(listener.port!.rawValue)/" }
    init(handler: @escaping @Sendable (Request, Int) -> Response) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.handler = handler
    }
    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            self.receive(connection, buffer: Data())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel(); lock.withLock { connections.forEach { $0.cancel() } } }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, done, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer; if let data { buffer.append(data) }
            guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done { connection.cancel() } else { self.receive(connection, buffer: buffer) }; return
            }
            let lines = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
            }
            let count = Int(headers["content-length"] ?? "0") ?? 0
            guard buffer.count - boundary.upperBound >= count else { self.receive(connection, buffer: buffer); return }
            guard first.count >= 2 else { connection.cancel(); return }
            let request = Request(method: String(first[0]), path: String(first[1]), headers: headers,
                                  body: Data(buffer[boundary.upperBound...].prefix(count)))
            let index = self.lock.withLock { self.recorded.append(request); return self.recorded.count }
            let response = self.handler(request, index)
            var fields = response.headers
            fields["Connection"] = "close"
            if response.knownLength { fields["Content-Length"] = String(response.body.count) }
            let head = "HTTP/1.1 \(response.status) Fixture\r\n" + fields.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
            if let delay = response.delayAfterFirstChunk {
                let split = min(response.body.count, 64 * 1024)
                connection.send(content: Data(head.utf8) + response.body.prefix(split), completion: .contentProcessed { _ in })
                self.queue.asyncAfter(deadline: .now() + delay) {
                    connection.send(content: Data(response.body.dropFirst(split)), completion: .contentProcessed { _ in connection.cancel() })
                }
            } else {
                connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

private final class OctoberProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ImageTransferProgress] = []
    func append(_ value: ImageTransferProgress) { lock.withLock { values.append(value) } }
    var snapshot: [ImageTransferProgress] { lock.withLock { values } }
}

final class OctoberTransportTests: XCTestCase {
    private let payload = Data(repeating: 65, count: 128 * 1024)
    func testRealImageIdleTimeoutRetriesOnlyOnceInsideSameTransfer() async throws {
        let payload = payload
        let server = try OctoberHTTPServer { _, index in
            .init(body: payload, delayAfterFirstChunk: index == 1 ? 3 : nil)
        }
        try await server.start(); defer { server.stop() }
        let progress = OctoberProgressRecorder()
        let downloader = ProgressImageDownloader(options: .init(policy: .init(seconds: 1, directConnect: false), retry: true),
            configuration: .ephemeral, onProgress: { progress.append($0) })
        let data = await downloader.run(URLRequest(url: URL(string: server.baseURL + "image.png")!))
        XCTAssertEqual(data, payload)
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertEqual(progress.snapshot.last?.retryCount, 1)
        XCTAssertTrue(progress.snapshot.last?.complete == true)
    }

    func testSecondStallFailsRatherThanCreatingUnboundedRetries() async throws {
        let payload = payload
        let server = try OctoberHTTPServer { _, _ in .init(body: payload, delayAfterFirstChunk: 3) }
        try await server.start(); defer { server.stop() }
        let downloader = ProgressImageDownloader(options: .init(policy: .init(seconds: 1, directConnect: false), retry: true),
                                                configuration: .ephemeral, onProgress: { _ in })
        let data = await downloader.run(URLRequest(url: URL(string: server.baseURL + "image.png")!))
        XCTAssertNil(data)
        XCTAssertEqual(server.requests.count, 2)
    }

    func testCancellationInterruptsCurrentImageAndNeverRetries() async throws {
        let payload = payload
        let server = try OctoberHTTPServer { _, _ in .init(body: payload, delayAfterFirstChunk: 10) }
        try await server.start(); defer { server.stop() }
        let downloader = ProgressImageDownloader(options: .init(policy: .init(seconds: 3, directConnect: false), retry: true),
                                                configuration: .ephemeral, onProgress: { _ in })
        let url = URL(string: server.baseURL + "image.png")!
        let task = Task { await downloader.run(URLRequest(url: url)) }
        for _ in 0..<100 where server.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let start = Date()
        task.cancel()
        let data = await task.value
        XCTAssertNil(data)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertEqual(server.requests.count, 1)
    }

    @MainActor func testSharedImageConsumerCanPauseWhileViewerFinishesTheSameRequest() async throws {
        let payload = payload
        let server = try OctoberHTTPServer { _, _ in .init(body: payload, delayAfterFirstChunk: 0.3) }
        try await server.start(); defer { server.stop() }
        let cache = PixivImageCache()
        let url = URL(string: server.baseURL + "shared.png")!
        let viewer = Task { await cache.loadData(url) }
        let download = Task { await cache.loadData(url, forDownload: true) }
        for _ in 0..<100 where server.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        download.cancel()
        let stopped = await download.value
        XCTAssertNil(stopped)
        let displayed = await viewer.value
        XCTAssertEqual(displayed, payload)
        XCTAssertEqual(server.requests.count, 1)
    }

    @MainActor func testLastObserverCancellationAllowsFreshReplacementWithoutOldCleanupRemovingIt() async throws {
        let payload = payload
        let server = try OctoberHTTPServer { _, index in .init(body: payload, delayAfterFirstChunk: index == 1 ? 10 : nil) }
        try await server.start(); defer { server.stop() }
        let cache = PixivImageCache()
        let url = URL(string: server.baseURL + "replacement.png")!
        let first = Task { await cache.loadData(url, forDownload: true) }
        for _ in 0..<100 where server.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        first.cancel()
        let stopped = await first.value
        XCTAssertNil(stopped)
        let replacement = await cache.loadData(url, forDownload: true)
        XCTAssertEqual(replacement, payload)
        XCTAssertEqual(server.requests.count, 2)
    }

    @MainActor func testInvalidDisplayBytesDoNotPoisonSubsequentVisits() async throws {
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }.pngData())
        let server = try OctoberHTTPServer { _, index in
            .init(body: index == 1 ? Data("<html>temporarily unavailable</html>".utf8) : png)
        }
        try await server.start(); defer { server.stop() }
        let url = try XCTUnwrap(URL(string: server.baseURL + "recoverable.png"))
        let cache = PixivImageCache()
        let first = await cache.load(url)
        XCTAssertNil(first)
        let recovered = await cache.load(url)
        XCTAssertNotNil(recovered)
        XCTAssertEqual(server.requests.count, 2)
        let revisited = await PixivImageCache().load(url)
        XCTAssertNotNil(revisited)
        XCTAssertEqual(server.requests.count, 2, "Valid images should still be reused from disk")
    }

    func testUnknownLengthStaysUnknownUntilEOFAndHttpErrorsAreNotImages() async throws {
        let payload = payload
        let server = try OctoberHTTPServer { request, _ in
            .init(status: request.path == "/missing" ? 404 : 200, body: payload, knownLength: false)
        }
        try await server.start(); defer { server.stop() }
        let progress = OctoberProgressRecorder()
        let downloader = ProgressImageDownloader(options: .init(retry: false), configuration: .ephemeral,
                                                onProgress: { progress.append($0) })
        let data = await downloader.run(URLRequest(url: URL(string: server.baseURL + "image")!))
        XCTAssertEqual(data, payload)
        XCTAssertTrue(progress.snapshot.contains { !$0.complete && $0.expected == nil })
        XCTAssertEqual(progress.snapshot.last?.fraction, 1)
        let bad = ProgressImageDownloader(options: .init(retry: true), configuration: .ephemeral, onProgress: { _ in })
        let missing = await bad.run(URLRequest(url: URL(string: server.baseURL + "missing")!))
        XCTAssertNil(missing)
        XCTAssertEqual(server.requests.count, 2)
    }

    func testWebDavXmlDepthNamesAndFolderCreationUseRealTransport() async throws {
        let xml = Data(#"<?xml version="1.0"?><multistatus xmlns="DAV:"><response><href>/dav/Shaft/</href><propstat><prop><resourcetype><collection/></resourcetype></prop></propstat></response><response><href>/dav/Shaft/%E7%8C%AB%20a.json.gz</href><propstat><prop><getcontentlength>123</getcontentlength></prop></propstat></response></multistatus>"#.utf8)
        let server = try OctoberHTTPServer { request, _ in
            .init(status: request.method == "MKCOL" ? 405 : 207, headers: ["Content-Type": "application/xml"], body: xml)
        }
        try await server.start(); defer { server.stop() }
        let client = try WebDAVClient(config: .init(baseURL: server.baseURL + "dav", username: "user", password: "pass", folder: "Shaft/nested"))
        try await client.testConnection()
        let entries = try await client.list()
        XCTAssertEqual(entries, [.init(name: "猫 a.json.gz", size: 123)])
        try await client.ensureFolder()
        XCTAssertEqual(server.requests.map(\.method), ["PROPFIND", "PROPFIND", "MKCOL", "MKCOL"])
        XCTAssertEqual(server.requests[0].headers["depth"], "0")
        XCTAssertEqual(server.requests[1].headers["depth"], "1")
        XCTAssertEqual(server.requests[3].path, "/dav/Shaft/nested/")
        XCTAssertTrue(server.requests.allSatisfy { $0.headers["authorization"] == "Basic dXNlcjpwYXNz" && $0.headers["cookie"] == nil })
    }

    func testWebDavUploadDownloadAndDeleteVerifyBytesAndStatus() async throws {
        let bytes = try ShaftBackupCodec.compressed(Data(#"{"settings":{}}"#.utf8))
        let server = try OctoberHTTPServer { request, _ in
            .init(status: request.method == "DELETE" ? 404 : 200, body: bytes)
        }
        try await server.start(); defer { server.stop() }
        let client = try WebDAVClient(config: .init(baseURL: server.baseURL, username: "user", password: "pass"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        try await client.upload(name: "a backup.json.gz", file: file)
        let remote = try await client.download(name: "a backup.json.gz")
        defer { try? FileManager.default.removeItem(at: remote) }
        XCTAssertEqual(try Data(contentsOf: remote), bytes)
        try await client.delete(name: "a backup.json.gz")
        XCTAssertEqual(server.requests[0].body, bytes)
        XCTAssertEqual(server.requests[0].headers["if-none-match"], "*")
        XCTAssertEqual(server.requests[0].path, "/Shaft/a%20backup.json.gz")
        XCTAssertEqual(server.requests.map(\.method), ["PUT", "GET", "DELETE"])
    }

    func testWebDavRejectsHtmlTruncatedXmlAndAuthenticationFailures() async throws {
        let server = try OctoberHTTPServer { request, _ in
            switch request.path {
            case "/html/": return .init(body: Data("<html>login</html>".utf8))
            case "/truncated/": return .init(status: 207, body: Data(#"<d:multistatus xmlns:d="DAV:">"#.utf8))
            default: return .init(status: 401)
            }
        }
        try await server.start(); defer { server.stop() }
        for path in ["html", "truncated", "auth"] {
            let client = try WebDAVClient(config: .init(baseURL: server.baseURL + path, username: "user", password: "pass"))
            do { try await client.testConnection(); XCTFail("Expected rejection for \(path)") }
            catch { if path == "auth" { guard case WebDAVError.authentication = error else { XCTFail("Wrong auth error"); continue } } }
        }
    }

    func testWebDavRefusesCrossOriginCredentialRedirect() async throws {
        let recipient = try OctoberHTTPServer { _, _ in .init(status: 207, body: Data(#"<multistatus xmlns="DAV:"/>"#.utf8)) }
        try await recipient.start(); defer { recipient.stop() }
        let destination = recipient.baseURL
        let server = try OctoberHTTPServer { _, _ in .init(status: 302, headers: ["Location": destination]) }
        try await server.start(); defer { server.stop() }
        let client = try WebDAVClient(config: .init(baseURL: server.baseURL, username: "user", password: "pass"))
        do { try await client.testConnection(); XCTFail("Cross-origin redirect must fail") } catch {}
        XCTAssertTrue(recipient.requests.isEmpty)
    }

    func testSameOriginRedirectKeepsDavMethodsBodiesAndConditionalUpload() async throws {
        let xml = Data(#"<multistatus xmlns="DAV:"/>"#.utf8)
        let server = try OctoberHTTPServer { request, _ in
            if request.path.hasPrefix("/dav/") {
                return .init(status: 301, headers: ["Location": request.method == "PUT" ? "/target/backup.json.gz" : "/target/"])
            }
            return .init(status: request.method == "PUT" ? 201 : 207, body: xml)
        }
        try await server.start(); defer { server.stop() }
        let client = try WebDAVClient(config: .init(baseURL: server.baseURL + "dav", username: "user", password: "pass"))
        try await client.testConnection()
        XCTAssertEqual(server.requests[1].method, "PROPFIND")
        XCTAssertEqual(server.requests[1].body, server.requests[0].body)
        XCTAssertEqual(server.requests[1].headers["content-type"], "application/xml; charset=utf-8")
        let bytes = try ShaftBackupCodec.compressed(Data(#"{"settings":{}}"#.utf8))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        try await client.upload(name: "backup.json.gz", file: file)
        XCTAssertEqual(server.requests.last?.method, "PUT")
        XCTAssertEqual(server.requests.last?.body, bytes)
        XCTAssertEqual(server.requests.last?.headers["if-none-match"], "*")
        XCTAssertEqual(server.requests.last?.headers["content-type"], "application/gzip")
    }

    func testCancellingQueuedBackupDoesNotWaitForOrCancelCurrentOperation() async throws {
        let server = try OctoberHTTPServer { _, _ in .init(body: Data(repeating: 65, count: 128 * 1024), delayAfterFirstChunk: 10) }
        try await server.start(); defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = await MainActor.run { WebDAVPreferences(file: directory.appendingPathComponent("preferences.json"), secrets: OctoberMemorySecrets()) }
        let service = WebDAVBackupService(preferences: preferences)
        let config = WebDAVConfig(baseURL: server.baseURL, username: "user", password: "pass")
        let current = Task { try await service.backup(config: config, includeHistory: false, skipUnchanged: false) }
        defer { current.cancel() }
        for _ in 0..<300 where server.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        guard !server.requests.isEmpty else {
            current.cancel()
            let result = await current.result
            XCTFail("Fixture did not reach network: \(result)")
            return
        }
        let queued = Task { try await service.localExport(includeHistory: false) }
        try await Task.sleep(for: .milliseconds(20))
        let start = Date()
        queued.cancel()
        do { _ = try await queued.value; XCTFail("Queued cancellation should throw") } catch is CancellationError {} catch { XCTFail("Wrong cancellation") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertFalse(current.isCancelled)
        current.cancel()
        _ = await current.result
    }

    func testWebDavUrlRejectsCredentialsAndUnsafeFileNames() throws {
        XCTAssertThrowsError(try WebDAVConfig(baseURL: "https://user:pass@example.com").normalized())
        XCTAssertThrowsError(try WebDAVConfig(baseURL: "file:///tmp").normalized())
        let config = try WebDAVConfig(baseURL: " https://example.com/dav?q=a#fragment ", username: " u ", password: " p ", folder: " /Shaft/../nested/ ").normalized()
        XCTAssertEqual(config.baseURL, "https://example.com/dav/?q=a")
        XCTAssertEqual(config.password, " p ")
        XCTAssertEqual(config.folder, "Shaft/nested")
        let client = try WebDAVClient(config: config)
        XCTAssertThrowsError(try client.url(segments: ["../secret"], directory: false))
        XCTAssertThrowsError(try client.url(segments: [".."], directory: false))
    }
}
