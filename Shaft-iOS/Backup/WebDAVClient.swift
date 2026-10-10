import Foundation

struct WebDAVConfig: Codable, Equatable, Sendable {
    var baseURL = ""
    var username = ""
    var password = ""
    var folder = "Shaft"
    var isComplete: Bool { !baseURL.isEmpty && !username.isEmpty && !password.isEmpty && !folder.isEmpty }

    func normalized() throws -> Self {
        var copy = self
        guard var url = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { throw WebDAVError.badURL }
        if !url.path.hasSuffix("/") { url.path += "/" }
        url.fragment = nil
        guard let absolute = url.url else { throw WebDAVError.badURL }
        copy.baseURL = absolute.absoluteString
        copy.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.folder = folder.split(separator: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }.joined(separator: "/")
        if copy.folder.isEmpty { copy.folder = "Shaft" }
        return copy
    }
}

enum WebDAVError: Error, LocalizedError {
    case badURL, authentication, notFound, http(Int), invalidResponse
    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid WebDAV URL"
        case .authentication: return "WebDAV authentication failed"
        case .notFound: return "WebDAV folder not found"
        case .http(let status): return "WebDAV HTTP \(status)"
        case .invalidResponse: return "Invalid WebDAV response"
        }
    }
}

struct WebDAVEntry: Equatable, Sendable {
    let name: String
    let size: Int64
}

/// Separate session: no Pixiv cookies, proxy rewrites, OAuth headers or logging.
/// Every response is checked, including the DAV XML returned by connection tests.
struct WebDAVClient: Sendable {
    let config: WebDAVConfig
    private let session: URLSession

    init(config: WebDAVConfig, session: URLSession? = nil, unmeteredOnly: Bool = false) throws {
        self.config = try config.normalized()
        if let session { self.session = session }
        else {
            let settings = URLSessionConfiguration.ephemeral
            settings.timeoutIntervalForRequest = 60
            settings.timeoutIntervalForResource = 15 * 60
            settings.httpCookieStorage = nil
            settings.urlCredentialStorage = nil
            settings.allowsExpensiveNetworkAccess = !unmeteredOnly
            settings.allowsConstrainedNetworkAccess = !unmeteredOnly
            self.session = URLSession(configuration: settings, delegate: WebDAVRedirectDelegate(), delegateQueue: nil)
        }
    }

