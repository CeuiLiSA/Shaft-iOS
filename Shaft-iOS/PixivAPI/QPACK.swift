import Foundation

/// Minimal QPACK (RFC 9204) + the integer/varint primitives HTTP/3 needs.
///
/// Scope is deliberately tiny — just enough to talk to Cloudflare/pixiv over
/// HTTP/3 (see `Http3Client`):
///   • Encoding requests: every header is a "Literal Field Line with Literal
///     Name", H=0 (no Huffman). Always valid, trivial, no static-table lookups.
///   • Decoding responses: we advertise QPACK dynamic-table capacity 0, so the
///     server encodes with the static table + literals only. We parse the field
///     *structure* by length (so unknown fields are skipped without decoding)
///     and only Huffman-decode the one field we care about — `:status` — whose
///     value is ASCII digits, i.e. the short, unambiguous Huffman codes.
enum QPACK {

    // MARK: Prefixed integers (RFC 7541 §5.1, reused by QPACK)

    /// Decodes an integer whose first `prefixBits` live in the low bits of
    /// `data[pos]`, advancing `pos` past all continuation bytes.
    static func decodeInt(_ data: [UInt8], _ pos: inout Int, prefixBits: Int) -> Int? {
        guard pos < data.count else { return nil }
        let mask = (1 << prefixBits) - 1
        var value = Int(data[pos]) & mask
        pos += 1
        if value < mask { return value }
        var shift = 0
        while pos < data.count {
            let b = data[pos]; pos += 1
            value += Int(b & 0x7f) << shift
            if b & 0x80 == 0 { return value }
            shift += 7
            if shift > 56 { return nil }
        }
        return nil
    }

    /// Encodes `value` with a `prefixBits`-wide prefix, OR-ing the pattern bits
    /// of `firstByte` into the first octet.
    static func encodeInt(_ value: Int, prefixBits: Int, firstByte: UInt8) -> [UInt8] {
        let mask = (1 << prefixBits) - 1
        var out: [UInt8] = []
        if value < mask {
            out.append(firstByte | UInt8(value))
        } else {
            out.append(firstByte | UInt8(mask))
            var v = value - mask
            while v >= 128 { out.append(UInt8(v % 128 + 128)); v /= 128 }
            out.append(UInt8(v))
        }
        return out
    }

    // MARK: QUIC variable-length integers (RFC 9000 §16) — HTTP/3 framing

    static func decodeVarint(_ data: [UInt8], _ pos: inout Int) -> UInt64? {
        guard pos < data.count else { return nil }
        let first = data[pos]
        let len = 1 << Int(first >> 6)          // 1, 2, 4, or 8 bytes
        guard pos + len <= data.count else { return nil }
        var value = UInt64(first & 0x3f)
        for i in 1..<len { value = (value << 8) | UInt64(data[pos + i]) }
        pos += len
        return value
    }

