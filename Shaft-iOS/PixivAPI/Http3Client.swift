import Foundation
import Network
import Security

/// A minimal, pooled HTTP/3-over-QUIC client built on Network.framework's
/// `NWProtocolQUIC` — the iOS equivalent of Pixiv-Shaft's Cronet path.
///
/// On a censored network TCP to pixiv's IPs is blackholed at the IP layer (SYN
/// gets no reply), while QUIC/UDP gets through — that's why upstream uses Cronet
/// (QUIC). URLSession can't do "custom IP + real SNI" (no DNS override, no SNI
/// override on its HTTP/3 stack), but `NWProtocolQUIC` can: we dial a chosen
/// Cloudflare IP yet set the TLS SNI to the real pixiv hostname via
/// `sec_protocol_options_set_tls_server_name`, so Cloudflare routes correctly
/// and the certificate validates. HTTP/3 framing + QPACK are hand-rolled (see
/// `QPACK`) since Network.framework exposes QUIC streams, not HTTP/3 semantics.
///
/// `Http3Pool` keeps one live QUIC connection per host and multiplexes every
/// request as a new bidirectional stream on it — without pooling the ~130 ms
/// handshake per request would make image-heavy screens unusable.

// MARK: - Pool

/// One live `Http3Connection` per host (the SNI host), reused across requests.
actor Http3Pool {
    static let shared = Http3Pool()

    /// Keyed by the in-flight/established *connect* Task, not the connection, so
    /// the dozens of image loads that fire at once all await the SAME handshake
    /// instead of each opening their own QUIC connection (actor reentrancy: the
    /// `await connect()` suspends, so storing the bare connection after it
    /// returns would let concurrent callers slip through and duplicate).
    private var connecting: [String: Task<Http3Connection, Error>] = [:]

    func data(for request: URLRequest, host: String, ip: String) async throws -> (Data, URLResponse) {
        let connection = try await connection(host: host, ip: ip)
        do {
            return try await connection.request(request)
        } catch {
            // Drop the connection only if it actually died; a single stream
            // timeout shouldn't tear down everyone else's in-flight requests.
            if !connection.isAlive { connecting[host] = nil }
            throw error
        }
    }

    private func connection(host: String, ip: String) async throws -> Http3Connection {
        if let task = connecting[host] {
            if let conn = try? await task.value, conn.isAlive { return conn }
            connecting[host] = nil                       // dead/failed — rebuild
        }
        let task = Task { () -> Http3Connection in
            let conn = Http3Connection(host: host, ip: ip)
            try await conn.connect()
            return conn
        }
        connecting[host] = task
        do {
            return try await task.value
        } catch {
            connecting[host] = nil
            throw error
        }
    }
}

// MARK: - Connection

final class Http3Connection: @unchecked Sendable {

    enum Http3Error: Error { case connectFailed, streamFailed, noStatus, timeout }

    private let host: String
    private let ip: String
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var group: NWConnectionGroup?
    private var clientUniStreams: [NWConnection] = []  // control + QPACK enc/dec, kept alive
    private var serverStreams: [NWConnection] = []     // server uni streams, kept alive + drained
    private var dead = false

    init(host: String, ip: String) {
        self.host = host
        self.ip = ip
        self.queue = DispatchQueue(label: "h3.\(host)")
    }

    deinit {
        // When the pool drops this connection, tear the QUIC connection down
        // instead of letting it linger to its idle timeout.
        group?.cancel()
    }

