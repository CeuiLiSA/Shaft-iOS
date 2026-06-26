import SwiftUI

// MARK: - Shimmer

extension View {
    /// Sweeps a soft highlight band across the receiver — the loading-skeleton
    /// shimmer. Apply ONCE around a whole group of placeholder shapes (not per
    /// shape) so the band moves as a single coherent animation. Honors
    /// Reduce Motion (static placeholder, no sweep).
    func shimmering(active: Bool = true) -> some View {
        modifier(Shimmer(isActive: active))
    }
}

/// Diagonal highlight sweep implemented as an animated gradient *mask*: the
/// bright band is where the content is fully opaque, the rest dims to ~40%, so
/// the placeholder shapes appear to pulse as the band passes over them.
struct Shimmer: ViewModifier {
    var isActive: Bool = true
    @State private var phase: CGFloat = -0.25
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if !isActive || reduceMotion {
            content
        } else {
            content
                .modifier(AnimatedMask(phase: phase))
                .onAppear {
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                        phase = 1.0
                    }
                }
        }
    }

    private struct AnimatedMask: AnimatableModifier {
        var phase: CGFloat = 0
        var animatableData: CGFloat {
            get { phase }
            set { phase = newValue }
        }
        func body(content: Content) -> some View {
            content.mask(GradientMask(phase: phase).scaleEffect(3))
        }
    }

    private struct GradientMask: View {
        let phase: CGFloat
        var body: some View {
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .black.opacity(0.4), location: phase),
                    .init(color: .black, location: phase + 0.1),
                    .init(color: .black.opacity(0.4), location: phase + 0.2),
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

// MARK: - Primitives

/// Neutral fill used by every placeholder shape — adapts to light/dark.
private let skeletonFill = Color(.systemGray5)

/// A flexible rounded-rectangle placeholder (takes whatever size it's given).
struct SkeletonShape: View {
    var corner: CGFloat = 6
    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous).fill(skeletonFill)
    }
}

/// A fixed-or-flexible bar placeholder. `width == nil` ⇒ stretches to fill
/// (use for text lines that run the row width); pass a width for short lines.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var corner: CGFloat = 4
    var body: some View {
        SkeletonShape(corner: corner).frame(width: width, height: height)
    }
}

struct SkeletonCircle: View {
    var size: CGFloat
    var body: some View {
        Circle().fill(skeletonFill).frame(width: size, height: size)
    }
}

// MARK: - Waterfall skeleton (瀑布流)

/// Loading placeholder for the masonry illust grid: `columns` columns of
/// rounded image blocks with varied (deterministic) heights, matching the real
/// `WaterfallGrid` so the layout doesn't jump when content arrives.
struct WaterfallSkeleton: View {
    var columns: Int = 2
    var spacing: CGFloat = 8
    var rowsPerColumn: Int = 4

    /// Pseudo-random but fixed height ratios (height ÷ width) — same clamp band
    /// as `Illust.waterfallImageHeightRatio` (0.6...2.0).
    private static let ratios: [CGFloat] = [1.35, 0.78, 1.6, 1.0, 1.2, 0.92, 1.5, 0.7, 1.15, 1.42]

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<max(1, columns), id: \.self) { col in
                LazyVStack(spacing: spacing) {
                    ForEach(0..<rowsPerColumn, id: \.self) { row in
                        let r = Self.ratios[(col * rowsPerColumn + row) % Self.ratios.count]
                        SkeletonShape(corner: 6)
                            .aspectRatio(1 / r, contentMode: .fit)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        // Natural height — always lives inside a ScrollView, so it must NOT
        // try to fill (an unbounded proposal + maxHeight:.infinity lets the
        // tall image blocks overflow uncipped into whatever sits below it).
        .frame(maxWidth: .infinity, alignment: .top)
        .clipped()
        .shimmering()
        .allowsHitTesting(false)
    }
}

// MARK: - Horizontal strip skeleton (今日排行榜 carousel)

/// Loading placeholder for a horizontal card carousel (the home ranking strip):
/// square thumbnail + title + author, repeated across the row.
struct RankingStripSkeleton: View {
    var cardWidth: CGFloat = 130
    var count: Int = 6

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(0..<count, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonShape(corner: 8).frame(width: cardWidth, height: cardWidth)
                        SkeletonBlock(width: cardWidth - 20, height: 11)
                        SkeletonBlock(width: 70, height: 9)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
        .shimmering()
        .allowsHitTesting(false)
    }
}

// MARK: - Tag-grid skeleton (热门标签)

/// Loading placeholder for the square trending-tag grid.
struct TagGridSkeleton: View {
    var columns: Int = 3
    var rows: Int = 4
    var corner: CGFloat = 0

    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 0), count: max(1, columns))
        LazyVGrid(columns: cols, spacing: 0) {
            ForEach(0..<(max(1, columns) * rows), id: \.self) { _ in
                SkeletonShape(corner: corner).aspectRatio(1, contentMode: .fit)
            }
        }
        .shimmering()
        .allowsHitTesting(false)
    }
}