    static func encodeVarint(_ v: UInt64) -> [UInt8] {
        if v <= 63 { return [UInt8(v)] }
        if v <= 16383 { return [UInt8(0x40 | (v >> 8)), UInt8(v & 0xff)] }
        if v <= 1_073_741_823 {
            return [UInt8(0x80 | (v >> 24)), UInt8((v >> 16) & 0xff),
                    UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        }
        return [UInt8(0xc0 | (v >> 56)), UInt8((v >> 48) & 0xff), UInt8((v >> 40) & 0xff),
                UInt8((v >> 32) & 0xff), UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    // MARK: Field section encode (requests)

    /// Encodes a header list as a QPACK field section with no dynamic-table use:
    /// a zeroed prefix (Required Insert Count 0, Base 0) followed by one
    /// literal-name/literal-value line per header.
    static func encodeFieldSection(_ headers: [(String, String)]) -> [UInt8] {
        var out: [UInt8] = [0x00, 0x00]          // RIC = 0, Sign+Base = 0
        for (name, value) in headers {
            let n = Array(name.utf8), v = Array(value.utf8)
            // Literal Field Line w/ Literal Name: bits 001, N=0, H=0; 3-bit name length.
            out += encodeInt(n.count, prefixBits: 3, firstByte: 0x20)
            out += n
            // Value string: H=0, 7-bit length.
            out += encodeInt(v.count, prefixBits: 7, firstByte: 0x00)
            out += v
        }
        return out
    }

    // MARK: Field section decode (responses)

    /// Decodes a response field section enough to recover `:status` and any
    /// plainly-encoded headers. Robust to fields it can't fully decode: each
    /// line's length is known, so unknown/Huffman-only fields are skipped rather
    /// than corrupting the parse.
    static func decodeFieldSection(_ data: [UInt8]) -> (status: Int, headers: [(String, String)]) {
        var pos = 0
        _ = decodeInt(data, &pos, prefixBits: 8)   // Required Insert Count (expect 0)
        _ = decodeInt(data, &pos, prefixBits: 7)   // Delta Base, S bit ignored (expect 0)

        var status = 0
        var headers: [(String, String)] = []

        func readString(prefixBits: Int) -> String? {
            guard pos < data.count else { return nil }
            let huffman = (data[pos] & 0x80) != 0
            guard let len = decodeInt(data, &pos, prefixBits: prefixBits),
                  pos + len <= data.count else { return nil }
            let raw = Array(data[pos ..< pos + len]); pos += len
            return huffman ? Huffman.decode(raw) : String(decoding: raw, as: UTF8.self)
        }

        while pos < data.count {
            let b = data[pos]
            if b & 0x80 != 0 {                      // Indexed Field Line
                let isStatic = (b & 0x40) != 0
                guard let idx = decodeInt(data, &pos, prefixBits: 6) else { break }
                if isStatic, idx < staticTable.count {
                    let entry = staticTable[idx]
                    headers.append(entry)
                    if entry.0 == ":status" { status = Int(entry.1) ?? status }
                }
            } else if b & 0x40 != 0 {               // Literal w/ Name Reference
                let isStatic = (b & 0x10) != 0
                guard let nameIdx = decodeInt(data, &pos, prefixBits: 4) else { break }
                let name = (isStatic && nameIdx < staticTable.count) ? staticTable[nameIdx].0 : ""
                guard let value = readString(prefixBits: 7) else { break }
                headers.append((name, value))
                if name == ":status" { status = Int(value) ?? status }
            } else if b & 0x20 != 0 {               // Literal w/ Literal Name
                let huffName = (b & 0x08) != 0
                guard let nlen = decodeInt(data, &pos, prefixBits: 3),
                      pos + nlen <= data.count else { break }
                let nraw = Array(data[pos ..< pos + nlen]); pos += nlen
                let name = (huffName ? Huffman.decode(nraw) : String(decoding: nraw, as: UTF8.self)) ?? ""
                guard let value = readString(prefixBits: 7) else { break }
                headers.append((name.lowercased(), value))
                if name == ":status" { status = Int(value) ?? status }
            } else {                                 // Post-Base / dynamic — unsupported
                break
            }
        }
        return (status, headers)
    }

    // MARK: QPACK static table (RFC 9204 Appendix A)

    static let staticTable: [(String, String)] = [
        (":authority", ""), (":path", "/"), ("age", "0"), ("content-disposition", ""),
        ("content-length", "0"), ("cookie", ""), ("date", ""), ("etag", ""),
        ("if-modified-since", ""), ("if-none-match", ""), ("last-modified", ""), ("link", ""),
        ("location", ""), ("referer", ""), ("set-cookie", ""), (":method", "CONNECT"),
        (":method", "DELETE"), (":method", "GET"), (":method", "HEAD"), (":method", "OPTIONS"),
        (":method", "POST"), (":method", "PUT"), (":scheme", "http"), (":scheme", "https"),
        (":status", "103"), (":status", "200"), (":status", "304"), (":status", "404"),
        (":status", "503"), ("accept", "*/*"), ("accept", "application/dns-message"),
        ("accept-encoding", "gzip, deflate, br"), ("accept-ranges", "bytes"),
        ("access-control-allow-headers", "cache-control"), ("access-control-allow-headers", "content-type"),
        ("access-control-allow-origin", "*"), ("cache-control", "max-age=0"),
        ("cache-control", "max-age=2592000"), ("cache-control", "max-age=604800"),
        ("cache-control", "no-cache"), ("cache-control", "no-store"),
        ("cache-control", "public, max-age=31536000"), ("content-encoding", "br"),
        ("content-encoding", "gzip"), ("content-type", "application/dns-message"),
        ("content-type", "application/javascript"), ("content-type", "application/json"),
        ("content-type", "application/x-www-form-urlencoded"), ("content-type", "image/gif"),
        ("content-type", "image/jpeg"), ("content-type", "image/png"), ("content-type", "text/css"),
        ("content-type", "text/html; charset=utf-8"), ("content-type", "text/plain"),
        ("content-type", "text/plain;charset=utf-8"), ("range", "bytes=0-"),
        ("strict-transport-security", "max-age=31536000"),
        ("strict-transport-security", "max-age=31536000; includesubdomains"),
        ("strict-transport-security", "max-age=31536000; includesubdomains; preload"),
        ("vary", "accept-encoding"), ("vary", "origin"), ("x-content-type-options", "nosniff"),
        ("x-xss-protection", "1; mode=block"), (":status", "100"), (":status", "204"),
        (":status", "206"), (":status", "302"), (":status", "400"), (":status", "403"),
        (":status", "421"), (":status", "425"), (":status", "500"), ("accept-language", ""),
        ("access-control-allow-credentials", "FALSE"), ("access-control-allow-credentials", "TRUE"),
        ("access-control-allow-headers", "*"), ("access-control-allow-methods", "get"),
        ("access-control-allow-methods", "get, post, options"), ("access-control-allow-methods", "options"),
        ("access-control-expose-headers", "content-length"), ("access-control-request-headers", "content-type"),
        ("access-control-request-method", "get"), ("access-control-request-method", "post"),
        ("alt-svc", "clear"), ("authorization", ""),
        ("content-security-policy", "script-src 'none'; object-src 'none'; base-uri 'none'"),
        ("early-data", "1"), ("expect-ct", ""), ("forwarded", ""), ("if-range", ""), ("origin", ""),
        ("purpose", "prefetch"), ("server", ""), ("timing-allow-origin", "*"),
        ("upgrade-insecure-requests", "1"), ("user-agent", ""), ("x-forwarded-for", ""),
        ("x-frame-options", "deny"), ("x-frame-options", "sameorigin"),
    ]
}

/// HPACK Huffman decoder (RFC 7541 Appendix B). Only the printable-ASCII range
/// (symbols 0–122, which covers digits/letters/common punctuation) is
/// installed — that's all `:status` and other ASCII header values need, and
/// limiting the set keeps the prefix-free lookup free of any transcription
/// ambiguity. Bytes outside it abort the decode gracefully (we never need them).
enum Huffman {
    /// (symbol, code, bit-length) for symbols 0…122.
    private static let codes: [(Int, UInt32, Int)] = [
        (0, 0x1ff8, 13), (1, 0x7fffd8, 23), (2, 0xfffffe2, 28), (3, 0xfffffe3, 28),
        (4, 0xfffffe4, 28), (5, 0xfffffe5, 28), (6, 0xfffffe6, 28), (7, 0xfffffe7, 28),
        (8, 0xfffffe8, 28), (9, 0xffffea, 24), (10, 0x3ffffffc, 30), (11, 0xfffffe9, 28),
        (12, 0xfffffea, 28), (13, 0x3ffffffd, 30), (14, 0xfffffeb, 28), (15, 0xfffffec, 28),
        (16, 0xfffffed, 28), (17, 0xfffffee, 28), (18, 0xfffffef, 28), (19, 0xffffff0, 28),
        (20, 0xffffff1, 28), (21, 0xffffff2, 28), (22, 0x3ffffffe, 30), (23, 0xffffff3, 28),
        (24, 0xffffff4, 28), (25, 0xffffff5, 28), (26, 0xffffff6, 28), (27, 0xffffff7, 28),
        (28, 0xffffff8, 28), (29, 0xffffff9, 28), (30, 0xffffffa, 28), (31, 0xffffffb, 28),
        (32, 0x14, 6), (33, 0x3f8, 10), (34, 0x3f9, 10), (35, 0xffa, 12), (36, 0x1ff9, 13),
        (37, 0x15, 6), (38, 0xf8, 8), (39, 0x7fa, 11), (40, 0x3fa, 10), (41, 0x3fb, 10),
        (42, 0xf9, 8), (43, 0x7fb, 11), (44, 0xfa, 8), (45, 0x16, 6), (46, 0x17, 6),
        (47, 0x18, 6), (48, 0x0, 5), (49, 0x1, 5), (50, 0x2, 5), (51, 0x19, 6), (52, 0x1a, 6),
        (53, 0x1b, 6), (54, 0x1c, 6), (55, 0x1d, 6), (56, 0x1e, 6), (57, 0x1f, 6), (58, 0x5c, 7),
        (59, 0xfb, 8), (60, 0x7ffc, 15), (61, 0x20, 6), (62, 0xffd, 12), (63, 0x7ffd, 15),
        (64, 0x1ffa, 13), (65, 0x21, 6), (66, 0x5d, 7), (67, 0x5e, 7), (68, 0x5f, 7),
        (69, 0x60, 7), (70, 0x61, 7), (71, 0x62, 7), (72, 0x63, 7), (73, 0x64, 7), (74, 0x65, 7),
        (75, 0x66, 7), (76, 0x67, 7), (77, 0x68, 7), (78, 0x69, 7), (79, 0x6a, 7), (80, 0x6b, 7),
        (81, 0x6c, 7), (82, 0x6d, 7), (83, 0x6e, 7), (84, 0x6f, 7), (85, 0x70, 7), (86, 0x71, 7),
        (87, 0x72, 7), (88, 0xfc, 8), (89, 0x73, 7), (90, 0xfd, 8), (91, 0x1ffb, 13),
        (92, 0x7fff0, 19), (93, 0x1ffc, 13), (94, 0x3ffc, 14), (95, 0x22, 6), (96, 0x7ffe, 15),
        (97, 0x3, 5), (98, 0x23, 6), (99, 0x4, 5), (100, 0x24, 6), (101, 0x5, 5), (102, 0x25, 6),
        (103, 0x26, 6), (104, 0x27, 6), (105, 0x6, 5), (106, 0x74, 7), (107, 0x75, 7),
        (108, 0x28, 6), (109, 0x29, 6), (110, 0x2a, 6), (111, 0x7, 5), (112, 0x2b, 6),
        (113, 0x76, 7), (114, 0x2c, 6), (115, 0x8, 5), (116, 0x9, 5), (117, 0x2d, 6),
        (118, 0x77, 7), (119, 0x78, 7), (120, 0x79, 7), (121, 0x7a, 7), (122, 0x7b, 7),
    ]

    /// Per-length code → symbol lookup. Codes are prefix-free, so the shortest
    /// length that matches at the current bit position is the symbol.
    private static let byLength: [Int: [UInt32: Int]] = {
        var m: [Int: [UInt32: Int]] = [:]
        for (sym, code, bits) in codes { m[bits, default: [:]][code] = sym }
        return m
    }()
    private static let lengths: [Int] = byLength.keys.sorted()

    static func decode(_ data: [UInt8]) -> String? {
        var out: [UInt8] = []
        var acc: UInt64 = 0
        var nbits = 0
        for byte in data {
            acc = (acc << 8) | UInt64(byte)
            nbits += 8
            while nbits >= 5 {
                var matched = false
                for len in lengths where len <= nbits {
                    let code = UInt32((acc >> UInt64(nbits - len)) & ((1 << UInt64(len)) - 1))
                    if let sym = byLength[len]?[code] {
                        out.append(UInt8(sym))
                        nbits -= len
                        matched = true
                        break
                    }
                }
                if !matched { break }
            }
            // No code exceeds 30 bits: ≥32 unmatched bits means an undecodable
            // symbol (a char outside the installed 0–122 set). Bail gracefully
            // rather than grow `acc` unbounded / overflow.
            if nbits >= 32 { break }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
