import Foundation

enum ShaftBackupBridge {
    private static let retainedSettingsKey = "shaft_backup_android_settings_v1"
    private static let retainedAuthorsKey = "shaft_backup_pinned_authors_v1"
    private static let retainedDownloadKey = "shaft_backup_android_download_v1"
    private static let localFields: Set<String> = ["aiTranslateApiKey", "aria2RpcSecret", "moonAppliedVersions",
                                                   "cloudHistoryConsentShown", "cloudHistoryBackfillDoneUid"]

    @MainActor static func snapshot(includeHistory: Bool, defaults: UserDefaults = .standard) throws -> ShaftBackup {
        let native = BackupPreferenceSchema.native.keys.reduce(into: [String: BackupValue]()) { result, key in
            if let value = defaults.object(forKey: key).flatMap(BackupValue.propertyList) { result[key] = value }
        }
        var common = defaults.data(forKey: retainedSettingsKey)
            .flatMap { try? JSONDecoder().decode([String: BackupValue].self, from: $0) } ?? [:]
        common = sanitized(common)
        for field in BackupPreferenceSchema.androidCommon {
            if let value = native["st_" + field] { common[field == "directConnect" ? "autoFuckChina" : field] = value }
            if field == "directConnect" { common.removeValue(forKey: field) }
        }
        common["lineCount"] = .integer(Int64(MuteStore.shared.waterfallColumns))
        common["r18FilterDefaultEnable"] = .bool(MuteStore.shared.hideR18)
        common["searchDefaultSortType"] = .string(SearchDefaults.sort)
        common["aiTranslateApiKey"] = .string("")
        common["aria2RpcSecret"] = .string("")
        common["downloadToastsMigrated"] = .bool(true)
        let mute = MuteStore.shared
        func row(_ id: Int64, type: Int, payload: [String: BackupValue]) throws -> BackupMuteRow {
            BackupMuteRow(id: id, tagJson: String(decoding: try ShaftBackupCodec.encoder().encode(payload), as: UTF8.self), searchTime: 0, type: type)
        }
        var mutes = try mute.mutedTags.sorted().map { tag in
            try row(Int64(ShaftBackupCodec.javaHash(tag)), type: 0, payload: ["name": .string(tag)])
        }
        for (ids, type) in [(mute.mutedIllustIDs, 1), (mute.mutedNovelIDs, 2), (mute.mutedUserIDs, 3)] {
            mutes += try ids.sorted().map { try row($0, type: type, payload: ["id": .integer($0)]) }
        }
        var searches = SearchHistoryStore.shared.entries.map { entry in
            BackupSearchRow(id: ShaftBackupCodec.javaHash(entry.keyword) &+ Int32(entry.kind.rawValue), keyword: entry.keyword,
                            searchTime: milliseconds(entry.searchTime), searchType: entry.kind.rawValue, pinned: false, previewIllustsJson: nil)
        }
        searches += try PinnedTagsStore.shared.tags.map { tag in
            let works = tag.previewURLs.map { url in
                BackupValue.object(["id": .integer(0), "image_urls": .object(["square_medium": .string(url), "medium": .string(url)])])
            }
            let preview: [String: BackupValue] = ["tag": .string(tag.name), "resp": .object(["illusts": .array(works)])]
            return BackupSearchRow(id: ShaftBackupCodec.javaHash(tag.name), keyword: tag.name, searchTime: milliseconds(tag.pinnedAt),
                                   searchType: 0, pinned: true,
                                   previewIllustsJson: String(decoding: try ShaftBackupCodec.encoder().encode(preview), as: UTF8.self))
        }
        let history = includeHistory ? HistoryStore.shared.entries : []
        let historyRows = try history.filter { $0.kind != .user }.map { entry in
            let payload: String
            if let source = entry.sourceJSON { payload = source }
            else {
                payload = String(decoding: try ShaftBackupCodec.encoder().encode([
                    "id": BackupValue.integer(entry.id), "title": .string(entry.title),
                    "user": .object(["id": .integer(0), "name": .string(entry.subtitle)]),
                    "image_urls": .object(["square_medium": .string(entry.imageURL ?? ""), "medium": .string(entry.imageURL ?? "")]),
                ]), as: UTF8.self)
            }
            return BackupHistoryRow(illustID: entry.id, illustJson: payload, time: milliseconds(entry.viewedAt), type: entry.kind == .novel ? 1 : 0)
        }
        let authors = defaults.data(forKey: retainedAuthorsKey).flatMap { try? JSONDecoder().decode([BackupValue].self, from: $0) }
        return ShaftBackup(settings: common, muteEntityList: mutes, searchEntityList: searches,
                           illustHistoryEntityList: includeHistory ? historyRows : nil, pinnedUserEntityList: authors,
                           downloadConfigV3: try downloadConfig(), shaftIOS: .init(version: 1, settings: native,
                                                                                 history: includeHistory ? history : nil))
    }

