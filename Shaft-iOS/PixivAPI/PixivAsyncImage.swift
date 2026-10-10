import CryptoKit
import ImageIO
import SwiftUI
import UIKit

/// Image CDN routes shared by every Pixiv image request.
///
/// Raw values intentionally match Android's persisted `Mode` ordinal. The
/// route is hydrated once at launch, like Android's image client; changing it
/// in Settings persists the choice and takes effect after the next launch so
/// an existing URLSession/cache cannot mix hosts.
enum ImageHostMode: Int, CaseIterable, Sendable {
    case pixiv = 0
    case pixivCat = 1
    case pixivRe = 2
    case pixivNl = 3
    case custom = 4
}

enum ImageHostManager {
    private static let pixivImageHost = "i.pximg.net"
    private static let pixivStaticHost = "s.pximg.net"
    private static let pixivCatImageHost = "i.pixiv.cat"
    private static let pixivCatStaticHost = "s.pixiv.cat"
    private static let pixivReImageHost = "i.pixiv.re"
    private static let pixivReStaticHost = "s.pixiv.re"
    private static let pixivNlImageHost = "i.pixiv.nl"
    private static let pixivNlStaticHost = "s.pixiv.nl"

    private(set) static var mode: ImageHostMode = .pixiv
    private(set) static var customHost = ""

    /// Loads the persisted route before the first networking object is built.
    static func hydrate(defaults: UserDefaults = .standard) {
        mode = ImageHostMode(rawValue: defaults.integer(forKey: "st_imageHostMode")) ?? .pixiv
        customHost = normalizeCustomHost(defaults.string(forKey: "st_customImageHost") ?? "")
    }

    static func requiresStandardClient() -> Bool {
        mode != .pixiv
    }

    static func normalizeCustomHost(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Rewrites only Pixiv's image hosts, preserving the full path/query.
    /// Non-Pixiv URLs and malformed strings pass through unchanged.
    static func rewrite(_ url: URL) -> URL {
        let rewritten = rewrite(url.absoluteString)
        guard let result = URL(string: rewritten) else {
            return url
        }
        return result
    }

    static func rewrite(_ value: String) -> String {
        guard !value.isEmpty, let schemeEnd = value.range(of: "://") else { return value }
        let hostStart = schemeEnd.upperBound
        // Treat query/fragment markers as the end of the authority too. This
        // keeps host-only URLs (and URLs without a path) on the same route as
        // regular image URLs while preserving their suffix verbatim.
        let pathStart = value[hostStart...].firstIndex {
            $0 == "/" || $0 == "?" || $0 == "#"
        } ?? value.endIndex
        let hostAndPort = String(value[hostStart..<pathStart])
        guard !hostAndPort.isEmpty else { return value }
        let host = hostAndPort.split(separator: ":", maxSplits: 1,
                                     omittingEmptySubsequences: true).first.map(String.init) ?? ""
        guard host == pixivImageHost || host == pixivStaticHost else { return value }

        switch mode {
        case .pixiv:
            return value
        case .pixivCat:
            let mapped = host == pixivImageHost ? pixivCatImageHost : pixivCatStaticHost
            return String(value[..<hostStart]) + mapped + String(value[pathStart...])
        case .pixivRe:
            let mapped = host == pixivImageHost ? pixivReImageHost : pixivReStaticHost
            return String(value[..<hostStart]) + mapped + String(value[pathStart...])
        case .pixivNl:
            let mapped = host == pixivImageHost ? pixivNlImageHost : pixivNlStaticHost
            return String(value[..<hostStart]) + mapped + String(value[pathStart...])
        case .custom:
            return customHost.isEmpty ? value : customHost + String(value[pathStart...])
        }
    }
}

extension URLRequest {
    /// Request for a pixiv image CDN URL with the Referer/User-Agent pair the
    /// CDN requires — the single place those headers live.
    static func pixivImage(_ url: URL) -> URLRequest {
        var req = URLRequest(url: ImageHostManager.rewrite(url))
        req.setValue("https://app-api.pixiv.net/", forHTTPHeaderField: "Referer")
        req.setValue(PixivClientIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }
}

@MainActor
final class PixivImageCache {
    static let shared = PixivImageCache()

    private let cache = NSCache<NSString, UIImage>()
    init() {
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    private func routed(_ url: URL) -> URL {
        ImageHostManager.rewrite(url)
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: routed(url).absoluteString as NSString)
    }

