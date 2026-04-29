import SwiftUI

/// Two-column waterfall: each item knows its own aspect ratio, items are
/// assigned greedily to the column with the smallest current accumulated
/// height. Suitable for content where the per-item height is known up front
/// (Pixiv illust width/height). Wraps two `LazyVStack`s in an `HStack` so
/// scrolling stays lazy.
struct WaterfallGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    let columns: Int
    let spacing: CGFloat
    /// Estimated relative cell height in *units of column width*. The exact
    /// scale doesn't matter — only ratios — but ~`1/aspect + label` is right.
    let estimatedRelativeHeight: (Item) -> Double
    let cell: (Item) -> Cell

    init(
        items: [Item],
        columns: Int = 2,
        spacing: CGFloat = 8,
        estimatedRelativeHeight: @escaping (Item) -> Double,
        @ViewBuilder cell: @escaping (Item) -> Cell
    ) {
        self.items = items
        self.columns = max(1, columns)
        self.spacing = spacing
        self.estimatedRelativeHeight = estimatedRelativeHeight
        self.cell = cell
    }

    var body: some View {
        let buckets = distribute()
        HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<columns, id: \.self) { col in
                LazyVStack(spacing: spacing) {
                    ForEach(buckets[col]) { item in
                        cell(item)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func distribute() -> [[Item]] {
        var heights = [Double](repeating: 0, count: columns)
        var buckets = [[Item]](repeating: [], count: columns)
        for item in items {
            let h = estimatedRelativeHeight(item)
            // Argmin: pick the shortest column.
            var bestIdx = 0
            var bestH = heights[0]
            for i in 1..<columns where heights[i] < bestH {
                bestH = heights[i]; bestIdx = i
            }
            buckets[bestIdx].append(item)
            heights[bestIdx] += h
        }
        return buckets
    }
}
