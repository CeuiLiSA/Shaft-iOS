import SwiftUI

/// Local view-history list. Replaces the placeholder.
struct HistoryView: View {
    @State private var store = HistoryStore.shared
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        List {
            if store.entries.isEmpty {
                ContentUnavailableView(l10n.t(.nothingHere),
                                       systemImage: "clock.arrow.circlepath")
            }
            ForEach(store.entries) { entry in
                NavigationLink(value: route(for: entry)) {
                    HistoryRow(entry: entry)
                }
            }
            .onDelete { offsets in
                var copy = store.entries
                copy.remove(atOffsets: offsets)
                store.entries = copy
                // Persist via re-record: simplest, replay order; use load/save
                // dance via clear + bulk re-add. Here we just write directly.
                let key = "view_history_v1"
                if let data = try? JSONEncoder().encode(copy) {
                    UserDefaults.standard.set(data, forKey: key)
                }
            }
        }
        .listStyle(.plain)
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
