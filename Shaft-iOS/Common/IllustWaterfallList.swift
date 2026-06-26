import SwiftUI

extension Illust {
    /// Waterfall cell image height in column-width units — parity with
    /// upstream `IAdapter` (`MIN_HEIGHT_RATIO = 0.6`, `MAX_HEIGHT_RATIO = 2.0`):
    /// only extreme tall/flat illusts are clamped (the cell's `.fill` image
    /// center-crops them); everything else renders its exact aspect ratio.
    var waterfallImageHeightRatio: Double {
        let w = max(Double(width ?? 1), 1)
        let h = max(Double(height ?? 1), 1)
        return min(max(h / w, 0.6), 2.0)
    }

}

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
    @State private var bulkSeed: BulkSelectionSeed?
    @State private var slideshowSeed: SlideshowSeed?
    @Environment(OnboardingStore.self) private var l10n

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
                } else if visible.isEmpty, isLoading {
                    // Initial load — masonry skeleton (普通列表 vs 瀑布流: this is
                    // the waterfall variant). Load-more keeps the spinner below.
                    WaterfallSkeleton(columns: mute.waterfallColumns)
                }
                if !visible.isEmpty {
                    WaterfallGrid(
                        items: visible,
                        columns: mute.waterfallColumns,
                        spacing: 8,
                        estimatedRelativeHeight: { $0.waterfallImageHeightRatio }
                    ) { illust in
                        NavigationLink(value: illust) {
                            IllustWaterfallCell(illust: illust)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                slideshowSeed = SlideshowBuilder.seed(from: visible, tapped: illust)
                            } label: {
                                Label(l10n.t(.slideshowPlay), systemImage: "play.rectangle.on.rectangle")
                            }
                            Button {
                                bulkSeed = BulkSelectionSeed(illusts: visible)
                            } label: {
                                Label(l10n.t(.dlBulkEntry), systemImage: "checklist")
                            }
                            Divider()
                            IllustCellContextMenuItems(illust: illust)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                if isLoading, !illusts.isEmpty {
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
        .fullScreenCover(item: $bulkSeed) { seed in
            BulkSelectView(illusts: seed.illusts)
        }
        .fullScreenCover(item: $slideshowSeed) { seed in
            SlideshowView(seed: seed)
        }
    }
}

/// Image-only waterfall cell — upstream `cell_illust_card` parity: no title or
/// author label, page-count badge top-right, bookmark heart bottom-right.
struct IllustWaterfallCell: View {
    let illust: Illust

    var body: some View {
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
            .overlay(alignment: .bottomTrailing) {
                WaterfallBookmarkButton(illust: illust)
            }
    }

    private var displayAspect: CGFloat {
        1 / CGFloat(illust.waterfallImageHeightRatio)
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

/// Bottom-right heart on every waterfall cell — upstream `cell_illust_card`'s
/// `ProgressImageButton`: an always-filled heart, white when not bookmarked and
/// red when bookmarked. Resolves and toggles through `InteractionStore`, so the
/// state always matches the detail page and every other surface in the app.
///
/// Inner `Button` inside the cell's `NavigationLink` label: in a ScrollView the
/// innermost control wins the tap, so the heart toggles without pushing detail.
private struct WaterfallBookmarkButton: View {
    let illust: Illust
    @State private var store = InteractionStore.shared

    var body: some View {
        let bookmarked = store.isBookmarked(illust)
        Button {
            Task { try? await store.toggleBookmark(illust) }
        } label: {
            Image(systemName: "heart.fill")
                .font(.system(size: 22))
                .foregroundStyle(bookmarked ? Theme.v3Bookmarked : .white)
                .shadow(color: .black.opacity(0.35), radius: 3)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(store.bookmarkBusy.contains(illust.id))
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
