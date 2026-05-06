import SwiftUI

/// Local view-history list with All/Illusts/Novels/Users tabs, mirroring
/// FragmentHistoryV3 from Pixiv-Shaft.
struct HistoryView: View {
    @State private var store = HistoryStore.shared
    @State private var section: Section = .all
    @Environment(OnboardingStore.self) private var l10n

    enum Section: Hashable, CaseIterable {
        case all, illust, novel, user

        var kind: HistoryStore.Kind? {
            switch self {
            case .all:    return nil
            case .illust: return .illust
            case .novel:  return .novel
            case .user:   return .user
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PagerTabBar(
                titles: Section.allCases.map { ($0, label(for: $0)) },
                selection: $section
            )
            TabView(selection: $section) {
                ForEach(Section.allCases, id: \.self) { sec in
                    list(for: sec).tag(sec)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle(l10n.t(.historyTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { store.clear() } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func list(for section: Section) -> some View {
        let entries = filtered(for: section)
        List {
            if entries.isEmpty {
                ContentUnavailableView(l10n.t(.nothingHere),
                                       systemImage: "clock.arrow.circlepath")
            }
            ForEach(entries) { entry in
                NavigationLink(value: route(for: entry)) {
                    HistoryRow(entry: entry)
                }
            }
            .onDelete { offsets in
                let toDelete = offsets.map { entries[$0].compositeID }
                store.entries.removeAll { toDelete.contains($0.compositeID) }
                store.persist()
            }
        }
        .listStyle(.plain)
    }

    private func filtered(for section: Section) -> [HistoryStore.Entry] {
        guard let kind = section.kind else { return store.entries }
        return store.entries.filter { $0.kind == kind }
    }

    private func label(for s: Section) -> String {
        switch s {
        case .all:    return l10n.t(.historyAll)
        case .illust: return l10n.t(.searchTabIllust)
        case .novel:  return l10n.t(.searchTabNovel)
        case .user:   return l10n.t(.searchTabUser)
        }
    }

    private func route(for entry: HistoryStore.Entry) -> AppRoute {
        switch entry.kind {
        case .illust: return .illustDetail(entry.id)
        case .novel:  return .novelDetail(entry.id)
        case .user:   return .userProfile(entry.id)
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryStore.Entry

    var body: some View {
        HStack(spacing: 12) {
            PixivAsyncImage(url: entry.imageURL.flatMap(URL.init(string:)))
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: entry.kind == .user ? 28 : 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? "(\(entry.kind.rawValue))" : entry.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(entry.subtitle)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(entry.viewedAt, format: .relative(presentation: .numeric))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
