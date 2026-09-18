import Foundation
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import ImageIO
import CryptoKit

struct PlazaUploadTicket: Codable, Sendable {
    let mediaId: String
    let objectKey: String
    let method: String
    let uploadUrl: String
    let expiresAt: Double
    let headers: [String: String]
}
struct PlazaMediaObject: Codable, Sendable {
    let mediaId: String
    let width: Int?
    let height: Int?
}
struct PlazaAttachment: Codable, Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let contentType: String
    let size: Int
    let width: Int
    let height: Int
    var mediaId: String?
    var ticket: PlazaUploadTicket?
}

/// File transfers avoid loading nine full-size photo-library images into RAM.
struct PlazaImportedFile: Transferable, Sendable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("plaza-\(UUID()).image")
            try FileManager.default.copyItem(at: received.file, to: url)
            return Self(url: url)
        }
    }
}

enum PlazaPhotoFiles {
    static let maxBytes = 25 * 1024 * 1024
    static func directory(uid: Int64, draft: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("plaza-drafts/\(uid)/\(draft)", isDirectory: true)
    }
    static func importFile(_ source: URL, directory: URL) throws -> PlazaAttachment {
        let values = try source.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0, size <= maxBytes else { throw PlazaFailure(key: "media_size_error") }
        guard let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(image) else { throw PlazaFailure(key: "media_bounds_error") }
        let mime = UTType(type as String)?.preferredMIMEType ?? ""
        guard ["image/jpeg", "image/png", "image/webp", "image/gif"].contains(mime) else {
            throw PlazaFailure(key: "media_type_error")
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 100_000, height <= 100_000 else {
            throw PlazaFailure(key: "media_bounds_error")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID(), name = "\(id).image"
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
        return PlazaAttachment(id: id, fileName: name, contentType: mime, size: size, width: width, height: height)
    }
    static func orientation(of data: Data) -> CGImagePropertyOrientation {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = properties[kCGImagePropertyOrientation] as? UInt32 else { return .up }
        return CGImagePropertyOrientation(rawValue: raw) ?? .up
    }
    static func thumbnail(_ url: URL, pixels: Int = 240) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}

/// The storage session has no API authentication/cookies, including on redirects.
private final class PlazaUploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    init(_ progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { progress(min(0.95, Double(totalBytesSent) / Double(totalBytesExpectedToSend) * 0.95)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct PlazaMediaUploader: Sendable {
    private static let storage: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()
    var api: PlazaAPI = .shared
    var put: @Sendable (URLRequest, URL, @escaping @Sendable (Double) -> Void) async throws -> Void = { request, file, progress in
        let delegate = PlazaUploadProgress(progress)
        let (data, response) = try await storage.upload(for: request, fromFile: file, delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PlazaFailure(key: "media_http_error", status: status, code: String(data: data.prefix(100), encoding: .utf8) ?? "")
        }
    }

    func upload(_ image: PlazaAttachment, directory: URL, uid: Int64,
                saveTicket: @escaping @Sendable (PlazaUploadTicket) async throws -> Void,
                progress: @escaping @Sendable (Double) -> Void) async throws -> PlazaMediaObject {
        let file = directory.appendingPathComponent(image.fileName)
        guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == image.size else {
            throw PlazaFailure(key: "media_changed_error")
        }
        var ticket = image.ticket
        if let old = ticket {
            do {
                let media = try await complete(old, image: image, uid: uid)
                progress(1)
                return media
            } catch let error as PlazaFailure {
                if error.status == 409 && error.code == "media_not_uploaded" && old.expiresAt > plazaNow() + 60_000 {
                    // Resume the same object while its signed PUT is still valid.
                } else if error.status == 404 || error.status == 409 { ticket = nil }
                else { throw error }
            }
        }
        if ticket == nil {
            struct Init: Encodable { let scene = "plaza"; let contentType: String; let size: Int }
            let fresh: PlazaUploadTicket = try await api.request(uid: uid, path: "v1/media/upload/init", method: "POST",
                body: JSONEncoder().encode(Init(contentType: image.contentType, size: image.size)))
            guard fresh.method == "PUT" else { throw PlazaFailure(key: "media_method_error") }
            try await saveTicket(fresh) // Persist before transmitting any bytes.
            ticket = fresh
        }
        guard let ticket, ticket.method == "PUT", let url = URL(string: ticket.uploadUrl),
              url.scheme == "https", url.host != nil else { throw PlazaFailure(key: "media_method_error") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(image.contentType, forHTTPHeaderField: "Content-Type")
        for (key, value) in ticket.headers { request.setValue(value, forHTTPHeaderField: key) }
        try Task.checkCancellation()
        try await put(request, file, progress)
        let media = try await complete(ticket, image: image, uid: uid)
        progress(1)
        return media
    }
    private func complete(_ ticket: PlazaUploadTicket, image: PlazaAttachment, uid: Int64) async throws -> PlazaMediaObject {
        struct Complete: Encodable {
            let mediaId: String; let objectKey: String; let contentType: String
            let size: Int; let width: Int; let height: Int
        }
        let body = Complete(mediaId: ticket.mediaId, objectKey: ticket.objectKey, contentType: image.contentType,
                            size: image.size, width: image.width, height: image.height)
        let media: PlazaMediaObject = try await api.request(uid: uid, path: "v1/media/upload/complete", method: "POST", body: JSONEncoder().encode(body))
        guard media.width == image.width, media.height == image.height else { throw PlazaFailure(key: "media_dimensions_error") }
        return media
    }
}
