import SwiftUI

/// Persisted ordinals match Android `IllustListLayout` (#1214).
enum IllustListLayout: Int, CaseIterable, Identifiable {
    case masonry, grid, justified, single
    var id: Int { rawValue }
    @MainActor static var current: Self {
        Self(rawValue: AppSettingsStore.shared.illustListLayout) ?? .masonry
    }
    var title: LocalizedKey {
        switch self {
        case .masonry: return .illustListLayoutMasonry
        case .grid: return .illustListLayoutGrid
        case .justified: return .illustListLayoutJustified
        case .single: return .illustListLayoutSingle
        }
    }
    var description: LocalizedKey {
        switch self {
        case .masonry: return .illustListLayoutMasonryDesc
        case .grid: return .illustListLayoutGridDesc
        case .justified: return .illustListLayoutJustifiedDesc
        case .single: return .illustListLayoutSingleDesc
        }
    }
}

/// Pure row geometry; a partial final row keeps the target height instead of
/// stretching one remaining landscape image to the height of a full row.
enum JustifiedRows {
    struct Row: Equatable {
        let indices: [Int]
        let widths: [Double]
        let height: Double
    }

    static func make(aspectRatios: [Double], width: Double, targetHeight: Double, spacing: Double) -> [Row] {
        guard width.isFinite, width > 0, targetHeight.isFinite, targetHeight > 0 else { return [] }
        let gap = spacing.isFinite ? min(max(0, spacing), width) : 0
        let minimumWidth = min(44, width)
        let ratios = aspectRatios.map { $0.isFinite && $0 > 0 ? min(max($0, 0.2), 5) : 1 }
        var rows: [Row] = []
        var pending: [Int] = []
        var sum = 0.0
        func append(final: Bool) {
            guard !pending.isEmpty else { return }
            let available = max(1, width - gap * Double(pending.count - 1))
            let fitted = available / sum
            let smallest = pending.map { ratios[$0] }.min() ?? 1
            let height = final ? min(fitted, max(targetHeight, minimumWidth / smallest)) : fitted
            rows.append(Row(indices: pending, widths: pending.map { ratios[$0] * height }, height: height))
            pending.removeAll(keepingCapacity: true)
            sum = 0
        }
        for i in ratios.indices {
            if !pending.isEmpty {
                let available = width - gap * Double(pending.count)
                let smallest = min(pending.map { ratios[$0] }.min() ?? 1, ratios[i])
                if available <= 0 || available / (sum + ratios[i]) * smallest < minimumWidth { append(final: false) }
            }
            pending.append(i)
            sum += ratios[i]
            if sum * targetHeight + gap * Double(pending.count - 1) >= width { append(final: false) }
        }
        append(final: true)
        return rows
    }
}

struct IllustListLayoutPicker: View {
    @State private var settings = AppSettingsStore.shared
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(l10n.t(.illustListLayoutSheetDesc))
                        .font(.subheadline).foregroundStyle(Theme.v3Text2)
                    ForEach(IllustListLayout.allCases) { layout in
                        Button {
                            settings.illustListLayout = layout.rawValue
                            dismiss()
                        } label: {
                            Group {
                                if typeSize.isAccessibilitySize {
                                    VStack(alignment: .leading, spacing: 14) {
                                        HStack {
                                            LayoutPreview(layout: layout).frame(width: 88, height: 68)
                                            Spacer()
                                            selection(layout)
                                        }
                                        description(layout)
                                    }
                                } else {
                                    HStack(spacing: 16) {
                                        LayoutPreview(layout: layout).frame(width: 88, height: 68)
                                        description(layout)
                                        Spacer(minLength: 0)
                                        selection(layout)
                                    }
                                }
                            }
                            .padding(16)
                            .background(Theme.v3Surface, in: .rect(cornerRadius: 22))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.v3Text1)
                        .accessibilityAddTraits(IllustListLayout.current == layout ? .isSelected : [])
                    }
                }.padding(20).frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
            }
            .background(Theme.v3Bg)
            .navigationTitle(l10n.t(.illustListLayout))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(l10n.t(.actionCancel)) { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    private func description(_ layout: IllustListLayout) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(l10n.t(layout.title)).font(.montserratSemiBold(16))
            Text(l10n.t(layout.description)).font(.subheadline).foregroundStyle(Theme.v3Text2)
        }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func selection(_ layout: IllustListLayout) -> some View {
        Image(systemName: IllustListLayout.current == layout ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(Theme.brand)
    }

}

private struct LayoutPreview: View {
    let layout: IllustListLayout
    var body: some View {
        Canvas { context, size in
            let rects: [CGRect]
            switch layout {
            case .masonry:
                rects = [CGRect(x: 0, y: 0, width: 41, height: 38), CGRect(x: 47, y: 0, width: 41, height: 25),
                         CGRect(x: 0, y: 44, width: 41, height: 24), CGRect(x: 47, y: 31, width: 41, height: 37)]
            case .grid:
                rects = [CGRect(x: 0, y: 0, width: 41, height: 31), CGRect(x: 47, y: 0, width: 41, height: 31),
                         CGRect(x: 0, y: 37, width: 41, height: 31), CGRect(x: 47, y: 37, width: 41, height: 31)]
            case .justified:
                rects = [CGRect(x: 0, y: 0, width: 53, height: 31), CGRect(x: 59, y: 0, width: 29, height: 31),
                         CGRect(x: 0, y: 37, width: 31, height: 31), CGRect(x: 37, y: 37, width: 51, height: 31)]
            case .single:
                rects = [CGRect(x: 0, y: 0, width: 88, height: 31), CGRect(x: 0, y: 37, width: 88, height: 31)]
            }
            for (i, rect) in rects.enumerated() {
                context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(Theme.brand.opacity(i.isMultiple(of: 2) ? 0.3 : 0.16)))
            }
        }
        .accessibilityHidden(true)
    }
}
