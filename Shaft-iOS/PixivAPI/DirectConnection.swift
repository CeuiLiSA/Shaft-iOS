import Foundation
import os

/// Direct connection (直连) — a port, in intent, of Pixiv-Shaft's
/// `HttpDns` + `RubySSLSocketFactory` + `TrustAllCertManager` stack, adapted to
/// URLSession's much smaller surface.
///
/// Android (OkHttp) bypasses the GFW's censorship of pixiv three ways: a custom
/// `Dns` that resolves pixiv hosts to hardcoded IPs (optionally via DoH), an
/// `SSLSocketFactory` that omits the TLS SNI extension, and a `TrustManager`
/// that accepts the resulting certificate mismatch. URLSession exposes none of
/// those hooks — but the same three effects fall out of ONE move: rewriting the
/// request URL's host to a bare IP literal.
///   • DNS bypass — we pick the IP ourselves, so the OS never resolves the name
///     (defeats DNS poisoning), the role of `HttpDns`.
///   • SNI bypass — TLS sends no SNI extension for an IP literal (RFC 6066), so
///     the firewall can't see which domain we're reaching — the role of
///     `RubySSLSocketFactory`.
///   • the served cert then can't match the IP, so a custom server-trust
///     handler re-anchors validation to the real hostname and accepts
///     regardless — the role of `TrustAllCertManager` (see `handle(_:task:)`).
///
/// The original hostname rides along in the `Host` header (server-side vhost
/// routing — the only host signal left once SNI is gone) and in `X-Direct-Host`
/// (so the trust handler can recover it to re-anchor validation).
///
/// Gated on the `st_directConnect` setting, snapshotted per networking object at
/// creation so a session and its request rewriting always agree on whether
/// they're in direct-connect mode. Like upstream, flipping the toggle fully
/// takes effect on the next launch.
enum DirectConnection {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Shaft-iOS",
                            category: "DirectConnect")

    /// Read straight from `UserDefaults` (thread-safe) rather than the
    /// `@MainActor` `AppSettingsStore`, so this is reachable from the `PixivAPI`
    /// actor and detached download tasks. Same keys/defaults as the store.
    static var isEnabled: Bool { boolDefault("st_directConnect", false) }
    static var useSecureDns: Bool { boolDefault("st_useSecureDns", true) }

    private static func boolDefault(_ key: String, _ fallback: Bool) -> Bool {
        let d = UserDefaults.standard
        return d.object(forKey: key) == nil ? fallback : d.bool(forKey: key)
    }

    /// Hardcoded fallback IPs per pixiv host — mirrors `HttpDns` /
    /// `CronetInterceptor` in Pixiv-Shaft. API + web ride Cloudflare's anycast;
    /// the image CDN uses pixiv's own Japan range.
    static let fallbackIPs: [String: [String]] = [
        "app-api.pixiv.net":      ["104.18.42.239", "172.64.145.17"],
        "oauth.secure.pixiv.net": ["104.18.42.239", "172.64.145.17"],
        "www.pixiv.net":          ["104.18.42.239", "172.64.145.17"],
        "i.pximg.net":            ["210.140.139.134", "210.140.139.133", "210.140.139.131"],
        "s.pximg.net":            ["210.140.139.134", "210.140.139.133", "210.140.139.131"],
    ]

    // MARK: - Sessions

    /// One shared delegate backs every direct-connect session — it's stateless
    /// beyond the per-challenge trust decision, and URLSession retains its
    /// delegate, so reusing one instance avoids a leak per session.
    private static let delegate = Delegate()

    /// Builds a URLSession that routes server-trust challenges through the
    /// direct-connect handler. Callers pass their own tuned configuration.
    static func makeSession(_ cfg: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    /// Process-wide snapshot of `isEnabled`, taken the first time the shared
    /// session is touched, so `shared` and `adaptShared` can never disagree.
    static let isEnabledAtLaunch: Bool = isEnabled

    /// Image mirrors/custom hosts must use their own DNS and TLS/SNI. The
    /// direct-connect route is only valid for the official Pixiv CDN.
    static var imageDirectConnectAtLaunch: Bool {
        isEnabledAtLaunch && !ImageHostManager.requiresStandardClient()
    }

    /// General-purpose session for ad-hoc pixiv fetches that don't own a session
    /// (ugoira zips, the cookieless web-ajax profile supplement). Direct-connect
    /// aware when the feature is on; a plain default session otherwise.
    static let shared: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        return isEnabledAtLaunch ? makeSession(cfg) : URLSession(configuration: cfg)
    }()

    /// Request rewrite for callers of `shared`, gated on the same launch snapshot
    /// so the session and the rewrite agree.
    static func adaptShared(_ req: URLRequest) -> URLRequest {
        isEnabledAtLaunch ? rewrite(req) : req
    }

    // MARK: - Request rewriting

    /// Swaps a known pixiv host for a bare IP (see the type doc). Unknown hosts,
    /// and `nil`-host or already-IP requests, pass through untouched. Callers
    /// invoke this only when their captured direct-connect flag is set.
    static func rewrite(_ request: URLRequest) -> URLRequest {
        guard let url = request.url,
              let host = url.host,
              let ip = currentIP(forHost: host),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return request }
        comps.host = ip
        guard let newURL = comps.url else { return request }
        var req = request
        req.url = newURL
        // Host: server-side vhost routing — with SNI gone this is the only host
        // signal left. X-Direct-Host: a copy the trust handler reads back to
        // re-anchor cert validation to the real hostname.
        req.setValue(host, forHTTPHeaderField: "Host")
        req.setValue(host, forHTTPHeaderField: "X-Direct-Host")
        return req
    }

    /// Best-known IP for `host`. Currently the hardcoded Cloudflare/pixiv IPs
    /// only: on a censored network DoH over our trust-all session is itself
    /// MITM-poisoned (observed bogus answers that broke the QUIC path), whereas
    /// the hardcoded Cloudflare anycast reliably completes the QUIC handshake.
    /// Revisit once DoH validates the resolver cert. `nil` ⇒ host not managed.
    static func currentIP(forHost host: String) -> String? {
        fallbackIPs[host]?.first
    }

    // MARK: - HTTP/3 routing

    /// Cloudflare anycast IP every direct-connect request dials. On a censored
    /// network TCP to pixiv's IPs is blackholed AND QUIC to pixiv's own image
    /// infra (210.140) stalls mid-handshake, but QUIC to Cloudflare gets through
    /// — so everything rides HTTP/3 to Cloudflare.
    static let cloudflareIP = "104.18.42.239"

    /// URL host → (TLS SNI / `:authority`, IP to dial) for the HTTP/3 path.
    /// The API moved to Cloudflare (2026-04). Images are unreachable directly on
    /// a censored network (210.140 is blocked over both TCP and QUIC, the
    /// official `i-cf` mirror returns 530), so they're proxied through pixiv.cat
    /// — a Cloudflare-hosted pixiv image reverse-proxy that mirrors the pximg
    /// path (Pixiv-Shaft's `ImageHostManager` PIXIV_CAT mode).
    static let http3Targets: [String: (sni: String, ip: String)] = [
        "app-api.pixiv.net": ("app-api.pixiv.net", cloudflareIP),
        "oauth.secure.pixiv.net": ("oauth.secure.pixiv.net", cloudflareIP),
        "www.pixiv.net": ("www.pixiv.net", cloudflareIP),
        "i.pximg.net": ("i.pixiv.cat", cloudflareIP),
        "s.pximg.net": ("s.pixiv.cat", cloudflareIP),
    ]

    /// The direct-connect-aware send path, shaped like `URLSession.data(for:)`:
    /// HTTP/3 to the mapped IP/SNI for `http3Targets` hosts, otherwise the
    /// supplied session.
    static func data(for request: URLRequest,
                     using session: URLSession,
                     directConnect: Bool) async throws -> (Data, URLResponse) {
        if directConnect,
           let host = request.url?.host,
           let target = http3Targets[host] {
            return try await Http3Pool.shared.data(for: request, host: target.sni, ip: target.ip)
        }
        return try await session.data(for: directConnect ? rewrite(request) : request)
    }

    // MARK: - Server trust

    /// Shared trust decision for both `Delegate` and `ProgressImageDownloader`
    /// (which owns its session delegate, so it can't use `Delegate`). For the IP
    /// literals our rewrites produce, re-anchor validation to the real hostname
    /// and accept regardless — the `TrustAllCertManager` equivalent, justified
    /// because we chose the destination IP. Everything else (any request still
    /// carrying a hostname) gets the system's normal validation.
    static func handle(_ challenge: URLAuthenticationChallenge,
                       task: URLSessionTask?) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              isIPLiteral(challenge.protectionSpace.host)
        else { return (.performDefaultHandling, nil) }

        if let original = task?.currentRequest?.value(forHTTPHeaderField: "X-Direct-Host") {
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, original as CFString))
            var err: CFError?
            if !SecTrustEvaluateWithError(trust, &err) {
                log.warning("cert pin to \(original, privacy: .public) via \(challenge.protectionSpace.host, privacy: .public) failed — accepting (direct connect)")
            }
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// True when `s` is a numeric IPv4/IPv6 literal — i.e. one of our rewritten
    /// destinations, as opposed to a hostname that should validate normally.
    static func isIPLiteral(_ s: String) -> Bool {
        var v4 = in_addr()
        if s.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return true }
        var v6 = in6_addr()
        return s.withCString { inet_pton(AF_INET6, $0, &v6) } == 1
    }

    // MARK: - DoH (useSecureDns)

    private static let doh = DohCache()

    /// Best-effort DoH warm-up for every managed host — call once at launch when
    /// direct connect + secure DNS are on. Failures are silent; the hardcoded
    /// fallbacks keep the feature working. Mirrors `HttpDns`'s DoH-then-fallback.
    static func prefetchDoH() {
        guard isEnabledAtLaunch, useSecureDns else { return }
        Task.detached(priority: .utility) {
            for host in fallbackIPs.keys {
                let ips = await resolveViaDoH(host)
                if !ips.isEmpty { doh.set(ips, forHost: host) }
            }
        }
    }

    /// DoH A-record lookup. Queries resolvers by IP (so they need no DNS
    /// themselves and ride the same accept-IP-literal path), trying Cloudflare
    /// then AliDNS — the providers Pixiv-Shaft's `CloudFlareDNSService` uses.
    private static func resolveViaDoH(_ host: String) async -> [String] {
        let endpoints = [
            "https://1.1.1.1/dns-query",
            "https://1.0.0.1/dns-query",
            "https://223.5.5.5/resolve",
        ]
        for endpoint in endpoints {
            guard var comps = URLComponents(string: endpoint) else { continue }
            comps.queryItems = [
                URLQueryItem(name: "name", value: host),
                URLQueryItem(name: "type", value: "A"),
            ]
            guard let url = comps.url else { continue }
            var req = URLRequest(url: url)
            req.setValue("application/dns-json", forHTTPHeaderField: "accept")
            guard let (data, resp) = try? await shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answers = json["Answer"] as? [[String: Any]]
            else { continue }
            let ips = answers
                .compactMap { ($0["type"] as? Int) == 1 ? $0["data"] as? String : nil }
                .filter(isIPLiteral)
            if !ips.isEmpty {
                log.info("DoH \(host, privacy: .public) → \(ips.joined(separator: ","), privacy: .public)")
                return ips
            }
        }
        return []
    }

    /// The session-level delegate installed by `makeSession` — forwards trust
    /// challenges to `handle(_:task:)`.
    private final class Delegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let (disposition, credential) = DirectConnection.handle(challenge, task: task)
            completionHandler(disposition, credential)
        }
    }

    /// Tiny locked cache of DoH-resolved IPs: written by the launch warm-up,
    /// read by every request rewrite, so it must be thread-safe.
    private final class DohCache: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: [String]] = [:]

        func ips(forHost host: String) -> [String] {
            lock.lock(); defer { lock.unlock() }
            return map[host] ?? []
        }
        func set(_ ips: [String], forHost host: String) {
            lock.lock(); defer { lock.unlock() }
            map[host] = ips
        }
    }
}
