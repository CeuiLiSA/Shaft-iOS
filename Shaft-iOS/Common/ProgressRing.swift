import SwiftUI

/// Shared determinate progress ring: a faint track circle plus a round-capped
/// arc starting at 12 o'clock, never collapsing below a visible sliver.
/// Size, colors and any percent label are the call site's business.
struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 2
    var tint: Color = .white
    var track: Color = .white.opacity(0.25)

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
