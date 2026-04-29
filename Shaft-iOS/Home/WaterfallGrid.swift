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
        .onChange(of: items.map(\.id)) { _, ids in
            // Drop assignments for items that left the list, so the cache
            // doesn't grow unbounded across many refreshes.
            let alive = Set(ids)
            columnByID = columnByID.filter { alive.contains($0.key) }
        }
    }

    private func distribute() -> [[Item]] {
        var heights = [Double](repeating: 0, count: columns)
        var buckets = [[Item]](repeating: [], count: columns)
        var newAssignments: [Item.ID: Int] = [:]

        for item in items {
            let h = estimatedRelativeHeight(item)
            let idx: Int
            if let cached = columnByID[item.id] {
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
                for (id, col) in newAssignments where columnByID[id] == nil {
                    columnByID[id] = col
                }
            }
        }
        return buckets
    }
}
