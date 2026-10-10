import SwiftUI

/// Raw keys are Android `DownloadToastKind.name`, so cross-device backups retain choices.
enum DownloadNoticeKind: String, CaseIterable, Identifiable {
    case enqueued = "ENQUEUED", enqueueFailed = "ENQUEUE_FAILED"
    case done = "DOWNLOAD_DONE", failed = "DOWNLOAD_FAILED", aria2 = "ARIA2"
    case storageUnavailable = "STORAGE_UNAVAILABLE", recordRestored = "RECORD_RESTORED"
    case lowStorage = "LOW_STORAGE_PAUSED", bulkEnqueue = "BULK_ENQUEUE", bulkSummary = "BULK_SUMMARY"
    case novelProgress = "NOVEL_PROGRESS", novelBatchResult = "NOVEL_BATCH_RESULT"
    case novelSave = "NOVEL_SAVE", novelSeriesExport = "NOVEL_SERIES_EXPORT", novelAutoDownload = "NOVEL_AUTO_DOWNLOAD"
    var id: String { rawValue }
    static let supported: [Self] = [.enqueued, .done, .failed, .lowStorage, .bulkEnqueue, .novelProgress, .novelBatchResult, .novelSave]
    var isNovel: Bool { rawValue.hasPrefix("NOVEL_") }
    var label: LocalizedKey {
        switch self {
        case .enqueued: return .downloadToastEnqueued
        case .enqueueFailed: return .downloadToastEnqueueFailed
        case .done: return .downloadToastDownloadDone
        case .failed: return .downloadToastDownloadFailed
        case .aria2: return .downloadToastAria2
        case .storageUnavailable: return .downloadToastStorageUnavailable
        case .recordRestored: return .downloadToastRecordRestored
        case .lowStorage: return .downloadToastLowStoragePaused
        case .bulkEnqueue: return .downloadToastBulkEnqueue
        case .bulkSummary: return .downloadToastBulkSummary
        case .novelProgress: return .downloadToastNovelProgress
        case .novelBatchResult: return .downloadToastNovelBatchResult
        case .novelSave: return .downloadToastNovelSave
        case .novelSeriesExport: return .downloadToastNovelSeriesExport
        case .novelAutoDownload: return .downloadToastNovelAutoDownload
        }
    }
    static func migratedMuted(_ muted: Set<String>, legacyEnabled: Bool, migrated: Bool) -> Set<String> {
        guard !migrated, !legacyEnabled else { return muted }
        return muted.union(["DOWNLOAD_DONE", "DOWNLOAD_FAILED", "ARIA2", "NOVEL_AUTO_DOWNLOAD"])
    }
    static func allows(_ kind: Self, muted: Set<String>) -> Bool { !muted.contains(kind.rawValue) }
    @MainActor var enabled: Bool { Self.allows(self, muted: AppSettingsStore.shared.mutedDownloadToasts) }
}

struct DownloadNoticeSettingsView: View {
    @State private var settings = AppSettingsStore.shared
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(l10n.t(.downloadToastDialogHint)).font(.subheadline).foregroundStyle(Theme.v3Text2) }
                ForEach([false, true], id: \.self) { novel in
                    Section(l10n.t(novel ? .downloadToastGroupNovel : .downloadToastGroupImage)) {
                        ForEach(DownloadNoticeKind.supported.filter { $0.isNovel == novel }) { kind in
                            Toggle(l10n.t(kind.label), isOn: Binding(get: { kind.enabled }, set: { value in
                                if value { settings.mutedDownloadToasts.remove(kind.rawValue) }
                                else { settings.mutedDownloadToasts.insert(kind.rawValue) }
                            }))
                        }
                    }
                }
            }
            .tint(Theme.brand)
            .navigationTitle(l10n.t(.downloadToastEntryTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(l10n.t(.actionDone)) { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}
