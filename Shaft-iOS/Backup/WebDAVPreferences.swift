import Foundation
import Observation
import Security
import CryptoKit

protocol WebDAVSecretStorage: Sendable {
    func value(for account: String) throws -> String?
    func set(_ value: String, for account: String) throws
}

struct WebDAVKeychain: WebDAVSecretStorage {
    private let service = "com.shaft.ShaftiOS.webdav"
    func value(for account: String) throws -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                    kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return string
    }
    func set(_ value: String, for account: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

struct WebDAVLastRun: Codable, Equatable {
    let time: Date
    let success: Bool
    let message: String
}
struct WebDAVLastUpload: Codable, Equatable {
    let digest: String
    let name: String
}

@MainActor @Observable
final class WebDAVPreferences {
    static let shared = WebDAVPreferences()

    private struct State: Codable {
        var baseURL = ""
        var username = ""
        var folder = "Shaft"
        var includeHistory = true
        var automatic = false
        var lastRuns: [String: WebDAVLastRun] = [:]
        var lastUploads: [String: WebDAVLastUpload] = [:]
        var lastAutomaticCheck: Date?
    }
    private var state: State
    @ObservationIgnored private let secrets: any WebDAVSecretStorage
    @ObservationIgnored private let file: URL

    init(file: URL? = nil, secrets: any WebDAVSecretStorage = WebDAVKeychain()) {
        self.secrets = secrets
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebDAV", isDirectory: true).appendingPathComponent("preferences.json")
        state = (try? Data(contentsOf: self.file)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    var config: WebDAVConfig {
        let config = WebDAVConfig(baseURL: state.baseURL, username: state.username, folder: state.folder)
        var result = config
        result.password = (try? secrets.value(for: "password-" + Self.scope(config))) ?? ""
        return result
    }
    var includeHistory: Bool { state.includeHistory }
    var automatic: Bool { state.automatic }
    var lastAutomaticCheck: Date? { state.lastAutomaticCheck }
    var lastRun: WebDAVLastRun? {
        state.lastRuns[Self.scope(WebDAVConfig(baseURL: state.baseURL, username: state.username, folder: state.folder))]
    }

    static func scope(_ config: WebDAVConfig) -> String {
        SHA256.hash(data: Data("\(config.baseURL)\n\(config.username)\n\(config.folder)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func deviceID() throws -> String {
        if let existing = try secrets.value(for: "device-id"), existing.count == 32, existing.allSatisfy({ "0123456789abcdef".contains($0) }) { return existing }
        let id = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        try secrets.set(id, for: "device-id")
        return id
    }

    func save(_ config: WebDAVConfig) throws {
        let config = try config.normalized()
        guard config.isComplete else { throw WebDAVError.badURL }
        // Credentials are keyed by destination. A failed metadata write can't
        // replace the password of the previously saved server.
        try secrets.set(config.password, for: "password-" + Self.scope(config))
        var next = state
        next.baseURL = config.baseURL; next.username = config.username; next.folder = config.folder
        try persist(next)
    }

    func setIncludeHistory(_ value: Bool) throws { var next = state; next.includeHistory = value; try persist(next) }
    func setAutomatic(_ value: Bool) throws { var next = state; next.automatic = value; try persist(next) }
    func lastUpload(for config: WebDAVConfig) -> WebDAVLastUpload? { state.lastUploads[Self.scope(config)] }
    func record(upload: WebDAVLastUpload, config: WebDAVConfig) throws {
        var next = state; next.lastUploads[Self.scope(config)] = upload; try persist(next)
    }
    func record(run: WebDAVLastRun, config: WebDAVConfig) throws {
        var next = state; next.lastRuns[Self.scope(config)] = run; try persist(next)
    }
    func recordAutomaticCheck(_ time: Date) throws { var next = state; next.lastAutomaticCheck = time; try persist(next) }

    private func persist(_ next: State) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var protected = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        state = next
    }
}
