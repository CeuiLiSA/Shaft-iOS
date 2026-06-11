import SwiftUI

@main
struct Shaft_iOSApp: App {
    init() {
        AppFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Holds the system launch screen's exact visual (LaunchBackground + centered
/// LaunchLogo) on screen briefly after first frame, then fades into the app.
private struct RootView: View {
    private static let splashHold: Duration = .seconds(0.8)
    private static let splashFade: TimeInterval = 0.3

    @State private var splashVisible = true
    @State private var splashRemoved = false

    var body: some View {
        ContentView()
            .overlay {
                if !splashRemoved {
                    ZStack {
                        Color(.launchBackground)
                            .ignoresSafeArea()
                        Image(.launchLogo)
                    }
                    .opacity(splashVisible ? 1 : 0)
                    .allowsHitTesting(splashVisible)
                    .accessibilityHidden(true)
                }
            }
            .task {
                try? await Task.sleep(for: Self.splashHold)
                withAnimation(.easeOut(duration: Self.splashFade)) {
                    splashVisible = false
                }
                try? await Task.sleep(for: .seconds(Self.splashFade))
                splashRemoved = true
            }
    }
}
