import SwiftUI
import UIKit

@MainActor
@Observable
final class PixivImageCache {
    static let shared = PixivImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession

    init() {
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1024 * 1024  // ~64 MB of decoded images
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.urlCache = nil  // dedup via NSCache; URLCache would double-cache encoded bytes
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    func load(_ url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url.absoluteString as NSString) {
            return cached
        }
        var req = URLRequest(url: url)
        req.setValue("https://app-api.pixiv.net/", forHTTPHeaderField: "Referer")
        req.setValue("PixivIOSApp/7.13.4", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await session.data(for: req)
            guard let img = UIImage(data: data) else { return nil }
            cache.setObject(img, forKey: url.absoluteString as NSString, cost: cost(img, data.count))
            return img
        } catch {
            return nil
        }
    }

    /// Like `load`, but reports download progress (0...1) for the byte stream —
    /// used by the illust detail hero to show a percentage while the full-res
    /// `original` downloads. Cache hits return immediately with no progress.
    func loadWithProgress(_ url: URL, onProgress: @MainActor @escaping (Double) -> Void) async -> UIImage? {
        if let cached = cache.object(forKey: url.absoluteString as NSString) {
            return cached
        }
        var req = URLRequest(url: url)
        req.setValue("https://app-api.pixiv.net/", forHTTPHeaderField: "Referer")
        req.setValue("PixivIOSApp/7.13.4", forHTTPHeaderField: "User-Agent")
        let downloader = ProgressImageDownloader { p in
            Task { @MainActor in onProgress(p) }
        }
        guard let data = await downloader.run(req), let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: url.absoluteString as NSString, cost: cost(img, data.count))
        return img
    }

    private func cost(_ img: UIImage, _ byteCount: Int) -> Int {
        (img.cgImage?.bytesPerRow ?? byteCount) * (img.cgImage?.height ?? 1)
    }
}

/// Delegate-based image download that reports byte progress. Used only for the
/// detail hero's `original` fetch; everything else goes through `load`, whose
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

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
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
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
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
            image = nil
            loadFailed = false
            guard let url else { loadFailed = true; return }
            // Cache hits return synchronously inside the await; the fade keeps
            // first-time loads from popping in harshly.
            if let img = await PixivImageCache.shared.load(url) {
                withAnimation(.easeIn(duration: 0.2)) { image = img }
            } else {
                loadFailed = true
            }
        }
    }
}
