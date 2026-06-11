import SwiftUI

// Reader bottom sheets — 1:1 ports of upstream ChapterListSheet /
// BookmarksSheet / AnnotationsSheet / SearchHitsSheet / SeriesListSheet /
// NoteEditorDialog / ExportSheet (70% height sheets, current item accented +
// bold + auto-scrolled, long-press delete flows, dated footers).

private let sheetDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f
}()

private struct SheetHeader: View {
    let title: String
    let count: String

    var body: some View {
        HStack {
            Text(title).font(.system(size: 16, weight: .semibold))
            Spacer()
            Text(count).font(.system(size: 13)).foregroundStyle(Theme.v3Text3)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }
}

// MARK: - 目录

struct ReaderChapterListSheet: View {
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss

    let outline: [ChapterOutlineEntry]
    let currentCharIndex: Int
    var onSelect: (ChapterOutlineEntry) -> Void

    private var currentEntry: ChapterOutlineEntry? {
        outline.last { $0.sourceStart <= currentCharIndex }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: l10n.t(.nrChaptersTitle),
                        count: String(format: l10n.t(.nrChaptersCountFmt), outline.count))
            ScrollViewReader { proxy in
                List(outline) { entry in
                    let isCurrent = entry == currentEntry
                    Button {
                        onSelect(entry)
                        dismiss()
                    } label: {
                        Text(entry.title)
                            .font(.system(size: 14, weight: isCurrent ? .bold : .regular))
                            .foregroundStyle(isCurrent ? Color.accentColor : Theme.v3Text1)
                    }
                    .id(entry.id)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .onAppear {
                    if let cur = currentEntry { proxy.scrollTo(cur.id, anchor: .center) }
                }
            }
        }
        .presentationDetents([.fraction(0.7)])
    }
}

// MARK: - 位置书签

struct ReaderBookmarksSheet: View {
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss

    let bookmarks: [NovelPositionBookmark]
    var onJump: (NovelPositionBookmark) -> Void
    var onDelete: (NovelPositionBookmark) -> Void

    @State private var pendingDelete: NovelPositionBookmark?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: l10n.t(.nrBookmarksTitle),
                        count: String(format: l10n.t(.nrBookmarksCountFmt), bookmarks.count))
            if bookmarks.isEmpty {
                Spacer()
                Text(l10n.t(.nrBookmarksEmpty))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.v3Text3)
                    .multilineTextAlignment(.center)
                Spacer()
            } else {
                List(bookmarks) { bm in
                    Button {
                        onJump(bm)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bm.preview.isEmpty
                                 ? String(format: l10n.t(.nrBookmarkPageFmt), bm.pageIndex + 1)
                                 : bm.preview)
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.v3Text1)
                                .lineLimit(2)
                            Text("\(String(format: l10n.t(.nrBookmarkPageFmt), bm.pageIndex + 1)) · \(sheetDateFormatter.string(from: Date(timeIntervalSince1970: bm.createdTime)))")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.v3Text3)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .onLongPressGesture { pendingDelete = bm }
                }
                .listStyle(.plain)
            }
        }
        .presentationDetents([.fraction(0.7)])
        .confirmationDialog(l10n.t(.nrBookmarkDeleteConfirm), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button(l10n.t(.actionDelete), role: .destructive) {
                if let bm = pendingDelete { onDelete(bm) }
                pendingDelete = nil
            }
        }
    }
}

// MARK: - 笔记 / 高亮

struct ReaderAnnotationsSheet: View {
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss

    let annotations: [NovelAnnotation]
    var onJump: (NovelAnnotation) -> Void
    var onEdit: (NovelAnnotation) -> Void
    var onDelete: (NovelAnnotation) -> Void

    @State private var actionTarget: NovelAnnotation?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: l10n.t(.nrAnnotationsTitle),
                        count: String(format: l10n.t(.nrBookmarksCountFmt), annotations.count))
            if annotations.isEmpty {
                Spacer()
                Text(l10n.t(.nrAnnotationsEmpty))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.v3Text3)
                    .multilineTextAlignment(.center)
                Spacer()
            } else {
                List(annotations) { a in
                    Button {
                        onJump(a)
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(UIColor(argb: a.colorARGB | 0xFF000000)))
                                .frame(width: 10, height: 10)
                                .padding(.top, 4)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("「\(a.excerpt)」")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.v3Text1)
                                    .lineLimit(3)
                                if !a.note.isEmpty {
                                    Text("🔖 \(a.note)")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.v3Text2)
                                        .lineLimit(3)
                                }
                                Text(sheetDateFormatter.string(from: Date(timeIntervalSince1970: a.updatedTime)))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.v3Text3)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .onLongPressGesture { actionTarget = a }
                }
                .listStyle(.plain)
            }
        }
        .presentationDetents([.fraction(0.7)])
        .confirmationDialog("", isPresented: Binding(
            get: { actionTarget != nil },
            set: { if !$0 { actionTarget = nil } }
        )) {
            Button(actionTarget?.note.isEmpty == false ? l10n.t(.nrNoteEditTitle) : l10n.t(.nrNoteAddTitle)) {
                if let a = actionTarget {
                    dismiss()
                    onEdit(a)
                }
                actionTarget = nil
            }
            Button(l10n.t(.actionDelete), role: .destructive) {
                if let a = actionTarget { onDelete(a) }
                actionTarget = nil
            }
        }
    }
}

