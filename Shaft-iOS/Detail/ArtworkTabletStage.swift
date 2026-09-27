import SwiftUI

/// 平板作品详情的「作品舞台」— 1:1 port of upstream `ArtworkTabletStage`
/// (`layout-sw600dp/fragment_artwork_v3.xml`, #1087).
///
/// On the phone the artwork is the top item of the list and scrolls away; on a
/// wide window it stays fixed in the stage while the info column scrolls on its
/// own beside (or below) it:
///
/// - The artwork fills the stage top to bottom (under the status bar too), at
///   its own ratio, centred, never cropped. The list thumbnail paints first,
///   then the large / original replaces it. Multi-page works page vertically,
///   with a side page strip and a 「当前 / 总页」 readout; ugoira plays in place;
///   3P+ works get the reader pill. Back / more are glass circles in the two top
///   corners. Tapping a page opens the full-screen viewer.
/// - The floating controls each keep clear of the system bars.
struct ArtworkTabletStage: View {
    let illust: Illust
    let pages: [IllustPageURLs]
    let forceOriginal: Bool
    /// Side-by-side: the stage's trailing edge meets the info column, not the screen.
    let sideBySide: Bool
    let onBack: () -> Void
    let onMore: () -> Void
    let onOpenReader: () -> Void
    let onOpenViewer: (Int) -> Void

    @State private var currentPage: Int? = 0
    @Environment(OnboardingStore.self) private var l10n

    /// Pill fill floating over any artwork: black 45 %, white text reads everywhere.
    private static let scrimPill = Color.black.opacity(0x73 / 255)
    private static let stripWidth: CGFloat = 72
    private static let stripThumb: CGFloat = 52
    private static let overlayEdge: CGFloat = 72

    var body: some View {
        GeometryReader { geo in
            let safe = geo.safeAreaInsets
            ZStack {
                if illust.type == "ugoira" {
                    UgoiraView(
                        illustId: illust.id,
                        fallbackURL: pages.first?.large ?? pages.first?.original,
                        contentMode: .fit,
                        onTap: { onOpenViewer(0) }
                    )
                    .frame(width: geo.size.width + safe.leading + safe.trailing,
                           height: geo.size.height + safe.top + safe.bottom)
                } else {
                    pager(size: CGSize(width: geo.size.width + safe.leading + safe.trailing,
                                       height: geo.size.height + safe.top + safe.bottom))
                }
            }
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                glassButton("chevron.backward", l10n.t(.chatActionBack), action: onBack)
                    .padding(.top, 16)
                    .padding(.leading, 20)
            }
            .overlay(alignment: .topTrailing) {
                glassButton("ellipsis", l10n.t(.chatActionMore), action: onMore)
                    .padding(.top, 16)
                    .padding(.trailing, 20)
            }
            .overlay(alignment: .trailing) {
                if pages.count > 1, illust.type != "ugoira" {
                    strip
                        .padding(.trailing, 12)
                        .padding(.vertical, max(Self.overlayEdge - safe.top, 16))
                }
            }
            .overlay(alignment: .bottom) {
                if pages.count > 1, illust.type != "ugoira" {
                    Text("\((currentPage ?? 0) + 1) / \(pages.count)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Self.scrimPill, in: .capsule)
                        .padding(.bottom, 20)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if pages.count > 2, illust.type != "ugoira" {
                    Button(action: onOpenReader) {
                        HStack(spacing: 6) {
                            Text(illust.type == "manga" ? l10n.t(.crEnter) : l10n.t(.artworkV3ReaderEnterIllust))
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.leading, 16)
                        .padding(.trailing, 18)
                        .frame(minHeight: 44)
                        .background(Self.scrimPill, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 20)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    // MARK: Pages

    private func pager(size: CGSize) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    TabletStagePage(
                        illust: illust, index: index, page: page,
                        forceOriginal: forceOriginal
                    ) { onOpenViewer(index) }
                    .frame(width: size.width, height: size.height)
                    .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentPage)
        .frame(width: size.width, height: size.height)
    }

    /// Side page strip on a glass plate: tap a thumbnail to jump; the current
    /// page gets a 2pt theme border, the rest dim to 60 %.
    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, _ in
                        let selected = index == (currentPage ?? 0)
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { currentPage = index }
                        } label: {
                            PixivAsyncImage(url: thumbURL(index), contentMode: .fill, showsProgress: false,
                                            placeholder: Theme.v3Surface2)
                                .frame(width: Self.stripThumb, height: Self.stripThumb)
                                .clipShape(.rect(cornerRadius: 12))
                                .overlay {
                                    if selected {
                                        RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.brand, lineWidth: 2)
                                    }
                                }
                                .opacity(selected ? 1 : 0.6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(index + 1) / \(pages.count)")
                        .id(index)
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 2)
                .frame(width: Self.stripWidth)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(Self.scrimPill, in: .rect(cornerRadius: 20))
            .onChange(of: currentPage) { _, page in
                if let page { withAnimation { proxy.scrollTo(page, anchor: .center) } }
            }
        }
    }

    private func thumbURL(_ index: Int) -> URL? {
        let urls = illust.metaPages?.indices.contains(index) == true ? illust.metaPages?[index].imageUrls : illust.imageUrls
        return (urls?.squareMedium ?? urls?.medium).flatMap(URL.init(string:))
    }

    /// Round glass button floating over the artwork (back / more): black 45 % + white glyph.
    private func glassButton(_ system: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Self.scrimPill, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// One stage page: the thumbnail already in cache paints at once, the large /
/// original replaces it; the picture is fitted whole, centred.
private struct TabletStagePage: View {
    let illust: Illust
    let index: Int
    let page: IllustPageURLs
    let forceOriginal: Bool
    let onTap: () -> Void

    private var thumbnail: URL? {
        let urls = illust.metaPages?.indices.contains(index) == true ? illust.metaPages?[index].imageUrls : illust.imageUrls
        return (urls?.medium ?? urls?.squareMedium).flatMap(URL.init(string:))
    }

    private var full: URL? {
        (forceOriginal || AppSettingsStore.shared.showOriginalPreviewImage) ? (page.original ?? page.large) : (page.large ?? page.original)
    }

    var body: some View {
        ZStack {
            // A failed large keeps the thumbnail underneath instead of blanking.
            PixivAsyncImage(url: thumbnail, contentMode: .fit, showsProgress: false, placeholder: .clear)
            PixivAsyncImage(url: full, contentMode: .fit, showsProgress: false, placeholder: .clear)
        }
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
        .accessibilityLabel("\(illust.title ?? "") \(index + 1)")
        .accessibilityAddTraits(.isImage)
    }
}

/// Whole-page ambient colour: the same artwork blurred and scaled to fill,
/// under a page-colour gradient (30 % → 55 %) so the info text stays readable.
struct ArtworkTabletBackdrop: View {
    let url: URL?

    var body: some View {
        ZStack {
            Theme.v3Bg
            PixivAsyncImage(url: url, contentMode: .fill, showsProgress: false, placeholder: .clear)
                .blur(radius: 40)
                .opacity(0.9)
            LinearGradient(colors: [Theme.v3Bg.opacity(0.30), Theme.v3Bg.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
