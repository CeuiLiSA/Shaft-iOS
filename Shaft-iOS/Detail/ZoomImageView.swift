import SwiftUI
import UIKit
import ImageIO

/// Multi-level tile decoder for one encoded image (JPEG/PNG bytes) — the iOS
/// counterpart of zoomimage's subsampling engine on Android. A small base
/// bitmap paints the whole image immediately; zoomed-in regions decode on
/// demand per tile, so arbitrarily large originals stay memory-bounded.
final class TileImageSource: @unchecked Sendable {
    /// Full-resolution pixel dimensions.
    let imageSize: CGSize
    /// Small whole-image bitmap shown underneath the tiles while they decode.
    let baseImage: UIImage
    /// Levels of detail: 0 = 1:1 pixels, each level halves the resolution.
    let levelCount: Int

    private let source: CGImageSource
    private let lock = NSLock()                    // guards the dictionaries only
    private var wholeLevels: [Int: CGImage] = [:]
    private var lazyLevels: [Int: CGImage] = [:]
    private var levelDecodeLocks: [Int: NSLock] = [:]

    /// Levels above this pixel count are never decoded whole; their tiles
    /// crop-decode from a deferred CGImage instead.
    private static let wholeLevelPixelLimit = 12_000_000
    private static let baseMaxPixel = 1536

    static func make(data: Data) async -> TileImageSource? {
        await Task.detached(priority: .userInitiated) { TileImageSource(data: data) }.value
    }

    init?(data: Data) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0
        else { return nil }
        source = src
        imageSize = CGSize(width: w, height: h)

        var levels = 1
        while (max(w, h) >> (levels - 1)) > Self.baseMaxPixel { levels += 1 }
        levelCount = levels

        let baseOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.baseMaxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let base = CGImageSourceCreateThumbnailAtIndex(src, 0, baseOpts as CFDictionary) else {
            return nil
        }
        baseImage = UIImage(cgImage: base)
    }

    /// Draws the tile covering `rect` (full-resolution pixel coordinates).
    /// `scale` is the context's CTM scale — rendered points per image pixel.
    func draw(rect: CGRect, scale: CGFloat, in ctx: CGContext) {
        let level = levelIndex(for: scale)
        if let whole = wholeImage(at: level) {
            ctx.saveGState()
            ctx.clip(to: rect)
            UIImage(cgImage: whole).draw(in: CGRect(origin: .zero, size: imageSize))
            ctx.restoreGState()
        } else if let lazy = lazyImage(at: level) {
            let sx = CGFloat(lazy.width) / imageSize.width
            let sy = CGFloat(lazy.height) / imageSize.height
            let crop = CGRect(x: rect.minX * sx, y: rect.minY * sy,
                              width: rect.width * sx, height: rect.height * sy)
                .integral
                .intersection(CGRect(x: 0, y: 0, width: lazy.width, height: lazy.height))
            guard !crop.isEmpty, let tile = lazy.cropping(to: crop) else { return }
            let drawRect = CGRect(x: crop.minX / sx, y: crop.minY / sy,
                                  width: crop.width / sx, height: crop.height / sy)
            UIImage(cgImage: tile).draw(in: drawRect)
        }
    }

    private func levelIndex(for scale: CGFloat) -> Int {
        guard scale > 0, scale < 1 else { return 0 }
        let level = Int(floor(log2(1 / scale)))
        return min(max(level, 0), levelCount - 1)
    }

    private func wholeImage(at level: Int) -> CGImage? {
        let w = Int(imageSize.width) >> level
        let h = Int(imageSize.height) >> level
        guard w * h <= Self.wholeLevelPixelLimit else { return nil }

        lock.lock()
        if let cached = wholeLevels[level] {
            lock.unlock()
            return cached
        }
        let levelLock: NSLock
        if let existing = levelDecodeLocks[level] {
            levelLock = existing
        } else {
            levelLock = NSLock()
            levelDecodeLocks[level] = levelLock
        }
        lock.unlock()

        // Decode under a per-level lock: CATiledLayer's concurrent tile threads
        // working on OTHER levels proceed; threads needing THIS level wait here
        // instead of decoding the same bitmap twice.
        levelLock.lock(); defer { levelLock.unlock() }
        lock.lock()
        if let cached = wholeLevels[level] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            return nil
        }
        lock.lock()
        wholeLevels[level] = img
        lock.unlock()
        return img
    }

    private func lazyImage(at level: Int) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let cached = lazyLevels[level] { return cached }
        // Subsampled deferred decode: JPEG/HEIF honor the factor so each tile
        // crop decodes only its region; PNG ignores it and falls back to a
        // full-size lazy image (slower per tile, still memory-bounded).
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceSubsampleFactor: 1 << level,
        ]
        guard let img = CGImageSourceCreateImageAtIndex(source, 0, opts as CFDictionary) else {
            return nil
        }
        lazyLevels[level] = img
        return img
    }
}

/// CATiledLayer-backed view sized to the image's full pixel dimensions
/// (1 point = 1 pixel); the scroll view's zoom maps it onto the screen.
private final class TilingView: UIView {
    private let source: TileImageSource

    override class var layerClass: AnyClass { CATiledLayer.self }

