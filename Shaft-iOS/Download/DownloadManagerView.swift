import SwiftUI

/// Download manager — 1:1 with Shaft's `DownloadManagerV3Fragment`: a three-tab
/// host (批量队列 / 正在下载 / 已完成) over the shared `DownloadManager`. Storage is
/// the Photo library (iOS has no SAF/NAS), so there are no per-file paths to
/// surface — rows show work-level progress and page counts instead.
struct DownloadManagerView: View {
    @State private var manager = DownloadManager.shared
    @Environment(OnboardingStore.self) private var l10n
    @State private var tab: DLTab = .queue

    enum DLTab: Hashable, CaseIterable { case queue, active, done }

    private func title(_ t: DLTab) -> String {
        switch t {
        case .queue:  return l10n.t(.dlTabQueue)
        case .active: return l10n.t(.dlTabActive)
        case .done:   return l10n.t(.dlTabDone)
        }
    }

    /// Tab title with a live count suffix, like upstream "正在下载 (3)".
    private func titleWithCount(_ t: DLTab) -> String {
        let base = title(t)
        let n: Int
        switch t {
        case .queue:  n = manager.queueRows.count
        case .active: n = manager.activeRows.count
        case .done:   n = manager.doneCards.count
        }
        return n > 0 ? "\(base) \(n)" : base
    }

    var body: some View {
        VStack(spacing: 0) {
            PagerTabBar(
                titles: DLTab.allCases.map { ($0, titleWithCount($0)) },
                selection: $tab
            )
            TabView(selection: $tab) {
                DownloadQueueTab(manager: manager).tag(DLTab.queue)
                DownloadActiveTab(manager: manager).tag(DLTab.active)
                DownloadDoneTab(manager: manager).tag(DLTab.done)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle(l10n.t(.dlTitle))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Shared bits

/// Small square thumbnail used by every download row.
private struct DLThumb: View {
    let urlString: String?
    var size: CGFloat = 60
    var corner: CGFloat = 10

    var body: some View {
        PixivAsyncImage(url: urlString.flatMap(URL.init(string:)), showsProgress: false)
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: corner))
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: corner))
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: .capsule)
            .foregroundStyle(color)
    }
}

private extension DownloadStatus {
    var badgeColor: Color {
        switch self {
        case .pending:     return Color(.systemGray)
        case .downloading: return .blue
        case .success:     return .green
        case .failed:      return .red
        case .paused:      return .orange
        }
    }
    var badgeKey: LocalizedKey {
        switch self {
        case .pending:     return .dlStatusPending
        case .downloading: return .dlStatusDownloading
        case .success:     return .dlStatusSuccess
        case .failed:      return .dlStatusFailed
        case .paused:      return .dlActivePaused
        }
    }
}

private struct DLEmptyState: View {
    let title: String
    let hint: String
    let systemImage: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Pill button used in each tab's bottom action bar (parity with upstream
/// btn1–btn4).
private struct DLActionButton: View {
    let title: String
    var role: ButtonRole? = nil
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: .capsule)
                .foregroundStyle(role == .destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.primary))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

// MARK: - Queue tab

private struct DownloadQueueTab: View {
    @Bindable var manager: DownloadManager
    @Environment(OnboardingStore.self) private var l10n
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            if manager.queueRows.isEmpty {
                DLEmptyState(
                    title: l10n.t(.dlQueueEmptyTitle),
                    hint: l10n.t(.dlQueueEmptyHint),
                    systemImage: "tray"
                )
            } else {
                List {
                    ForEach(manager.queueRows) { item in
                        QueueRow(item: item)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .swipeActions {
                                Button(role: .destructive) { manager.remove(item.id) } label: {
                                    Label(l10n.t(.actionDelete), systemImage: "trash")
                                }
                                if item.status == .failed {
                                    Button { manager.retry(item.id) } label: {
                                        Label(l10n.t(.actionRetry), systemImage: "arrow.clockwise")
                                    }.tint(.blue)
                                }
                            }
                    }
                }
                .listStyle(.plain)
            }

