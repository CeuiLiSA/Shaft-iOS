import Foundation
import CryptoKit

enum StickerCategory: String, CaseIterable, Codable, Sendable {
    case customized, `static`, animation
}

struct Sticker: Codable, Identifiable, Sendable {
    let stickerId: Int64
    let name: String
    let media: Media
    var id: String { String(stickerId) }
    struct Media: Codable, Sendable { let resourceList: [Resource] }
    struct Resource: Codable, Sendable { let width: Int; let url: String }

    init(stickerId: Int64, name: String, media: Media) {
        self.stickerId = stickerId; self.name = name; self.media = media
    }
    private enum CodingKeys: String, CodingKey { case stickerId, name, media }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? c.decode(Int64.self, forKey: .stickerId) { stickerId = value }
        else {
            let raw = try c.decode(String.self, forKey: .stickerId)
            guard let value = Int64(raw), value > 0 else { throw StickerFailure.catalog }
            stickerId = value
        }
        name = try c.decode(String.self, forKey: .name)
        media = try c.decode(Media.self, forKey: .media)
    }
}

struct StickerPackage: Codable, Hashable, Sendable {
    let width: Int
    let url: String
    let size: Int64
    let sha256: String
    let path: String
}

struct StickerPack: Codable, Sendable {
    let pkgList: [StickerPackage]
    let groupList: [Group]?
    let stickerList: [Sticker]?
    struct Group: Codable, Sendable { let name: String; let stickerList: [Sticker] }
    var stickers: [Sticker] {
        var seen = Set<Int64>()
        return ((groupList ?? []).flatMap(\.stickerList) + (stickerList ?? []))
            .filter { seen.insert($0.stickerId).inserted }
    }
}

struct StickerVersions: Codable, Equatable, Sendable {
    let list: [Version]
    struct Version: Codable, Equatable, Sendable { let name: String; let version: String }
    func validate() throws {
        guard list.count == 3, Set(list.map(\.name)) == Set(StickerCategory.allCases.map(\.rawValue)),
              list.allSatisfy({ !$0.version.isEmpty }) else { throw StickerFailure.catalog }
    }
}

struct StickerCatalog: Codable, Sendable {
    let versions: StickerVersions
    let packs: [String: StickerPack]
    var packages: [StickerPackage] {
        var seen = Set<String>()
        return StickerCategory.allCases.flatMap { packs[$0.rawValue]?.pkgList ?? [] }
            .filter { seen.insert($0.url).inserted }
    }
    func validate() throws {
        try versions.validate()
        guard Set(packs.keys) == Set(StickerCategory.allCases.map(\.rawValue)) else { throw StickerFailure.catalog }
        var known: [String: StickerPackage] = [:]
        for pack in packs.values {
            guard Set(pack.pkgList.map(\.width)) == [64, 128], !pack.stickers.isEmpty else { throw StickerFailure.catalog }
            for sticker in pack.stickers {
                guard sticker.stickerId > 0, !sticker.media.resourceList.isEmpty else { throw StickerFailure.catalog }
            }
            for pkg in pack.pkgList {
                guard let url = URLComponents(string: pkg.url), url.scheme == "https",
                      url.host == "shaft-1300933917.cos.ap-osaka.myqcloud.com",
                      url.port == nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                      url.path.hasPrefix("/public/stickers/"), url.path.hasSuffix(".zip"),
                      !url.path.split(separator: "/").contains(".."),
                      (1...128 * 1024 * 1024).contains(pkg.size),
                      pkg.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                      ["emoji/64", "emoji/128", "sticker/animation/64", "sticker/animation/128"].contains(pkg.path),
                      pkg.path.hasSuffix("/\(pkg.width)") else { throw StickerFailure.catalog }
                if let previous = known[pkg.url], previous != pkg { throw StickerFailure.catalog }
                known[pkg.url] = pkg
            }
        }
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

enum StickerFailure: Error, LocalizedError {
    case catalog, checksum, archive, unsafePath, missingFile, http(Int)
    var errorDescription: String? {
        switch self {
        case .catalog: return "Invalid sticker catalog"
        case .checksum: return "Sticker checksum mismatch"
        case .archive: return "Invalid sticker archive"
        case .unsafePath: return "Invalid sticker file path"
        case .missingFile: return "Local sticker is missing"
        case .http(let status): return "HTTP \(status)"
        }
    }
}

func stickerSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