    /// Memoized display-sized decode of an original (see `decodeForDisplay`) —
    /// revisiting the same detail page must not re-read disk and re-decode.
    func displayImage(for url: URL) -> UIImage? {
        cache.object(forKey: "display:" + routed(url).absoluteString as NSString)
    }

    func setDisplayImage(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: "display:" + routed(url).absoluteString as NSString,
                        cost: cost(image, 0))
    }

    /// True when the encoded bytes for `url` are already in the disk cache —
    /// callers can skip placeholder work when the real thing is instant.
    nonisolated func hasDiskData(for url: URL) -> Bool {
        FileManager.default.fileExists(atPath: diskURL(for: ImageHostManager.rewrite(url)).path)
    }

    func load(_ url: URL) async -> UIImage? {
        let url = routed(url)
        if let cached = cache.object(forKey: url.absoluteString as NSString) { return cached }
        guard let data = await loadData(url), !Task.isCancelled else { return nil }
        let image = await Self.decodeThumbnail(data)
        guard !Task.isCancelled else { return nil }
        if let image { cache.setObject(image, forKey: url.absoluteString as NSString, cost: cost(image, 0)) }
        else {
            // A proxy can return a login/error page with HTTP 200. Keep a
            // failed decode from poisoning every later visit to this URL.
            let file = diskURL(for: url)
            await Self.diskFiles.remove(file, ifMatching: data)
        }
        return image
    }

