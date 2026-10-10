import Foundation
import zlib
import CoreFoundation

enum BackupValue: Codable, Equatable, Sendable {
    case null, bool(Bool), integer(Int64), decimal(Double), string(String)
    case array([BackupValue]), object([String: BackupValue])
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Int64.self) { self = .integer(v) }
        else if let v = try? value.decode(Double.self) { self = .decimal(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([BackupValue].self) { self = .array(v) }
        else { self = .object(try value.decode([String: BackupValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let v): try value.encode(v)
        case .integer(let v): try value.encode(v)
        case .decimal(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        }
    }
    var text: String? { if case .string(let v) = self { return v }; return nil }
    var number: Int64? { if case .integer(let v) = self { return v }; return nil }
    var boolean: Bool? { if case .bool(let v) = self { return v }; return nil }
    var object: [String: BackupValue]? { if case .object(let v) = self { return v }; return nil }
    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .integer(let v): return v
        case .decimal(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(\.foundation)
        case .object(let v): return v.mapValues(\.foundation)
        }
    }
    static func propertyList(_ value: Any) -> Self? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let type = String(cString: number.objCType)
            return ["f", "d"].contains(type) ? .decimal(number.doubleValue) : .integer(number.int64Value)
        }
        if let string = value as? String { return .string(string) }
        if let array = value as? [Any] {
            let values = array.compactMap(propertyList)
            return values.count == array.count ? .array(values) : nil
        }
        return nil
    }
}

struct BackupMuteRow: Codable, Equatable, Sendable {
    let id: Int64
    let tagJson: String?
    let searchTime: Int64?
    let type: Int
}
struct BackupSearchRow: Codable, Equatable, Sendable {
    let id: Int32?
    let keyword: String?
    let searchTime: Int64?
    let searchType: Int?
    let pinned: Bool?
    let previewIllustsJson: String?
}
struct BackupHistoryRow: Codable, Equatable, Sendable {
    let illustID: Int64
    let illustJson: String?
    let time: Int64?
    let type: Int?
}

/// The Android field names are retained. Native-only data is namespaced; login
/// accounts and credentials have no field in this type and cannot be re-exported.
struct ShaftBackup: Codable, Sendable {
    var deviceLocalSettings: Bool? = true
    var settings: [String: BackupValue]?
    var muteEntityList: [BackupMuteRow]?
    var searchEntityList: [BackupSearchRow]?
    var illustHistoryEntityList: [BackupHistoryRow]?
    var pinnedUserEntityList: [BackupValue]?
    var downloadConfigV3: String?
    var shaftIOS: Native?

    struct Native: Codable, Sendable {
        var version: Int?
        var settings: [String: BackupValue]?
        var history: [HistoryStore.Entry]?
    }
    var hasPayload: Bool {
        settings != nil || muteEntityList != nil || searchEntityList != nil || illustHistoryEntityList != nil
            || pinnedUserEntityList != nil || downloadConfigV3 != nil || shaftIOS != nil
    }
}

enum ShaftBackupError: Error, LocalizedError {
    case invalid, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalid: return "Invalid or incomplete Shaft backup"
        case .tooLarge: return "Backup exceeds the supported size"
        }
    }
}

enum ShaftBackupCodec {
    static let maxExpandedBytes = 128 * 1024 * 1024
    static func encoder() -> JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
    static func encode(_ backup: ShaftBackup) throws -> Data { try encoder().encode(backup) }
    static func decode(_ data: Data) throws -> ShaftBackup {
        let bytes = try decompressed(data)
        let backup = try JSONDecoder().decode(ShaftBackup.self, from: bytes)
        guard backup.hasPayload, (backup.shaftIOS?.version ?? 1) <= 1 else { throw ShaftBackupError.invalid }
        return backup
    }

    /// UTF-16 hashing, including supplementary characters, matches Java String.hashCode.
    static func javaHash(_ value: String) -> Int32 {
        value.utf16.reduce(Int32(0)) { ($0 &* 31) &+ Int32($1) }
    }

    static func compressed(_ data: Data) throws -> Data { try gzip(data, compress: true) }
    static func decompressed(_ data: Data) throws -> Data {
        if data.starts(with: [0x1f, 0x8b]) { return try gzip(data, compress: false) }
        guard data.count <= maxExpandedBytes else { throw ShaftBackupError.tooLarge }
        return data
    }
    private static func gzip(_ data: Data, compress: Bool) throws -> Data {
        guard data.count <= maxExpandedBytes else { throw ShaftBackupError.tooLarge }
        var stream = z_stream()
        let initialized = compress
            ? deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            : inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw ShaftBackupError.invalid }
        defer { if compress { deflateEnd(&stream) } else { inflateEnd(&stream) } }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let status = buffer.withUnsafeMutableBytes { bytes -> Int32 in
                    stream.next_out = bytes.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(bytes.count)
                    return compress ? deflate(&stream, Z_FINISH) : inflate(&stream, Z_NO_FLUSH)
                }
                let count = buffer.count - Int(stream.avail_out)
                guard output.count + count <= maxExpandedBytes else { throw ShaftBackupError.tooLarge }
                output.append(contentsOf: buffer.prefix(count))
                if status == Z_STREAM_END {
                    // zlib validates the gzip CRC and length. Reject trailing
                    // streams/bytes rather than applying an incomplete prefix.
                    guard stream.avail_in == 0 else { throw ShaftBackupError.invalid }
                    return output
                }
                guard status == Z_OK, count > 0 || stream.avail_in > 0 else { throw ShaftBackupError.invalid }
            }
        }
    }
}
