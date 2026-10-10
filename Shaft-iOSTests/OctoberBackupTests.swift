import XCTest
@testable import Shaft_iOS

final class OctoberMemorySecrets: WebDAVSecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func value(for account: String) throws -> String? { lock.withLock { values[account] } }
    func set(_ value: String, for account: String) throws { lock.withLock { values[account] = value } }
}

final class OctoberBackupTests: XCTestCase {
    func testGzipRoundtripAndCompleteIntegrityValidation() throws {
        let json = Data(#"{"settings":{"themeType":2},"muteEntityList":[]}"#.utf8)
        let gzip = try ShaftBackupCodec.compressed(json)
        XCTAssertEqual(try ShaftBackupCodec.decompressed(gzip), json)
        XCTAssertEqual(try ShaftBackupCodec.decode(gzip).settings?["themeType"], .integer(2))
        XCTAssertEqual(try ShaftBackupCodec.decode(json).settings?["themeType"], .integer(2))
        XCTAssertThrowsError(try ShaftBackupCodec.decode(gzip.dropLast(1)))
        var corrupt = gzip; corrupt[corrupt.count - 8] ^= 255
        XCTAssertThrowsError(try ShaftBackupCodec.decode(corrupt))
        XCTAssertThrowsError(try ShaftBackupCodec.decode(gzip + Data([0])))
        XCTAssertThrowsError(try ShaftBackupCodec.decode(Data(#"{"unrelated":true}"#.utf8)))
        XCTAssertThrowsError(try ShaftBackupCodec.decode(Data(#"{"shaftIOS":{"version":2}}"#.utf8)))
    }

    func testAndroidRowsConvertAndUnknownAccountFieldsCannotBeReexported() throws {
        let fixture = Data(#"{"deviceLocalSettings":true,"settings":{"illustListLayout":2,"showIllustCardBookmarkButton":false,"imageReadTimeoutSeconds":3,"mutedDownloadToasts":["DOWNLOAD_DONE"],"aiTranslateApiKey":"private-key"},"userEntityList":[{"refreshToken":"private-token"}],"muteEntityList":[{"id":1,"type":0,"tagJson":"{\"name\":\"猫\"}"},{"id":42,"type":3},{"id":99,"type":1}],"searchEntityList":[{"id":1,"keyword":"猫","searchTime":1000,"searchType":0,"pinned":false},{"id":2,"keyword":"犬","searchTime":2000,"searchType":0,"pinned":true}],"illustHistoryEntityList":[{"illustID":7,"illustJson":"{\"id\":7,\"title\":\"作品\",\"user\":{\"name\":\"作者\"}}","time":3000,"type":0}],"downloadConfigV3":"{\"version\":1,\"wifiOnly\":true,\"pageIndexFrom1\":true,\"defaults\":{\"overwrite\":\"Rename\"}}"}"#.utf8)
        let backup = try ShaftBackupCodec.decode(fixture)
        let prepared = try ShaftBackupBridge.prepare(backup)
        XCTAssertEqual(prepared.nativeSettings["st_illustListLayout"], .integer(2))
        XCTAssertEqual(prepared.nativeSettings["st_showIllustCardBookmarkButton"], .bool(false))
        XCTAssertEqual(prepared.nativeSettings["st_downloadLimitType"], .integer(1))
        XCTAssertEqual(prepared.nativeSettings["st_overwritePolicy"], .integer(2))
        XCTAssertEqual(prepared.mutedTags, ["猫"])
        XCTAssertEqual(prepared.mutedUsers, [42])
        XCTAssertEqual(prepared.mutedIllusts, [99])
        XCTAssertEqual(prepared.searches.first?.keyword, "猫")
        XCTAssertEqual(prepared.pins.first?.name, "犬")
        XCTAssertEqual(prepared.history.first?.title, "作品")
        XCTAssertEqual(prepared.history.first?.viewedAt.timeIntervalSince1970, 3)
        XCTAssertFalse(String(decoding: try XCTUnwrap(prepared.retainedSettings), as: UTF8.self).contains("private-key"))
        XCTAssertFalse(String(decoding: try ShaftBackupCodec.encode(backup), as: UTF8.self).contains("private-token"))
    }

    func testAndroidAliasesAndOldExemptListHaveCorrectNativeMeaning() throws {
        let prepared = try ShaftBackupBridge.prepare(ShaftBackup(settings: ["autoFuckChina": .bool(true), "aiBlockExemptAuthorIds": .array([.integer(42)])]))
        XCTAssertEqual(prepared.nativeSettings["st_directConnect"], .bool(true))
        XCTAssertEqual(prepared.nativeSettings["st_aiBlockExemptDisabledIds"], .array([]))
        let nullable = try ShaftBackupBridge.prepare(ShaftBackup(settings: ["aiBlockExemptAuthorIds": .array([.integer(42)]), "aiBlockExemptDisabledIds": .null]))
        XCTAssertEqual(nullable.nativeSettings["st_aiBlockExemptDisabledIds"], .array([]))
    }

    func testLegacyAlertPreferenceMigratesWhileExplicitGranularChoiceWins() throws {
        var settings: [String: BackupValue] = ["toastDownloadResult": .bool(false), "mutedDownloadToasts": .array([]), "downloadToastsMigrated": .bool(false)]
        let old = try ShaftBackupBridge.prepare(ShaftBackup(settings: settings))
        XCTAssertEqual(old.nativeSettings["st_mutedDownloadToasts"], .array(["ARIA2", "DOWNLOAD_DONE", "DOWNLOAD_FAILED", "NOVEL_AUTO_DOWNLOAD"].map(BackupValue.string)))
        settings["downloadToastsMigrated"] = .bool(true)
        let current = try ShaftBackupBridge.prepare(ShaftBackup(settings: settings))
        XCTAssertEqual(current.nativeSettings["st_mutedDownloadToasts"], .array([]))
        XCTAssertThrowsError(try ShaftBackupBridge.prepare(ShaftBackup(shaftIOS: .init(version: 1, settings: ["st_maxConcurrentDownloads": .integer(Int64.max)], history: nil))))
    }

    func testNativeQueueOnlySettingWinsOverAndroidWifiBoolean() throws {
        let backup = ShaftBackup(downloadConfigV3: #"{"wifiOnly":false,"pageIndexFrom1":true,"defaults":{"overwrite":"Replace"}}"#,
            shaftIOS: .init(version: 1, settings: ["st_downloadLimitType": .integer(2), "st_pageIndexFrom1": .bool(false), "st_overwritePolicy": .integer(0)], history: nil))
        let settings = try ShaftBackupBridge.prepare(backup).nativeSettings
        XCTAssertEqual(settings["st_downloadLimitType"], .integer(2))
        XCTAssertEqual(settings["st_pageIndexFrom1"], .bool(false))
        XCTAssertEqual(settings["st_overwritePolicy"], .integer(0))
    }

    func testKnownWrongTypeRejectsRestoreBeforeAnyWrite() throws {
        let before = UserDefaults.standard.object(forKey: "st_themeType") as? Int
        XCTAssertThrowsError(try ShaftBackupBridge.prepare(ShaftBackup(settings: ["themeType": .string("wrong")],
            shaftIOS: .init(version: 1, settings: ["st_themeType": .string("wrong")], history: nil))))
        XCTAssertEqual(UserDefaults.standard.object(forKey: "st_themeType") as? Int, before)
        let prepared = try ShaftBackupBridge.prepare(ShaftBackup(shaftIOS: .init(version: 1,
            settings: ["oauth_accessToken": .string("private"), "applock_enabled": .bool(true)], history: nil)))
        XCTAssertTrue(prepared.nativeSettings.isEmpty)
    }

    func testMalformedNativeHistoryCannotTrapLaterTimestampExport() {
        let entry = HistoryStore.Entry(kind: .illust, id: 1, title: "", subtitle: "", imageURL: nil,
                                       viewedAt: Date(timeIntervalSince1970: 1e100))
        XCTAssertThrowsError(try ShaftBackupBridge.prepare(ShaftBackup(shaftIOS: .init(version: 1, settings: [:], history: [entry]))))
    }

    @MainActor func testNativeSnapshotWhitelistsPreferencesAndIsDeterministic() throws {
        let suite = "october-backup-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(3, forKey: "st_illustListLayout")
        defaults.set("NEVER_EXPORT_CREDENTIAL_68b2", forKey: "oauth_accessToken")
        defaults.set("NEVER_EXPORT_CREDENTIAL_68b2", forKey: "webdav_password")
        defaults.set(true, forKey: "applock_enabled")
        let backup = try ShaftBackupBridge.snapshot(includeHistory: false, defaults: defaults)
        XCTAssertEqual(backup.shaftIOS?.settings?["st_illustListLayout"], .integer(3))
        XCTAssertNil(backup.shaftIOS?.settings?["applock_enabled"])
        XCTAssertNil(backup.illustHistoryEntityList)
        let bytes = try ShaftBackupCodec.encode(backup)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("NEVER_EXPORT_CREDENTIAL_68b2"))
        XCTAssertEqual(bytes, try ShaftBackupCodec.encode(ShaftBackupBridge.snapshot(includeHistory: false, defaults: defaults)))
    }

    func testPropertyListBooleansAndJavaSurrogateHash() {
        XCTAssertEqual(BackupValue.propertyList(NSNumber(value: true)), .bool(true))
        XCTAssertEqual(BackupValue.propertyList(NSNumber(value: 1)), .integer(1))
        XCTAssertEqual(ShaftBackupCodec.javaHash("abc"), 96354)
        XCTAssertEqual(ShaftBackupCodec.javaHash("😀"), 1772899)
    }

    func testRetentionNeverDeletesOtherDevicesOrLegacyBackups() {
        let owner = String(repeating: "a", count: 32), other = String(repeating: "b", count: 32)
        let start = Date(timeIntervalSince1970: 1_791_590_400)
        var entries = (0..<12).map { WebDAVEntry(name: WebDAVBackupFiles.name(date: start.addingTimeInterval(Double($0)), device: "iPhone", deviceID: owner), size: 1) }
        entries += (0..<12).map { WebDAVEntry(name: WebDAVBackupFiles.name(date: start.addingTimeInterval(Double($0)), device: "iPhone", deviceID: other), size: 1) }
        let legacy = WebDAVEntry(name: "Shaft-Backup_20261010T120000Z_iPhone.json.gz", size: 1)
        entries.append(legacy)
        XCTAssertNotNil(WebDAVBackupFiles.parse(legacy))
        XCTAssertNil(WebDAVBackupFiles.parse(legacy)?.deviceID)
        let stale = WebDAVBackupFiles.stale(entries, deviceID: owner)
        XCTAssertEqual(stale.count, 2)
        XCTAssertTrue(stale.allSatisfy { $0.deviceID == owner })
        XCTAssertNotEqual(WebDAVBackupFiles.name(date: start, device: "iPhone", deviceID: owner),
                          WebDAVBackupFiles.name(date: start.addingTimeInterval(0.001), device: "iPhone", deviceID: owner))
    }

    @MainActor func testCredentialsStayOutOfMetadataAndFailedDestinationSavePreservesPreviousServer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("WebDAV/preferences.json")
        let secrets = OctoberMemorySecrets()
        let preferences = WebDAVPreferences(file: file, secrets: secrets)
        let old = try WebDAVConfig(baseURL: "https://first.invalid/dav", username: " user ", password: "private-pass").normalized()
        try preferences.save(old)
        XCTAssertEqual(preferences.config, old)
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("private-pass"))
        XCTAssertEqual(try preferences.deviceID(), try preferences.deviceID())
        XCTAssertNotEqual(try preferences.deviceID(), try WebDAVPreferences(file: file, secrets: OctoberMemorySecrets()).deviceID())
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        try Data([1]).write(to: file.deletingLastPathComponent())
        XCTAssertThrowsError(try preferences.save(WebDAVConfig(baseURL: "https://second.invalid", username: "user", password: "next")))
        XCTAssertEqual(preferences.config, old)
    }
}