            bottomBar
        }
        .confirmationDialog(l10n.t(.dlClearQueueTitle), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(l10n.t(.dlQueueClearAll), role: .destructive) { manager.clearQueue() }
            Button(l10n.t(.actionCancel), role: .cancel) {}
        } message: {
            Text(l10n.t(.dlClearQueueMessage))
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            DLActionButton(
                title: manager.isPaused ? l10n.t(.dlQueueResume) : l10n.t(.dlQueuePause)
            ) { manager.togglePause() }
            DLActionButton(
                title: l10n.t(.dlQueueRetryFailed),
                disabled: manager.failedCount == 0
            ) { manager.retryFailed() }
            DLActionButton(
                title: l10n.t(.dlQueueClearAll),
                role: .destructive,
                disabled: manager.queueRows.isEmpty
            ) { confirmClear = true }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }
}

private struct QueueRow: View {
    let item: DownloadItem
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        NavigationLink(value: AppRoute.illustDetail(item.id)) {
            HStack(spacing: 12) {
                DLThumb(urlString: item.info.thumbnailURL)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.info.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !item.info.userName.isEmpty {
                        Text("by: \(item.info.userName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text("#\(seqText) · \(l10n.t(item.info.kind.label))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        StatusBadge(text: l10n.t(item.status.badgeKey), color: item.status.badgeColor)
                        if item.retryCount > 0 {
                            StatusBadge(text: l10n.t(.dlRetryFmt, "\(item.retryCount)"), color: .orange)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var seqText: String { String(item.seq) }
}

// MARK: - Active tab

private struct DownloadActiveTab: View {
    @Bindable var manager: DownloadManager
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
            if manager.activeRows.isEmpty {
                DLEmptyState(
                    title: l10n.t(.dlActiveEmptyTitle),
                    hint: l10n.t(.dlActiveEmptyHint),
                    systemImage: "arrow.down.circle"
                )
            } else {
                List {
                    ForEach(manager.activeRows) { item in
                        ActiveRow(item: item, paused: manager.isPaused) { manager.remove(item.id) }
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                }
                .listStyle(.plain)
            }
            bottomBar
        }
    }

    private var statusHeader: some View {
        let parts: [String] = [
            manager.downloadingCount > 0 ? "\(l10n.t(.dlStatusDownloading)) \(manager.downloadingCount)" : nil,
            manager.pendingCount > 0 ? "\(l10n.t(.dlStatusPending)) \(manager.pendingCount)" : nil,
            manager.failedCount > 0 ? "\(l10n.t(.dlStatusFailed)) \(manager.failedCount)" : nil,
        ].compactMap { $0 }
        return Group {
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 7)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            DLActionButton(
                title: manager.isPaused ? l10n.t(.dlResumeAll) : l10n.t(.dlPauseAll)
            ) { manager.togglePause() }
            DLActionButton(
                title: l10n.t(.dlQueueClearAll),
                role: .destructive,
                disabled: manager.queueRows.isEmpty
            ) { manager.clearQueue() }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }
}

private struct ActiveRow: View {
    let item: DownloadItem
    let paused: Bool
    let onCancel: () -> Void
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        HStack(spacing: 12) {
            DLThumb(urlString: item.info.thumbnailURL)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.info.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                ProgressView(value: min(max(item.progress, 0), 1))
                    .tint(paused ? .orange : (item.info.kind == .ugoira ? .purple : .blue))
                HStack(spacing: 8) {
                    Text(detailText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("\(Int(item.progress * 100))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
    }

    private var detailText: String {
        if paused { return l10n.t(.dlActivePaused) }
        if item.info.kind == .ugoira {
            let phase = item.ugoiraPhase ?? .queued
            return "UGOIRA · \(l10n.t(phase.label))"
        }
        if item.info.pageCount > 1 {
            return String(format: l10n.t(.dlActivePageFmt), "\(max(item.currentPage, 1))", "\(item.info.pageCount)")
        }
        return l10n.t(.dlStatusDownloading)
    }
}

// MARK: - Done tab

private struct DownloadDoneTab: View {
    @Bindable var manager: DownloadManager
    @Environment(OnboardingStore.self) private var l10n
    @State private var query = ""
    @State private var confirmClear = false

    private var filtered: [DoneRecord] {
        let cards = manager.doneCards
        guard !query.isEmpty else { return cards }
        let q = query.lowercased()
        return cards.filter { $0.title.lowercased().contains(q) || $0.userName.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if manager.doneCards.isEmpty {
                DLEmptyState(
                    title: l10n.t(.dlDoneEmptyTitle),
                    hint: l10n.t(.dlDoneEmptyHint),
                    systemImage: "checkmark.circle"
                )
            } else {
                content
            }
            bottomBar
        }
        .confirmationDialog(l10n.t(.dlDoneClearTitle), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(l10n.t(.dlDoneClearHistory), role: .destructive) { manager.clearDoneHistory() }
            Button(l10n.t(.actionCancel), role: .cancel) {}
        } message: {
            Text(l10n.t(.dlDoneClearMessage))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch manager.doneLayout {
        case .list:
            List {
                ForEach(filtered) { rec in
                    DoneListRow(record: rec)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .swipeActions {
                            Button(role: .destructive) { manager.deleteDone(rec.id) } label: {
                                Label(l10n.t(.actionDelete), systemImage: "trash")
                            }
                        }
                }
            }
            .listStyle(.plain)
        case .grid, .compact:
            gridView
        }
    }

    private var gridView: some View {
        let cols = manager.doneLayout == .compact ? 4 : 2
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: cols)
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(filtered) { rec in
                    DoneGridCell(record: rec, compact: manager.doneLayout == .compact) {
                        manager.deleteDone(rec.id)
                    }
                }
            }
            .padding(8)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(l10n.t(.dlDoneSearchHint), text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: .capsule)
        .padding(.horizontal, 12).padding(.top, 8)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            DLActionButton(title: l10n.t(manager.doneLayout.label)) {
                manager.doneLayout = manager.doneLayout.next
            }
            DLActionButton(
                title: l10n.t(.dlDoneClearHistory),
                role: .destructive,
                disabled: manager.doneCards.isEmpty
            ) { confirmClear = true }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }
}

private struct PageCountBadge: View {
    let count: Int
    var body: some View {
        if count > 1 {
            Text("\(count)P")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.6), in: .capsule)
                .foregroundStyle(.white)
        }
    }
}

private struct DoneListRow: View {
    let record: DoneRecord
    var body: some View {
        NavigationLink(value: AppRoute.illustDetail(record.id)) {
            HStack(spacing: 12) {
                DLThumb(urlString: record.thumbnailURL, size: 64, corner: 10)
                    .overlay(alignment: .topLeading) {
                        PageCountBadge(count: record.pageCount).padding(4)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !record.userName.isEmpty {
                        Text("by: \(record.userName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(Self.dateText(record.savedAt))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Cached — `DateFormatter` is expensive to construct, and rows recycle
    /// constantly while scrolling.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func dateText(_ d: Date) -> String { formatter.string(from: d) }
}

private struct DoneGridCell: View {
    let record: DoneRecord
    let compact: Bool
    let onDelete: () -> Void

    var body: some View {
        NavigationLink(value: AppRoute.illustDetail(record.id)) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topLeading) {
                    PixivAsyncImage(url: record.thumbnailURL.flatMap(URL.init(string:)), showsProgress: false)
                        .aspectRatio(1, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: compact ? 90 : 150)
                        .clipShape(.rect(cornerRadius: compact ? 8 : 12))
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: compact ? 8 : 12))
                    PageCountBadge(count: record.pageCount).padding(5)
                }
                .overlay(alignment: .bottomTrailing) {
                    Button(action: onDelete) {
                        Image(systemName: "trash.circle.fill")
                            .font(compact ? .body : .title3)
                            .foregroundStyle(.white, .black.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                }
                if !compact {
                    Text(record.title).font(.caption.weight(.medium)).lineLimit(1)
                    if !record.userName.isEmpty {
                        Text("by: \(record.userName)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}
