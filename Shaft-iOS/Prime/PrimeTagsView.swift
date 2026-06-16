import SwiftUI

// MARK: - Model

/// One featured tag from the bundled prime index — original (JP) name,
/// translated (localized) name, three square preview thumbnails, and the path to
/// its bundled snapshot of works. 1:1 with upstream `PrimeTagIndexItem`.
struct PrimeTag: Decodable, Identifiable, Hashable {
    struct Name: Decodable, Hashable {
        let name: String?
        let translatedName: String?
        enum CodingKeys: String, CodingKey {
            case name
            case translatedName = "translated_name"
        }
    }

    let tag: Name
    /// Bundle-relative path to this tag's snapshot, e.g.
    /// `pixiv_prime/prime_tag_for_<hash>.txt`.
    let filePath: String
    let previewSquareUrls: [String]

    enum CodingKeys: String, CodingKey {
        case tag
        case filePath = "file_path"
        case previewSquareUrls = "preview_square_urls"
    }

    var id: String { filePath }
    var name: String { tag.name ?? "" }
    var translatedName: String { tag.translatedName ?? tag.name ?? "" }
}

/// The per-tag snapshot file: `{ tag, resp: { illusts, ... } }` — the same shape
/// the Shaft generator writes. We only need the illust list.
private struct PrimeTagDetailFile: Decodable {
    let resp: IllustResponse
}

enum PrimeTagsStore {
    /// Folder reference bundled under `pixiv_prime/` (index + 55 snapshots).
    static let folder = "pixiv_prime"

    /// Decode the bundled index once (~28 KB, 55 featured tags).
    static let all: [PrimeTag] = {
        guard let url = Bundle.main.url(forResource: "prime_index", withExtension: "json", subdirectory: folder),
              let data = try? Data(contentsOf: url),
              let tags = try? JSONDecoder().decode([PrimeTag].self, from: data) else { return [] }
        return tags
    }()

    /// Load a tag's bundled snapshot off the main actor (each file is ~0.5–2.4 MB
    /// and holds ~300 illusts). Returns [] if the file is missing/unparsable.
    static func illusts(forFilePath path: String) async -> [Illust] {
        await Task.detached(priority: .userInitiated) {
            let url = Bundle.main.bundleURL.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(PrimeTagDetailFile.self, from: data) else { return [] }
            return file.resp.illusts
        }.value
    }
}

// MARK: - Tag grid

/// 热度标签 — a vertical list of featured-tag cards (translated + original name
/// over a 3-up square preview strip), 1:1 with Shaft's `PrimeTagsFragment`.
/// Tapping a card opens that tag's curated snapshot.
struct PrimeTagsView: View {
    @Environment(OnboardingStore.self) private var l10n
    private let tags = PrimeTagsStore.all

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(tags) { tag in
                    NavigationLink(value: AppRoute.primeTagDetail(file: tag.filePath, title: tag.translatedName)) {
                        PrimeTagCard(tag: tag)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .navigationTitle(l10n.t(.primeTagsTitle))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrimeTagCard: View {
    let tag: PrimeTag

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tag.translatedName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.primary)
                if !tag.name.isEmpty, tag.name != tag.translatedName {
                    Text(tag.name)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }

            if !tag.previewSquareUrls.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(tag.previewSquareUrls.prefix(3).enumerated()), id: \.offset) { _, s in
                        Color(.tertiarySystemBackground)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                PixivAsyncImage(url: URL(string: s), showsProgress: false)
                                    .aspectRatio(contentMode: .fill)
                            }
                            .clipShape(.rect(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
    }
}

// MARK: - Tag detail (curated snapshot)

/// Waterfall of a featured tag's bundled illusts — 1:1 with upstream
/// `PrimeTagDetailFragment` (which reads the same per-tag snapshot file). Fully
/// local; no API call until a work is opened.
struct PrimeTagDetailView: View {
    let file: String
    let title: String

    @State private var illusts: [Illust] = []
    @State private var loading = true

    var body: some View {
        IllustWaterfallList(
            illusts: illusts,
            isLoading: loading,
            errorMessage: nil,
            onRefresh: { await load() },
            hasMore: false
        )
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard illusts.isEmpty else { return }
            await load()
        }
    }

    private func load() async {
        loading = true
        illusts = await PrimeTagsStore.illusts(forFilePath: file)
        loading = false
    }
}
