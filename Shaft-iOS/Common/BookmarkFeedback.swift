import SwiftUI
import UIKit

/// Two-stage haptics for every bookmark heart in the app, modelled on the
/// Mac trackpad's Force Touch click: one crisp tick when the finger lands,
/// a second, stronger one when it lifts and the bookmark commits.
///
/// Stage 1 (`pressDown`) — `.rigid` at 0.7: the "click down".
/// Stage 2 (`commit`)    — `.heavy` full strength when bookmarking, `.medium`
///                          when un-bookmarking, so adding feels weightier than
///                          removing. This is the "click up".
/// `failed`              — `.error` notification when the optimistic flip is
///                          reverted by a network error.
///
/// Generators are kept alive and `prepare()`d ahead of time so both stages
/// fire with no Taptic Engine spin-up latency (Apple's recommended pattern):
/// the press generator on appear / after each commit, the release generators
/// on press-down.
@MainActor
enum BookmarkHaptics {
    private static let press   = UIImpactFeedbackGenerator(style: .rigid)
    private static let heavy   = UIImpactFeedbackGenerator(style: .heavy)
    private static let medium  = UIImpactFeedbackGenerator(style: .medium)
    private static let note    = UINotificationFeedbackGenerator()

    /// 设置 · 收藏与互动「收藏按钮振动反馈」(upstream `isLikeHapticEnabled()`)。
    /// 收藏与取消收藏共用这一个开关；每次现读，关掉立即生效。
    private static var enabled: Bool { AppSettingsStore.shared.likeHapticEnable }

    /// Warm the engine so the first press-down is not late.
    static func warmUp() {
        press.prepare()
    }

    /// Finger lands on the heart.
    static func pressDown() {
        guard enabled else { return }
        press.impactOccurred(intensity: 0.7)
        // Warm up both possible release generators; the engine stays ready
        // for a couple of seconds, long enough to cover the release.
        heavy.prepare()
        medium.prepare()
    }

    /// Finger lifts and the toggle is issued.
    static func commit(bookmarking: Bool) {
        guard enabled else { return }
        if bookmarking {
            heavy.impactOccurred(intensity: 1.0)
        } else {
            medium.impactOccurred(intensity: 0.9)
        }
        note.prepare()
        press.prepare()
    }

    /// The optimistic state was rolled back.
    static func failed() {
        guard enabled else { return }
        note.notificationOccurred(.error)
    }
}

/// Button style for bookmark hearts: scales down while pressed and plays the
/// stage-1 haptic the instant the finger lands. Touch-down is tracked with a
/// never-completing `LongPressGesture` rather than `isPressed`, because inside
/// a ScrollView SwiftUI delays `isPressed` until the scroll-vs-tap decision —
/// on a quick tap that arrives together with the release and the two stages
/// blur into one. The stage-2 haptic lives in the button's action (via
/// `BookmarkHaptics.commit`) so it only fires on a real tap — never when a
/// context menu steals the touch or the finger slides off.
struct BookmarkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressTracked(label: configuration.label, isPressed: configuration.isPressed)
    }

    private struct PressTracked<Label: View>: View {
        let label: Label
        let isPressed: Bool
        @GestureState private var touching = false

        var body: some View {
            let down = touching || isPressed
            label
                .scaleEffect(down ? 0.84 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.55), value: down)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: .infinity, maximumDistance: 40)
                        .updating($touching) { value, state, _ in state = value }
                )
                .onChange(of: touching) { _, now in
                    if now { BookmarkHaptics.pressDown() }
                }
                .onAppear { BookmarkHaptics.warmUp() }
        }
    }
}

extension ButtonStyle where Self == BookmarkButtonStyle {
    static var bookmark: BookmarkButtonStyle { BookmarkButtonStyle() }
}

extension View {
    /// SF Symbol bounce on the heart whenever the bookmark state flips —
    /// the visual counterpart of the stage-2 click.
    func bookmarkBounce(_ bookmarked: Bool) -> some View {
        symbolEffect(.bounce.up.byLayer, value: bookmarked)
    }
}
