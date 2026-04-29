import SwiftUI

struct RecommendView: View {
    @State private var subTab: SubTab = .recommended

    enum SubTab: Hashable, CaseIterable {
        case recommended, hotTag

        var title: String {
            switch self {
            case .recommended: return "Recommended works"
            case .hotTag:      return "Popular Tags"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PagerTabBar(
                titles: SubTab.allCases.map { ($0, $0.title) },
                selection: $subTab
            )
            TabView(selection: $subTab) {
                ForEach(SubTab.allCases, id: \.self) { tab in
                    SubTabPlaceholder(title: tab.title)
                        .tag(tab)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Color(.systemBackground))
    }
}

private struct SubTabPlaceholder: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text("Nothing here yet")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