    init(source: TileImageSource) {
        self.source = source
        super.init(frame: CGRect(origin: .zero, size: source.imageSize))
        let tiled = layer as! CATiledLayer
        tiled.levelsOfDetail = source.levelCount
        tiled.levelsOfDetailBias = 2
        tiled.tileSize = CGSize(width: 768, height: 768)
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Keep the layer at 1x so the CTM scale in draw(_:) equals the LOD scale.
    override var contentScaleFactor: CGFloat {
        didSet { super.contentScaleFactor = 1 }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        source.draw(rect: rect, scale: ctx.ctm.a, in: ctx)
    }
}

/// UIScrollView that hosts the tiled image: pinch zoom between fit and past
/// 1:1 pixels, double-tap to the medium scale at the tap point, single tap
/// reported out (toolbar toggle), and zoomimage-style read mode — long images
/// start filling the width from the top instead of letterboxed.
final class ZoomImageScrollViewImpl: UIScrollView, UIScrollViewDelegate {
    var onSingleTap: (() -> Void)?

    private let imageSize: CGSize
    private let container: UIView
    private var lastLayoutSize: CGSize = .zero
    private var mediumScale: CGFloat = 1

    init(source: TileImageSource) {
        imageSize = source.imageSize
        container = UIView(frame: CGRect(origin: .zero, size: source.imageSize))
        super.init(frame: .zero)

        let base = UIImageView(image: source.baseImage)
        base.frame = container.bounds
        base.contentMode = .scaleToFill
        container.addSubview(base)
        container.addSubview(TilingView(source: source))
        addSubview(container)
        contentSize = imageSize

        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastLayoutSize, bounds.width > 0, bounds.height > 0 {
            let isFirstLayout = lastLayoutSize == .zero
            let wasAtMin = abs(zoomScale - minimumZoomScale) < 0.001
            lastLayoutSize = bounds.size
            configureScales(isFirstLayout: isFirstLayout, wasAtMin: wasAtMin)
        }
        centerContent()
    }

    private func configureScales(isFirstLayout: Bool, wasAtMin: Bool) {
        let fit = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let fill = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        mediumScale = max(fit * 2.5, fill)
        minimumZoomScale = fit
        // 1.0 = one image pixel per point — already past 100% on Retina; allow 2x beyond.
        maximumZoomScale = max(mediumScale * 2, 2.0)

        if isFirstLayout {
            // Read mode: a long strip starts filling the screen from its top
            // left corner; everything else starts fitted.
            if fill / fit >= 2.2 {
                setZoomScale(fill, animated: false)
                contentOffset = .zero
            } else {
                setZoomScale(fit, animated: false)
            }
        } else if wasAtMin {
            setZoomScale(fit, animated: false)
        } else {
            zoomScale = min(max(zoomScale, minimumZoomScale), maximumZoomScale)
        }
    }

    private func centerContent() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { container }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale < mediumScale - 0.001 {
            let point = recognizer.location(in: container)
            let w = bounds.width / mediumScale
            let h = bounds.height / mediumScale
            zoom(to: CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h),
                 animated: true)
        } else {
            setZoomScale(minimumZoomScale, animated: true)
        }
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }
}

struct ZoomImageScrollView: UIViewRepresentable {
    let source: TileImageSource
    var onSingleTap: () -> Void

    func makeUIView(context: Context) -> ZoomImageScrollViewImpl {
        ZoomImageScrollViewImpl(source: source)
    }

    func updateUIView(_ uiView: ZoomImageScrollViewImpl, context: Context) {
        uiView.onSingleTap = onSingleTap
    }
}

/// One viewer page: paints the already-cached `large` immediately, downloads
/// the `original` bytes with a progress ring, then swaps in the tiled zoom
/// view. Mirrors Shaft `FragmentImageDetail`'s large-placeholder → original
/// progression.
struct ZoomImagePage: View {
    let large: URL?
    let original: URL?
    var onSingleTap: () -> Void = {}

    @State private var source: TileImageSource?
    @State private var placeholder: UIImage?
    @State private var progress: Double = 0
    @State private var failed = false

    var body: some View {
        ZStack {
            if let source {
                ZoomImageScrollView(source: source, onSingleTap: onSingleTap)
                    .ignoresSafeArea()
            } else {
                if let placeholder {
                    Image(uiImage: placeholder)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if failed {
                    Button {
                        Task { await load() }
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise")
                                .font(.title2)
                            Image(systemName: "photo")
                                .font(.largeTitle)
                        }
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(16)
                        .background(.black.opacity(0.4), in: .rect(cornerRadius: 12))
                    }
                } else {
                    ZStack {
                        ProgressRing(progress: progress, lineWidth: 4, track: .white.opacity(0.2))
                        Text("\(Int(progress * 100))%")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    }
                    .frame(width: 56, height: 56)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: placeholder == nil ? .center : .bottomTrailing)
                    .padding(placeholder == nil ? 0 : 24)
                }
            }
        }
        .task(id: original) { await load() }
    }

    private func load() async {
        failed = false
        progress = 0
        guard let original else {
            failed = true
            return
        }
        // 秒显 large：内存缓存命中立即出图（瀑布流/一级详情已加载过）；
        // 未命中且 original 不在磁盘缓存时才并行拉取——original 秒开的场景
        // 没必要为一闪而过的占位图花一次网络请求。
        if source == nil, placeholder == nil, let large {
            if let cached = PixivImageCache.shared.image(for: large) {
                placeholder = cached
            } else if !PixivImageCache.shared.hasDiskData(for: original) {
                Task {
                    if let img = await PixivImageCache.shared.load(large), source == nil {
                        placeholder = img
                    }
                }
            }
        }
        guard let data = await PixivImageCache.shared.loadData(original, onProgress: { progress = $0 }),
              let made = await TileImageSource.make(data: data)
        else {
            failed = true
            return
        }
        source = made
    }
}
