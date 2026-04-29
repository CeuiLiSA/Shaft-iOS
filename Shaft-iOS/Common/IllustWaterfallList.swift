import SwiftUI

/// Reusable two-column waterfall illust list with built-in loading / error /
/// pull-to-refresh wiring. Tapping a cell pushes `illustDetail(id)` onto the
/// nearest navigation stack via the `path` binding.
struct IllustWaterfallList: View {
    let illusts: [Illust]
    let isLoading: Bool
    let errorMessage: String?
    let onRefresh: () async -> Void
    let onTap: (Illust) -> Void

    @Environment(OnboardingStore.self) private var l10n

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if illusts.isEmpty, let err = errorMessage {
                    InlineError(message: err) { Task { await onRefresh() } }
                        .padding(.horizontal, 12)
                }
                if !illusts.isEmpty {
                    WaterfallGrid(
                        items: illusts,
                        columns: 2,
                        spacing: 8,
                        estimatedRelativeHeight: relativeHeight(for:)
                    ) { illust in
                        Button { onTap(illust) } label: {
                            IllustWaterfallCell(illust: illust)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                }
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
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
        let s = illust.imageUrls?.medium
            ?? illust.imageUrls?.large
            ?? illust.imageUrls?.squareMedium
        return s.flatMap(URL.init(string:))
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