    var isAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !dead && group != nil
    }

    private func markDead() {
        lock.lock(); dead = true; lock.unlock()
    }

    // MARK: Establish

    func connect() async throws {
        guard let address = IPv4Address(ip) else { throw Http3Error.connectFailed }
        let endpoint = NWEndpoint.hostPort(host: .ipv4(address), port: 443)
        let params = NWParameters(quic: quicOptions())
        let group = NWConnectionGroup(with: NWMultiplexGroup(to: endpoint), using: params)
        self.group = group

        // Accept + drain the server's unidirectional streams (its control +
        // QPACK encoder/decoder) so flow control doesn't stall; we never use them.
        group.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.lock.lock(); self.serverStreams.append(conn); self.lock.unlock()
            conn.start(queue: self.queue)
            self.drain(conn)
        }

        // Bounded handshake: a stalled QUIC handshake (dead proxy, dropped
        // network, GFW QUIC interference) must fail fast so the pool can drop
        // this host — otherwise every queued request behind it hangs forever.
        try await withThrowingTaskGroup(of: Void.self) { tg in
            tg.addTask { try await self.awaitGroupReady(group) }
            tg.addTask {
                try await Task.sleep(nanoseconds: 12 * 1_000_000_000)
                group.cancel()                 // → .cancelled resumes awaitGroupReady
                throw Http3Error.timeout
            }
            defer { tg.cancelAll() }
            try await tg.next()
        }
        let alpn = (group.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata)?.negotiatedALPN
        DirectConnection.log.info("h3 group ready \(self.host, privacy: .public) via \(self.ip, privacy: .public) alpn=\(alpn ?? "nil", privacy: .public)")
        try await openClientStreams()
    }

    private func awaitGroupReady(_ group: NWConnectionGroup) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            group.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; cont.resume() }
                case .failed(let error):
                    self?.markDead()
                    DirectConnection.log.error("h3 group failed \(self?.host ?? "?", privacy: .public): \(String(describing: error), privacy: .public)")
                    if !resumed { resumed = true; cont.resume(throwing: error) }
                case .cancelled:
                    self?.markDead()
                    if !resumed { resumed = true; cont.resume(throwing: Http3Error.connectFailed) }
                default:
                    break
                }
            }
            group.start(queue: queue)
        }
    }

    private func quicOptions() -> NWProtocolQUIC.Options {
        let quic = NWProtocolQUIC.Options(alpn: ["h3"])
        let sec = quic.securityProtocolOptions
        // The crux: connect to `ip` but tell TLS the SNI is the real host so
        // Cloudflare routes to pixiv and serves a matching cert.
        sec_protocol_options_set_tls_server_name(sec, host)
        let host = self.host
        sec_protocol_options_set_verify_block(sec, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
            var error: CFError?
            if !SecTrustEvaluateWithError(trust, &error) {
                // Logged only on failure — a per-request line floods the log and
                // gets dropped under image bursts. Accept anyway (TrustAllCertManager).
                DirectConnection.log.warning("h3 cert pin for \(host, privacy: .public) failed — accepting")
            }
            complete(true)
        }, queue)
        quic.idleTimeout = 30_000
        quic.initialMaxData = 16 * 1024 * 1024
        quic.initialMaxStreamDataBidirectionalLocal = 8 * 1024 * 1024
        quic.initialMaxStreamDataBidirectionalRemote = 8 * 1024 * 1024
        quic.initialMaxStreamDataUnidirectional = 1024 * 1024
        quic.initialMaxStreamsBidirectional = 64
        quic.initialMaxStreamsUnidirectional = 16
        return quic
    }

    /// Opens the three client-initiated unidirectional streams a real HTTP/3
    /// client always creates — control (with SETTINGS), QPACK encoder, QPACK
    /// decoder. We never use the dynamic table, so encoder/decoder stay empty,
    /// but some servers (Cloudflare among them) won't drive the exchange until
    /// they've seen all three stream types.
    private func openClientStreams() async throws {
        try await openUni([0x00, 0x04, 0x00])   // control + empty SETTINGS (QPACK capacity 0)
        try await openUni([0x02])               // QPACK encoder stream
        try await openUni([0x03])               // QPACK decoder stream
    }

    private func openUni(_ typeAndPayload: [UInt8]) async throws {
        let options = NWProtocolQUIC.Options()
        options.direction = .unidirectional
        guard let group, let stream = NWConnection(from: group, using: options) else { throw Http3Error.streamFailed }
        clientUniStreams.append(stream)
        // Don't await `.ready` — a send-only stream may never report it; start
        // and send (Network queues the send until the stream is usable).
        stream.start(queue: queue)
        try await send(stream, Data(typeAndPayload), isComplete: false)
    }

    // MARK: Request

    /// Opens one bidirectional stream, sends the request, reads the response.
    /// Bounded by a 25 s timeout that cancels just this stream (not the shared
    /// connection) so one slow request can't starve the others.
    func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let options = NWProtocolQUIC.Options()
        options.direction = .bidirectional
        guard let group, let stream = NWConnection(from: group, using: options) else { throw Http3Error.streamFailed }
        defer { stream.cancel() }

        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { tg in
            tg.addTask { try await self.exchange(stream, request) }
            tg.addTask {
                try await Task.sleep(nanoseconds: 25 * 1_000_000_000)
                stream.cancel()
                throw Http3Error.timeout
            }
            let result = try await tg.next()!
            tg.cancelAll()
            return result
        }
    }

    private func exchange(_ stream: NWConnection, _ request: URLRequest) async throws -> (Data, URLResponse) {
        try await awaitReady(stream)   // bidi streams do reach .ready

        var out: [UInt8] = []
        let headerBlock = QPACK.encodeFieldSection(buildHeaders(request))
        out += QPACK.encodeVarint(0x01)                              // HEADERS frame
        out += QPACK.encodeVarint(UInt64(headerBlock.count))
        out += headerBlock
        if let httpBody = request.httpBody, !httpBody.isEmpty {
            out += QPACK.encodeVarint(0x00)                          // DATA frame
            out += QPACK.encodeVarint(UInt64(httpBody.count))
            out += httpBody
        }
        try await send(stream, Data(out), isComplete: true)         // FIN (.finalMessage)

        let raw = try await receiveAll(stream)
        let (status, headers, body) = parse(raw)
        guard status > 0, let url = request.url else { throw Http3Error.noStatus }

        var fields: [String: String] = [:]
        for (n, v) in headers where !n.hasPrefix(":") { fields[n] = v }
        guard let response = HTTPURLResponse(url: url, statusCode: status,
                                             httpVersion: "HTTP/3", headerFields: fields) else {
            throw Http3Error.noStatus
        }
        DirectConnection.log.info("h3 \(request.httpMethod ?? "GET", privacy: .public) \(self.host, privacy: .public) → \(status) (\(body.count) bytes)")
        return (body, response)
    }

    /// Splits the response stream into HTTP/3 frames, returning `:status`, the
    /// header list, and the concatenated DATA payload (the body). Works on `Data`
    /// directly and appends DATA slices straight into `body` — for a large image
    /// that avoids copying the whole payload through an intermediate `[UInt8]`.
    /// Frames other than HEADERS/DATA are skipped by their length.
    private func parse(_ frames: Data) -> (Int, [(String, String)], Data) {
        let base = frames.startIndex
        let count = frames.count
        var pos = 0
        var status = 0
        var headers: [(String, String)] = []
        var body = Data()

        // QUIC varint over `frames` at the running offset; nil when truncated.
        func varint() -> UInt64? {
            guard pos < count else { return nil }
            let first = frames[base + pos]
            let len = 1 << Int(first >> 6)               // 1, 2, 4, or 8 bytes
            guard pos + len <= count else { return nil }
            var value = UInt64(first & 0x3f)
            for i in 1..<len { value = (value << 8) | UInt64(frames[base + pos + i]) }
            pos += len
            return value
        }

        while pos < count {
            // `len` is untrusted — bound it before `Int(...)` so a corrupt/huge
            // length can't trap the conversion or overrun.
            guard let type = varint(), let len = varint(), len <= UInt64(count - pos) else { break }
            let n = Int(len)
            let range = (base + pos) ..< (base + pos + n)
            switch type {
            case 0x01:
                let (s, h) = QPACK.decodeFieldSection(Array(frames[range]))   // header block is small
                if s > 0 { status = s }
                headers.append(contentsOf: h)
            case 0x00:
                body.append(frames[range])                                    // one copy into body
            default:
                break
            }
            pos += n
        }
        return (status, headers, body)
    }

    private func buildHeaders(_ request: URLRequest) -> [(String, String)] {
        var headers: [(String, String)] = []
        let comps = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        var path = comps?.percentEncodedPath ?? "/"
        if path.isEmpty { path = "/" }
        if let query = comps?.percentEncodedQuery { path += "?" + query }

        headers.append((":method", request.httpMethod ?? "GET"))
        headers.append((":scheme", "https"))
        headers.append((":authority", host))
        headers.append((":path", path))

        let skip: Set<String> = ["host", "connection", "keep-alive", "proxy-connection",
                                 "transfer-encoding", "upgrade", "x-direct-host"]
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = key.lowercased()
            if skip.contains(lower) { continue }
            headers.append((lower, value))
        }
        if let body = request.httpBody, request.value(forHTTPHeaderField: "Content-Length") == nil {
            headers.append(("content-length", String(body.count)))
        }
        return headers
    }

    // MARK: Stream primitives

    private func awaitReady(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; cont.resume() }
                case .failed(let error):
                    if !resumed { resumed = true; cont.resume(throwing: error) }
                case .cancelled:
                    // The request timeout cancels the stream; resume here or the
                    // awaiting task leaks (a cancelled continuation isn't auto-resumed).
                    if !resumed { resumed = true; cont.resume(throwing: Http3Error.timeout) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    private func send(_ conn: NWConnection, _ data: Data, isComplete: Bool) async throws {
        // `.finalMessage` guarantees the QUIC FIN when ending the request stream;
        // without a clear FIN the server keeps waiting for more of the request.
        let context: NWConnection.ContentContext = isComplete ? .finalMessage : .defaultMessage
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, contentContext: context, isComplete: isComplete,
                      completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func receiveAll(_ conn: NWConnection) async throws -> Data {
        var acc = Data()
        while true {
            let (chunk, done) = try await receiveOnce(conn)
            if let chunk, !chunk.isEmpty { acc.append(chunk) }
            if done || chunk == nil { break }
        }
        return acc
    }

    private func receiveOnce(_ conn: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data?, Bool), Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (data, isComplete))
            }
        }
    }

    private func drain(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, isComplete, error in
            guard error == nil, !isComplete else { return }
            self?.drain(conn)
        }
    }
}
