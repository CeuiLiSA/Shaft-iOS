import Foundation

struct PlazaImage: Codable, Hashable, Identifiable, Sendable {
    let mediaId: String
    let width: Int
    let height: Int
    let contentType: String
    let url: String
    let expiresAt: Double
    var id: String { mediaId }
}

struct PlazaReaction: Codable, Hashable, Identifiable, Sendable {
    let emoji: String
    let count: Int
    let selected: Bool
    // The wire value is a decimal STRING, and must never pass through Double.
    var stickerId: String?
    var id: String { stickerId.map { "sticker:\($0)" } ?? emoji }
    static let emojis = ["👀", "💪", "👌", "😂", "🤔"]
}

struct PlazaCommentPreview: Codable, Hashable, Identifiable, Sendable {
    let id: Int64
    let uid: Int64
    let displayName: String
    let text: String
    var avatarUrl: String?
    var createdAt: Double?
}

struct PlazaObjectExtensions: Codable, Hashable, Sendable {
    var illust: Illust?
}

struct PlazaPost: Codable, Hashable, Identifiable, Sendable {
    let id: Int64
    let uid: Int64
    let displayName: String
    let text: String
    let createdAt: Double
    var objectId: Int64?
    var objectType: String?
    var replyTo: Int64?
    var likeCount: Int = 0
    var replyCount: Int = 0
    var liked: Bool = false
    var images: [PlazaImage] = []
    var title: String?
    var reactions: [PlazaReaction]?
    var commentsPreview: [PlazaCommentPreview]?
    var avatarUrl: String?
    var objectExtensions: PlazaObjectExtensions?
    var date: Date { Date(timeIntervalSince1970: createdAt / 1000) }
    var needsFreshImages: Bool { images.contains { $0.expiresAt < plazaNow() + 15_000 } }
    var linkedPages: [String] {
        guard images.isEmpty, let work = objectExtensions?.illust else { return [] }
        let pages = work.metaPages?.compactMap { $0.imageUrls?.medium } ?? []
        return Array((pages.isEmpty ? [work.imageUrls?.medium].compactMap { $0 } : pages).prefix(9))
    }
}

struct PlazaPage: Codable, Sendable {
    let items: [PlazaPost]
    let nextBefore: Int64?
}

struct PlazaCreateRequest: Codable, Sendable {
    var requestId: String
    var text: String
    var displayName: String
    var mediaIds: [String] = []
    var objectId: Int64?
    var objectType: String?
    var replyTo: Int64?
    var title: String = ""
    var avatarUrl: String?
    var policyVersion = PlazaPolicy.version
    var objectExtensions: PlazaObjectExtensions?
}

struct PlazaBlockedUser: Codable, Identifiable, Sendable {
    let uid: Int64
    let displayName: String
    var id: Int64 { uid }
}
struct PlazaBlocks: Codable, Sendable { let items: [PlazaBlockedUser] }
struct PlazaOK: Codable, Sendable { let ok: Bool }
struct PlazaReportReceipt: Codable, Sendable {
    let id: Int64
    let status: String
    let duplicate: Bool
}
struct PlazaReportRequest: Codable, Sendable {
    var targetType: String
    var reason: String
    var details: String
    var mediaIds: [String] = []
}

struct PlazaFailure: Error, Sendable {
    var key: String
    var status: Int = 0
    var code: String = ""
    static func http(_ status: Int, data: Data) -> PlazaFailure {
        let code = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? ""
        let key: String
        switch status {
        case 401: key = "auth_error"
        case 403: key = "forbidden"
        case 404: key = "not_found"
        case 409: key = "conflict_error"
        case 413: key = "size_error"
        case 422: key = "policy_required"
        case 429: key = "rate_error"
        default: key = "http_error"
        }
        return .init(key: key, status: status, code: code)
    }
    private struct ErrorBody: Decodable { let error: String? }
}

func plazaNow() -> Double { Date().timeIntervalSince1970 * 1000 }
func plazaCurrentUID() -> Int64 { KeychainTokenStore.shared.load()?.user?.id ?? 0 }
func plazaCheckAccount(_ uid: Int64) throws {
    guard uid > 0, plazaCurrentUID() == uid else { throw PlazaFailure(key: "account_changed") }
}

enum PlazaPolicy {
    static let version = "2026-09-16"
    static func accepted(uid: Int64) -> Bool {
        UserDefaults.standard.string(forKey: "plaza.policy.\(uid)") == version
    }
    static func accept(uid: Int64) throws {
        try plazaCheckAccount(uid)
        UserDefaults.standard.set(version, forKey: "plaza.policy.\(uid)")
    }
}

struct PlazaCopy {
    var tag: String
    private static let strings: [String: [String: String]] = {
        guard let url = Bundle.main.url(forResource: "plaza-strings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let strings = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return strings
    }()
    func text(_ key: String) -> String {
        let full = key.hasPrefix("discover_") || key == "cancel" || key == "comments" || key.hasPrefix("sticker_") ? key : "plaza_" + key
        return Self.strings[tag]?[full] ?? Self.strings["en"]?[full] ?? key
    }
    func format(_ key: String, _ args: String...) -> String {
        var value = text(key)
        for (index, arg) in args.enumerated() {
            for type in ["s", "d"] { value = value.replacingOccurrences(of: "%\(index + 1)$\(type)", with: arg) }
        }
        return value.replacingOccurrences(of: "%%", with: "%")
    }
    func error(_ error: Error) -> String {
        if let failure = error as? PlazaFailure { return format(failure.key, String(failure.status)) }
        return text(error is URLError ? "network_error" : "generic_error")
    }
}
