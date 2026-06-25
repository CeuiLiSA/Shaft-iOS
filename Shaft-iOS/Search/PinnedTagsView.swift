import SwiftUI
import Observation

// MARK: - Store

/// App-wide truth for pinned ("置顶") search tags, persisted to UserDefaults.
/// 1:1 with upstream `pixiv/ui/pinned/` — the Android app keeps these as
/// `search_table` rows with `pinned = 1`, keyed by tag name and ordered by the
/// pin time (newest first). We mirror that: a tag is keyed by `name`, re-pinning
/// just refreshes its preview + moves it to the front, and the optional preview
/// thumbnail mirrors `previewIllustsJson` (the square thumb of the illust the
/// user pinned from). Unlike upstream's recent-search list this is never capped —
/// pins are explicit user intent (issue #524).
@MainActor
@Observable
final class PinnedTagsStore {
    static let shared = PinnedTagsStore()

    private let key = "pinned_tags_v1"
    private let defaults = UserDefaults.standard

    /// Newest pin first.
    var tags: [PinnedTag] = []

    init() { tags = load() }

    func isPinned(_ name: String?) -> Bool {
        guard let n = normalized(name) else { return false }
        return tags.contains { $0.name == n }
    }

    /// Pin a tag, or refresh an existing pin. `previewURL` is the square thumb of
    /// the work the user pinned from (mirrors upstream's `buildPinnedTagPreviewJson`);
    /// when nil — e.g. pinning from a tag chip with no work context — any preview
    /// already stored is preserved rather than wiped (matches the 3-arg
    /// `insertPinnedSearchHistory` path).
    func pin(name: String?, translatedName: String?, previewURL: String? = nil) {
        guard let n = normalized(name) else { return }
        var previews: [String] = []
        if let p = previewURL, !p.isEmpty {
            previews = [p]
        } else if let existing = tags.first(where: { $0.name == n }) {
            previews = existing.previewURLs
        }
        tags.removeAll { $0.name == n }
        tags.insert(
            PinnedTag(name: n, translatedName: translatedName, previewURLs: previews, pinnedAt: Date()),
            at: 0
        )
        save()
    }

    func unpin(_ name: String?) {
        guard let n = normalized(name) else { return }
        tags.removeAll { $0.name == n }
        save()
    }

    func toggle(name: String?, translatedName: String?, previewURL: String? = nil) {
        if isPinned(name) { unpin(name) }
        else { pin(name: name, translatedName: translatedName, previewURL: previewURL) }
    }

    func clear() {
        tags.removeAll()
        save()
    }

    private func normalized(_ name: String?) -> String? {
        let t = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    private func load() -> [PinnedTag] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([PinnedTag].self, from: data)
        else { return [] }
        return decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tags) {
            defaults.set(data, forKey: key)
        }
    }
}

/// One pinned tag. `previewURLs` holds up to a few square thumbs (we currently
/// store one, like upstream) shown on the card; empty for tags pinned without a
/// work context.
struct PinnedTag: Codable, Hashable, Identifiable {
    let name: String
    let translatedName: String?
    var previewURLs: [String]
    let pinnedAt: Date

    var id: String { name }
}

// MARK: - List screen

/// "置顶标签" list page — 1:1 with `PinnedTagsFragment`. Cards mirror the prime-tag
/// cell (translated name as title, original as subtitle, up to three square
/// previews); tapping opens search results, long-press unpins, and the toolbar
/// clears all (with confirmation, like upstream's QMUIDialog).
struct PinnedTagsView: View {
    @State private var store = PinnedTagsStore.shared
    @State private var showClear = false
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        ScrollView {
            if store.tags.isEmpty {
                ContentUnavailableView(l10n.t(.nothingHere), systemImage: "pin")
                    .padding(.top, 100)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(store.tags) { tag in
                        NavigationLink(value: AppRoute.searchResults(word: tag.name)) {
                            PinnedTagCard(tag: tag) { store.unpin(tag.name) }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { store.unpin(tag.name) } label: {
                                Label(l10n.t(.actionUnpinTag), systemImage: "pin.slash")
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .navigationTitle(l10n.t(.pinnedTagsTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.tags.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { showClear = true } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .confirmationDialog(l10n.t(.pinnedClearMessage), isPresented: $showClear, titleVisibility: .visible) {
            Button(l10n.t(.actionClear), role: .destructive) { store.clear() }
            Button(l10n.t(.actionCancel), role: .cancel) {}
        }
    }
}

private struct PinnedTagCard: View {
    let tag: PinnedTag
    let onUnpin: () -> Void

    private var title: String {
        let t = tag.translatedName ?? ""
        return t.isEmpty ? tag.name : t
    }
    private var showSubtitle: Bool {
        guard let t = tag.translatedName, !t.isEmpty else { return false }
        return t != tag.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(title)")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)
                    if showSubtitle {
                        Text(tag.name)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button(action: onUnpin) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(.tertiarySystemBackground), in: .circle)
                }
                .buttonStyle(.plain)
            }

            if !tag.previewURLs.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(tag.previewURLs.prefix(3).enumerated()), id: \.offset) { _, s in
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
