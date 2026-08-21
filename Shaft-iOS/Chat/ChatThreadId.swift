import Foundation

/// Swift port of Pixiv-Shaft `ceui.pixiv.chat.api.ChatThreadId`, which is itself
/// a bit-exact port of shaft-api-v2 `src/chat/threadId.js` / weaver
/// `utils.ReverseXOR`.
///
/// Two `uint64` pixiv uids derive one symmetric, deterministic `uint64` thread
/// id without a server-assigned room number — client A and client B compute the
/// same id independently.
///
/// ## Algorithm
/// 1. sort: `v1 = min(m,n)`, `v2 = max(m,n)` — guarantees `f(a,b) == f(b,a)`
/// 2. encode v1, v2 to 8-byte big-endian buffers
/// 3. `b1[i] ^= b2[7 - i]` — XOR with the byte-reversed counterpart
/// 4. decode b1 as big-endian uint64
///
/// Sanity check: `oneOnOneThreadId(1, 2) == "144115188075855873"` (`0x0200_0000_0000_0001`).
///
/// Swift uses `UInt64` throughout where Kotlin had to fake unsigned math on
/// `Long` — the bit pattern is identical, the code is just shorter.
enum ChatThreadId {

    /// Server's literal `room_id` for the public broadcast room.
    static let roomGlobal = "global"

    /// Bit-exact port of weaver `utils.ReverseXOR(m, n)`.
    static func reverseXOR(_ uidA: UInt64, _ uidB: UInt64) -> UInt64 {
        let v1 = min(uidA, uidB)
        let v2 = max(uidA, uidB)
        var b1 = (0..<8).map { UInt8(truncatingIfNeeded: v1 >> UInt64((7 - $0) * 8)) }
        let b2 = (0..<8).map { UInt8(truncatingIfNeeded: v2 >> UInt64((7 - $0) * 8)) }
        for i in 0..<8 { b1[i] ^= b2[7 - i] }
        return b1.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// 1v1 chat room id for two pixiv uids, as a uint64 decimal string — drops
    /// straight into `?room=<threadId>`.
    ///
    /// Returns `nil` when both uids are equal: self-chat is rejected at the
    /// server (`self_chat_not_allowed`), so failing here saves a round trip.
    /// (Kotlin threw; a Swift optional keeps call sites from needing `try`.)
    static func oneOnOneThreadId(_ uidA: Int64, _ uidB: Int64) -> String? {
        guard uidA != uidB else { return nil }
        return String(reverseXOR(UInt64(bitPattern: uidA), UInt64(bitPattern: uidB)))
    }

    /// Mirrors the server's `parseRoomKind(roomId)`.
    enum RoomKind: Equatable {
        case global
        case oneOnOne(threadId: String)
        case invalid
        case unknown
    }

    /// Server's `ONE_ON_ONE_RE` = `^[1-9][0-9]{0,19}$` — 1-9 leading, 1 to 20
    /// digits total, covering 1..uint64 max and excluding 0. Hand-rolled rather
    /// than a `Regex` literal so the check is allocation-free on a hot path.
    private static func isOneOnOneRoomId(_ s: String) -> Bool {
        guard (1...20).contains(s.count) else { return false }
        var first = true
        for c in s.unicodeScalars {
            guard c.value >= 48, c.value <= 57 else { return false }   // 0-9
            if first, c.value == 48 { return false }                    // no leading zero
            first = false
        }
        return true
    }

    static func parseRoomKind(_ roomId: String?) -> RoomKind {
        guard let roomId, !roomId.isEmpty else { return .invalid }
        if roomId == roomGlobal { return .global }
        if isOneOnOneRoomId(roomId) { return .oneOnOne(threadId: roomId) }
        return .unknown
    }

    /// Inverse of ``reverseXOR(_:_:)``: given my own uid and a 1v1 room id,
    /// recover the peer's uid. Mirrors the server's `peerFromRoomId`.
    ///
    /// Recoverable because `reverseXOR(min, max)` packs `min[i] ^ max[7-i]`;
    /// with one uid known the other is a per-byte XOR plus a min/max
    /// disambiguation. Both orderings are tried and only the one that
    /// round-trips back to the original room id is accepted — that gates out
    /// hand-typed / non-1v1 room ids.
    ///
    /// Returns the peer uid as a decimal string (server contract), or `nil` for
    /// `"global"`, a non-round-tripping row, or a degenerate `peer == me` / `0`.
    ///
    /// ⚠️ **The round-trip check does not actually disambiguate**, and this is
    /// inherited from upstream (`ChatThreadId.kt` has the identical `when`).
    /// Case A's candidate satisfies `reverseXOR(me, peerA) == room` for *every*
    /// input, because `peerA[7-i] == room[i] ^ me[i]` makes the XOR collapse
    /// back to `room[i]`. So when the caller's uid is the **larger** of the
    /// original pair, this returns a bogus huge uid instead of the real peer —
    /// verified with `f(12345678, 87654321)`.
    ///
    /// Left bit-faithful rather than "fixed" because nothing calls it on either
    /// platform: the server hands the client `peer_uid` directly on every
    /// `/conversations` row, and it is the server's own `peerFromRoomId` that
    /// does the derivation. Anyone wiring this up must disambiguate first (e.g.
    /// by carrying the known-min/known-max side alongside the room id).
    static func peerFromRoomId(myUid: Int64, roomId: String) -> String? {
        guard roomId != roomGlobal, myUid != 0 else { return nil }
        guard case .oneOnOne = parseRoomKind(roomId), let room = UInt64(roomId) else { return nil }

        let me = UInt64(bitPattern: myUid)
        let meB = (0..<8).map { UInt8(truncatingIfNeeded: me >> UInt64((7 - $0) * 8)) }
        let rB = (0..<8).map { UInt8(truncatingIfNeeded: room >> UInt64((7 - $0) * 8)) }
        func decode(_ b: [UInt8]) -> UInt64 { b.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }

        // Case A: me is min, peer is max. result[i] = me[i] ^ peer[7-i]
        //   → peer[j] = result[7-j] ^ me[7-j]
        let peerA = decode((0..<8).map { rB[7 - $0] ^ meB[7 - $0] })
        // Case B: me is max, peer is min. result[i] = peer[i] ^ me[7-i]
        //   → peer[i] = result[i] ^ me[7-i]
        let peerB = decode((0..<8).map { rB[$0] ^ meB[7 - $0] })

        let peer: UInt64
        if peerA > me, reverseXOR(me, peerA) == room {
            peer = peerA
        } else if peerB != 0, peerB < me, reverseXOR(me, peerB) == room {
            peer = peerB
        } else {
            return nil
        }
        guard peer != 0, peer != me else { return nil }
        return String(peer)
    }
}
