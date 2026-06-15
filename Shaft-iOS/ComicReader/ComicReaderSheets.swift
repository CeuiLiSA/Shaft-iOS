import SwiftUI

// The manga reader's modal sheets: page thumbnails (ComicThumbsSheet), per-page
// bookmarks (ComicBookmarksSheet) and the series list (ComicSeriesListSheet) —
// counterparts of the upstream BottomSheetDialogFragments.

// MARK: - Thumbnails

struct ComicThumbsSheet: View {
    let pages: [ComicReaderViewModel.ComicPage]
    let currentIndex: Int
    let title: String
    let previewFor: (ComicReaderViewModel.ComicPage) -> URL?
    let onSelect: (Int) -> Void

    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(pages) { page in
                            Button {
                                onSelect(page.index)
                                dismiss()
                            } label: {
                                VStack(spacing: 4) {
                                    PixivAsyncImage(url: previewFor(page), contentMode: .fill)
                                        .frame(height: 130)
                                        .clipShape(.rect(cornerRadius: 8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .strokeBorder(page.index == currentIndex ? Theme.brand : .clear, lineWidth: 2)
                                        )
                                        .opacity(page.index == currentIndex ? 1 : 0.9)
                                    Text("\(page.index + 1) / \(pages.count)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.v3Text3)
                                }
                            }
                            .buttonStyle(.plain)
                            .id(page.index)
                        }
                    }
                    .padding(16)
                }
                .onAppear { proxy.scrollTo(currentIndex, anchor: .center) }
            }
            .navigationTitle(title.isEmpty ? l10n.t(.crThumbsTitle) : title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Bookmarks

struct ComicBookmarksSheet: View {
    let illustId: Int64
    let onJump: (ComicBookmark) -> Void
    let onAddCurrent: () -> Void

    @State private var store = ComicReaderLocalStore.shared
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss

    private var entries: [ComicBookmark] { store.bookmarks(for: illustId) }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bookmark")
                            .font(.largeTitle)
                            .foregroundStyle(Theme.v3Text3)
                        Text(l10n.t(.crBookmarksEmpty))
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.v3Text2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(entries) { entry in
                            Button {
                                onJump(entry)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    PixivAsyncImage(url: URL(string: entry.previewUrl), contentMode: .fill)
                                        .frame(width: 48, height: 64)
                                        .clipShape(.rect(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(entry.pageIndex + 1) / \(max(entry.totalPages, 1))")
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(Theme.v3Text1)
                                        if !entry.note.isEmpty {
                                            Text(entry.note)
                                                .font(.system(size: 13))
                                                .foregroundStyle(Theme.v3Text2)
                                                .lineLimit(1)
                                        }
                                        Text(relativeTime(entry.createdTime))
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.v3Text3)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    store.deleteBookmark(id: entry.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(l10n.t(.crBookmarksTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onAddCurrent()
                        dismiss()
                    } label: {
                        Label(l10n.t(.crBookmarksAddHere), systemImage: "bookmark.fill")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private func relativeTime(_ timestamp: Double) -> String {
        Self.relativeFormatter.localizedString(for: Date(timeIntervalSince1970: timestamp), relativeTo: Date())
    }
}

// MARK: - Series list

struct ComicSeriesListSheet: View {
    let vm: ComicReaderViewModel
    let currentIllustId: Int64
    let onOpen: (Int64) -> Void

    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if vm.seriesLoading && vm.seriesIllusts.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = vm.seriesError, vm.seriesIllusts.isEmpty {
                    Text(String(format: l10n.t(.crSeriesLoadFailedFmt), error))
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.v3Text2)
                        .padding(32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.seriesIllusts.isEmpty {
                    Text(l10n.t(.crSeriesEmpty))
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.v3Text2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                    List {
                        ForEach(Array(vm.seriesIllusts.enumerated()), id: \.element.id) { idx, illust in
                            let isCurrent = illust.id == currentIllustId
                            Button {
                                if !isCurrent { onOpen(illust.id) }
                            } label: {
                                HStack(spacing: 12) {
                                    Text("\(idx + 1)")
                                        .font(.system(size: 14, weight: isCurrent ? .bold : .regular))
                                        .foregroundStyle(isCurrent ? Theme.brand : Theme.v3Text3)
                                        .frame(minWidth: 28, alignment: .leading)
                                    Text(illust.title ?? "")
                                        .font(.system(size: 15, weight: isCurrent ? .bold : .regular))
                                        .foregroundStyle(isCurrent ? Theme.brand : Theme.v3Text1)
                                        .lineLimit(2)
                                    Spacer()
                                    if isCurrent {
                                        Text(l10n.t(.crSeriesCurrent))
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Theme.brand, in: .capsule)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .id(illust.id)
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: vm.seriesIllusts.count) {
                        proxy.scrollTo(currentIllustId, anchor: .center)
                    }
                    .onAppear { proxy.scrollTo(currentIllustId, anchor: .center) }
                    }
                }
            }
            .navigationTitle(seriesTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !vm.seriesIllusts.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text(String(format: l10n.t(.crSeriesCountFmt), "\(vm.seriesIllusts.count)"))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.v3Text3)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await vm.loadSeriesIfNeeded() }
    }

    private var seriesTitle: String {
        if let t = vm.illust?.series?.title, !t.isEmpty { return t }
        return l10n.t(.crSeriesTitle)
    }
}
