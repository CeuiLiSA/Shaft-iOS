import Foundation

struct ImageTransferPolicy: Equatable, Sendable {
    let idleSeconds: TimeInterval
    let customized: Bool
    init(seconds: Int, directConnect: Bool) {
        let maximum = directConnect ? 30 : 10
        idleSeconds = TimeInterval(seconds < 1 ? maximum : min(seconds, maximum))
        customized = seconds > 0 && seconds < maximum
    }
    static let active = ImageTransferPolicy(
        seconds: UserDefaults.standard.integer(forKey: "st_imageReadTimeoutSeconds"),
        directConnect: DirectConnection.imageDirectConnectAtLaunch)

    static func shouldRetry(error: Error, received: Int64, attempts: Int, enabled: Bool) -> Bool {
        guard enabled, attempts == 0, received > 0 else { return false }
        return (error as? URLError)?.code == .timedOut
            || (error as? Http3Connection.Http3Error) == .timeout
    }
}

struct ImageTransferProgress: Codable, Hashable, Sendable {
    var received: Int64 = 0
    var expected: Int64? = nil
    var lastByteUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    var complete = false
    var retryCount = 0
    var fraction: Double? {
        if complete { return 1 }
        guard let expected, expected > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(expected)))
    }
    func stalledSeconds(now: TimeInterval, threshold: TimeInterval) -> Int? {
        let elapsed = now - lastByteUptime
        return !complete && elapsed >= threshold ? Int(elapsed) : nil
    }
}

/// A download joining an on-screen image may enable that transfer's single retry.
final class ImageTransferOptions: @unchecked Sendable {
    let policy: ImageTransferPolicy
    private let lock = NSLock()
    private var retry: Bool
    private var display: Bool
    init(policy: ImageTransferPolicy = .active, retry: Bool, display: Bool = false) {
        self.policy = policy
        self.retry = retry
        self.display = display
    }
    var allowsRetry: Bool { lock.withLock { retry || (display && UserDefaults.standard.bool(forKey: "st_imageLoadRetryOnStall")) } }
    func enableRetry() { lock.withLock { retry = true } }
    func includeDisplay() { lock.withLock { display = true } }
}

final class TransferActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ImageTransferProgress()
    private var expired = false
    var received: Int64 { lock.withLock { value.received } }
    var timedOut: Bool { lock.withLock { expired } }
    func markTimedOut() { lock.withLock { expired = true } }
    func report(_ progress: ImageTransferProgress) { lock.withLock { value = progress } }
    func idle(now: TimeInterval) -> TimeInterval { lock.withLock { now - value.lastByteUptime } }
}

/// Parses framing incrementally so progress counts DATA bytes rather than QUIC headers.
struct HTTP3TransferProgress {
    private var pending = Data()
    private var type: UInt64?
    private var remaining: UInt64 = 0
    private var headers = Data()
    private(set) var value = ImageTransferProgress()

    mutating func append(_ chunk: Data, now: TimeInterval) throws {
        pending.append(chunk)
        if !chunk.isEmpty { value.lastByteUptime = now }
        while !pending.isEmpty {
            if type == nil {
                guard let first = varint(at: 0), let second = varint(at: first.1) else { return }
                type = first.0
                remaining = second.0
                pending.removeFirst(first.1 + second.1)
                headers.removeAll(keepingCapacity: true)
            }
            let count = Int(min(remaining, UInt64(pending.count)))
            if type == 0 { value.received += Int64(count) }
            if type == 1 {
                guard headers.count + count <= 1024 * 1024 else { throw URLError(.badServerResponse) }
                headers.append(pending.prefix(count))
            }
            pending.removeFirst(count)
            remaining -= UInt64(count)
            if remaining == 0 {
                if type == 1 {
                    let (_, fields) = QPACK.decodeFieldSection(Array(headers))
                    if let expected = fields.first(where: { $0.0.lowercased() == "content-length" }).flatMap({ Int64($0.1) }), expected > 0 {
                        value.expected = expected
                    }
                }
                type = nil
            } else { return }
        }
    }
    var complete: Bool { pending.isEmpty && type == nil }
    private func varint(at offset: Int) -> (UInt64, Int)? {
        guard offset < pending.count else { return nil }
        let index = pending.startIndex + offset
        let first = pending[index]
        let length = 1 << Int(first >> 6)
        guard offset + length <= pending.count else { return nil }
        var value = UInt64(first & 0x3f)
        for i in 1..<length { value = value << 8 | UInt64(pending[index + i]) }
        return (value, length)
    }
}

enum DownloadStartPolicy {
    static func allows(mode: Int, wifi: Bool, manuallyAllowed: Bool, globallyPaused: Bool) -> Bool {
        guard !globallyPaused || manuallyAllowed else { return false }
        return manuallyAllowed || mode == 0 || (mode == 1 && wifi)
    }
}