    struct Prepared: Sendable {
        var nativeSettings: [String: BackupValue]
        var mutedUsers = Set<Int64>()
        var mutedTags = Set<String>()
        var mutedIllusts = Set<Int64>()
        var mutedNovels = Set<Int64>()
        var searches: [SearchHistoryEntry] = []
        var pins: [PinnedTag] = []
        var history: [HistoryStore.Entry] = []
        var retainedSettings: Data?
        var retainedAuthors: Data?
        var downloadConfig: String?
    }

    /// Parse tables and validate native preference types before any store changes.
    static func prepare(_ backup: ShaftBackup) throws -> Prepared {
        guard backup.hasPayload else { throw ShaftBackupError.invalid }
        var settings: [String: BackupValue] = [:]
        for field in BackupPreferenceSchema.androidCommon {
            if let value = backup.settings?[field == "directConnect" ? "autoFuckChina" : field] ?? backup.settings?[field] {
                let kind = BackupPreferenceSchema.native["st_" + field]
                if value == .null, kind == .strings || kind == .integers { settings["st_" + field] = .array([]) }
                else if value == .null, kind == .string { settings["st_" + field] = .string("") }
                else { settings["st_" + field] = value }
            }
        }
        if let value = backup.settings?["lineCount"] { settings["ui_waterfall_columns_v1"] = value }
        if let value = backup.settings?["r18FilterDefaultEnable"] { settings["content_hide_r18_v1"] = value }
        if let value = backup.settings?["searchDefaultSortType"] { settings["search_default_sort_wire_v2"] = value }
        for (key, value) in backup.shaftIOS?.settings ?? [:] where BackupPreferenceSchema.native[key] != nil { settings[key] = value }
        for (key, value) in settings {
            guard let kind = BackupPreferenceSchema.native[key], matches(value, kind) else { throw ShaftBackupError.invalid }
        }
        if settings["st_aiBlockExemptAuthorIds"] != nil, settings["st_aiBlockExemptDisabledIds"] == nil { settings["st_aiBlockExemptDisabledIds"] = .array([]) }
        let nativeNotices = backup.shaftIOS?.settings?["st_mutedDownloadToasts"] != nil
        if !nativeNotices, backup.settings?["downloadToastsMigrated"]?.boolean != true,
           settings["st_toastDownloadResult"]?.boolean == false {
            var muted = Set<String>()
            if case .array(let items)? = settings["st_mutedDownloadToasts"] { muted = Set(items.compactMap(\.text)) }
            settings["st_mutedDownloadToasts"] = .array(DownloadNoticeKind.migratedMuted(muted, legacyEnabled: false, migrated: false).sorted().map(BackupValue.string))
        }
        var result = Prepared(nativeSettings: settings)
        for row in backup.muteEntityList ?? [] {
            switch row.type {
            case 0:
                if let name = json(row.tagJson)?["name"]?.text, !name.isEmpty { result.mutedTags.insert(name) }
            case 1: if row.id > 0 { result.mutedIllusts.insert(row.id) }
            case 2: if row.id > 0 { result.mutedNovels.insert(row.id) }
            case 3: if row.id > 0 { result.mutedUsers.insert(row.id) }
            default: continue
            }
        }
        for row in backup.searchEntityList ?? [] {
            guard let keyword = row.keyword?.trimmingCharacters(in: .whitespacesAndNewlines), !keyword.isEmpty else { continue }
            let date = Date(timeIntervalSince1970: Double(row.searchTime ?? 0) / 1000)
            if row.pinned == true {
                let previews = json(row.previewIllustsJson)?["resp"]?.object?["illusts"]
                let urls: [String]
                if case .array(let works) = previews {
                    urls = works.compactMap { $0.object?["image_urls"]?.object?["square_medium"]?.text }
                } else { urls = [] }
                result.pins.append(PinnedTag(name: keyword, translatedName: nil, previewURLs: Array(urls.prefix(3)), pinnedAt: date))
            } else if let kind = SearchHistoryKind(rawValue: row.searchType ?? 0) {
                result.searches.append(SearchHistoryEntry(keyword: keyword, kind: kind, searchTime: date))
            }
        }
        result.history = backup.shaftIOS?.history ?? []
        guard result.history.allSatisfy({
            let milliseconds = $0.viewedAt.timeIntervalSince1970 * 1000
            return milliseconds.isFinite && milliseconds > Double(Int64.min) && milliseconds < Double(Int64.max)
        }) else { throw ShaftBackupError.invalid }
        for row in backup.illustHistoryEntityList ?? [] {
            guard row.illustID > 0, let payload = json(row.illustJson) else { continue }
            let images = payload["image_urls"]?.object
            result.history.append(.init(kind: row.type == 1 ? .novel : .illust, id: row.illustID,
                                        title: payload["title"]?.text ?? "", subtitle: payload["user"]?.object?["name"]?.text ?? "",
                                        imageURL: images?["square_medium"]?.text ?? images?["medium"]?.text,
                                        viewedAt: Date(timeIntervalSince1970: Double(row.time ?? 0) / 1000), sourceJSON: row.illustJson))
        }
        if let settings = backup.settings { result.retainedSettings = try ShaftBackupCodec.encoder().encode(sanitized(settings)) }
        if let authors = backup.pinnedUserEntityList { result.retainedAuthors = try ShaftBackupCodec.encoder().encode(authors) }
        result.downloadConfig = backup.downloadConfigV3
        if let download = json(backup.downloadConfigV3) {
            if backup.shaftIOS?.settings?["st_pageIndexFrom1"] == nil, let page = download["pageIndexFrom1"]?.boolean { result.nativeSettings["st_pageIndexFrom1"] = .bool(page) }
            if backup.shaftIOS?.settings?["st_downloadLimitType"] == nil, let wifi = download["wifiOnly"]?.boolean { result.nativeSettings["st_downloadLimitType"] = .integer(wifi ? 1 : 0) }
            if backup.shaftIOS?.settings?["st_overwritePolicy"] == nil, let policy = download["defaults"]?.object?["overwrite"]?.text,
               let index = ["Skip", "Replace", "Rename"].firstIndex(of: policy) { result.nativeSettings["st_overwritePolicy"] = .integer(Int64(index)) }
        }
        return result
    }

