import SwiftUI

/// Identifiable seed so a waterfall long-press can drive a `.fullScreenCover`.
struct BulkSelectionSeed: Identifiable {
    let id = UUID()
    let illusts: [Illust]
}

/// V3 bulk-download multi-select page — 1:1 with Shaft's `BulkSelectV3Fragment`.
/// Reached by long-pressing a waterfall cell; seeded with that list's works, all
/// pre-selected. A 3-column grid of toggleable cards; select-all / clear-all and
/// export-links in the toolbar; a summary + "download selected" at the bottom
/// that batch-enqueues into the `DownloadManager`.
struct BulkSelectView: View {
    let illusts: [Illust]
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingStore.self) private var l10n

    @State private var selected: Set<Int64>
    @State private var toast: String?

    init(illusts: [Illust]) {
        // Dedupe by id (a list can repeat across pages) while keeping order.
        var seen = Set<Int64>()
        self.illusts = illusts.filter { seen.insert($0.id).inserted }
        _selected = State(initialValue: Set(self.illusts.map(\.id)))
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    private var selectedIllusts: [Illust] { illusts.filter { selected.contains($0.id) } }
    private var imageCount: Int { selectedIllusts.reduce(0) { $0 + max($1.pageCount ?? 1, 1) } }
    private var allSelected: Bool { selected.count == illusts.count }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(illusts) { illust in
                            BulkCell(illust: illust, selected: selected.contains(illust.id)) {
                                toggle(illust.id)
                            }
                        }
                    }
                    .padding(8)
                    .padding(.bottom, 76)   // clear the bottom bar
                }

                bottomBar
            }
            .navigationTitle(l10n.t(.dlBulkTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(l10n.t(.actionCancel)) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let n = DownloadExportLinks.copyToClipboard(selectedIllusts)
                        flash(l10n.t(.dlLinksCopiedFmt, "\(n)"))
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .disabled(selected.isEmpty)
                    .accessibilityLabel(l10n.t(.dlBulkExportLinks))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if allSelected { selected.removeAll() }
                        else { selected = Set(illusts.map(\.id)) }
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
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Text(String(format: l10n.t(.dlBulkSummaryFmt), "\(illusts.count)", "\(selected.count)", "\(imageCount)"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                let n = DownloadManager.shared.enqueue(selectedIllusts)
                flash(l10n.t(.dlEnqueuedFmt, "\(n)"))
                Task {
                    try? await Task.sleep(nanoseconds: 850_000_000)
                    dismiss()
                }
            } label: {
                Text(l10n.t(.dlBulkDownloadSelected))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(selected.isEmpty ? AnyShapeStyle(Color(.systemGray4)) : AnyShapeStyle(Theme.brand), in: .capsule)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)
        .background(.bar)
    }

    private func toggle(_ id: Int64) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func flash(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if toast == message { toast = nil }
        }
    }
}

private struct BulkCell: View {
    let illust: Illust
    let selected: Bool
    let onTap: () -> Void

    private var thumbURL: URL? {
        (illust.imageUrls?.squareMedium ?? illust.imageUrls?.medium ?? illust.imageUrls?.large)
            .flatMap(URL.init(string:))
    }

    var body: some View {
        Button(action: onTap) {
            PixivAsyncImage(url: thumbURL, showsProgress: false)
                .aspectRatio(1, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: 118)
                .clipShape(.rect(cornerRadius: 10))
                .overlay(alignment: .topTrailing) { badges }
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(selected ? Theme.brand : Color.clear, lineWidth: 3)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.white))
                        .background(Circle().fill(.black.opacity(0.25)))
                        .padding(5)
                }
                .scaleEffect(selected ? 0.94 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: selected)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if illust.type == "ugoira" {
                Text("GIF")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.purple.opacity(0.85), in: .capsule)
                    .foregroundStyle(.white)
            }
            if (illust.pageCount ?? 1) > 1 {
                Text("\(illust.pageCount ?? 1)P")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: .capsule)
                    .foregroundStyle(.white)
            }
        }
        .padding(5)
    }
}
