import Foundation
import Observation
import os

enum StickerState: Sendable {
    case idle, checking, downloading(Int64, Int64), extracting, ready(StickerReady), failed(Error)
    var ready: StickerReady? { if case .ready(let value) = self { value } else { nil } }
}

enum StickerLog {
    private static let logger = Logger(subsystem: "com.shaft.ShaftiOS", category: "Sticker-System")
    static func event(_ value: String) { logger.info("\(value, privacy: .public)") }
}

/// One application-owned flight. Closing a picker only removes its observation.
@MainActor @Observable final class StickerRepository {
    static let shared = StickerRepository()
    private(set) var state: StickerState = .idle
    @ObservationIgnored private var flight: Task<Void, Never>?
    @ObservationIgnored private var warmFlight: Task<StickerReady?, Never>?
    @ObservationIgnored private let installer: StickerInstaller

    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("stickers")) {
        installer = StickerInstaller(store: StickerStore(root: root))
    }

    func warmUp() {
        guard flight == nil, warmFlight == nil, case .idle = state else { return }
        let task = Task { await installer.reopen() }; warmFlight = task
        Task {
            if let ready = await task.value, flight == nil, case .idle = state { state = .ready(ready) }
            warmFlight = nil
        }
    }

    func prepare() {
        guard flight == nil else { return }
        let previous = state.ready
        if previous == nil { state = .checking }
        StickerLog.event("prepare_start")
        flight = Task { [self] in
            defer { flight = nil }
            do {
                let ready = try await installer.prepare(previous: previous) { [self] state in await updateProgress(state) }
                state = .ready(ready)
                StickerLog.event("gate_ready stickers=\(ready.images.count) packages=\(ready.catalog.packages.count)")
            } catch {
                state = .failed(error)
                StickerLog.event("installation_failed \(error.localizedDescription)")
            }
        }
    }

    private func updateProgress(_ state: StickerState) {
        if flight != nil { self.state = state }
    }

    func localFailure(_ error: Error, generation: String) {
        guard state.ready?.generation == generation, flight == nil else { return }
        state = .failed(error)
        StickerLog.event("local_file_failed generation=\(generation)")
    }

    // Deterministic local previews and render tests do not touch the singleton or network.
    init(ready: StickerReady) {
        installer = StickerInstaller(store: StickerStore(root: ready.marker.deletingLastPathComponent()))
        state = .ready(ready)
    }
}

actor StickerInstaller {
    let store: StickerStore
    private var versionChecked = false
    private let session: URLSession
    init(store: StickerStore) {
        self.store = store
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config)
    }
    func reopen() -> StickerReady? { store.reopen() }

    func prepare(previous: StickerReady?, progress: @escaping @Sendable (StickerState) async -> Void) async throws -> StickerReady {
        let saved = store.savedCatalog()
        let local = previous ?? store.reopen()
        let localUnchanged = local.map { previous == nil || store.unchanged($0) } ?? false
        // Publish a verified disk installation before the network version probe;
        // cold offline launches must not wait for an HTTP timeout to show images.
        if let local, localUnchanged { await progress(.ready(local)) }
        var versions: StickerVersions?
        if !versionChecked {
            versions = try? await metadata("stickers-version", as: StickerVersions.self)
            if let versions { try versions.validate() }
        }
        if let local, localUnchanged, versions == nil || versions == local.catalog.versions {
            if versions != nil { versionChecked = true }
            StickerLog.event("gate_reused files=\(local.inventory.count)")
            return local
        }
        await progress(.checking)
        let catalog: StickerCatalog
        if let versions {
            if saved?.versions == versions, let saved { catalog = saved }
            else {
                var packs: [String: StickerPack] = [:]
                for category in StickerCategory.allCases {
                    packs[category.rawValue] = try await metadata("stickers?type=\(category.rawValue)", as: StickerPack.self)
                }
                catalog = StickerCatalog(versions: versions, packs: packs)
            }
        } else if let saved { catalog = saved }
        else { throw URLError(.cannotConnectToHost) }
        try catalog.validate()
        try store.begin()
        let total = catalog.packages.reduce(Int64(0)) { $0 + $1.size }
        var completed: Int64 = 0
        for package in catalog.packages {
            if !store.validArchive(package) {
                let base = completed
                await progress(.downloading(base, total))
                let delegate = StickerTransfer(limit: package.size, followsReleaseRedirects: true) { bytes in
                    Task { await progress(.downloading(base + bytes, total)) }
                }
                // The catalog URL is only the legacy wire / cache identity; the bytes come from
                // the content-addressed GitHub release asset, resolved by checksum.
                let (file, response) = try await session.download(from: StickerDownloadSource.url(package), delegate: delegate)
                defer { try? FileManager.default.removeItem(at: file) }
                try Self.check(response)
                try store.installArchive(file, package: package)
                StickerLog.event("download_verified size=\(package.size) sha256=\(package.sha256)")
            }
            await progress(.extracting)
            try store.extract(package)
            completed += package.size
        }
        let ready = try store.finish(catalog)
        if versions != nil { versionChecked = true }
        return ready
    }

    private func metadata<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        StickerLog.event("metadata_start path=\(path)")
        let delegate = StickerTransfer(limit: 8 * 1024 * 1024)
        let (file, response) = try await session.download(from: URL(string: "https://api.pixshaft.com/f/v1/\(path)")!, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: file) }
        try Self.check(response)
        let data = try Data(contentsOf: file)
        guard data.count <= 8 * 1024 * 1024 else { throw StickerFailure.catalog }
        StickerLog.event("metadata_complete path=\(path) bytes=\(data.count)")
        return try JSONDecoder().decode(T.self, from: data)
    }
    private static func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw StickerFailure.http(status) }
    }
}

/// Content-addressed sticker ZIPs (upstream `StickerDownloadSource`): the legacy
/// catalog URL is never downloaded.
enum StickerDownloadSource {
    static let releaseBase = "https://github.com/CeuiLiSA/Pixiv-Shaft/releases/download/sticker-assets/"

    static func url(_ pkg: StickerPackage) -> URL {
        URL(string: releaseBase + pkg.sha256 + ".zip")!
    }

    /// Only the exact release asset on github.com, and GitHub's short-lived signed
    /// CDN it redirects public release assets to.
    static func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.fragment == nil, let host = url.host else { return false }
        switch host {
        case "github.com":
            let name = url.lastPathComponent
            return url.query == nil && url.absoluteString == releaseBase + name && name.hasSuffix(".zip")
                && name.dropLast(4).range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
        case "release-assets.githubusercontent.com":
            return true
        default:
            return false
        }
    }
}

/// Separate ephemeral transfer; cookies and tokens never reach the asset hosts, and
/// redirects are refused except GitHub's release-asset hop.
private final class StickerTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int64
    let followsReleaseRedirects: Bool
    let progress: @Sendable (Int64) -> Void
    private var lastReport = Date.distantPast
    init(limit: Int64, followsReleaseRedirects: Bool = false, progress: @escaping @Sendable (Int64) -> Void = { _ in }) {
        self.limit = limit; self.followsReleaseRedirects = followsReleaseRedirects; self.progress = progress
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(followsReleaseRedirects && StickerDownloadSource.allows(request.url) ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel(); return }
        if Date().timeIntervalSince(lastReport) > 0.15 || totalBytesWritten == limit {
            lastReport = Date(); progress(totalBytesWritten)
        }
    }
}
