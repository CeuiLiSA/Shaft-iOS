import SwiftUI

/// Reusable two-column waterfall illust list with built-in loading / error /
/// pull-to-refresh / load-more wiring. Each cell pushes the full `Illust`
/// (value-based navigation → instant detail render) onto the nearest navigation
/// stack and exposes a context menu with share,
/// copy link, open in browser, and mute artist.
struct IllustWaterfallList: View {
    let illusts: [Illust]
    let isLoading: Bool
    let errorMessage: String?
    let onRefresh: () async -> Void
    let onLoadMore: (() async -> Void)?
    let hasMore: Bool
    /// When true the caller already applied mute / R-18 filtering (e.g. search,
    /// whose per-search R-18 mode governs) — skip the built-in `mute.filter`.
    let prefiltered: Bool

    @State private var mute = MuteStore.shared

    init(
        illusts: [Illust],
        isLoading: Bool,
        errorMessage: String?,
        onRefresh: @escaping () async -> Void,
        onLoadMore: (() async -> Void)? = nil,
        hasMore: Bool = false,
        prefiltered: Bool = false
    ) {
        self.illusts = illusts
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.onRefresh = onRefresh
        self.onLoadMore = onLoadMore
        self.hasMore = hasMore
        self.prefiltered = prefiltered
    }

    var body: some View {
        let visible = prefiltered ? illusts : mute.filter(illusts)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if illusts.isEmpty, let err = errorMessage {
                    InlineError(message: err) { Task { await onRefresh() } }
                        .padding(.horizontal, 12)
                }
                if !visible.isEmpty {
                    WaterfallGrid(
                        items: visible,
                        columns: mute.waterfallColumns,
                        spacing: 8,
                        estimatedRelativeHeight: relativeHeight(for:)
                    ) { illust in
                        NavigationLink(value: illust) {
                            IllustWaterfallCell(illust: illust)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            IllustCellContextMenuItems(illust: illust)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                } else if hasMore, !illusts.isEmpty {
                    Color.clear
                        .frame(height: 40)
                        .onAppear { Task { await onLoadMore?() } }
                }
            }
            .padding(.vertical, 8)
        }
        .refreshable { await onRefresh() }
    }

    private func relativeHeight(for illust: Illust) -> Double {
        let w = max(Double(illust.width ?? 1), 1)
        let h = max(Double(illust.height ?? 1), 1)
        let aspect = max(0.5, min(w / h, 2.0))
        return 1.0 / aspect + 0.18
    }
}

struct IllustWaterfallCell: View {
    let illust: Illust

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PixivAsyncImage(url: imageURL)
                .aspectRatio(displayAspect, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    if (illust.pageCount ?? 1) > 1 {
                        Label("\(illust.pageCount ?? 1)", systemImage: "square.on.square")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: .capsule)
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }

            Text(illust.title ?? "")
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.primary)
            if let user = illust.user {
                Text(user.name ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var displayAspect: CGFloat {
        let w = max(CGFloat(illust.width ?? 1), 1)
        let h = max(CGFloat(illust.height ?? 1), 1)
        return min(max(w / h, 0.5), 2.0)
    }

    private var imageURL: URL? {
        // `large` (not `medium`) so the cache entry is shared with the detail
        // hero, which shows this same URL instantly before fetching the original.
        let s = illust.imageUrls?.large
            ?? illust.imageUrls?.medium
            ?? illust.imageUrls?.squareMedium
        return s.flatMap(URL.init(string:))
    }
}

/// Context-menu items used on illust cells across the app — share, copy URL,
/// open in browser, and mute artist (writes to the local MuteStore).
struct IllustCellContextMenuItems: View {
    let illust: Illust
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.openURL) private var openURL

    private var pixivURL: URL {
        URL(string: "https://www.pixiv.net/artworks/\(illust.id)")!
    }

    var body: some View {
        ShareLink(item: pixivURL) {
            Label(l10n.t(.actionShare), systemImage: "square.and.arrow.up")
        }
        Button {
            UIPasteboard.general.string = pixivURL.absoluteString
        } label: {
            Label(l10n.t(.actionCopyLink), systemImage: "doc.on.doc")
        }
        Button {
            openURL(pixivURL)
        } label: {
            Label(l10n.t(.actionOpenInBrowser), systemImage: "safari")
        }
        if let user = illust.user {
            Divider()
            Button(role: .destructive) {
                MuteStore.shared.toggleUser(user.id)
            } label: {
                Label(l10n.t(.actionMuteArtist), systemImage: "speaker.slash")
            }
        }
    }
}

struct InlineError: View {
    let message: String
    let retry: () -> Void
    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .lineLimit(3)
            Spacer()
            Button(l10n.t(.actionRetry), action: retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
    }
}