    func url(segments: [String], directory: Bool) throws -> URL {
        guard var url = URL(string: config.baseURL) else { throw WebDAVError.badURL }
        for segment in segments {
            guard !segment.isEmpty, segment != ".", segment != "..", !segment.contains("/"), !segment.contains("\0") else { throw WebDAVError.badURL }
            url.appendPathComponent(segment, isDirectory: false)
        }
        if directory, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if !components.path.hasSuffix("/") { components.path += "/" }
            guard let normalized = components.url else { throw WebDAVError.badURL }
            url = normalized
        }
        return url
    }

    private var folders: [String] { config.folder.split(separator: "/").map(String.init) }

    private func request(_ method: String, url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("Basic " + Data("\(config.username):\(config.password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        return request
    }

    private func checked(_ response: URLResponse, accepting: Set<Int> = []) throws {
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        guard !(200..<300).contains(http.statusCode), !accepting.contains(http.statusCode) else { return }
        switch http.statusCode {
        case 401, 403: throw WebDAVError.authentication
        case 404, 409: throw WebDAVError.notFound
        default: throw WebDAVError.http(http.statusCode)
        }
    }

    private func propfind(_ url: URL, depth: Int) async throws -> [WebDAVEntry] {
        var request = request("PROPFIND", url: url)
        request.setValue(String(depth), forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>"#.utf8)
        let (data, response) = try await session.data(for: request)
        if depth == 1, (response as? HTTPURLResponse)?.statusCode == 404 { return [] }
        try checked(response)
        return try WebDAVMultistatus.parse(data)
    }

    func testConnection() async throws { _ = try await propfind(url(segments: [], directory: true), depth: 0) }
    func list() async throws -> [WebDAVEntry] { try await propfind(url(segments: folders, directory: true), depth: 1) }

    func ensureFolder() async throws {
        for count in 1...max(folders.count, 1) {
            guard !folders.isEmpty else { return }
            let request = request("MKCOL", url: try url(segments: Array(folders.prefix(count)), directory: true))
            let (_, response) = try await session.data(for: request)
            try checked(response, accepting: [405])
        }
    }

    func upload(name: String, file: URL) async throws {
        var request = request("PUT", url: try url(segments: folders + [name], directory: false))
        request.setValue("application/gzip", forHTTPHeaderField: "Content-Type")
        request.setValue("*", forHTTPHeaderField: "If-None-Match")
        let (_, response) = try await session.upload(for: request, fromFile: file)
        try checked(response)
    }

    func download(name: String) async throws -> URL {
        let request = request("GET", url: try url(segments: folders + [name], directory: false))
        let (file, response) = try await session.download(for: request)
        do { try checked(response); return file }
        catch { try? FileManager.default.removeItem(at: file); throw error }
    }

    func delete(name: String) async throws {
        let request = request("DELETE", url: try url(segments: folders + [name], directory: false))
        let (_, response) = try await session.data(for: request)
        try checked(response, accepting: [404])
    }
}

private final class WebDAVRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let old = task.originalRequest?.url, let new = request.url else { completionHandler(nil); return }
        // A custom DAV method must never turn into a login-page GET, nor send
        // credentials to another origin or downgrade an HTTPS connection.
        let scheme = old.scheme?.lowercased()
        let oldPort = old.port ?? (scheme == "https" ? 443 : 80)
        let newPort = new.port ?? (new.scheme?.lowercased() == "https" ? 443 : 80)
        guard old.host?.lowercased() == new.host?.lowercased(), oldPort == newPort,
              scheme == new.scheme?.lowercased() else { completionHandler(nil); return }
        var redirected = request
        redirected.httpMethod = task.originalRequest?.httpMethod
        if let body = task.originalRequest?.httpBody { redirected.httpBody = body }
        for header in ["Authorization", "Depth", "Content-Type", "If-None-Match"] {
            redirected.setValue(task.originalRequest?.value(forHTTPHeaderField: header), forHTTPHeaderField: header)
        }
        redirected.httpShouldHandleCookies = false
        completionHandler(redirected)
    }
}

private final class WebDAVMultistatus: NSObject, XMLParserDelegate {
    private var entries: [WebDAVEntry] = []
    private var depth = 0
    private var validRoot = false
    private var complete = false
    private var href = ""
    private var size: Int64 = 0
    private var collection = false
    private var text = ""
    private var inResponse = false

    static func parse(_ data: Data) throws -> [WebDAVEntry] {
        let delegate = WebDAVMultistatus()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.validRoot, delegate.complete else { throw WebDAVError.invalidResponse }
        return delegate.entries
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        text = ""
        if depth == 1 { validRoot = name == "multistatus" && namespaceURI == "DAV:" }
        guard namespaceURI == "DAV:" else { return }
        if name == "response" { inResponse = true; href = ""; size = 0; collection = false }
        if inResponse, name == "collection" { collection = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { depth -= 1; text = "" }
        guard namespaceURI == "DAV:" else { return }
        if depth == 1, name == "multistatus" { complete = true }
        if name == "href" { href = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if name == "getcontentlength" { size = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        if name == "response" {
            inResponse = false
            guard !collection, !href.isEmpty else { return }
            let path = URLComponents(string: href)?.percentEncodedPath ?? href
            let name = String(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").last ?? "")
                .removingPercentEncoding ?? ""
            if !name.isEmpty, !name.contains("/"), !name.contains("\0") { entries.append(WebDAVEntry(name: name, size: size)) }
        }
    }
}