// MARK: - 搜索结果

struct ReaderSearchHitsSheet: View {
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss

    let hits: [ReaderSearchHit]
    let currentIndex: Int
    let query: String
    var onSelect: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: l10n.t(.nrSearchHitsTitle),
                        count: String(format: l10n.t(.nrSearchHitsCountFmt), hits.count))
            ScrollViewReader { proxy in
                List(hits.indices, id: \.self) { i in
                    Button {
                        onSelect(i)
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(i + 1)")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Theme.v3Text3)
                                .frame(minWidth: 28, alignment: .trailing)
                            highlightedSnippet(hits[i].snippet)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.v3Text1)
                                .lineLimit(2)
                        }
                    }
                    .id(i)
                    .listRowBackground(i == currentIndex ? Theme.v3Surface : Color.clear)
                }
                .listStyle(.plain)
                .onAppear { proxy.scrollTo(currentIndex, anchor: .center) }
            }
        }
        .presentationDetents([.fraction(0.7)])
    }

    /// Orange (0xAAFF9800) highlight over case-insensitive query matches.
    private func highlightedSnippet(_ snippet: String) -> Text {
        guard !query.isEmpty,
              let range = snippet.range(of: query, options: [.caseInsensitive]) else {
            return Text(snippet)
        }
        let before = String(snippet[..<range.lowerBound])
        let match = String(snippet[range])
        let after = String(snippet[range.upperBound...])
        var attr = AttributedString(match)
        attr.backgroundColor = Color(UIColor(argb: 0xAAFF9800))
        return Text(before) + Text(attr) + Text(after)
    }
}

// MARK: - 系列

struct ReaderSeriesSheet: View {
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss

    let seriesTitle: String?
    let novels: [Novel]
    let currentNovelId: Int64
    let isLoading: Bool
    let errorMessage: String?
    var onSelect: (Novel) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: seriesTitle ?? l10n.t(.nrSeriesTitle),
                        count: String(format: l10n.t(.nrSeriesCountFmt), novels.count))
            if isLoading && novels.isEmpty {
                Spacer()
                ProgressView(l10n.t(.nrSeriesLoading))
                Spacer()
            } else if let errorMessage, novels.isEmpty {
                Spacer()
                Text(String(format: l10n.t(.nrSeriesLoadFailedFmt), errorMessage))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.v3Text3)
                Spacer()
            } else if novels.isEmpty {
                Spacer()
                Text(l10n.t(.nrSeriesEmpty))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.v3Text3)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List(Array(novels.enumerated()), id: \.element.id) { i, novel in
                        let isCurrent = novel.id == currentNovelId
                        Button {
                            if !isCurrent {
                                onSelect(novel)
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(i + 1)")
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(isCurrent ? Color.accentColor : Theme.v3Text3)
                                    .frame(minWidth: 28, alignment: .trailing)
                                Text(novel.title ?? "")
                                    .font(.system(size: 14, weight: isCurrent ? .bold : .regular))
                                    .foregroundStyle(isCurrent ? Color.accentColor : Theme.v3Text1)
                                    .lineLimit(2)
                                if isCurrent {
                                    Spacer()
                                    Text(l10n.t(.nrSeriesCurrent))
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor, in: .capsule)
                                }
                            }
                        }
                        .id(novel.id)
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .onAppear { proxy.scrollTo(currentNovelId, anchor: .center) }
                }
            }
        }
        .presentationDetents([.fraction(0.7)])
    }
}

// MARK: - 笔记编辑

struct ReaderNoteEditorSheet: View {
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss

    let annotationId: Int64
    let charStart: Int
    let charEnd: Int
    let excerpt: String
    let initialNote: String
    let colorARGB: UInt32
    let showDelete: Bool
    var onSave: (Int64, Int, Int, String, String, UInt32) -> Void
    var onDelete: (Int64) -> Void

    @State private var noteText: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                if !excerpt.isEmpty {
                    Text("「\(String(excerpt.prefix(200)))」")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.v3Text3)
                }
                TextEditor(text: $noteText)
                    .font(.system(size: 15))
                    .frame(minHeight: 120, maxHeight: 240)
                    .focused($focused)
                    .overlay(alignment: .topLeading) {
                        if noteText.isEmpty {
                            Text(l10n.t(.nrNoteHint))
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.v3Text3)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                    }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .navigationTitle(l10n.t(annotationId == 0 ? .nrNoteAddTitle : .nrNoteEditTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(l10n.t(.actionCancel)) { dismiss() }
                }
                if showDelete {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(l10n.t(.actionDelete), role: .destructive) {
                            onDelete(annotationId)
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(l10n.t(.nrActionSave)) {
                        onSave(annotationId, charStart, charEnd, excerpt, noteText, colorARGB)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            noteText = initialNote
            focused = true
        }
    }
}

// MARK: - 导出

struct ReaderExportSheet: View {
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss

    var onChoose: (ReaderExportFormat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: l10n.t(.nrExportTitle), count: "")
            List(ReaderExportFormat.allCases, id: \.self) { format in
                Button {
                    onChoose(format)
                    dismiss()
                } label: {
                    HStack(spacing: 14) {
                        Text(format.emoji).font(.system(size: 22))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(l10n.t(format.titleKey))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.v3Text1)
                            Text(l10n.t(format.descKey))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.v3Text3)
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
        }
        .presentationDetents([.fraction(0.45)])
    }
}