    /// Fully decodes (and, for oversized sources, downsamples) off the main
    /// thread. `UIImage(data:)` defers JPEG decode to the Core Animation
    /// commit — on the main thread, mid-scroll, one hitch per appearing cell.
    /// `kCGImageSourceShouldCacheImmediately` rasterizes here instead.
    nonisolated static func decodeThumbnail(_ data: Data, longEdgeCap: Int = 2048) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: longEdgeCap,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
                .map(UIImage.init(cgImage:))
        }.value
    }

    /// Decodes encoded bytes into a display-sized bitmap for the detail hero:
    /// just enough pixels for the image's rendered WIDTH to be `pixelWidth`
    /// (the screen's physical width), long edge capped at `longEdgeCap` so
    /// extreme manga strips stay texture-friendly. The full pixels stay on
    /// disk for the zoom viewer's tile decoder.
    nonisolated static func decodeForDisplay(_ data: Data,
                                             pixelWidth: Int,
                                             longEdgeCap: Int = 4096) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            var maxPixel = longEdgeCap
            if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int,
               let h = props[kCGImagePropertyPixelHeight] as? Int,
               w > 0, h > 0 {
                if h > w {
                    // Portrait: size the long edge so the width lands on screen width.
                    maxPixel = min(h, min(longEdgeCap, pixelWidth * h / w))
                } else {
                    maxPixel = min(w, pixelWidth)
                }
            }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
                .map(UIImage.init(cgImage:))
        }.value
    }

    private func cost(_ img: UIImage, _ byteCount: Int) -> Int {
        (img.cgImage?.bytesPerRow ?? byteCount) * (img.cgImage?.height ?? 1)
    }

    // MARK: Raw-bytes disk cache (zoom viewer + lossless save)

    private nonisolated static let diskLimit = 512 * 1024 * 1024
    private nonisolated static let diskFiles = ImageCacheFiles()

    private nonisolated static let diskDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OriginalImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        trimDiskCache(at: dir)
        return dir
    }()

    private nonisolated func diskURL(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
        return Self.diskDir.appendingPathComponent(hash).appendingPathExtension(ext)
    }

    private var inflightData: [URL: InflightDataDownload] = [:]

    /// Encoded bytes for `url`, cached on disk. The zoom viewer tile-decodes
    /// these directly (decoded bitmaps never enter the memory cache) and the
    /// save flow writes them to Photos losslessly.
    ///
    /// Concurrent calls for the same URL share one download: a late joiner
    /// (e.g. the zoom viewer opened while the detail hero is still fetching)
    /// is replayed the current progress immediately and continues from there.
    func loadData(_ url: URL, forDownload: Bool = false,
                  onTransfer: @MainActor @escaping (ImageTransferProgress) -> Void = { _ in },
                  onProgress: @MainActor @escaping (Double) -> Void = { _ in }) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let url = routed(url)
        let file = diskURL(for: url)
        if let data = await Self.diskFiles.read(file) {
            guard !Task.isCancelled else { return nil }
            onTransfer(ImageTransferProgress(received: Int64(data.count), expected: Int64(data.count), complete: true))
            onProgress(1)
            return data
        }
        let retry = forDownload && ImageTransferPolicy.active.customized
        let download: InflightDataDownload
        if let existing = inflightData[url] {
            download = existing
            if retry { download.options.enableRetry() }
            if !forDownload { download.options.includeDisplay() }
        } else {
            download = InflightDataDownload(retry: retry, display: !forDownload)
            inflightData[url] = download
            let req = URLRequest.pixivImage(url)
            download.task = Task.detached(priority: .userInitiated) { [self, download] in
                let downloader = ProgressImageDownloader(options: download.options) { progress in
                    Task { @MainActor in download.report(progress) }
                }
                let data = await downloader.run(req)
                if let data, !Task.isCancelled { await Self.diskFiles.write(data, to: file) }
                await MainActor.run {
                    download.finish(data)
                    if inflightData[url] === download { inflightData[url] = nil }
                }
            }
        }
        let observerID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: nil); return }
                download.addObserver(observerID, continuation: continuation, callback: { progress in
                    onTransfer(progress)
                    if let fraction = progress.fraction { onProgress(fraction) }
                })
            }
        } onCancel: {
            Task { @MainActor in
                download.cancelObserver(observerID)
                if download.isEmpty {
                    download.task.cancel()
                    if self.inflightData[url] === download { self.inflightData[url] = nil }
                }
            }
        }
    }

    @MainActor
    private final class InflightDataDownload {
        let options: ImageTransferOptions
        var task: Task<Void, Never>!
        private var progress = ImageTransferProgress()
        private var observers: [UUID: (CheckedContinuation<Data?, Never>, @MainActor (ImageTransferProgress) -> Void)] = [:]
        private var finished = false
        private var result: Data?
        var isEmpty: Bool { observers.isEmpty }
        init(retry: Bool, display: Bool) { options = ImageTransferOptions(retry: retry, display: display) }
        func addObserver(_ id: UUID, continuation: CheckedContinuation<Data?, Never>,
                         callback: @MainActor @escaping (ImageTransferProgress) -> Void) {
            callback(progress)
            if finished { continuation.resume(returning: result) }
            else { observers[id] = (continuation, callback) }
        }
        func cancelObserver(_ id: UUID) { observers.removeValue(forKey: id)?.0.resume(returning: nil) }
        func report(_ value: ImageTransferProgress) {
            guard !finished else { return }
            progress = value
            for observer in observers.values { observer.1(value) }
        }
        func finish(_ data: Data?) {
            guard !finished else { return }
            finished = true
            result = data
            let pending = observers.values
            observers.removeAll()
            for observer in pending { observer.0.resume(returning: data) }
        }
    }

    /// Oldest-first trim so the originals dir never grows past `diskLimit`.
    private nonisolated static func trimDiskCache(at dir: URL) {
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else {
                return
            }
            var entries = files.compactMap { url -> (URL, Int, Date)? in
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return (url, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
            }
            var total = entries.reduce(0) { $0 + $1.1 }
            guard total > diskLimit else { return }
            entries.sort { $0.2 < $1.2 }
            for (url, size, _) in entries where total > diskLimit / 2 {
                try? fm.removeItem(at: url)
                total -= size
            }
        }
    }
}

/// Serial disk access also keeps a failed old decode from deleting the bytes
/// of a newer successful transfer. No filesystem work runs on the main actor.
private actor ImageCacheFiles {
    func read(_ file: URL) -> Data? { try? Data(contentsOf: file, options: .mappedIfSafe) }
    func write(_ data: Data, to file: URL) {
        guard !Task.isCancelled else { return }
        try? data.write(to: file, options: .atomic)
    }
    func remove(_ file: URL, ifMatching data: Data) {
        guard read(file) == data else { return }
        try? FileManager.default.removeItem(at: file)
    }
}

