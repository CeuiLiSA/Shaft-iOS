import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Ugoira → animated GIF pipeline for the download manager. Mirrors Shaft's
/// `UgoiraTask` (fetch meta → download zip → unpack frames → encode GIF), but
/// targets the Photo library instead of a SAF/MediaStore file. The intermediate
/// zip/frames live only in memory — the final artifact is a single GIF whose
/// bytes go straight to Photos (which preserves the animation).
enum UgoiraGIF {
    enum UgoiraError: LocalizedError {
        case noZip, noFrames, encodeFailed
        var errorDescription: String? {
            switch self {
            case .noZip:        return "No ugoira zip"
            case .noFrames:     return "No ugoira frames"
            case .encodeFailed: return "GIF encode failed"
            }
        }
    }

    /// One decoded frame: encoded bytes (JPEG/PNG as stored in the zip) + delay.
    struct Frame: Sendable {
        let data: Data
        let delaySeconds: Double
    }

    /// Fetch the manifest, download the zip, and unpack the frames in playback
    /// order. `onPhase` reports coarse progress so the active-list row can show
    /// META / FRAMES while this runs. Pure I/O — safe to call off the main actor.
    static func fetchFrames(
        illustId: Int64,
        api: PixivAPI,
        onPhase: @Sendable @escaping (DownloadItem.UgoiraPhase) -> Void
    ) async throws -> [Frame] {
        onPhase(.meta)
        let meta = try await api.ugoiraMetadata(illustId).ugoiraMetadata
        guard let zipString = meta.zipUrls?.medium ?? meta.zipUrls?.large ?? meta.zipUrls?.original,
              let zipURL = URL(string: zipString) else {
            throw UgoiraError.noZip
        }
        let order: [(file: String, delayMs: Int)] = meta.frames.map {
            ($0.file ?? "", $0.delay ?? 100)
        }
        onPhase(.frames)
        let (data, _) = try await URLSession.shared.data(for: .pixivImage(zipURL))
        let files = try ZipReader.unpackAll(data)
        let frames = order.compactMap { ref -> Frame? in
            guard let bytes = files[ref.file] else { return nil }
            return Frame(data: bytes, delaySeconds: Double(max(ref.delayMs, 10)) / 1000.0)
        }
        guard !frames.isEmpty else { throw UgoiraError.noFrames }
        return frames
    }

    /// Encode ordered frames into a single animated GIF. Runs the (CPU-heavy)
    /// ImageIO encode off the main actor.
    static func encode(_ frames: [Frame]) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let mutable = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                mutable as CFMutableData, UTType.gif.identifier as CFString, frames.count, nil
            ) else { throw UgoiraError.encodeFailed }

            let fileProps: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
            ]
            CGImageDestinationSetProperties(dest, fileProps as CFDictionary)

            for frame in frames {
                guard let src = CGImageSourceCreateWithData(frame.data as CFData, nil),
                      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
                let frameProps: [CFString: Any] = [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFUnclampedDelayTime: frame.delaySeconds,
                        kCGImagePropertyGIFDelayTime: frame.delaySeconds,
                    ]
                ]
                CGImageDestinationAddImage(dest, cg, frameProps as CFDictionary)
            }

            guard CGImageDestinationFinalize(dest) else { throw UgoiraError.encodeFailed }
            return mutable as Data
        }.value
    }
}
