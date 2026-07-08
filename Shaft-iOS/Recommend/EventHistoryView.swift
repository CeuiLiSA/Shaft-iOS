import SwiftUI

/// 操作记录 — this device's own shaft-api-v2 event log (收藏 / 关注 …), read back
/// by the anonymous `client_id`. 1:1 with upstream `FragmentEventHistory`.
/// Empty unless event reporting is enabled (a non-empty `ShaftEventsConfig.hmacSecret`).
@MainActor
@Observable
final class EventHistoryVM {
    var entries: [EventHistoryEntry] = []
    var nextBefore: Int64?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?
    let clientId = ShaftEventsConfig.clientId

    @ObservationIgnored private let client = ShaftApiV2Client.shared

    func loadIfNeeded() async { if entries.isEmpty { await load() } }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await client.eventsHistory(clientId: clientId, limit: 50)
            entries = page.entries
            nextBefore = page.nextBefore
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let before = nextBefore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let page = try? await client.eventsHistory(clientId: clientId, limit: 50, before: before) {
            entries.append(contentsOf: page.entries)
            nextBefore = page.nextBefore
        }
    }
}

struct EventHistoryView: View {
    @State private var vm = EventHistoryVM()
    @State private var copiedBanner = false
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        SensitiveGate {
            List {
                ForEach(vm.entries) { entry in
                    EventHistoryRow(entry: entry)
                }
                if vm.nextBefore != nil, !vm.entries.isEmpty {
                    Color.clear.frame(height: 40)
                        .listRowSeparator(.hidden)
                        .onAppear { Task { await vm.loadMore() } }
                }
            }
            .listStyle(.plain)
            .overlay {
                if vm.isLoading && vm.entries.isEmpty {
                    ProgressView()
                } else if vm.entries.isEmpty, let err = vm.errorMessage {
                    InlineError(message: err) { Task { await vm.load() } }.padding()
                } else if vm.entries.isEmpty, !vm.isLoading {
                    ContentUnavailableView(l10n.t(.eventHistoryEmpty), systemImage: "clock.arrow.circlepath")
                }
            }
            .overlay(alignment: .top) {
                if copiedBanner {
                    Text(l10n.t(.eventHistoryClientIdCopied, String(vm.clientId.prefix(8))))
                        .font(.footnote).padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.regularMaterial, in: .capsule)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .refreshable { await vm.load() }
            .task { await vm.loadIfNeeded() }
        }
        .navigationTitle(l10n.t(.eventHistory))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = vm.clientId
                    withAnimation { copiedBanner = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation { copiedBanner = false }
                    }
                } label: {
                    Label(l10n.t(.eventHistoryCopyClientId), systemImage: "doc.on.doc")
                }
            }
        }
    }
}

private struct EventHistoryRow: View {
    let entry: EventHistoryEntry
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                PixivAsyncImage(url: thumb, showsProgress: false)
                    .frame(width: 56, height: 56)
                    .clipShape(.rect(cornerRadius: 8))
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(titleLine).font(.subheadline).lineLimit(2)
                    Text(subtitleLine).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
    }

    private var route: AppRoute {
        switch entry.targetType {
        case "user":  return .userProfile(entry.targetId)
        case "novel": return .novelDetail(entry.targetId)
        default:      return .illustDetail(entry.targetId)
        }
    }

    private var thumb: URL? {
        let s: String?
        if let u = entry.user { s = u.profileImageUrls?.medium ?? u.profileImageUrls?.px170x170 }
        else if let n = entry.novel { s = n.imageUrls?.medium ?? n.imageUrls?.squareMedium }
        else { s = entry.illust?.imageUrls?.squareMedium ?? entry.illust?.imageUrls?.medium }
        return s.flatMap(URL.init(string:))
    }

    private var verb: String {
        switch entry.eventType {
        case "bookmark":   return l10n.t(.eventVerbBookmark)
        case "unbookmark": return l10n.t(.eventVerbUnbookmark)
        case "download":   return l10n.t(.eventVerbDownload)
        case "follow":     return l10n.t(.eventVerbFollow)
        case "unfollow":   return l10n.t(.eventVerbUnfollow)
        default:           return entry.eventType
        }
    }

    private var targetName: String {
        if let u = entry.user { return u.name ?? "@\(entry.targetId)" }
        if let n = entry.novel { return n.title ?? "#\(entry.targetId)" }
        if let il = entry.illust { return il.title ?? "#\(entry.targetId)" }
        return "#\(entry.targetId)"
    }

    private var titleLine: String { "\(verb) \(targetName)" }

    private var typeLabel: String {
        switch entry.targetType {
        case "user":  return l10n.t(.typeUser)
        case "manga": return l10n.t(.profileManga)
        case "novel": return l10n.t(.profileNovels)
        default:      return l10n.t(.profileIllusts)
        }
    }

    private var subtitleLine: String {
        "\(typeLabel) · \(Self.relative(entry.ts))"
    }

    /// `ts` is server epoch-ms. Relative to now.
    private static func relative(_ tsMillis: Int64) -> String {
        guard tsMillis > 0 else { return "" }
        let date = Date(timeIntervalSince1970: Double(tsMillis) / 1000)
        return relFmt.localizedString(for: date, relativeTo: Date())
    }
    private static let relFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
