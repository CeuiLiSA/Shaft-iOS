import SwiftUI
import UIKit

/// A crossing triggers once; content loading and initially resting at the top
/// don't vibrate. Re-arms only after moving back into the scrollable content.
struct ScrollEdgeState {
    private(set) var previous: Int?
    mutating func crossed(offset: Double, content: Double, viewport: Double) -> Bool {
        guard content > viewport + 1 else { previous = nil; return false }
        let edge = offset <= 0.5 ? -1 : offset >= content - viewport - 0.5 ? 1 : 0
        defer { previous = edge }
        guard let previous else { return false }
        return edge != 0 && previous == 0
    }
}

private struct ScrollEdgeFeedback: ViewModifier {
    @State private var state = ScrollEdgeState()
    @State private var settings = AppSettingsStore.shared
    @State private var interacting = false
    func body(content: Content) -> some View {
        content.onScrollPhaseChange { _, phase in interacting = phase == .interacting || phase == .decelerating }
        .onScrollGeometryChange(for: ScrollEdgeGeometry.self) { geometry in
            ScrollEdgeGeometry(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                               content: geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom,
                               viewport: geometry.containerSize.height)
        } action: { _, geometry in
            let crossed = state.crossed(offset: geometry.offset, content: geometry.content, viewport: geometry.viewport)
            if crossed && interacting && settings.scrollEdgeHapticEnable { UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5) }
        }
    }
}

private struct ScrollEdgeGeometry: Equatable {
    let offset: Double
    let content: Double
    let viewport: Double
}

extension View {
    func scrollEdgeFeedback() -> some View { modifier(ScrollEdgeFeedback()) }
}

private struct IllustScrollPosition: ViewModifier {
    @State private var position: Int64?
    func body(content: Content) -> some View {
        content.scrollPosition(id: $position, anchor: .top)
    }
}
extension View {
    func preserveIllustScrollPosition() -> some View { modifier(IllustScrollPosition()) }
}
