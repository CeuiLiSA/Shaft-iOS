import CryptoKit
import ImageIO
import SwiftUI
import UIKit

extension URLRequest {
    /// Request for a pixiv image CDN URL with the Referer/User-Agent pair the
    /// CDN requires — the single place those headers live.
    static func pixivImage(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("https://app-api.pixiv.net/", forHTTPHeaderField: "Referer")
        req.setValue("PixivIOSApp/7.13.4", forHTTPHeaderField: "User-Agent")
        return req
    }
}

@MainActor
final class PixivImageCache {
    static let shared = PixivImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession

    init() {
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1024 * 1024  // ~64 MB of decoded images
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        // Disk-only HTTP cache: cold launches reuse encoded bytes from earlier
        // sessions instead of re-downloading the whole feed. memoryCapacity 0
        // because decoded images already dedup via NSCache — an in-memory
        // URLCache would double-cache the encoded bytes.
        cfg.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 256 * 1024 * 1024)
        // Pixiv CDN image URLs are immutable (content changes get new paths) —
        // serve straight from disk without revalidation round-trips.
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        self.session = URLSession(configuration: cfg)
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    /// Memoized display-sized decode of an original (see `decodeForDisplay`) —
    /// revisiting the same detail page must not re-read disk and re-decode.
    func displayImage(for url: URL) -> UIImage? {
        cache.object(forKey: "display:" + url.absoluteString as NSString)
    }

    func setDisplayImage(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: "display:" + url.absoluteString as NSString,
                        cost: cost(image, 0))
    }

    /// True when the encoded bytes for `url` are already in the disk cache —
    /// callers can skip placeholder work when the real thing is instant.
    nonisolated func hasDiskData(for url: URL) -> Bool {
        FileManager.default.fileExists(atPath: diskURL(for: url).path)
    }

    private var inflightLoads: [URL: Task<UIImage?, Never>] = [:]

    func load(_ url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url.absoluteString as NSString) {
            return cached
        }
        // One download+decode per URL no matter how many cells/pages want it
        // (waterfall cell + detail hero share the same `large` URL).
        if let inflight = inflightLoads[url] {
            return await inflight.value
        }
        let task = Task { [session] () -> UIImage? in
            guard let (data, _) = try? await session.data(for: .pixivImage(url)) else { return nil }
            return await Self.decodeThumbnail(data)
        }
        inflightLoads[url] = task
        let img = await task.value
        inflightLoads.removeValue(forKey: url)
        if let img {
            cache.setObject(img, forKey: url.absoluteString as NSString, cost: cost(img, 0))
        }
        return img
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
    func loadData(_ url: URL,
                  onProgress: @MainActor @escaping (Double) -> Void = { _ in }) async -> Data? {
        let file = diskURL(for: url)
        if let data = try? Data(contentsOf: file, options: .mappedIfSafe) {
            return data
        }

        let download: InflightDataDownload
        if let existing = inflightData[url] {
            download = existing
        } else {
            download = InflightDataDownload()
            inflightData[url] = download
            let req = URLRequest.pixivImage(url)
            // Strong captures: the task → download cycle lasts only until the
            // download finishes; `self` is the long-lived singleton.
            download.task = Task.detached(priority: .userInitiated) { [self, download] in
                let downloader = ProgressImageDownloader { p in
                    Task { @MainActor in download.report(p) }
                }
                let data = await downloader.run(req)
                if let data { try? data.write(to: file) }
                await MainActor.run { _ = inflightData.removeValue(forKey: url) }
                return data
            }
        }

        let observerID = download.addObserver(onProgress)
        let data = await download.task.value
        download.removeObserver(observerID)
        return data
    }

    /// One shared original-bytes download with progress fan-out to every page
    /// that's watching it.
    @MainActor
    private final class InflightDataDownload {
        var task: Task<Data?, Never>!
        private var progress: Double = 0
        private var nextID = 0
        private var observers: [Int: @MainActor (Double) -> Void] = [:]

        func addObserver(_ cb: @MainActor @escaping (Double) -> Void) -> Int {
            let id = nextID
            nextID += 1
            observers[id] = cb
            cb(progress)
            return id
        }

        func removeObserver(_ id: Int) {
            observers.removeValue(forKey: id)
        }

        func report(_ p: Double) {
            progress = p
            for cb in observers.values { cb(p) }
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

/// Delegate-based image download that reports byte progress. Backs `loadData`'s
/// `original` fetches; everything else goes through `load`, whose
/// `URLSession.data` gives no incremental progress. Cancelling the awaiting
/// task cancels the underlying download.
private final class ProgressImageDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Data?, Never>?
    private var finished = false

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func run(_ request: URLRequest) async -> Data? {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.urlCache = nil  // originals persist in our own disk cache
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: request)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                self.continuation = cont
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ data: Data?, _ session: URLSession) {
        guard !finished else { return }
        finished = true
        continuation?.resume(returning: data)
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    /// Last progress forwarded; delegate callbacks arrive per network chunk
    /// (hundreds/sec on fast Wi-Fi) and each forwarded value hops to the main
    /// actor and re-renders SwiftUI — throttle to whole-percent steps.
    private var lastReportedProgress: Double = -1

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        guard p - lastReportedProgress >= 0.01 || p >= 1 else { return }
        lastReportedProgress = p
        onProgress(p)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Must read the temp file synchronously — it's removed when this returns.
        finish(try? Data(contentsOf: location), session)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { finish(nil, session) }
    }
}

struct PixivAsyncImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    /// When false, the loading state is a plain placeholder (no spinner) — used
    /// for small images like the author avatar where a spinner reads as "loading"
    /// even though the URL is already known from seeded data.
    var showsProgress: Bool = true

    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color(.secondarySystemBackground))
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
