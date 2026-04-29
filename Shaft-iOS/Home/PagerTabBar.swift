import SwiftUI

struct PagerTabBar<T: Hashable>: View {
    let titles: [(value: T, title: String)]
    @Binding var selection: T

    @Namespace private var underline

    var body: some View {
        HStack(spacing: 0) {
            ForEach(titles, id: \.value) { item in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        selection = item.value
                    }
                } label: {
                    VStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 15, weight: selection == item.value ? .semibold : .regular))
                            .foregroundStyle(selection == item.value ? Color.primary : Color.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                        ZStack {
                            Capsule()
                                .fill(.clear)
                                .frame(height: 2)
                            if selection == item.value {
                                Capsule()
                                    .fill(.tint)
                                    .frame(width: 24, height: 2)
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