// MARK: - Normal-list skeleton (普通列表)

/// Vertical stack of identical placeholder rows. Used for every row-based list
/// (novels, users, notifications, watchlist, markers, comments). Fills from the
/// top so it can drop straight into a `.overlay` over an empty `List`.
struct RowSkeletonList<Row: View>: View {
    var count: Int = 8
    var spacing: CGFloat = 10
    var horizontalPadding: CGFloat = 16
    var divider: Bool = false
    @ViewBuilder var row: () -> Row

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<count, id: \.self) { i in
                row()
                if divider, i < count - 1 { Divider() }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 8)
        // Top-aligned fill so it drops into an `.overlay` over an empty List
        // and starts at the top; `.clipped()` keeps it from spilling past the
        // host's bounds if the row count is taller than the available area.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .shimmering()
        .allowsHitTesting(false)
    }
}

// MARK: Row shapes

/// Cover thumbnail + title/meta lines — novel rows.
struct NovelRowSkeleton: View {
    var coverWidth: CGFloat = 60
    var coverHeight: CGFloat = 80

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SkeletonBlock(width: coverWidth, height: coverHeight, corner: 4)
            VStack(alignment: .leading, spacing: 7) {
                SkeletonBlock(height: 13)
                SkeletonBlock(width: 150, height: 13)
                SkeletonBlock(width: 80, height: 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// Avatar + name + 3-up thumb strip — user-preview rows.
struct UserRowSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                SkeletonCircle(size: 48)
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBlock(width: 150, height: 13)
                    SkeletonBlock(width: 90, height: 10)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonShape(corner: 4).frame(height: 100).frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Cover thumbnail + lines, larger cover — watchlist / novel-marker rows.
struct MediaRowSkeleton: View {
    var coverWidth: CGFloat = 64
    var coverHeight: CGFloat = 88

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SkeletonBlock(width: coverWidth, height: coverHeight, corner: 6)
            VStack(alignment: .leading, spacing: 7) {
                SkeletonBlock(height: 13)
                SkeletonBlock(width: 120, height: 11)
                SkeletonBlock(width: 56, height: 18, corner: 6)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}

/// Circle avatar + text lines — notification / comment rows.
struct AvatarRowSkeleton: View {
    var avatar: CGFloat = 44
    var lines: Int = 2

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SkeletonCircle(size: avatar)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(height: 12)
                SkeletonBlock(width: 200, height: 12)
                if lines > 2 { SkeletonBlock(width: 120, height: 10) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

/// Text-only row (title + meta) — announcement / info rows with no thumbnail.
struct InfoRowSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonBlock(height: 13)
            SkeletonBlock(width: 110, height: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }
}

// MARK: Ready-made list skeletons

struct NovelListSkeleton: View {
    var body: some View {
        RowSkeletonList(count: 8, spacing: 8, horizontalPadding: 12, divider: true) {
            NovelRowSkeleton()
        }
    }
}

struct UserListSkeleton: View {
    var body: some View {
        RowSkeletonList(count: 5, spacing: 12, horizontalPadding: 12, divider: true) {
            UserRowSkeleton()
        }
    }
}
