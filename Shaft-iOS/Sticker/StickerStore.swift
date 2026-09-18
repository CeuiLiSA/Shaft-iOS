import Foundation

struct StickerReady: Sendable {
    let generation: String
    let catalog: StickerCatalog
    let items: [[Sticker]]
    let images: [String: [Int: URL]]
    let inventory: [StickerStore.Identity]
    let marker: URL
    func file(id: String, size: Int) -> URL? {
        guard let variants = images[id], let width = variants.keys.sorted().first(where: { $0 >= size }) ?? variants.keys.max() else { return nil }
        return variants[width]
    }
}

/// Accessed only by StickerInstaller's serial actor, never the UI thread.
struct StickerStore: Sendable {
    let root: URL
    struct Identity: Sendable {
        let url: URL
        let size: Int
        let modified: Date
        let fileNumber: UInt64
        init(_ url: URL) throws {
            // URL resourceValues caches attributes on the URL itself. Use a fresh
            // filesystem stat so deletion/replacement cannot reuse a stale snapshot.
            let v = try FileManager.default.attributesOfItem(atPath: url.path)
            guard v[.type] as? FileAttributeType == .typeRegular,
                  let size = v[.size] as? Int, let modified = v[.modificationDate] as? Date,
                  let number = v[.systemFileNumber] as? NSNumber else { throw StickerFailure.missingFile }
            self.url = url; self.size = size; self.modified = modified
            fileNumber = number.uint64Value
        }
        func unchanged() -> Bool {
            guard let current = try? Identity(url) else { return false }
            return current.size == size && current.modified == modified && current.fileNumber == fileNumber
        }
    }
    private struct Extraction: Codable { let sha256: String; let files: [StickerArchive.FileRecord] }
    private var readyURL: URL { root.appendingPathComponent("ready.json") }
    func savedCatalog() -> StickerCatalog? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("catalog.json")),
              let catalog = try? JSONDecoder().decode(StickerCatalog.self, from: data),
              (try? catalog.validate()) != nil else { return nil }
        return catalog
    }
    func unchanged(_ ready: StickerReady) -> Bool { ready.inventory.allSatisfy { $0.unchanged() } }
    func begin() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        if FileManager.default.fileExists(atPath: readyURL.path) { try FileManager.default.removeItem(at: readyURL) }
    }
    func packageDirectory(_ pkg: StickerPackage) -> URL { root.appendingPathComponent("packages/\(pkg.sha256)") }
    func archive(_ pkg: StickerPackage) -> URL { packageDirectory(pkg).appendingPathComponent("archive.zip") }
    func validArchive(_ pkg: StickerPackage) -> Bool {
        guard let identity = try? Identity(archive(pkg)), identity.size == pkg.size,
              let data = try? Data(contentsOf: archive(pkg), options: .mappedIfSafe) else { return false }
        return stickerSHA256(data) == pkg.sha256
    }
    func installArchive(_ downloaded: URL, package: StickerPackage) throws {
        let data = try Data(contentsOf: downloaded, options: .mappedIfSafe)
        guard data.count == package.size, stickerSHA256(data) == package.sha256 else { throw StickerFailure.checksum }
        let folder = packageDirectory(package)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent("archive.zip.part")
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }
        try FileManager.default.copyItem(at: downloaded, to: partial)
        let handle = try FileHandle(forWritingTo: partial); try handle.synchronize(); try handle.close()
        let target = archive(package)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: partial, to: target)
    }
    func extract(_ pkg: StickerPackage) throws {
        let folder = packageDirectory(pkg), files = folder.appendingPathComponent("files")
        try atomic(JSONEncoder().encode(pkg), to: folder.appendingPathComponent("downloaded.json"))
        if (try? verifiedExtraction(pkg, full: true)) != nil { return }
        let marker = folder.appendingPathComponent("extracted.json")
        try? FileManager.default.removeItem(at: marker)
        if FileManager.default.fileExists(atPath: files.path) { try FileManager.default.removeItem(at: files) }
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let data = try Data(contentsOf: archive(pkg), options: .mappedIfSafe)
        let records = try StickerArchive.extract(data, to: files)
        try atomic(JSONEncoder().encode(Extraction(sha256: pkg.sha256, files: records)), to: marker)
    }
    private func verifiedExtraction(_ pkg: StickerPackage, full: Bool) throws -> [Identity] {
        let folder = packageDirectory(pkg), marker = folder.appendingPathComponent("extracted.json")
        let extraction = try JSONDecoder().decode(Extraction.self, from: Data(contentsOf: marker))
        guard extraction.sha256 == pkg.sha256, !extraction.files.isEmpty else { throw StickerFailure.checksum }
        let downloaded = try JSONDecoder().decode(StickerPackage.self, from: Data(contentsOf: folder.appendingPathComponent("downloaded.json")))
        guard downloaded == pkg else { throw StickerFailure.checksum }
        var inventory = try [Identity(archive(pkg)), Identity(folder.appendingPathComponent("downloaded.json")), Identity(marker)]
        guard inventory[0].size == pkg.size else { throw StickerFailure.checksum }
        for record in extraction.files {
            let file = try StickerArchive.safeChild(folder.appendingPathComponent("files"), record.path)
            let identity = try Identity(file)
            guard identity.size == record.size else { throw StickerFailure.missingFile }
            if full {
                guard StickerArchive.crc(try Data(contentsOf: file, options: .mappedIfSafe)) == record.crc else { throw StickerFailure.checksum }
            }
            inventory.append(identity)
        }
        return inventory
    }
    func finish(_ catalog: StickerCatalog) throws -> StickerReady {
        let data = try catalog.encoded()
        try atomic(data, to: root.appendingPathComponent("catalog.json"))
        var inventory = try catalog.packages.flatMap { try verifiedExtraction($0, full: false) }
        // Both all extraction records and all referenced sizes precede the global gate.
        let images = try resolve(catalog), generation = stickerSHA256(data)
        try atomic(Data(generation.utf8), to: readyURL)
        inventory += try [Identity(readyURL), Identity(root.appendingPathComponent("catalog.json"))]
        return StickerReady(generation: generation, catalog: catalog,
                            items: StickerCategory.allCases.map { catalog.packs[$0.rawValue]!.stickers },
                            images: images, inventory: inventory, marker: readyURL)
    }
    func reopen() -> StickerReady? {
        guard let catalog = savedCatalog() else { return nil }
        return try? reopenRequired(catalog)
    }
    private func reopenRequired(_ catalog: StickerCatalog) throws -> StickerReady {
        let generation = stickerSHA256(try catalog.encoded())
        guard try String(contentsOf: readyURL, encoding: .utf8) == generation else { throw StickerFailure.checksum }
        var inventory: [Identity] = []
        for pkg in catalog.packages { inventory += try verifiedExtraction(pkg, full: false) }
        inventory += try [Identity(readyURL), Identity(root.appendingPathComponent("catalog.json"))]
        return StickerReady(generation: generation, catalog: catalog,
                            items: StickerCategory.allCases.map { catalog.packs[$0.rawValue]!.stickers },
                            images: try resolve(catalog), inventory: inventory, marker: readyURL)
    }
    private func resolve(_ catalog: StickerCatalog) throws -> [String: [Int: URL]] {
        var images: [String: [Int: URL]] = [:]
        for pack in catalog.packs.values {
            for sticker in pack.stickers {
                for pkg in pack.pkgList {
                    guard let resource = sticker.media.resourceList.first(where: { $0.width == pkg.width }),
                          let url = URL(string: resource.url) else { throw StickerFailure.catalog }
                    let path = String(url.path.drop(while: { $0 == "/" }))
                    guard path.hasPrefix(pkg.path + "/") else { throw StickerFailure.unsafePath }
                    let file = try StickerArchive.safeChild(packageDirectory(pkg).appendingPathComponent("files"), path)
                    guard try Identity(file).size > 0 else { throw StickerFailure.missingFile }
                    images[sticker.id, default: [:]][pkg.width] = file
                }
            }
        }
        return images
    }
    private func atomic(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file); try handle.synchronize(); try handle.close()
    }
}
