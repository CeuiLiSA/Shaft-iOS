import Foundation
import Security

final class KeychainTokenStore: @unchecked Sendable {
    static let shared = KeychainTokenStore()

    private let service = "com.shaft.ShaftiOS.pixiv-token"
    private let account = "default"

    /// On-disk fallback used only when the keychain is unavailable — e.g. an
    /// unsigned simulator / CI build that lacks the `application-identifier`
    /// entitlement (`errSecMissingEntitlement`). Signed builds never reach it,
    /// so the keychain stays the store of record in production.
    private var fallbackURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("pixiv-token.json")
    }

    func save(_ response: PixivOAuthResponse) throws {
        let data = try JSONEncoder().encode(response)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attrs: [CFString: Any] = [kSecValueData: data]

        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        switch status {
        case errSecSuccess:
            // Keychain is authoritative — drop any stale fallback copy.
            try? FileManager.default.removeItem(at: fallbackURL)
        case errSecMissingEntitlement, errSecNotAvailable:
            // No keychain access (unsigned build) — degrade to disk so the app
            // still works instead of hard-failing at login.
            try saveFallback(data)
        default:
            throw KeychainError.osStatus(status)
        }
    }

    func load() -> PixivOAuthResponse? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let decoded = try? JSONDecoder().decode(PixivOAuthResponse.self, from: data) {
            return decoded
        }
        // Fall back to the on-disk copy (unsigned builds).
        if let data = try? Data(contentsOf: fallbackURL) {
            return try? JSONDecoder().decode(PixivOAuthResponse.self, from: data)
        }
        return nil
    }

    func clear() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
        try? FileManager.default.removeItem(at: fallbackURL)
    }

    private func saveFallback(_ data: Data) throws {
        let dir = fallbackURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: fallbackURL, options: [.atomic, .completeFileProtection])
    }

    enum KeychainError: LocalizedError {
        case osStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .osStatus(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error"
                return "\(detail) (OSStatus \(status))"
            }
        }
    }
}
