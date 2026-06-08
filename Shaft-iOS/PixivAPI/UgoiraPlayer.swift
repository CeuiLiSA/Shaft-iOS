import SwiftUI
import UIKit
import Compression

// MARK: - Decoded animation

/// Decoded ugoira animation: ordered frames with their display durations.
struct UgoiraAnimation: Sendable {
    struct Frame: Sendable {
        let image: UIImage
        let duration: Double  // seconds
    }
    let frames: [Frame]
}

/// One decoded frame as raw bytes + delay — `Sendable` so the heavy
/// download/unzip work can run off the main actor before we make UIImages.
private struct UgoiraFrameData: Sendable {
    let data: Data
    let duration: Double
}

private struct UgoiraFrameRef: Sendable {
    let file: String
    let delayMs: Int
}

// MARK: - Loader

/// Loads + decodes a Pixiv ugoira: fetch the frame manifest, download the
/// zip, unpack each frame, and pair it with its delay. Mirrors Shaft's
/// `FragmentSingleUgora`. Ugoira zips store each frame as an individual image
/// (usually a JPEG stored without compression).
@MainActor
@Observable
final class UgoiraLoader {
    enum LoadState {
        case idle, loading, ready(UgoiraAnimation), failed(String)
    }
    private(set) var state: LoadState = .idle

    @ObservationIgnored private let api: PixivAPI
    @ObservationIgnored private let illustId: Int64

