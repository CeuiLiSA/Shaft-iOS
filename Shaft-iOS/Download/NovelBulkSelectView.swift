import SwiftUI

/// Identifiable seed so a novel-card long-press can drive a `.fullScreenCover`.
struct NovelBulkSelectionSeed: Identifiable {
    let id = UUID()
    let novels: [Novel]
}

/// Novel multi-select page — 1:1 with upstream `NovelBulkSelectV3Fragment`
/// (issue #974). Seeded with the list the long-pressed card came from, all
/// pre-selected. Bottom bar downloads the selection as TXT files
/// (`BatchDownloadNovelsTask`); the toolbar menu bulk-bookmarks or
/// bulk-unbookmarks the selection behind a confirm.
struct NovelBulkSelectView: View {
    let novels: [Novel]
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n
    @State private var store = InteractionStore.shared

    @State private var selected: Set<Int64>
    @State private var toast: String?
    @State private var progress: (done: Int, total: Int)?
    @State private var pendingBookmark: BookmarkOp?

    private enum BookmarkOp: Identifiable {
        case add(count: Int), remove(count: Int)
        var id: String {
            switch self {
                case .add(let n): return "add\(n)"
                case .remove(let n): return "remove\(n)"
            }
        }
    }

    init(novels: [Novel]) {
        var seen = Set<Int64>()
        self.novels = novels.filter { seen.insert($0.id).inserted }
        _selected = State(initialValue: Set(self.novels.map(\.id)))
    }

    private var selectedNovels: [Novel] { novels.filter { selected.contains($0.id) } }
    private var allSelected: Bool { selected.count == novels.count }
    private var toBookmark: [Novel] { selectedNovels.filter { !store.isBookmarked($0) } }
    private var toUnbookmark: [Novel] { selectedNovels.filter { store.isBookmarked($0) } }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(novels) { novel in
                            NovelBulkCell(novel: novel, selected: selected.contains(novel.id)) {
                                toggle(novel.id)
                            }
                        }
                    }
                    .padding(.bottom, 76)
                }
                bottomBar
            }
            .navigationTitle(l10n.t(.novelBulkTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(l10n.t(.actionCancel)) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            requestBookmark(add: true)
                        } label: {
                            Label(l10n.t(.bulkBookmarkAddFmt, "\(toBookmark.count)"), systemImage: "heart.fill")
                        }
                        Button {
                            requestBookmark(add: false)
                        } label: {
                            Label(l10n.t(.bulkBookmarkRemoveFmt, "\(toUnbookmark.count)"), systemImage: "heart.slash")
                        }
                    } label: {
                        Image(systemName: "heart.circle")
                    }
                    .disabled(selected.isEmpty || progress != nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if allSelected { selected.removeAll() }
                        else { selected = Set(novels.map(\.id)) }
                    } label: {
                        Image(systemName: allSelected ? "checkmark.square.fill" : "square")
                    }
                    .accessibilityLabel(allSelected ? l10n.t(.dlBulkDeselectAll) : l10n.t(.dlBulkSelectAll))
                }
            }
            .overlay(alignment: .top) {
                if let toast {
                    Text(toast)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.black.opacity(0.82), in: .capsule)
                        .foregroundStyle(.white)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: toast)
            .confirmationDialog(
                bookmarkConfirmTitle,
                isPresented: Binding(get: { pendingBookmark != nil }, set: { if !$0 { pendingBookmark = nil } }),
                titleVisibility: .visible
            ) {
                Button(l10n.t(.bulkBookmarkConfirmGo)) {
                    if let op = pendingBookmark { runBookmark(op) }
                }
                Button(l10n.t(.actionCancel), role: .cancel) { pendingBookmark = nil }
            }
        }
    }

    private var bookmarkConfirmTitle: String {
        switch pendingBookmark {
            case .add(let n): return l10n.t(.bulkBookmarkAddConfirmFmt, "\(n)")
            case .remove(let n): return l10n.t(.bulkBookmarkRemoveConfirmFmt, "\(n)")
            case nil: return ""
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let progress {
                Text(l10n.t(.dlBulkProgressFmt, "\(progress.done)", "\(progress.total)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(l10n.t(.novelBulkSummaryFmt, "\(novels.count)", "\(selected.count)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                runDownload()
            } label: {
                Text(l10n.t(.dlBulkDownloadSelected))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        selected.isEmpty || progress != nil
                            ? AnyShapeStyle(Color(.systemGray4)) : AnyShapeStyle(Theme.brand),
                        in: .capsule
                    )
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty || progress != nil)
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)
        .background(.bar)
    }

    private func toggle(_ id: Int64) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func runDownload() {
        let targets = selectedNovels
        guard !targets.isEmpty else { return }
        progress = (0, targets.count)
        Task {
            let failures = await NovelDownloader.download(targets) { done, total in
                progress = (done, total)
            }
            progress = nil
            flash(failures.isEmpty
                  ? l10n.t(.batchDownloadAllOk)
                  : l10n.t(.batchDownloadSomeFailedFmt, "\(failures.count)"))
        }
    }

    /// `bulk_bookmark_nothing` when every selected work is already in the target
    /// state; otherwise a confirm carrying the affected count.
    private func requestBookmark(add: Bool) {
        let n = add ? toBookmark.count : toUnbookmark.count
        guard n > 0 else { flash(l10n.t(.bulkBookmarkNothing)); return }
        pendingBookmark = add ? .add(count: n) : .remove(count: n)
    }

    private func runBookmark(_ op: BookmarkOp) {
        pendingBookmark = nil
        let add: Bool
        if case .add = op { add = true } else { add = false }
        let targets = add ? toBookmark : toUnbookmark
        progress = (0, targets.count)
        Task {
            var failed = 0
            for (i, novel) in targets.enumerated() {
                do { try await store.toggleBookmark(novel: novel) } catch { failed += 1 }
                progress = (i + 1, targets.count)
            }
            progress = nil
            flash(failed == 0
                  ? l10n.t(.bulkBookmarkDoneFmt, "\(targets.count)")
                  : l10n.t(.bulkBookmarkSomeFailedFmt, "\(failed)"))
        }
    }

    private func flash(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if toast == message { toast = nil }
        }
    }
}

/// `cell_novel_bulk_select`: cover · title · author · word count · bookmark
/// state, with a leading check glyph.
private struct NovelBulkCell: View {
    let novel: Novel
    let selected: Bool
    let onTap: () -> Void
    @State private var store = InteractionStore.shared
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.secondary))
                PixivAsyncImage(
                    url: (novel.imageUrls?.medium ?? novel.imageUrls?.squareMedium).flatMap(URL.init(string:)),
                    showsProgress: false, placeholder: Theme.v3Surface2
                )
                .frame(width: 56, height: 80)
                .clipShape(.rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(novel.title ?? "")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                        .foregroundStyle(Theme.v3Text1)
                    Text(novel.user?.name ?? "")
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(Theme.v3Text2)
                    HStack(spacing: 6) {
                        Text(l10n.t(.novelWordCountFmt, "\(novel.textLength ?? 0)"))
                        if store.isBookmarked(novel) {
                            Image(systemName: "heart.fill").foregroundStyle(Theme.v3Bookmarked)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.v3Text3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(.rect)
            .opacity(selected ? 1 : 0.55)
        }
        .buttonStyle(.plain)
    }
}
