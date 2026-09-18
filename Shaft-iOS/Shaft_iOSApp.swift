import SwiftUI

@main
struct Shaft_iOSApp: App {
    init() {
        AppFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--referral-preview") {
                ReferralPreviewScreen()
            } else if ProcessInfo.processInfo.arguments.contains("--discover-social-preview") {
                DiscoverSocialPreview()
            } else { RootView() }
            #else
            RootView()
            #endif
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
            .task {
                // Retry durable account handoffs left by a rotated borrowed
                // refresh token before the next search needs that account.
                await BorrowedAccountReportOutbox.shared.flush()
                // Prime the per-account kill switch during cold start. Reads
                // remain non-blocking in the search path and use the cached
                // value while this refresh runs in the background.
                let uid = KeychainTokenStore.shared.load()?.user?.id ?? 0
                if uid > 0 {
                    _ = await BorrowedSearchRemoteConfig.shared.enabled(uid: uid)
                }
            }
    }
}
