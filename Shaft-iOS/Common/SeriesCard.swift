import SwiftUI

/// Display model for the shared V3 series card (`cell_series_v3` +
/// `SeriesCard.kt`). Both the 追更列表 (pixiv `WatchlistItem`) and the 系列榜
/// (shaft-api-v2 `SeriesRankItem`) map into this; the card itself knows
/// nothing about either data source.
struct SeriesCardModel {
    var title: String
    var coverUrl: String?
    /// 「N话」chip text.
    var countText: String
    /// Text right of the chip: watchlist = 「更新于 2026-08-12」, ranking = 「累计收藏 2.0M」.
    var subtitle: String
    /// true → `V3Palette.textAccent`; false → `v3_text_3`.
    var subtitleAccent: Bool
    var authorName: String
    var authorAvatarUrl: String?
    /// Bottom-right secondary pill (「查看最新话 / 阅读最新话」); nil hides it.
    var actionText: String? = nil
    /// 1-based rank → `#N` badge on the cover; nil hides it (watchlist).
    var rank: Int? = nil
    /// Non-nil = masked / delisted placeholder: only this line is shown.
    var maskText: String? = nil
}

/// `cell_series_v3`: `bg_v3_card` (v3_surface_1 fill, 0.5dp v3_border_2 hairline,
/// r28), 12dp padding, cover **left** 84×112 r16 with the rank badge top-left,
/// title v3_text_1 16 bold ×2 lines, 「N话」tonal chip (`bg_v3_chip`) + subtitle,
/// bottom row 24dp avatar + author (v3_text_2 13) + secondary pill action.
/// Card spacing (12) is the list's job, not the card's — same as upstream.
struct SeriesCard: View {
    let model: SeriesCardModel
    var onAuthorTap: (() -> Void)? = nil
    var onAction: (() -> Void)? = nil

    private static let coverSize = CGSize(width: 84, height: 112)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            cover
            VStack(alignment: .leading, spacing: 0) {
                Text(model.maskText ?? model.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.v3Text1)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.maskText == nil {
                    metaRow.padding(.top, 6)
                    Spacer(minLength: 0)
                    authorRow
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(height: Self.coverSize.height)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.v3Surface1, in: .rect(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Theme.v3Border2, lineWidth: 0.5)
        )
        .contentShape(.rect(cornerRadius: 28, style: .continuous))
    }

    /// Masked entries keep the cover slot (upstream `INVISIBLE`, not `GONE`) so
    /// card height stays uniform down the list.
    private var cover: some View {
        ZStack(alignment: .topLeading) {
            if model.maskText == nil {
                PixivAsyncImage(
                    url: model.coverUrl.flatMap(URL.init(string:)),
                    showsProgress: false,
                    placeholder: Theme.v3Surface2
                )
                .clipShape(.rect(cornerRadius: 16, style: .continuous))
                if let rank = model.rank {
                    // `pillPrimary` + `onPrimary`: solid brand pill, white text in both modes.
                    Text("#\(rank)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .frame(minWidth: 26)
                        .background(Theme.brand, in: Capsule())
                        .padding(6)
                }
            }
        }
        .frame(width: Self.coverSize.width, height: Self.coverSize.height)
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            Text(model.countText)
                .font(.system(size: 12))
                .foregroundStyle(Theme.v3Text2)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Theme.v3Surface1, in: .rect(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.v3Border1, lineWidth: 0.5)
                )
            Text(model.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(model.subtitleAccent ? Theme.v3TextAccent : Theme.v3Text3)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var authorRow: some View {
        HStack(spacing: 6) {
            Button { onAuthorTap?() } label: {
                HStack(spacing: 6) {
                    PixivAsyncImage(
                        url: model.authorAvatarUrl.flatMap(URL.init(string:)),
                        showsProgress: false,
                        placeholder: Theme.v3Surface2
                    )
                    .frame(width: 24, height: 24)
                    .clipShape(.circle)
                    Text(model.authorName)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.v3Text2)
                        .lineLimit(1)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(onAuthorTap == nil)
            Spacer(minLength: 8)
            if let action = model.actionText {
                Button { onAction?() } label: {
                    Text(action)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.v3TextSecondary)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        // `V3Palette.pillSecondary`: brand@20% fill + 1dp brand@30% stroke.
                        .background(Theme.brand.opacity(0.20), in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.brand.opacity(0.30), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressAlphaStyle())
            }
        }
    }
}

/// Alias of `formatRankCount` (RankPickerViews.swift) — one implementation, locale pinned.
enum RankCountFormat {
    static func compact(_ n: Int) -> String { formatRankCount(n) }
}

#Preview("Series cards") {
    ScrollView {
        LazyVStack(spacing: 12) {
            SeriesCard(model: SeriesCardModel(
                title: "タヌキ出没注意 気になる先輩に注意喚起をする陸上部のタヌキさん",
                coverUrl: nil, countText: "120话", subtitle: "累计收藏 1999.8k",
                subtitleAccent: true, authorName: "画师名", authorAvatarUrl: nil, rank: 1
            ), onAuthorTap: {})
            SeriesCard(model: SeriesCardModel(
                title: "追更中的漫画", coverUrl: nil, countText: "12话",
                subtitle: "更新于 2026-08-12", subtitleAccent: false,
                authorName: "画师名", authorAvatarUrl: nil, actionText: "查看最新话"
            ), onAuthorTap: {}, onAction: {})
            SeriesCard(model: SeriesCardModel(
                title: "", coverUrl: nil, countText: "", subtitle: "", subtitleAccent: false,
                authorName: "", authorAvatarUrl: nil, maskText: "该系列已被屏蔽"
            ))
        }
        .padding(.horizontal, 12)
    }
    .background(Theme.v3Bg)
    .environment(OnboardingStore())
}
