import SwiftUI
import ImageIO

/// Only a verified local file is accepted; there is deliberately no URL loader.
struct StickerImage: View {
    var id: String
    var resourceSize = 64
    var repository: StickerRepository = .shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        StickerLocalImage(ready: repository.state.ready, id: id, resourceSize: resourceSize,
                          animate: !reduceMotion && scenePhase == .active) { error, generation in
            repository.localFailure(error, generation: generation)
        }
        .task { if case .idle = repository.state { repository.prepare() } }
        .accessibilityHidden(true)
    }
}

private struct StickerLocalImage: UIViewRepresentable {
    let ready: StickerReady?
    let id: String
    let resourceSize: Int
    let animate: Bool
    let failure: (Error, String) -> Void
    func makeUIView(context: Context) -> StickerBitmapView { StickerBitmapView() }
    func updateUIView(_ view: StickerBitmapView, context: Context) {
        view.configure(ready: ready, id: id, size: resourceSize, animate: animate, failure: failure)
    }
    static func dismantleUIView(_ view: StickerBitmapView, coordinator: ()) { view.clear() }
}

/// Visible cells decode one frame ahead. Offscreen views have no playback task.
final class StickerBitmapView: UIImageView {
    private var playback: Task<Void, Never>?
    private var key: String?
    private var local: (URL, URL, String)?
    private var animate = true
    private var failure: ((Error, String) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFit
        tintColor = UIColor(Theme.v3Text2)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { playback?.cancel(); playback = nil; image = nil }
        else { start() }
    }
    func configure(ready: StickerReady?, id: String, size: Int, animate: Bool, failure: @escaping (Error, String) -> Void) {
        let next = ready.map { "\($0.generation):\(id):\(size)" }
        self.failure = failure
        if key == next, self.animate == animate {
            if local == nil { image = UIImage(systemName: "face.smiling") }
            return
        }
        playback?.cancel(); playback = nil; image = nil
        key = next; self.animate = animate
        local = ready.flatMap { value in value.file(id: id, size: size).map { ($0, value.marker, value.generation) } }
        image = UIImage(systemName: "face.smiling")
        start()
    }
    func clear() { playback?.cancel(); playback = nil; key = nil; local = nil; image = nil; failure = nil }
    private func start() {
        guard window != nil, playback == nil, let key, let (file, marker, generation) = local else { return }
        let animated = animate
        playback = Task { [weak self] in
            do {
                try await StickerDecoder.shared.validate(file: file, marker: marker, generation: generation)
                var index = 0
                while !Task.isCancelled {
                    let frame = try await StickerDecoder.shared.frame(file: file, key: key, index: index)
                    try Task.checkCancellation()
                    guard self?.key == key else { return }
                    self?.image = frame.image
                    if !animated || frame.count <= 1 { return }
                    index = (index + 1) % frame.count
                    try await Task.sleep(for: .seconds(frame.duration))
                }
            } catch is CancellationError { }
            catch { if self?.key == key { self?.failure?(error, generation) } }
        }
    }
}

actor StickerDecoder {
    static let shared = StickerDecoder()
    private final class Source {
        let value: CGImageSource
        init(_ value: CGImageSource) { self.value = value }
    }
    final class Frame: @unchecked Sendable {
        let image: UIImage
        let count: Int
        let duration: Double
        init(image: UIImage, count: Int, duration: Double) { self.image = image; self.count = count; self.duration = duration }
    }
    private let sources = NSCache<NSString, Source>()
    private let frames = NSCache<NSString, Frame>()
    init() { sources.countLimit = 80; frames.totalCostLimit = 24 * 1024 * 1024 }

    func validate(file: URL, marker: URL, generation: String) throws {
        guard file.isFileURL, try String(contentsOf: marker, encoding: .utf8) == generation,
              try StickerStore.Identity(file).size > 0 else { throw StickerFailure.missingFile }
    }
    func frame(file: URL, key: String, index: Int) throws -> Frame {
        let cacheKey = "\(key):\(index)" as NSString
        if let frame = frames.object(forKey: cacheKey) { return frame }
        let source: CGImageSource
        if let cached = sources.object(forKey: key as NSString) { source = cached.value }
        else {
            guard file.isFileURL, let opened = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw StickerFailure.missingFile
            }
            source = opened; sources.setObject(Source(source), forKey: key as NSString)
        }
        let count = CGImageSourceGetCount(source)
        guard count > index, let image = CGImageSourceCreateImageAtIndex(source, index,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw StickerFailure.archive }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
        var delay = 0.1
        for key in ["{WebP}", "{GIF}", "{PNG}"] {
            if let values = properties[key] as? [String: Any],
               let value = (values["UnclampedDelayTime"] ?? values["DelayTime"]) as? Double, value > 0 {
                delay = value; break
            }
        }
        let frame = Frame(image: UIImage(cgImage: image), count: count, duration: max(0.02, delay))
        frames.setObject(frame, forKey: cacheKey, cost: image.bytesPerRow * image.height)
        return frame
    }
}
