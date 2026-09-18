import Foundation
import zlib

/// Bounded ZIP reader for the installed sticker packs. Delivers one file at a time;
/// never holds the archive's entire expanded contents in memory.
enum StickerArchive {
    struct FileRecord: Codable, Equatable, Sendable {
        let path: String
        let size: Int64
        let crc: UInt32
    }
    static let maxFileBytes = 16 * 1024 * 1024
    static let maxExpandedBytes = 512 * 1024 * 1024

    static func safeChild(_ root: URL, _ path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              !parts.contains(".."), !parts.contains("."), !parts.dropLast().contains("") else {
            throw StickerFailure.unsafePath
        }
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
            throw StickerFailure.unsafePath
        }
        return file
    }

    static func crc(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { bytes in
            UInt32(crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)))
        }
    }

    static func extract(_ data: Data, to root: URL) throws -> [FileRecord] {
        func u16(_ p: Int) throws -> Int {
            guard p >= 0, p + 2 <= data.count else { throw StickerFailure.archive }
            return Int(data[p]) | Int(data[p + 1]) << 8
        }
        func u32(_ p: Int) throws -> Int { try u16(p) | (u16(p + 2) << 16) }
        guard data.count >= 22 else { throw StickerFailure.archive }
        let end = stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1).first {
            (try? u32($0)) == 0x06054b50 && (try? u16($0 + 20)) == data.count - $0 - 22
        }
        guard let end, try u16(end + 4) == 0, try u16(end + 6) == 0 else { throw StickerFailure.archive }
        let count = try u16(end + 10), directorySize = try u32(end + 12), directory = try u32(end + 16)
        guard (1...50_000).contains(count), try u16(end + 8) == count,
              directory + directorySize == end else { throw StickerFailure.archive }
        var offset = directory, expanded = 0, seen = Set<String>(), records: [FileRecord] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            guard offset + 46 <= end, try u32(offset) == 0x02014b50 else { throw StickerFailure.archive }
            let flags = try u16(offset + 8), method = try u16(offset + 10)
            let expectedCRC = try u32(offset + 16), packed = try u32(offset + 20), size = try u32(offset + 24)
            let nameLength = try u16(offset + 28), extra = try u16(offset + 30), comment = try u16(offset + 32)
            let attributes = try u32(offset + 38), local = try u32(offset + 42)
            let next = offset + 46 + nameLength + extra + comment
            guard next <= end, flags & 1 == 0, [0, 8].contains(method),
                  try u16(offset + 34) == 0,
                  (attributes >> 16) & 0xF000 != 0xA000,
                  size <= maxFileBytes, expanded + size <= maxExpandedBytes,
                  let name = String(data: data.subdata(in: offset + 46..<offset + 46 + nameLength), encoding: .utf8),
                  seen.insert(name).inserted else { throw StickerFailure.archive }
            let target = try safeChild(root, name)
            guard local + 30 <= directory, try u32(local) == 0x04034b50,
                  try u16(local + 6) == flags, try u16(local + 8) == method else { throw StickerFailure.archive }
            let localNameLength = try u16(local + 26), localExtra = try u16(local + 28)
            let start = local + 30 + localNameLength + localExtra
            guard start + packed <= directory,
                  localNameLength == nameLength,
                  data.subdata(in: local + 30..<local + 30 + localNameLength) == Data(name.utf8) else {
                throw StickerFailure.archive
            }
            expanded += size
            offset = next
            if name.hasSuffix("/") {
                guard size == 0 else { throw StickerFailure.archive }
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            let input = data.subdata(in: start..<start + packed)
            let output: Data
            if method == 0 { output = input }
            else { output = try inflate(input, size: size) }
            guard output.count == size, crc(output) == UInt32(expectedCRC) else { throw StickerFailure.checksum }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try output.write(to: target, options: .atomic)
            records.append(.init(path: name, size: Int64(size), crc: UInt32(expectedCRC)))
        }
        guard offset == end, !records.isEmpty else { throw StickerFailure.archive }
        return records
    }

    private static func inflate(_ input: Data, size: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw StickerFailure.archive
        }
        defer { inflateEnd(&stream) }
        // An extra byte lets zlib consume the end marker for exact-sized payloads.
        var output = Data(count: size + 1)
        let result = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(size + 1)
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END, stream.total_out == size, stream.total_in == input.count else {
            throw StickerFailure.archive
        }
        output.count = size
        return output
    }
}
