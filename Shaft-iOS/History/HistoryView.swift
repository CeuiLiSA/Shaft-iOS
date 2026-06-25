import SwiftUI
import UniformTypeIdentifiers

/// Local view-history list with All/Illusts/Novels/Users tabs, mirroring
/// FragmentHistoryV3 from Pixiv-Shaft.
struct HistoryView: View {
    @State private var store = HistoryStore.shared
    @State private var section: Section = .all
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var exportDoc: HistoryBackupDocument?
    @State private var alertMessage: String?
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
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        if store.entries.isEmpty {
                            alertMessage = l10n.t(.historyExportEmpty)
                        } else if let data = store.exportJSON() {
                            exportDoc = HistoryBackupDocument(data: data)
                            showExporter = true
                        }
                    } label: {
                        Label(l10n.t(.actionExport), systemImage: "square.and.arrow.up")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label(l10n.t(.actionImport), systemImage: "square.and.arrow.down")
                    }
                    if !store.entries.isEmpty {
                        Divider()
                        Button(role: .destructive) { store.clear() } label: {
                            Label(l10n.t(.actionClear), systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        // Save the snapshot to Files / share, and restore one back (1:1 with
        // BrowseHistoryBackup's export/import — local only).
        .fileExporter(isPresented: $showExporter, document: exportDoc,
                      contentType: .json, defaultFilename: "shaft-history") { _ in }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            handleImport(result)
        }
        .alert(alertMessage ?? "", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button(l10n.t(.actionDone), role: .cancel) {}
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            alertMessage = l10n.t(.historyImportFailed)
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let imported = try HistoryStore.decodeBackup(data)
            let added = store.merge(imported)
            alertMessage = String(format: l10n.t(.historyImportedFmt), "\(added)")
        } catch {
            alertMessage = l10n.t(.historyImportFailed)
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

/// Thin `FileDocument` wrapper so `.fileExporter` can write the history-backup
/// JSON to Files / a share sheet, and the importer can read one back.
struct HistoryBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
