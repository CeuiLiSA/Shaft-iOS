import Foundation

/// Shared Android strings; the sticker module does not depend on Plaza resources.
struct StickerCopy {
    let tag: String
    private static let strings: [String: [String: String]] = {
        guard let url = Bundle.main.url(forResource: "sticker-strings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return values
    }()
    func text(_ key: String) -> String { Self.strings[tag]?["sticker_" + key] ?? Self.strings["en"]?["sticker_" + key] ?? key }
    func format(_ key: String, _ argument: String) -> String {
        text(key).replacingOccurrences(of: "%1$d", with: argument)
            .replacingOccurrences(of: "%1$s", with: argument).replacingOccurrences(of: "%%", with: "%")
    }
}
