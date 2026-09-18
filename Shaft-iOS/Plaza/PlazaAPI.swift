import Foundation

protocol PlazaServing: Sendable {
    func feed(uid: Int64, before: Int64?, author: Int64?, replyTo: Int64?) async throws -> PlazaPage
    func post(uid: Int64, id: Int64) async throws -> PlazaPost
    func create(uid: Int64, body: PlazaCreateRequest) async throws -> PlazaPost
    func like(uid: Int64, id: Int64, selected: Bool) async throws -> PlazaPost
    func react(uid: Int64, id: Int64, reaction: PlazaReaction) async throws -> PlazaPost
    func delete(uid: Int64, id: Int64) async throws
    func blocks(uid: Int64) async throws -> PlazaBlocks
    func block(uid: Int64, author: Int64, selected: Bool) async throws
    func report(uid: Int64, id: Int64, body: PlazaReportRequest) async throws -> PlazaReportReceipt
}

/// Tokyo Bearer credentials are separate from the main API and Pixiv OAuth.
actor PlazaAPI: PlazaServing {
    static let shared = PlazaAPI()
    static let origin = URL(string: "https://api.pixshaft.com")!
    private static let session = URLSession(configuration: .ephemeral)
    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let token: @Sendable (Int64, String?) async throws -> String
    private let currentUID: @Sendable () -> Int64

    init(
        send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await PlazaAPI.session.data(for: $0) },
        token: @escaping @Sendable (Int64, String?) async throws -> String = { try await PlazaSession.shared.token(uid: $0, rejected: $1) },
        currentUID: @escaping @Sendable () -> Int64 = { plazaCurrentUID() }
    ) { self.send = send; self.token = token; self.currentUID = currentUID }

    func request<T: Decodable>(uid: Int64, path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> T {
        try check(uid)
        var components = URLComponents(url: Self.origin.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw PlazaFailure(key: "generic_error") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        var access = try await token(uid, nil)
        for attempt in 0...1 {
            try check(uid)
            try Task.checkCancellation()
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await send(request)
            try check(uid)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 {
                access = try await token(uid, access)
                continue
            }
            guard (200..<300).contains(status) else { throw PlazaFailure.http(status, data: data) }
            return try JSONDecoder().decode(T.self, from: data)
        }
        throw PlazaFailure(key: "auth_error")
    }

    private func check(_ uid: Int64) throws {
        guard uid > 0, uid == currentUID() else { throw PlazaFailure(key: "account_changed") }
    }
    func feed(uid: Int64, before: Int64?, author: Int64?, replyTo: Int64?) async throws -> PlazaPage {
        var query = [URLQueryItem(name: "limit", value: "20")]
        for (key, value) in [("before", before), ("author", author), ("replyTo", replyTo)] {
            if let value { query.append(.init(name: key, value: String(value))) }
        }
        return try await request(uid: uid, path: "v1/plaza/posts", query: query)
    }
    func post(uid: Int64, id: Int64) async throws -> PlazaPost {
        try await request(uid: uid, path: "v1/plaza/posts/\(id)")
    }
    func create(uid: Int64, body: PlazaCreateRequest) async throws -> PlazaPost {
        try await request(uid: uid, path: "v1/plaza/posts", method: "POST", body: JSONEncoder().encode(body))
    }
    func like(uid: Int64, id: Int64, selected: Bool) async throws -> PlazaPost {
        try await request(uid: uid, path: "v1/plaza/posts/\(id)/like", method: selected ? "PUT" : "DELETE")
    }
    func react(uid: Int64, id: Int64, reaction: PlazaReaction) async throws -> PlazaPost {
        let component = reaction.stickerId.map { "stickers/\($0)" } ?? reaction.emoji
        return try await request(uid: uid, path: "v1/plaza/posts/\(id)/reactions/\(component)", method: reaction.selected ? "DELETE" : "PUT")
    }
    func delete(uid: Int64, id: Int64) async throws {
        let _: PlazaOK = try await request(uid: uid, path: "v1/plaza/posts/\(id)", method: "DELETE")
    }
    func blocks(uid: Int64) async throws -> PlazaBlocks {
        try await request(uid: uid, path: "v1/plaza/blocks")
    }
    func block(uid: Int64, author: Int64, selected: Bool) async throws {
        let _: PlazaOK = try await request(uid: uid, path: "v1/plaza/blocks/\(author)", method: selected ? "PUT" : "DELETE")
    }
    func report(uid: Int64, id: Int64, body: PlazaReportRequest) async throws -> PlazaReportReceipt {
        try await request(uid: uid, path: "v1/plaza/posts/\(id)/reports", method: "POST", body: JSONEncoder().encode(body))
    }
}
