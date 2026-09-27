import SwiftUI

/// Two-column waterfall: each item knows its own aspect ratio, items are
/// assigned greedily to the column with the smallest current accumulated
/// height. Suitable for content where the per-item height is known up front
/// (Pixiv illust width/height). Wraps two `LazyVStack`s in an `HStack` so
/// scrolling stays lazy.
///
/// Distribution is **stable across refreshes**: once an item with a given
/// `id` lands in column N, it stays in column N as long as it remains in the
/// `items` array. New items are placed in the shortest column the same way.
/// This avoids the visual reshuffle when pull-to-refresh returns the same
/// items in a different order.
struct WaterfallGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    let columns: Int
    let spacing: CGFloat
    /// Estimated relative cell height in *units of column width*. The exact
    /// scale doesn't matter — only ratios — but ~`1/aspect + label` is right.
    let estimatedRelativeHeight: (Item) -> Double
    let cell: (Item) -> Cell

    @State private var columnByID: [Item.ID: Int] = [:]
    /// Column count the cached assignments were made for — a cache from another
    /// count (e.g. the first pass before the width was known) is ignored.
    @State private var cachedColumns = 0
    /// The grid's own content width — split view / slide-over / the tablet rail
    /// all make it narrower than the screen.
    @State private var contentWidth: CGFloat = 0

    /// Columns actually laid out: phones keep the 「每行几列」 setting; tablets size
    /// cards like the setting does on a phone and fit as many as the width takes
    /// (`AdaptiveStaggerColumns`, #1087).
    private var effectiveColumns: Int {
        AdaptiveStaggerColumns.columns(contentWidth: contentWidth, base: columns)
    }

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
        let columns = effectiveColumns
        let buckets = distribute(columns: columns)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        // A new column count re-deals every card; stale assignments would pile
        // everything into the old columns.
        .onChange(of: items.map(\.id)) { _, ids in
            // Drop assignments for items that left the list, so the cache
            // doesn't grow unbounded across many refreshes.
            let alive = Set(ids)
            columnByID = columnByID.filter { alive.contains($0.key) }
        }
    }

    private func distribute(columns: Int) -> [[Item]] {
        var heights = [Double](repeating: 0, count: columns)
        var buckets = [[Item]](repeating: [], count: columns)
        var newAssignments: [Item.ID: Int] = [:]

        let cache = cachedColumns == columns ? columnByID : [:]
        for item in items {
            let h = estimatedRelativeHeight(item)
            let idx: Int
            if let cached = cache[item.id] {
                idx = min(max(cached, 0), columns - 1)
            } else {
                // Argmin: pick the shortest column.
                var bestIdx = 0
                var bestH = heights[0]
                for i in 1..<columns where heights[i] < bestH {
                    bestH = heights[i]; bestIdx = i
                }
                idx = bestIdx
                newAssignments[item.id] = idx
            }
            buckets[idx].append(item)
            heights[idx] += h
        }

        // Persist newly-assigned ids. Done in a Task to avoid mutating
        // @State during view evaluation.
        if !newAssignments.isEmpty {
            Task { @MainActor in
                // A new column count re-deals every card; drop the old deal first.
                if cachedColumns != columns {
                    columnByID = [:]
                    cachedColumns = columns
                }
                for (id, col) in newAssignments where columnByID[id] == nil {
                    columnByID[id] = col
                }
            }
        }
        return buckets
    }
}


/// 瀑布流按列表实际宽度决定列数（平板重排，upstream `AdaptiveStaggerColumns`, #1087）。
///
/// 「每行几列」设置（2/3/4）描述的是**卡片大小**：在 360pt 宽的手机上排几列。列表变宽时
/// 保持卡片的物理尺寸，按宽度多排几列；窄于参考宽度时不少于设置值。只在平板上生效
/// （设备最小边 ≥ 600pt），手机横竖屏与以前一致。
/// `columns = floor((contentWidth + gap) / (minCardWidth + gap))`。
enum AdaptiveStaggerColumns {
    private static let referenceWidth: CGFloat = 360
    private static let gap: CGFloat = 8

    static var isTablet: Bool {
        let bounds = UIScreen.main.bounds
        return min(bounds.width, bounds.height) >= 600
    }

    static func columns(contentWidth: CGFloat, base: Int) -> Int {
        let base = max(base, 1)
        guard isTablet, contentWidth > 0 else { return base }
        let minCard = referenceWidth / CGFloat(base)
        let fit = Int((contentWidth + gap) / (minCard + gap))
        return max(base, fit)
    }
}