    init(illustId: Int64) {
        self.illustId = illustId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    var isReady: Bool { if case .ready = state { return true } else { return false } }

    func loadIfNeeded() async {
        if case .idle = state { await load() }
    }

    func load() async {
        state = .loading
        do {
            let meta = try await api.ugoiraMetadata(illustId).ugoiraMetadata
            guard let zipString = meta.zipUrls?.medium
                    ?? meta.zipUrls?.large
                    ?? meta.zipUrls?.original,
                  let zipURL = URL(string: zipString) else {
                state = .failed("No ugoira zip")
                return
            }
            let order = meta.frames.map {
                UgoiraFrameRef(file: $0.file ?? "", delayMs: $0.delay ?? 100)
            }
            let frameDatas = try await Task.detached(priority: .userInitiated) {
                try await UgoiraLoader.fetchAndUnpack(zipURL: zipURL, order: order)
            }.value
            let frames = frameDatas.compactMap { fd -> UgoiraAnimation.Frame? in
                guard let img = UIImage(data: fd.data) else { return nil }
                return .init(image: img, duration: fd.duration)
            }
            guard !frames.isEmpty else { state = .failed("No frames"); return }
            state = .ready(UgoiraAnimation(frames: frames))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Download the zip and unpack the frames named in `order`, off the main
    /// actor. Returns frames in playback order.
    private static func fetchAndUnpack(zipURL: URL, order: [UgoiraFrameRef]) async throws -> [UgoiraFrameData] {
        var req = URLRequest(url: zipURL)
        req.setValue("https://app-api.pixiv.net/", forHTTPHeaderField: "Referer")
        req.setValue("PixivIOSApp/7.13.4", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        let files = try ZipReader.unpackAll(data)
        return order.compactMap { ref in
            guard let bytes = files[ref.file] else { return nil }
            return UgoiraFrameData(data: bytes, duration: Double(max(ref.delayMs, 10)) / 1000.0)
        }
    }
}

// MARK: - Minimal in-memory ZIP reader (stored + deflate)

/// Parses a ZIP archive entirely in memory. Reads the central directory once,
/// then slices each entry's data from the local headers. Supports the only
/// two methods ugoira archives use: stored (0) and deflate (8).
enum ZipReader {
    enum ZipError: Error { case notZip, corrupt }

    static func unpackAll(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        guard let eocd = findEOCD(bytes) else { throw ZipError.notZip }
        let cdCount = Int(readU16(bytes, eocd + 10))
        let cdOffset = Int(readU32(bytes, eocd + 16))

        var result: [String: Data] = [:]
        var p = cdOffset
        for _ in 0..<cdCount {
            guard p + 46 <= bytes.count, readU32(bytes, p) == 0x0201_4b50 else { break }
            let method = readU16(bytes, p + 10)
            let compSize = Int(readU32(bytes, p + 20))
            let uncompSize = Int(readU32(bytes, p + 24))
            let nameLen = Int(readU16(bytes, p + 28))
            let extraLen = Int(readU16(bytes, p + 30))
            let commentLen = Int(readU16(bytes, p + 32))
            let localOffset = Int(readU32(bytes, p + 42))
            let nameStart = p + 46
            guard nameStart + nameLen <= bytes.count else { throw ZipError.corrupt }
            let name = String(decoding: bytes[nameStart..<nameStart + nameLen], as: UTF8.self)

            let lh = localOffset
            if lh + 30 <= bytes.count, readU32(bytes, lh) == 0x0403_4b50 {
                let lNameLen = Int(readU16(bytes, lh + 26))
                let lExtraLen = Int(readU16(bytes, lh + 28))
                let dataStart = lh + 30 + lNameLen + lExtraLen
                if dataStart + compSize <= bytes.count {
                    let slice = Data(bytes[dataStart..<dataStart + compSize])
                    if method == 0 {
                        result[name] = slice
                    } else if method == 8, let inflated = inflate(slice, expectedSize: uncompSize) {
                        result[name] = inflated
                    }
                }
            }
            p = nameStart + nameLen + extraLen + commentLen
        }
        return result
    }

    /// Raw DEFLATE (RFC 1951) — Apple's `COMPRESSION_ZLIB` decodes a bare
    /// deflate stream, which is exactly what ZIP method 8 stores.
    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        let capacity = max(expectedSize, data.count * 8, 4096)
        return data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { dst.deallocate() }
            let written = compression_decode_buffer(dst, capacity, srcBase, data.count, nil, COMPRESSION_ZLIB)
            guard written > 0 else { return nil }
            return Data(bytes: dst, count: written)
        }
    }

    private static func readU16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func readU32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    /// Scan backward for the End Of Central Directory signature (0x06054b50).
    private static func findEOCD(_ b: [UInt8]) -> Int? {
        guard b.count >= 22 else { return nil }
        let minStart = max(0, b.count - 22 - 65_536)
        var i = b.count - 22
        while i >= minStart {
            if b[i] == 0x50, b[i + 1] == 0x4b, b[i + 2] == 0x05, b[i + 3] == 0x06 {
                return i
            }
            i -= 1
        }
        return nil
    }
}

// MARK: - Views

/// Loops the decoded frames respecting each frame's delay. Cancels its driver
/// task automatically when it leaves the hierarchy.
struct AnimatedUgoiraView: View {
    let animation: UgoiraAnimation
    var contentMode: ContentMode = .fit

    @State private var index = 0

    var body: some View {
        Image(uiImage: animation.frames[min(index, animation.frames.count - 1)].image)
            .resizable()
            .aspectRatio(contentMode: contentMode)
            .task {
                guard animation.frames.count > 1 else { return }
                while !Task.isCancelled {
                    let dur = animation.frames[min(index, animation.frames.count - 1)].duration
                    try? await Task.sleep(nanoseconds: UInt64(max(dur, 0.01) * 1_000_000_000))
                    if Task.isCancelled { break }
                    index = (index + 1) % animation.frames.count
                }
            }
    }
}

/// Drop-in animated ugoira surface. Shows the static fallback frame while the
/// zip downloads/decodes, then swaps to the looping animation. Falls back to
/// the static image if the manifest or zip can't be loaded.
struct UgoiraView: View {
    let illustId: Int64
    let fallbackURL: URL?
    var contentMode: ContentMode = .fit
    var onTap: () -> Void = {}

    @State private var loader: UgoiraLoader

    init(
        illustId: Int64,
        fallbackURL: URL?,
        contentMode: ContentMode = .fit,
        onTap: @escaping () -> Void = {}
    ) {
        self.illustId = illustId
        self.fallbackURL = fallbackURL
        self.contentMode = contentMode
        self.onTap = onTap
        _loader = State(wrappedValue: UgoiraLoader(illustId: illustId))
    }

    var body: some View {
        ZStack {
            switch loader.state {
            case .ready(let anim):
                AnimatedUgoiraView(animation: anim, contentMode: contentMode)
            default:
                PixivAsyncImage(url: fallbackURL, contentMode: contentMode)
            }

            if case .loading = loader.state {
                ProgressView()
                    .padding(8)
                    .background(.black.opacity(0.35), in: .circle)
            }

            if !loader.isReady {
                Text("UGOIRA")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: .capsule)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
            }
        }
        .contentShape(.rect)
        .onTapGesture { onTap() }
        .task { await loader.loadIfNeeded() }
    }
}