/// Each instance belongs to one shared transfer. Delegate state is serialized;
/// cancellation may arrive on any executor and only touches the locked task.
final class ProgressImageDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let options: ImageTransferOptions
    private let onProgress: @Sendable (ImageTransferProgress) -> Void
    private let configuration: URLSessionConfiguration?
    private let lock = NSLock()
    private var currentTask: URLSessionDownloadTask?
    private var cancelled = false
    private var continuation: CheckedContinuation<Data?, Never>?
    private var finished = false
    private var progress = ImageTransferProgress()
    private var lastReportUptime: TimeInterval = 0
    private var request: URLRequest?
    init(options: ImageTransferOptions, configuration: URLSessionConfiguration? = nil,
         onProgress: @escaping @Sendable (ImageTransferProgress) -> Void) {
        self.options = options
        self.configuration = configuration
        self.onProgress = onProgress
    }

    func run(_ request: URLRequest) async -> Data? {
        if configuration == nil && DirectConnection.imageDirectConnectAtLaunch {
            var attempts = 0
            while !Task.isCancelled {
                let activity = TransferActivity()
                let attempt = attempts
                do {
                    let (data, response) = try await DirectConnection.data(
                        for: request, using: URLSession.shared, directConnect: true,
                        transfer: activity, idleSeconds: options.policy.idleSeconds,
                        onTransfer: { [onProgress] value in
                            var value = value; value.retryCount = attempt; onProgress(value)
                        })
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else { return nil }
                    onProgress(ImageTransferProgress(received: Int64(data.count), expected: Int64(data.count), complete: true, retryCount: attempts))
                    return data
                } catch {
                    guard !Task.isCancelled, ImageTransferPolicy.shouldRetry(error: error,
                        received: activity.received, attempts: attempts, enabled: options.allowsRetry) else { return nil }
                    attempts += 1
                }
            }
            return nil
        }
        self.request = request
        let cfg = configuration ?? URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = options.policy.idleSeconds
        cfg.timeoutIntervalForResource = 15 * 60
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.launch(session.downloadTask(with: request))
            }
        } onCancel: {
            self.lock.withLock { self.cancelled = true; self.currentTask?.cancel() }
        }
    }

    private func launch(_ task: URLSessionDownloadTask) {
        lock.withLock {
            currentTask = task
            if cancelled { task.cancel() } else { task.resume() }
        }
    }
    private func finish(_ data: Data?, _ session: URLSession) {
        guard !finished else { return }
        finished = true
        continuation?.resume(returning: data)
        continuation = nil
        lock.withLock { currentTask = nil }
        session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        progress.received = totalBytesWritten
        progress.expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        if bytesWritten > 0 { progress.lastByteUptime = now }
        if now - lastReportUptime >= 0.2 {
            lastReportUptime = now
            onProgress(progress)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let http = downloadTask.response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let data = try? Data(contentsOf: location), !data.isEmpty else { finish(nil, session); return }
        progress.received = Int64(data.count)
        progress.expected = Int64(data.count)
        progress.complete = true
        onProgress(progress)
        finish(data, session)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if let error, !lock.withLock({ cancelled }),
           ImageTransferPolicy.shouldRetry(error: error, received: progress.received,
               attempts: progress.retryCount, enabled: options.allowsRetry), let request {
            progress.retryCount += 1
            progress.lastByteUptime = ProcessInfo.processInfo.systemUptime
            onProgress(progress)
            let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            launch(resume.map(session.downloadTask(withResumeData:)) ?? session.downloadTask(with: request))
        } else { finish(nil, session) }
    }
}

struct PixivAsyncImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    /// When false, the loading state is a plain placeholder (no spinner) — used
    /// for small images like the author avatar where a spinner reads as "loading"
    /// even though the URL is already known from seeded data.
    var showsProgress: Bool = true
    /// Fill shown behind the image while loading / on failure. Defaults to the
    /// system grouped surface; V3 cards pass their own (e.g. `Theme.v3Surface2`).
    var placeholder: Color = Color(.secondarySystemBackground)

    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            Rectangle().fill(placeholder)
            if let image {
                // Overlay keeps the image layout-neutral: a `.fill` image whose
                // aspect differs from the proposal reports a size LARGER than
                // proposed, which would inflate this view past its container
                // (waterfall cells overflowing their column). The overlay pins
                // the layout size to the proposal; `.clipped()` crops the rest.
                Color.clear
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                    }
                    .transition(.opacity)
            } else if loadFailed {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            } else if showsProgress {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .clipped()
        .task(id: url) {
            guard let url else { image = nil; loadFailed = true; return }
            // Synchronous cache hit: show immediately with no fade — cells
            // scrolling back into view must not re-animate (or flash the
            // placeholder for one runloop turn).
            if let cached = PixivImageCache.shared.image(for: url) {
                image = cached
                loadFailed = false
                return
            }
            image = nil
            loadFailed = false
            if let img = await PixivImageCache.shared.load(url) {
                withAnimation(.easeIn(duration: 0.2)) { image = img }
            } else {
                loadFailed = true
            }
        }
    }
}