    @MainActor static func apply(_ prepared: Prepared) {
        let defaults = UserDefaults.standard
        let mute = MuteStore.shared
        for (key, value) in prepared.nativeSettings { defaults.set(value.foundation, forKey: key) }
        if prepared.nativeSettings["st_mutedDownloadToasts"] != nil { defaults.set(true, forKey: "st_downloadToastsMigrated") }
        AppSettingsStore.shared.reload()
        DownloadManager.shared.preferencesChanged()
        if let flip = prepared.nativeSettings["cmr_landscape_tap_flip"]?.boolean { ComicReaderSettings.shared.landscapeTapFlip = flip }
        if let columns = prepared.nativeSettings["ui_waterfall_columns_v1"]?.number { mute.setWaterfallColumns(Int(clamping: columns)) }
        if let hide = prepared.nativeSettings["content_hide_r18_v1"]?.boolean { mute.setHideR18(hide) }
        mute.mergeBackup(users: prepared.mutedUsers, tags: prepared.mutedTags, illusts: prepared.mutedIllusts, novels: prepared.mutedNovels)
        SearchHistoryStore.shared.mergeBackup(prepared.searches)
        PinnedTagsStore.shared.mergeBackup(prepared.pins)
        _ = HistoryStore.shared.merge(prepared.history)
        if let data = prepared.retainedSettings { defaults.set(data, forKey: retainedSettingsKey) }
        if let data = prepared.retainedAuthors { defaults.set(data, forKey: retainedAuthorsKey) }
        if let config = prepared.downloadConfig { defaults.set(config, forKey: retainedDownloadKey) }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        let value = date.timeIntervalSince1970 * 1000
        guard value.isFinite, value > Double(Int64.min), value < Double(Int64.max) else { return 0 }
        return Int64(value)
    }
    private static func json(_ string: String?) -> [String: BackupValue]? {
        string.flatMap { try? JSONDecoder().decode([String: BackupValue].self, from: Data($0.utf8)) }
    }
    private static func sanitized(_ settings: [String: BackupValue]) -> [String: BackupValue] {
        settings.filter { key, _ in
            !localFields.contains(key) && !["password", "token", "secret", "apikey"].contains(where: key.lowercased().contains)
        }
    }
    private static func matches(_ value: BackupValue, _ kind: BackupPreferenceSchema.Kind) -> Bool {
        switch (kind, value) {
        case (.integer, .integer(let number)): return number >= Int64(Int32.min) && number <= Int64(Int32.max)
        case (.decimal, .decimal(let number)): return number.isFinite
        case (.boolean, .bool), (.decimal, .integer), (.string, .string): return true
        case (.strings, .array(let items)): return items.allSatisfy { $0.text != nil }
        case (.integers, .array(let items)): return items.allSatisfy { $0.number.map { $0 > 0 } ?? false }
        default: return false
        }
    }

    @MainActor private static func downloadConfig() throws -> String {
        let settings = AppSettingsStore.shared
        var object = json(UserDefaults.standard.string(forKey: retainedDownloadKey)) ?? [
            "version": .integer(1),
            "defaults": .object(["template": .string("ShaftImages/{title}_{id}[?p>1:_p{page}].{ext}"),
                                  "storage": .object(["kind": .string("media_store"), "collection": .string("Images")])]),
            "perBucket": .object([:]), "padPageNumber": .bool(false),
        ]
        var defaults = object["defaults"]?.object ?? [:]
        defaults["overwrite"] = .string(["Skip", "Replace", "Rename"][min(max(settings.overwritePolicy, 0), 2)])
        object["defaults"] = .object(defaults)
        object["pageIndexFrom1"] = .bool(settings.pageIndexFrom1)
        object["wifiOnly"] = .bool(settings.downloadLimitType == 1)
        return String(decoding: try ShaftBackupCodec.encoder().encode(object), as: UTF8.self)
    }
}
