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
            let cost = (img.cgImage?.bytesPerRow ?? data.count) * (img.cgImage?.height ?? 1)
            cache.setObject(img, forKey: url.absoluteString as NSString, cost: cost)
            return img
        } catch {
            return nil
        }
    }
}

struct PixivAsyncImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color(.secondarySystemBackground))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if loadFailed {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .clipped()
        .task(id: url) {
            image = nil
            loadFailed = false
            guard let url else { loadFailed = true; return }
            if let img = await PixivImageCache.shared.load(url) {
                image = img
            } else {
                loadFailed = true
            }
        }
    }
}
