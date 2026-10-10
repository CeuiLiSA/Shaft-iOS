import Foundation
import CryptoKit
import UIKit

struct WebDAVRemoteBackup: Identifiable, Equatable, Sendable {
    let name: String
    let size: Int64
    let date: Date
    let device: String
    let deviceID: String?
    var id: String { name }
}

enum WebDAVBackupFiles {
    static let keepPerDevice = 10
    private static let pattern = try! NSRegularExpression(pattern: #"^Shaft-Backup_(\d{8}T\d{6}(?:\d{3})?Z)_(.+?)(?:_([0-9a-f]{32}))?\.json\.gz$"#)
    private static func formatter(milliseconds: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = milliseconds ? "yyyyMMdd'T'HHmmssSSS'Z'" : "yyyyMMdd'T'HHmmss'Z'"
        formatter.isLenient = false
        return formatter
    }
    static func name(date: Date, device: String, deviceID: String) -> String {
        let safe = device.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(32)
        return "Shaft-Backup_\(formatter(milliseconds: true).string(from: date))_\(safe.isEmpty ? "iOS" : String(safe))_\(deviceID).json.gz"
    }
    static func parse(_ entry: WebDAVEntry) -> WebDAVRemoteBackup? {
        let string = entry.name as NSString
        guard let match = pattern.firstMatch(in: entry.name, range: NSRange(location: 0, length: string.length)) else { return nil }
        let timestamp = string.substring(with: match.range(at: 1))
        guard let date = formatter(milliseconds: timestamp.count == 19).date(from: timestamp) else { return nil }
        let owner = match.range(at: 3).location == NSNotFound ? nil : string.substring(with: match.range(at: 3))
        return .init(name: entry.name, size: entry.size, date: date, device: string.substring(with: match.range(at: 2)), deviceID: owner)
    }
    static func stale(_ entries: [WebDAVEntry], deviceID: String) -> [WebDAVRemoteBackup] {
        Array(entries.compactMap(parse).filter { $0.deviceID == deviceID }.sorted { $0.date > $1.date }.dropFirst(keepPerDevice))
    }
}

/// A single serialization gate covers local and remote restore, manual backup
/// and background backup. Awaiting a network response doesn't release this gate.
actor WebDAVBackupService {
    static let shared = WebDAVBackupService()
    enum Result: Sendable { case uploaded(String, Int64), unchanged }
    private let preferencesOverride: WebDAVPreferences?
    init(preferences: WebDAVPreferences? = nil) { preferencesOverride = preferences }
    private var busy = false
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, Error> }
    private var waiters: [Waiter] = []
    private func acquire() async throws {
        try Task.checkCancellation()
        guard busy else { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: { Task { await self.cancelWaiter(id) } }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().continuation.resume(returning: ()) }
    }

    func backup(config: WebDAVConfig, includeHistory: Bool, skipUnchanged: Bool, unmeteredOnly: Bool = false) async throws -> Result {
        try await acquire(); defer { release() }
        try Task.checkCancellation()
        let preferences = await MainActor.run { preferencesOverride ?? WebDAVPreferences.shared }
        let client = try WebDAVClient(config: config, unmeteredOnly: unmeteredOnly)
        let backup = try await ShaftBackupBridge.snapshot(includeHistory: includeHistory)
        let json = try ShaftBackupCodec.encode(backup)
        let digest = SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
        if skipUnchanged, let previous = await preferences.lastUpload(for: config), previous.digest == digest,
           try await client.list().contains(where: { $0.name == previous.name }) { return .unchanged }
        try Task.checkCancellation()
        let id = try await preferences.deviceID()
        let device = await MainActor.run { UIDevice.current.model }
        let name = WebDAVBackupFiles.name(date: Date(), device: device, deviceID: id)
        let data = try ShaftBackupCodec.compressed(json)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json.gz")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file, options: .atomic)
        try await client.ensureFolder()
        try Task.checkCancellation()
        try await client.upload(name: name, file: file)
        try await preferences.record(upload: .init(digest: digest, name: name), config: config)
        try await preferences.record(run: .init(time: Date(), success: true, message: name), config: config)
        // Cleanup failure cannot turn a verified upload into a reported failure.
        do {
            for stale in WebDAVBackupFiles.stale(try await client.list(), deviceID: id) {
                try Task.checkCancellation()
                try await client.delete(name: stale.name)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { /* Retention is retried after the next successful upload. */ }
        return .uploaded(name, Int64(data.count))
    }

    func list(config: WebDAVConfig) async throws -> [WebDAVRemoteBackup] {
        try await WebDAVClient(config: config).list().compactMap(WebDAVBackupFiles.parse).sorted { $0.date > $1.date }
    }

    func restore(config: WebDAVConfig, name: String) async throws {
        try await acquire(); defer { release() }
        try Task.checkCancellation()
        let file = try await WebDAVClient(config: config).download(name: name)
        defer { try? FileManager.default.removeItem(at: file) }
        let prepared = try ShaftBackupBridge.prepare(ShaftBackupCodec.decode(Data(contentsOf: file, options: .mappedIfSafe)))
        try Task.checkCancellation()
        try await MainActor.run { try Task.checkCancellation(); ShaftBackupBridge.apply(prepared) }
    }

    func localExport(includeHistory: Bool) async throws -> Data {
        try await acquire(); defer { release() }
        try Task.checkCancellation()
        let backup = try await ShaftBackupBridge.snapshot(includeHistory: includeHistory)
        return try ShaftBackupCodec.compressed(ShaftBackupCodec.encode(backup))
    }

    func localRestore(file: URL) async throws {
        try await acquire(); defer { release() }
        try Task.checkCancellation()
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() } }
        let prepared = try ShaftBackupBridge.prepare(ShaftBackupCodec.decode(Data(contentsOf: file, options: .mappedIfSafe)))
        try Task.checkCancellation()
        try await MainActor.run { try Task.checkCancellation(); ShaftBackupBridge.apply(prepared) }
    }
}
