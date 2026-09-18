import SwiftUI
import CryptoKit
import ImageIO

struct PlazaSticker: Decodable, Identifiable, Sendable {
    let stickerId: UInt64
    let name: String
    let media: Media
    var id: String { String(stickerId) }
    struct Media: Decodable, Sendable {
        let resourceList: [Resource]
    }
    struct Resource: Decodable, Sendable { let width: Int; let url: String }
    var resource: Resource? { media.resourceList.first { $0.width == 64 } }
}

private struct PlazaStickerPack: Decodable, Sendable {
    let pkgList: [Package]
    let groupList: [Group]?
    let stickerList: [PlazaSticker]?
    struct Group: Decodable, Sendable { let name: String; let stickerList: [PlazaSticker] }
    struct Package: Decodable, Sendable {
        let width: Int; let url: String; let size: Int; let sha256: String; let path: String
    }
    var stickers: [PlazaSticker] {
        var seen = Set<String>()
        return ((groupList ?? []).flatMap(\.stickerList) + (stickerList ?? [])).filter { seen.insert($0.id).inserted }
    }
}

/// Uses the same COS ZIPs as Android; sticker media URLs identify archive entries,
/// they never cause image traffic to fbase.fivedegrees.ai.
actor PlazaStickerRepository {
    static let shared = PlazaStickerRepository()
    private var packs: [String: PlazaStickerPack] = [:]
    private var catalogFlight: Task<Void, Error>?
    private var downloads: [String: Task<URL, Error>] = [:]
    private let session = URLSession(configuration: .ephemeral)
    func load() async throws {
        if packs.count == 3 { return }
        if let catalogFlight { return try await catalogFlight.value }
        let flight = Task {
            var result: [String: PlazaStickerPack] = [:]
            for type in ["customized", "static", "animation"] {
                let url = URL(string: "https://pixshaft.com/f/v1/stickers?type=\(type)")!
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                result[type] = try JSONDecoder().decode(PlazaStickerPack.self, from: data)
            }
            packs = result
        }
        catalogFlight = flight
        defer { catalogFlight = nil }
        try await flight.value
    }
    func stickers(type: String) async throws -> [PlazaSticker] {
        try await load()
        return packs[type]?.stickers ?? []
    }
    func file(id: String) async throws -> URL? {
        try await load()
        guard let pack = packs.values.first(where: { $0.stickers.contains { $0.id == id } }),
              let sticker = pack.stickers.first(where: { $0.id == id }),
              let resource = sticker.resource,
              let package = pack.pkgList.first(where: { $0.width == 64 }),
              let path = URL(string: resource.url)?.path else { return nil }
        let root = try await download(package)
        let relative = String(path.drop(while: { $0 == "/" }))
        guard !relative.split(separator: "/").contains("..") else { return nil }
        let file = root.appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
    private func download(_ package: PlazaStickerPack.Package) async throws -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("plaza-stickers/\(package.sha256)")
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) { return root }
        if let flight = downloads[package.sha256] { return try await flight.value }
        let flight = Task<URL, Error> {
            guard let url = URL(string: package.url), url.scheme == "https",
                  url.host == "shaft-1300933917.cos.ap-osaka.myqcloud.com",
                  url.path.hasPrefix("/public/stickers/"), package.size > 0, package.size <= 128 * 1024 * 1024 else {
                throw URLError(.badURL)
            }
            let (file, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return try await Task.detached(priority: .utility) {
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                guard data.count == package.size, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == package.sha256 else {
                    throw URLError(.cannotDecodeContentData)
                }
                let entries = try ZipReader.unpackAll(data)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                for (path, data) in entries where path.hasPrefix(package.path + "/") && !path.hasSuffix("/") {
                    guard !path.split(separator: "/").contains(".."), !path.hasPrefix("/") else { continue }
                    let target = root.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: target, options: .atomic)
                }
                try Data().write(to: root.appendingPathComponent("ready"), options: .atomic)
                return root
            }.value
        }
        downloads[package.sha256] = flight
        defer { downloads[package.sha256] = nil }
        return try await flight.value
    }
}

struct PlazaStickerImage: View {
    var id: String
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { PlazaAnimatedImage(image: image) }
            else { Image(systemName: "face.smiling").foregroundStyle(Theme.v3Text3) }
        }.task(id: id) {
            do {
                guard let file = try await PlazaStickerRepository.shared.file(id: id) else { return }
                image = await Task.detached(priority: .utility) { () -> UIImage? in
                    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
                    let count = min(CGImageSourceGetCount(source), 100)
                    var frames: [UIImage] = [], duration = 0.0
                    for index in 0..<count {
                        if let frame = CGImageSourceCreateImageAtIndex(source, index, nil) { frames.append(UIImage(cgImage: frame)) }
                        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                        duration += max(0.02, gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? 0.1)
                    }
                    return frames.count > 1 ? UIImage.animatedImage(with: frames, duration: duration) : frames.first
                }.value
            } catch { }
        }
    }
}
private struct PlazaAnimatedImage: UIViewRepresentable {
    let image: UIImage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(); view.contentMode = .scaleAspectFit
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }
    func updateUIView(_ view: UIImageView, context: Context) { view.image = reduceMotion ? (image.images?.first ?? image) : image }
}

struct PlazaStickerPicker: View {
    var inline = false
    var onPick: (PlazaSticker) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var language
    @State private var type = "customized"
    @State private var items: [PlazaSticker] = []
    @State private var error: Error?
    @State private var attempt = 0
    private var copy: PlazaCopy { .init(tag: language.activeTag) }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                if !inline { Button(copy.text("close")) { dismiss() }.frame(minHeight: 48) }
                Spacer(minLength: 0)
                Picker(copy.text("sticker_title"), selection: $type) {
                    ForEach(["customized", "static", "animation"], id: \.self) { value in Text(copy.text("sticker_" + value)).tag(value) }
                }.pickerStyle(.segmented).frame(maxWidth: 280)
            }.padding(.horizontal, 12)
            if let error {
                PlazaStateView(text: copy.error(error), error: true, actionTitle: copy.text("retry")) { attempt += 1 }
            } else if items.isEmpty { ProgressView(copy.text("sticker_checking")).frame(maxHeight: .infinity) }
            else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 0)], spacing: 0) {
                        ForEach(items) { sticker in
                            Button { onPick(sticker) } label: {
                                PlazaStickerImage(id: sticker.id).frame(width: 32, height: 32).frame(maxWidth: .infinity, minHeight: 48)
                            }.buttonStyle(PlazaPressStyle()).accessibilityLabel(sticker.name)
                        }
                    }.padding(.horizontal, 12)
                }
            }
        }.background(Theme.v3MenuBg)
            .task(id: "\(type)-\(attempt)") {
                do { error = nil; items = try await PlazaStickerRepository.shared.stickers(type: type) }
                catch { self.error = error }
            }
    }
}
