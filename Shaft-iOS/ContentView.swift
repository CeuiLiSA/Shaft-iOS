import SwiftUI

struct ContentView: View {
    @State private var onboarding = OnboardingStore()
    @State private var auth = AuthViewModel()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if !onboarding.hasUserConfigured {
                LanguageOnboardingView(store: onboarding) {
                    // language chosen — flow falls through to login
                }
                .transition(.opacity)
            } else if auth.token == nil {
                LoginView(auth: auth)
                    .transition(.opacity)
            } else {
                HomeView(auth: auth)
                    .transition(.opacity)
            }
        }
        .environment(onboarding)
        .environment(\.locale, onboarding.currentLocale)
        .onOpenURL { url in ReferralLinkStore.shared.receive(url) }
        .task(id: phase == .active ? auth.token?.user?.id : nil) {
            guard phase == .active, let uid = auth.token?.user?.id else { return }
            await ReferralActivityReporter.shared.active(uid: uid)
        }
        // Upstream crossFadeLanguagePageToLoginPage runs 380ms; the tunnel
        // keeps rendering behind both pages so only the content fades.
        .animation(.easeInOut(duration: 0.38), value: onboarding.hasUserConfigured)
        .animation(.easeInOut(duration: 0.38), value: auth.token != nil)
    }
}

#Preview { ContentView() }
