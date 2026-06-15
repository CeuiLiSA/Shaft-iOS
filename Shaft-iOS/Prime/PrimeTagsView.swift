import SwiftUI

// MARK: - Model

/// One featured tag from the bundled prime index — original (JP) name,
/// translated (localized) name, and three square preview thumbnails. 1:1 with
/// upstream `PrimeTagIndexItem` (we drop `file_path`: the 90 MB of per-tag
/// snapshot JSON the Android app bundles isn't shipped — tapping a tag does a
/// live tag search instead, so results stay fresh and the app stays small).
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
    let previewSquareUrls: [String]

    enum CodingKeys: String, CodingKey {
        case tag
        case previewSquareUrls = "preview_square_urls"
    }

    var id: String { tag.name ?? tag.translatedName ?? "" }
    var name: String { tag.name ?? "" }
    var translatedName: String { tag.translatedName ?? tag.name ?? "" }
    /// What to feed pixiv search — the canonical JP tag, falling back to the
    /// translated name if a tag somehow has no original.
    var searchTerm: String { name.isEmpty ? translatedName : name }
}

enum PrimeTagsStore {
    /// Decode the bundled `prime_index.json` (97 featured tags, ~48 KB) once.
    static let all: [PrimeTag] = {
        guard let url = Bundle.main.url(forResource: "prime_index", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let tags = try? JSONDecoder().decode([PrimeTag].self, from: data) else { return [] }
        return tags
    }()
}

// MARK: - View

/// 热度标签 — a vertical list of featured-tag cards (translated + original name
/// over a 3-up square preview strip), 1:1 with Shaft's `PrimeTagsFragment`.
/// Tapping a card opens a live search for that tag.
struct PrimeTagsView: View {
    @Environment(OnboardingStore.self) private var l10n
    private let tags = PrimeTagsStore.all

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(tags) { tag in
                    NavigationLink(value: AppRoute.tagResults(tag: tag.searchTerm)) {
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
